use strict;
use warnings;
use Test::More;
use Test::Fake::HTTPD;
use JSON;
use Redis;

BEGIN { use_ok 'Shypper::SchemaConnected' }

my $template_a = '[% abc %]';

my $httpd = Test::Fake::HTTPD->new( timeout => 5, );

$httpd->run(
    sub {
        my $req = shift;

        if ( $req->uri->as_string eq '/abc' ) {
            return [ 200, [ 'Content-Type' => 'text/plain' ], [$template_a] ];
        }
        else {
            return [ 400, [ 'Content-Type' => 'text/plain' ], ['failed!'] ];
        }
    }
);

my $redis = Redis->new;
my $schema = GET_SCHEMA;

eval {
    $schema->txn_do(
        sub {
            my $cache_prefix = 'testing-myprefix' . rand.rand;

            my $ec = $schema->resultset('EmaildbConfig')->create(
                {
                    from                     => '"Testint" <testing@email.com>',
                    template_resolver_class  => 'Shypper::TemplateResolvers::HTTP',
                    template_resolver_config => encode_json(
                        {
                            base_url => $httpd->endpoint . '/',
                           }
                    ),
                    email_transporter_class => 'Email::Sender::Transport::Test'
                }
            );

            is( $ec->get_template('abc'), $template_a, 'template downloading works!' );


            die 'rollback';
        }
    );
};
die $@ unless $@ =~ /rollback/;
done_testing();
