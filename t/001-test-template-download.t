use strict;
use warnings;
use Test::More;
use Test::Fake::HTTPD;
use JSON;
use Redis;

BEGIN { use_ok 'Shypper::SchemaConnected' }

my $redis = Redis->new;
my $template_a = 'This is [% abc %] template!';

my $httpd = Test::Fake::HTTPD->new( timeout => 5, );

$httpd->run(
    sub {
        my $req = shift;

        if ( $req->uri->as_string eq '/abc' ) {
            return [ 200, [ 'Content-Type' => 'text/plain' ], [$template_a] ];
        }
        elsif ( $req->uri->as_string eq '/header' ) {
            return [ 200, [ 'Content-Type' => 'text/plain' ], [ $req->headers->header('SomeHeader') ] ];
        }
        elsif ( $req->uri->as_string eq '/agent' ) {
            return [ 200, [ 'Content-Type' => 'text/plain' ], [ $req->headers->user_agent ] ];
        }
        else {
            return [ 400, [ 'Content-Type' => 'text/plain' ], ['failed!'] ];
        }
    }
);

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

                            cache_timeout => 10,
                            cache_prefix  => $cache_prefix,
                            headers       => [ 'SomeHeader' => '123' ],
                            furl_opts     => {
                                agent => 'otheragent',
                            }
                        }
                    ),
                    email_transporter_class => 'Email::Sender::Transport::Test'

                }
            );


            my (@anykey) = $redis->keys($cache_prefix .'*');
            is(scalar @anykey, 0, 'no keys on redis yet');

            is( $ec->get_template('abc'), $template_a, 'template downloading works!' );

            (@anykey) = $redis->keys($cache_prefix .'*');
            is(scalar @anykey, 1, 'one key on redis!');
            ok ( $redis->ttl( $anykey[0] ) <= 10, 'less than 10 seconds to live' );

            is( $ec->get_template('header'), '123',        'header option is working' );
            is( $ec->get_template('agent'),  'otheragent', 'agent option is working' );

            eval { $ec->get_template('xabc') };
            like( $@, qr/template failed/, 'template not loaded' );

            die 'rollback';
        }
    );
};
die $@ unless $@ =~ /rollback/;
done_testing();
