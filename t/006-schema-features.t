use strict;
use warnings;
use Test::More;
use JSON;

BEGIN { use_ok 'Shypper::SchemaConnected' }
BEGIN { use_ok 'Shypper::SchemaFeatures' }
BEGIN { use_ok 'Shypper::Daemon::ProcessQueue' }

# A database copied before `sqitch deploy` ran does not have the 0001 columns.
# The service has to keep sending e-mail on it, with the webhook simply off.

my $schema = GET_SCHEMA;

ok( has_schema_feature('config_variables'), 'feature is on against an up to date database' );

eval {
    $schema->txn_do(
        sub {
            # postgres ddl is transactional, so this whole downgrade is undone below
            $schema->storage->dbh_do(
                sub {
                    my ( undef, $dbh ) = @_;

                    $dbh->do('ALTER TABLE emaildb_config DROP COLUMN variables_url, DROP COLUMN variables_url_config');
                }
            );

            Shypper::SchemaFeatures::_reset_schema_features();
            detect_schema_features($schema);

            ok( !has_schema_feature('config_variables'), 'feature is off when the columns are missing' );
            ok(
                !$schema->source('EmaildbConfig')->has_column('variables_url'),
                'the column is gone from the result source, so nothing selects it'
            );

            my $cfg = $schema->resultset('EmaildbConfig')->create(
                {
                    from                     => '"Emaildb" <from@email.com>',
                    template_resolver_class  => 'Shypper::TemplateResolvers::HTTP',
                    template_resolver_config => encode_json( { base_url => 'http://127.0.0.1:1/' } ),
                    email_transporter_class  => 'Email::Sender::Transport::Test',
                    email_transporter_config => encode_json( {} ),
                }
            );

            is_deeply( $cfg->config_variables, {}, 'no config variables and no crash' );
            is_deeply( $cfg->variables_options, {}, 'no options either' );
            is( $cfg->variables_namespace, 'cfg', 'namespace falls back to the default' );

            ok( $cfg->template_resolver,  'the template resolver still builds' );
            ok( $cfg->email_transporter,  'the transporter still builds' );
            ok( $schema->resultset('EmaildbConfig')->find( $cfg->id ), 'and the config is still selectable' );

            die "rollback\n";
        }
    );
};
like( $@, qr/rollback/, 'downgrade rolled back' );

subtest 'VARIABLES_JSON_IS_UTF8 defaults to on' => sub {
    my $is_utf8 = \&Shypper::Daemon::ProcessQueue::_variables_json_is_utf8;

    local %ENV = %ENV;

    delete $ENV{VARIABLES_JSON_IS_UTF8};
    ok( $is_utf8->(), 'unset means the database holds correct utf8' );

    $ENV{VARIABLES_JSON_IS_UTF8} = 1;
    ok( $is_utf8->(), 'explicit 1' );

    for my $off (qw/0 no false off/) {
        $ENV{VARIABLES_JSON_IS_UTF8} = $off;
        ok( !$is_utf8->(), "'$off' opts out for legacy double-encoded rows" );
    }

    $ENV{VARIABLES_JSON_IS_UTF8} = '';
    ok( !$is_utf8->(), 'empty opts out too, that was the old documented default' );
};

done_testing;
