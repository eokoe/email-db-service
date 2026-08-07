use strict;
use warnings;
use Test::More;
use Test::Fake::HTTPD;
use MIME::Base64;
use Email::MIME;
use JSON;

BEGIN { use_ok 'Shypper::SchemaConnected' }
BEGIN { use_ok 'Shypper::Daemon::ProcessQueue' }

my $template = '<html><body><a href="https://example.com/x">hello</a> [% name %]</body></html>';

my $httpd = Test::Fake::HTTPD->new( timeout => 5 );
$httpd->run( sub { [ 200, [ 'Content-Type' => 'text/plain' ], [$template] ] } );

my $schema = GET_SCHEMA;
my $daemon = Shypper::Daemon::ProcessQueue->new( schema => $schema );

# every message that leaves this service must be parseable by a real MIME parser:
# a multipart without a boundary parameter is silently dropped by mail servers
sub check_multipart {
    my ( $email, $type, $name ) = @_;

    my $ct = $email->header('Content-Type');
    like( $ct, qr{^\Q$type\E}, "$name: content-type is $type" );
    like( $ct, qr{boundary=}, "$name: boundary is on the content-type header" );

    my @parts = $email->parts;
    cmp_ok( scalar(@parts), '>', 1, "$name: parser found the parts back" );

    return @parts;
}

eval {
    $schema->txn_do(
        sub {
            my $ec = $schema->resultset('EmaildbConfig')->create(
                {
                    from                     => '"Test" <from@email.com>',
                    template_resolver_class  => 'Shypper::TemplateResolvers::HTTP',
                    template_resolver_config => encode_json(
                        { base_url => $httpd->endpoint . '/', cache_prefix => 'testing-mime' . rand . rand }
                    ),
                    email_transporter_class => 'Email::Sender::Transport::Test',
                }
            );

            my $send = sub {
                my ($vars) = @_;

                $schema->resultset('EmaildbQueue')->create(
                    {
                        to        => '<to@email.com>',
                        template  => 'tpl',
                        subject   => 'mime',
                        config_id => $ec->id,
                        variables => encode_json($vars),
                    }
                );
                is $daemon->run_once, 1, 'sent';

                # shift_deliveries hands over one delivery per call
                my $conf = $daemon->config_bridge->get_config( $ec->id );
                my @sent;
                while ( my $delivery = $conf->email_transporter->shift_deliveries ) {
                    push @sent, Email::MIME->new( $delivery->{email}->as_string );
                }
                return @sent;
            };

            # ---- html only -------------------------------------------------

            my ($html) = $send->( { name => 'x' } );
            like( $html->header('Content-Type'), qr{^text/html}, 'html only: single text/html message' );
            like( $html->body_str, qr{hello</a> x}, 'html only: body' );
            ok( $html->header('Date'),         'html only: has Date' );
            ok( $html->header('MIME-Version'), 'html only: has MIME-Version' );

            # ---- :txt ------------------------------------------------------

            my ($alt) = $send->( { name => 'x', ':txt' => 1 } );
            my @parts = check_multipart( $alt, 'multipart/alternative', ':txt' );
            like( $parts[0]->header('Content-Type'), qr{^text/plain}, ':txt: first part is the text version' );
            like( $parts[1]->header('Content-Type'), qr{^text/html},  ':txt: second part is the html version' );
            like( $parts[0]->body_str, qr/hello \( https/, ':txt: text part was generated from the html, with the links' );

            # ---- attachment -------------------------------------------------

            my ($mixed) = $send->(
                {
                    name               => 'x',
                    attachments_config => {
                        files => [ { name => 'a.txt', content_type => 'text/plain', content => encode_base64('file body'), disposition => 'attachment' } ]
                    }
                }
            );
            @parts = check_multipart( $mixed, 'multipart/mixed', 'attachment' );
            like( $parts[0]->header('Content-Type'), qr{^text/html}, 'attachment: first part is the body' );
            like( $parts[1]->header('Content-Type'), qr{^text/plain}, 'attachment: second part is the file' );
            like( $parts[1]->body, qr/file body/, 'attachment: content' );
            like( $parts[1]->header('Content-Disposition'), qr/^attachment/, 'attachment: disposition is honoured' );

            # ---- :txt + attachment -------------------------------------------

            my ($both) = $send->(
                {
                    name               => 'x',
                    ':txt'             => 1,
                    attachments_config => {
                        files => [ { name => 'a.txt', content_type => 'text/plain', content => encode_base64('file body') } ]
                    }
                }
            );
            @parts = check_multipart( $both, 'multipart/mixed', 'both' );
            check_multipart( $parts[0], 'multipart/alternative', 'both: nested body' );

            # ---- bcc gets its own, equally valid, copy ------------------------

            my @sent = $send->( { name => 'x', ':txt' => 1, ':bcc' => '<bcc@email.com>' } );
            is( scalar(@sent), 2, 'bcc: two messages left' );
            check_multipart( $sent[1], 'multipart/alternative', 'bcc copy' );
            like( $sent[1]->header('To'), qr/bcc\@email\.com/, 'bcc: addressed to the bcc' );

            die 'rollback';
        }
    );
};
die $@ unless $@ =~ /rollback/;
done_testing();
