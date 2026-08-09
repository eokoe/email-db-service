package Shypper::Daemon::ProcessQueue;
use Moo;
use strict;

use utf8;
use JSON;
use Shypper::SchemaConnected;
use Shypper::Logger;
use Shypper::TrapSignals;
use Shypper::ConfigBridge;
use Parallel::Prefork;
use Text::Xslate;
use MIME::Base64;
use Email::MIME;
use Email::Sender::Simple qw(sendmail);
use Encode;

use feature 'state';

my $xslate = Text::Xslate->new(
    syntax => 'TTerse',
    type   => 'html'
);

has 'schema' => (is => 'rw', lazy => 1, builder => \&GET_SCHEMA);
has 'logger' => (is => 'rw', lazy => 1, builder => \&get_logger);

has 'config_bridge' => (
    is      => 'rw',
    lazy    => 1,
    builder => sub {
        my ($self) = @_;
        Shypper::ConfigBridge->new(schema => $self->schema, logger => $self->logger);
    }
);

has 'EMAILDB_FETCH_ROWS' => (
    is      => 'ro',
    builder => sub {
        my $x = $ENV{EMAILDB_FETCH_ROWS} || 100;
        die 'invalid $ENV{EMAILDB_FETCH_ROWS}' unless $x =~ /^[0-9]+$/ && $x < 10000;
        return $x;
    }
);
has 'EMAILDB_MAX_WORKERS' => (
    is      => 'ro',
    builder => sub {
        my $x = $ENV{EMAILDB_MAX_WORKERS} || 1;
        die 'invalid $ENV{EMAILDB_MAX_WORKERS}' unless $x =~ /^[0-9]+$/ && $x < 100;

        return $x;
    }
);

has '_email_queue' => (
    is      => 'rw',
    builder => sub {
        shift->schema->resultset('EmaildbQueue');
    }
);

sub pending_jobs {
    my ($self, %opts) = @_;

    my @rows = $self->_email_queue->search(
        {

            'me.sent' => undef,
            '-or'     => [{'me.visible_after' => undef}, {'me.visible_after' => {'<=' => \'clock_timestamp()'}}],
        },
        {
            rows         => $opts{rows} ? $opts{rows} : $self->EMAILDB_FETCH_ROWS(),
            result_class => 'DBIx::Class::ResultClass::HashRefInflator',
            for          => \'update skip locked'
        }
    )->all;
    return @rows;
}

sub run_once {
    my ($self, %opts) = @_;

    $self->config_bridge->prewarm_configs();

    return $self->schema->txn_do(
        sub {

            my ($pending) = $self->pending_jobs(rows => 1);

            # no item on queue
            return -2 unless $pending;

            # ok
            return 1 if $self->_send_email($pending, 1);

            # nok
            return -1;
        }
    );

}

