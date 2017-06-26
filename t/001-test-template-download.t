use strict;
use warnings;
use Test::More;
use Test::Fake::HTTPD;

BEGIN { use_ok 'Shypper::SchemaConnected' }

my $template_a = 'This is [% abc %] template!';

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

my $schema = GET_SCHEMA;

eval {
    $schema->txn_do(
        sub {
            my $ec = $schema->resultset('EmaildbConfig')->create(
                {
                    from               => '"Testint" <testing@email.com>',
                    html_server        => $httpd->endpoint . '/',
                    html_authorization => '{}'
                }
            );

            my $ok = $ec->get_template('abc');
            is( $ok, $template_a, 'template downloading works!' );

            eval { $ec->get_template('xabc') };
            like( $@, qr/template failed/, 'template not loaded' );

            die 'rollback';
        }
    );
};
die $@ unless $@ =~ /rollback/;
done_testing();
