use strict;
use warnings;
use Test::More;

BEGIN { use_ok 'Shypper::SchemaConnected' }

BEGIN { use_ok 'Shypper::API::Schedule' }

my $api = Shypper::API::Schedule->new;

is($api->_http_request_rs->count, '0', 'good, running tests on a empty database!');

done_testing();