sub listen_queue {
    my ($self) = @_;

    my $logger = $self->logger;

    $self->config_bridge->prewarm_configs();

    my $pm = Parallel::Prefork->new(
        {
            max_workers  => $self->EMAILDB_MAX_WORKERS,
            trap_signals => {
                TERM => 'TERM',
                HUP  => 'TERM',
                USR1 => undef,
            }
        }
    );
    $logger->info("master listen_queue");

    my $sent_per_worker = $ENV{EXIT_WORKER_AFTER} ? $ENV{EXIT_WORKER_AFTER} : 999999;
    while (1) {
        my $signal = $pm->signal_received;
        if ($signal eq 'TERM') {
            $logger->info("master signal_received=TERM");
            exit(0);
        }
        $pm->start(
            sub {
                my $loop_times = 0;
                my $dbh;
                eval {
                    while (1) {

                        while (my $notify = $dbh && $dbh->pg_notifies) {
                            $loop_times = 0;
                        }

                        if ($loop_times <= 0) {
                            ON_TERM_WAIT;

                            $self->schema->txn_do(
                                sub {
                                    my @pendings = $self->pending_jobs();
                                    my @success;

                                    for my $email (@pendings) {

                                        $sent_per_worker--;
                                        eval { $self->_send_email($email, 0) };
                                        if ($@) {
                                            $self->_email_queue->find($email->{id})->update(
                                                {
                                                    sent       => 0,
                                                    updated_at => \'clock_timestamp()',
                                                    errmsg     => "$@"
                                                }
                                            );
                                        }
                                        else {
                                            push @success, $email->{id};
                                        }

                                    }

                                    $self->_email_queue->search({'me.id' => {'in' => \@success}})->update(
                                        {
                                            sent       => 1,
                                            updated_at => \'clock_timestamp()',
                                        }
                                    ) if @success;

                                }
                            );

                            # only listen after a query, ensuring that we are connected to database
                            if (!$dbh) {
                                $dbh = $self->schema->storage->dbh;
                                $logger->info("LISTEN newemail");
                                $dbh->do("LISTEN newemail");
                            }

                            ON_TERM_EXIT;
                            EXIT_IF_ASKED;

                            if ($ENV{EXIT_WORKER_AFTER} && $sent_per_worker < 0) {
                                $logger->info(
                                    sprintf "Worker is exiting after %s processed emails",
                                    $ENV{EXIT_WORKER_AFTER}
                                );
                                exit(0);
                            }
                        }

                        # sleep for 0.1 sec
                        select undef, undef, undef, 0.1;

                        # 1/0.1 = 10 = 1 sec, force a query each 60 seconds
                        $loop_times = 0 if ++$loop_times == 10 * 60;
                    }
                };

                $logger->error("Fatal error: $@") if $@;
                sleep 1;
            }
        );

    }    # while 1

    $logger->info("wait_all_children");
    $pm->wait_all_children();

}

# '0', 'no', 'false', 'off' and the empty string turn a flag off, anything else on
sub _flag_is_on {
    my ($v) = @_;

    return 0 unless defined $v;
    return length("$v") && "$v" !~ /^(?:0|no|false|off)$/i ? 1 : 0;
}

sub _env_flag {
    my ( $name, $default ) = @_;

    return defined $ENV{$name} ? _flag_is_on( $ENV{$name} ) : $default;
}

# a json column holds correct utf8, so this is the default now. Only a database
# that was filled with double-encoded variables needs VARIABLES_JSON_IS_UTF8=0.
sub _variables_json_is_utf8 { _env_flag( 'VARIABLES_JSON_IS_UTF8', 1 ) }

# the text/plain alternative is generated for every e-mail unless this row, or
# the whole daemon, asks for html only
sub _generate_text {
    my ($row_value) = @_;

    return _flag_is_on($row_value) if defined $row_value;

    return _env_flag( 'USE_TXT_DEFAULT', 1 );
}

