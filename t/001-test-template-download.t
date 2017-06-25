use strict;
use warnings;
use Test::More;
use Test::Fake::HTTPD;

BEGIN { use_ok 'Shypper::SchemaConnected' }


my $httpd = Test::Fake::HTTPD->new( timeout => 5, );

$httpd->run(
    sub {
        my $req = shift;

        use DDP; p $req;

        return [ 200, [ 'Content-Type' => 'text/plain' ], ['Hello World'] ];
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

            use DDP; p $ec->get_template('abc');


            die 'rollback';
        }
    );
};
die $@ if $@ =~ /^rollback/;

done_testing();
