use strict;
use warnings;
use Test::More;
use Test::Fake::HTTPD;
use JSON;

BEGIN { use_ok 'Shypper::SchemaConnected' }
BEGIN { use_ok 'Shypper::Daemon::ProcessQueue' }

my $template = '<html><body>[% cfg.site_url %]/u/[% user_id %] [% cfg.support %]</body></html>';

my $httpd = Test::Fake::HTTPD->new( timeout => 5 );

$httpd->run(
    sub {
        my $req = shift;
        my $uri = $req->uri->as_string;

        if ( $uri eq '/tpl' ) {
            return [ 200, [ 'Content-Type' => 'text/plain' ], [$template] ];
        }
        elsif ( $uri eq '/vars' ) {
            return [
                200,
                [ 'Content-Type' => 'application/json' ],
                [ encode_json( { site_url => 'https://app.example.com', poll_auth => $req->headers->header('Authorization') // '' } ) ]
            ];
        }
        elsif ( $uri eq '/not-a-hash' ) {
            return [ 200, [ 'Content-Type' => 'application/json' ], ['[1,2,3]'] ];
        }
        else {
            return [ 500, [ 'Content-Type' => 'text/plain' ], ['failed!'] ];
        }
    }
);

my $endpoint = $httpd->endpoint;

# the env is only readable from the *config* side
local %ENV = (
    %ENV,
    EMAILDB_TEST_BASE_URL => "$endpoint/",
    EMAILDB_TEST_TOKEN    => 'tok-123',
);

my $schema = GET_SCHEMA;
my $daemon = Shypper::Daemon::ProcessQueue->new( schema => $schema );

eval {
    $schema->txn_do(
        sub {
            my $make_config = sub {
                my (%args) = @_;

                return $schema->resultset('EmaildbConfig')->create(
                    {
                        from                     => '"Emaildb ${EMAILDB_TEST_TOKEN}" <from@email.com>',
                        template_resolver_class  => 'Shypper::TemplateResolvers::HTTP',
                        template_resolver_config => encode_json(
                            {
                                base_url      => '${EMAILDB_TEST_BASE_URL}',
                                cache_timeout => 0,
                                cache_prefix  => 'testing-cfgvars' . rand . rand,
                            }
                        ),
                        email_transporter_class => 'Email::Sender::Transport::Test',
                        %args,
                    }
                );
            };

            # ---- env substitution on the config columns -------------------

            my $ec = $make_config->(
                variables_url        => '${EMAILDB_TEST_BASE_URL}vars',
                variables_url_config => encode_json(
                    {
                        headers  => [ 'Authorization' => 'Bearer ${EMAILDB_TEST_TOKEN}' ],
                        defaults => { support => 'help@example.com', site_url => 'https://never-used.example.com' },
                    }
                ),
            );

            is( $ec->template_resolver->base_url, "$endpoint/", 'template_resolver_config expanded ${ENV}' );
            is( $ec->from_env, '"Emaildb tok-123" <from@email.com>', 'from expanded ${ENV}' );
            is( $ec->from, '"Emaildb ${EMAILDB_TEST_TOKEN}" <from@email.com>', 'the stored column is untouched' );

            # ---- the variables webhook ------------------------------------

            my $cfg_vars = $ec->config_variables;
            is( $cfg_vars->{site_url},  'https://app.example.com', 'webhook variable was polled' );
            is( $cfg_vars->{support},   'help@example.com',        'defaults fill what the webhook omitted' );
            is( $cfg_vars->{poll_auth}, 'Bearer tok-123',          'headers expanded ${ENV} on the poll request' );
            is( $ec->variables_namespace, 'cfg', 'default namespace' );

            # ---- rendering -------------------------------------------------

            is $daemon->run_once, -2, 'no item on queue';

            $schema->resultset('EmaildbQueue')->create(
                {
                    to        => '<to@email.com>',
                    template  => 'tpl',
                    subject   => 'config variables',
                    config_id => $ec->id,
                    variables => encode_json( { user_id => 42 } ),
                }
            );

            is $daemon->run_once, 1, 'sent';

            my $conf = $daemon->config_bridge->get_config( $ec->id );
            my ($delivery) = $conf->email_transporter->shift_deliveries;

            if ( ok( $delivery, 'defined $delivery' ) ) {
                my $str = $delivery->{email}->as_string;
                like( $str, qr{https://app\.example\.com/u/42}, 'cfg.* and row variables render together' );
                like( $str, qr{help\@example\.com},             'default variable rendered' );
                like( $str, qr{Emaildb tok-123},                'From header used the expanded value' );
            }

            # ---- an e-mail cannot read the environment ---------------------

            $schema->resultset('EmaildbQueue')->create(
                {
                    to        => '<to@email.com>',
                    template  => 'tpl',
                    subject   => 'no env leak',
                    config_id => $ec->id,
                    variables => encode_json( { user_id => '${EMAILDB_TEST_TOKEN}' } ),
                }
            );

            is $daemon->run_once, 1, 'sent';
            ($delivery) = $conf->email_transporter->shift_deliveries;
            my $str = $delivery->{email}->as_string;
            unlike( $str, qr{/u/tok-123}, 'row variables are never env-expanded' );
            like( $str, qr{/u/\$\{EMAILDB_TEST_TOKEN\}}, 'the placeholder is rendered as plain text' );

            # ---- a config that forges the namespace from the row ------------

            $schema->resultset('EmaildbQueue')->create(
                {
                    to        => '<to@email.com>',
                    template  => 'tpl',
                    subject   => 'forged cfg',
                    config_id => $ec->id,
                    variables => encode_json( { user_id => 1, cfg => { site_url => 'https://evil.example.com' } } ),
                }
            );

            is $daemon->run_once, 1, 'sent';
            ($delivery) = $conf->email_transporter->shift_deliveries;
            unlike( $delivery->{email}->as_string, qr{evil\.example\.com}, 'row cannot override the cfg namespace' );

            # ---- custom namespace ------------------------------------------

            my $ns = $make_config->(
                variables_url        => '${EMAILDB_TEST_BASE_URL}vars',
                variables_url_config => encode_json( { namespace => 'site' } ),
            );
            is( $ns->variables_namespace, 'site', 'namespace is configurable' );
            is( $ns->config_variables->{site_url}, 'https://app.example.com', 'polled under a custom namespace' );

            # ---- no url at all ----------------------------------------------

            my $none = $make_config->();
            is_deeply( $none->config_variables, {}, 'no variables_url means no config variables' );

            # ---- failures ----------------------------------------------------

            my $broken = $make_config->( variables_url => '${EMAILDB_TEST_BASE_URL}nope' );
            eval { $broken->config_variables };
            like( $@, qr/Cannot poll .+variables_url/, 'a failing webhook dies at boot by default' );

            my $not_hash = $make_config->( variables_url => '${EMAILDB_TEST_BASE_URL}not-a-hash' );
            eval { $not_hash->config_variables };
            like( $@, qr/json object/, 'webhook must answer an object' );

            my $optional = $make_config->(
                variables_url        => '${EMAILDB_TEST_BASE_URL}nope',
                variables_url_config => encode_json( { required => JSON::false, defaults => { support => 'fallback@example.com' } } ),
            );
            is_deeply(
                $optional->config_variables,
                { support => 'fallback@example.com' },
                'required=false falls back to the defaults'
            );

            my $missing_env = $make_config->( variables_url => '${EMAILDB_NOT_SET_ANYWHERE}vars' );
            eval { $missing_env->config_variables };
            like( $@, qr/EMAILDB_NOT_SET_ANYWHERE/, 'a missing env var is a boot error, naming the variable' );

            die 'rollback';
        }
    );
};
die $@ unless $@ =~ /rollback/;
done_testing();