sub _send_email {
    my ($self, $row, $update_row) = @_;

    $self->logger->debug("${\$row->{id}} preparing to send '${\$row->{to}}' '${\$row->{subject}}'");
    my $ok   = 0;
    my $step = 'prepare';
    eval {

        my $config = $self->config_bridge->get_config($row->{config_id});
        my $vars
          = $row->{variables}
          ? (_variables_json_is_utf8() ? from_json($row->{variables}) : decode_json($row->{variables}))
          : {};
        my $reply              = delete $vars->{'reply-to'};
        my $cc                 = delete $vars->{':cc'};
        my $bcc                = delete $vars->{':bcc'};
        my $gen_text           = _generate_text( delete $vars->{':txt'} );
        my $attachments_config = delete $vars->{'attachments_config'};

        # config-wide variables (polled from variables_url at boot) always win over
        # the row ones on their own namespace, so an e-mail cannot forge them
        my $config_variables = $config->config_variables;
        $vars->{ $config->variables_namespace } = $config_variables if %$config_variables;

        my $base_template = $config->get_template($row->{template})
          || $self->logger->logcroak("Template ${\$row->{template}} not found!");

        $step = 'render_string';
        my $body = $xslate->render_string($base_template, $vars,);

        if ($gen_text) {
            $step = 'text_from_html';

            $gen_text = &_text_from_html($body);
        }

        $self->logger->debug("Cc $cc")          if $cc;
        $self->logger->debug("reply-to $reply") if $reply;
        $self->logger->debug("Bcc $bcc")        if $bcc;

        my $html_part = Email::MIME->create(
            attributes => {
                content_type => "text/html",
                charset      => "UTF-8",
                encoding     => 'quoted-printable',
            },
            body_str => $body,
        );

        my $body_part = $html_part;

        if ($gen_text) {
            my $text_part = Email::MIME->create(
                attributes => {
                    content_type => "text/plain",
                    charset      => "UTF-8",
                    encoding     => 'quoted-printable',
                },
                body_str => $gen_text,
            );

            # two parts on create(), so Email::MIME generates the boundary itself;
            # nesting it later inside a one-part message would drop that boundary
            $body_part = Email::MIME->create(
                attributes => {content_type => 'multipart/alternative'},
                parts      => [$text_part, $html_part],
            );
        }

        my @attachments;

        if ($attachments_config) {
            my $conf = $attachments_config;

            foreach my $attachment (@{$conf->{files}}) {
                my $binary = decode_base64($attachment->{content});

                push @attachments, Email::MIME->create(
                    attributes => {
                        filename     => $attachment->{name}         || 'attachment',
                        content_type => $attachment->{content_type} || 'application/octet-stream',
                        encoding     => "base64",
                        name         => $attachment->{name} || 'attachment',

                        # 'inline' is Email::MIME's default and what this service
                        # always sent; set "disposition":"attachment" per file to
                        # get the paperclip instead of an inlined part
                        $attachment->{disposition} ? (disposition => $attachment->{disposition}) : (),
                    },
                    body => $binary,
                );
            }


        }

        my $compose = sub {
            my (@headers) = @_;

            return Email::MIME->create(
                header_str => [@headers],
                attributes => {content_type => 'multipart/mixed'},
                parts      => [$body_part, @attachments],
            ) if @attachments;

            # without attachments the body part *is* the message: it is cloned so
            # each copy gets its own headers, keeping its content-type intact
            my $msg = Email::MIME->new($body_part->as_string);
            while (my ($name, $value) = splice(@headers, 0, 2)) {
                $msg->header_str_set($name, $value);
            }
            return $msg;
        };

        $step = 'Email::MIME create';
        my $email = $compose->(
            From    => $config->from_env(),
            To      => $row->{to},
            Subject => $row->{subject},
            $reply ? ('Reply-To' => $reply) : (),
            $cc    ? ('Cc'       => $cc)    : (),
        );

        $step = 'send message';

        sendmail($email->as_string, {transport => $config->email_transporter()});
        $ok = 1;

        if ($bcc) {
            my $email = $compose->(
                From    => $config->from_env(),
                To      => $bcc,
                Subject => 'BCC: ' . $row->{subject} . ': To ' . $row->{to} . ($cc ? ' Copy ' . $cc : ''),
                $reply ? ('Reply-To' => $reply) : (),
            );

            $step = 'send message bcc';

            eval { sendmail($email->as_string, {transport => $config->email_transporter()}) };
            if ($@) {
                $self->logger->error("BCC ${\$row->{id}} Errored at $step with msg $@");
            }

        }


    };

    if ($@) {
        $self->_email_queue->find($row->{id})->update(
            {
                sent       => 0,
                updated_at => \'clock_timestamp()',
                errmsg     => "$@"
            }
        ) if $update_row;

        $self->logger->error("${\$row->{id}} Errored at $step with msg $@");
        die "$@" unless $update_row;
    }
    else {
        $self->_email_queue->find($row->{id})->update(
            {
                sent       => 1,
                updated_at => \'clock_timestamp()'
            }
        ) if $update_row;
        $self->logger->info("${\$row->{id}} succeed to next hop");
    }

    return $ok;
}

sub _text_from_html {
    my $html = shift;

    require HTML::FormatText::WithLinks;

    state $f = HTML::FormatText::WithLinks->new(
        before_link => '',
        after_link  => ' ( %l )',
        footnote    => ''
    );

    # characters, not bytes: Email::MIME encodes it from body_str + charset
    return $f->parse($html);
}

1;
