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
use Email::MIME::CreateHTML;
use Email::Sender::Simple qw(sendmail);

my $xslate = Text::Xslate->new(
    syntax => 'TTerse',
    type   => 'html'
);

has 'schema' => ( is => 'rw', lazy => 1, builder => \&GET_SCHEMA );
has 'logger' => ( is => 'rw', lazy => 1, builder => \&get_logger );

has 'config_bridge' => (
    is      => 'rw',
    lazy    => 1,
    builder => sub {
        my ($self) = @_;
        Shypper::ConfigBridge->new( schema => $self->schema, logger => $self->logger );
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
    my ( $self, %opts ) = @_;

    my @rows = $self->_email_queue->search(
        {

            'me.sent' => undef,
            '-or'     => [ { 'me.visible_after' => undef }, { 'me.visible_after' => { '<=' => \'clock_timestamp()' } } ],
        },
        {
            rows => $opts{rows} ? $opts{rows} : $self->EMAILDB_FETCH_ROWS(),
            result_class => 'DBIx::Class::ResultClass::HashRefInflator',
            for          => \'update skip locked'
        }
    )->all;
    return @rows;
}

sub run_once {
    my ( $self, %opts ) = @_;

    $self->config_bridge->prewarm_configs();

    return $self->schema->txn_do(
        sub {

            my ($pending) = $self->pending_jobs( rows => 1 );

            # no item on queue
            return -2 unless $pending;

            # ok
            return 1 if $self->_send_email( $pending, 1 );

            # nok
            return -1;
        }
    );

}

sub listen_queue {
    my ($self) = @_;

    my $async  = $self->afurl;
    my $logger = $self->logger;
    my $dbh    = $self->schema->storage->dbh;

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

    while ( $pm->signal_received ne 'TERM' ) {
        $pm->start(
            sub {
                $logger->info("LISTEN newemail");
                $dbh->do("LISTEN newemail");
                my $loop_times = 0;
                eval {
                    while (1) {

                        while ( my $notify = $dbh->pg_notifies ) {
                            $loop_times = 0;
                        }

                        if ( $loop_times == 0 ) {
                            ON_TERM_WAIT;

                            $self->schema->txn_do(
                                sub {
                                    my @pendings = $self->pending_jobs();
                                    my @success;

                                    for my $email (@pendings) {

                                        eval { $self->_send_email($_) };
                                        if ($@) {
                                            $self->_email_queue->find( $email->{id} )->update(
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

                                    $self->_email_queue->search( { 'me.id' => { 'in' => \@success } } )->update(
                                        {
                                            sent       => 1,
                                            updated_at => \'clock_timestamp()',
                                        }
                                    );

                                }
                            );

                            ON_TERM_EXIT;
                            EXIT_IF_ASKED;
                        }

                        # sleep for 0.1 sec
                        select undef, undef, undef, 0.1;

                        # 1/0.1 = 10 = 1 sec, force a query each 60 seconds
                        $loop_times = 0 if ++$loop_times == 10 * 60;
                    }
                };

                $logger->fatal("Fatal error: $@") if $@;
            }
        );

    }

    $pm->wait_all_children();

}

sub _send_email {
    my ( $self, $row, $update_row ) = @_;

    $self->logger->debug("${\$row->{id}} preparing to send '${\$row->{to}}' '${\$row->{subject}}'");
    my $ok   = 0;
    my $step = 'prepare';
    eval {
        my $config = $self->config_bridge->get_config( $row->{config_id} );
        my $vars = $row->{variables} ? decode_json( $row->{variables} ) : {};

        my $base_template = $config->get_template( $row->{template} )
          || $self->logger->logcroak("Template ${\$row->{template}} not found!");

        $step = 'rendering';
        my $body = $xslate->render_string( $base_template, $vars, );

        $step = 'Email::MIME';
        my $email = Email::MIME->create_html(
            header => [
                To      => $row->{to},
                From    => $config->from(),
                Subject => $row->{subject},
            ],
            body => $body,
        );

        $step = 'sending message';

        sendmail( $email, { transport => $config->email_transporter() } );
        $ok = 1;
    };

    if ($@) {
        $self->_email_queue->find( $row->{id} )->update(
            {
                sent       => 0,
                updated_at => \'clock_timestamp()',
                errmsg     => "$@"
            }
        ) if $update_row;

        $self->logger->error("${\$row->{id}} Errored $step $@");
        die "$@" unless $update_row;
    }
    else {
        $self->_email_queue->find( $row->{id} )->update(
            {
                sent       => 1,
                updated_at => \'clock_timestamp()'
            }
        ) if $update_row;
        $self->logger->info("${\$row->{id}} succeed to next hop");
    }

    return $ok;
}

1;
