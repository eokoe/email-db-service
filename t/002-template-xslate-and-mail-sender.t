use strict;
use warnings;
use Test::More;
use Test::Fake::HTTPD;
use JSON;
use Redis;

BEGIN { use_ok 'Shypper::SchemaConnected' }
BEGIN { use_ok 'Shypper::Daemon::ProcessQueue' }

my $template_a = '<html><body>[% abc %]</body></html>';

my $httpd = Test::Fake::HTTPD->new( timeout => 5, );

$httpd->run(
    sub {
        my $req = shift;

        if ( $req->uri->as_string eq '/txtxt' ) {
            return [ 200, [ 'Content-Type' => 'text/plain' ], [$template_a] ];
        }
        else {
            return [ 400, [ 'Content-Type' => 'text/plain' ], ['failed!'] ];
        }
    }
);

my $schema = GET_SCHEMA;
my $daemon = Shypper::Daemon::ProcessQueue->new( schema => $schema );

eval {
    $schema->txn_do(
        sub {
            my $cache_prefix = 'testing-myprefix' . rand . rand;

            my $ec = $schema->resultset('EmaildbConfig')->create(
                {
                    from                     => '"Testint" <from@email.com>',
                    template_resolver_class  => 'Shypper::TemplateResolvers::HTTP',
                    template_resolver_config => encode_json(
                        {
                            base_url => $httpd->endpoint . '/',
                        }
                    ),
                    email_transporter_class => 'Email::Sender::Transport::Test'
                }
            );

            is $daemon->run_once, -2, 'no item on queue';
            my $rand      = 'this is a ' . rand . ' text!';
            my $the_email = $schema->resultset('EmaildbQueue')->create(
                {
                    to        => '"TO EMAIL" <to@email.com>',
                    template  => 'txtxt',
                    subject   => 'this is a test subject!',
                    config_id => $ec->id,
                    variables => encode_json(
                        {
                            abc => $rand
                        }
                    )
                }
            );

            is $daemon->run_once, 1, 'ok';

            my $conf = $daemon->config_bridge->get_config( $ec->id );

            my ($delivery) = $conf->email_transporter->deliveries;
            if ( ok( $delivery, 'defined $delivery' ) ) {
                my $xx = qq($rand);
                like( $delivery->{email}->as_string, qr(.+$xx.+), 'text match' );

                is( $delivery->{successes}[0], 'to@email.com', 'is successes' );
            }

            is $daemon->run_once, -2, 'no item after running';

            die 'rollback';
        }
    );
};
die $@ unless $@ =~ /rollback/;
done_testing();
