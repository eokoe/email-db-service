use strict;
use warnings;
use Test::More;
use JSON;

BEGIN { use_ok 'Shypper::EnvSubst', qw/env_subst env_subst_deep/ }

local %ENV = (
    SMTP_PASS => 's3cr3t',
    BASE_URL  => 'https://templates.example.com/',
    EMPTY     => '',
);

is( env_subst('plain string'),      'plain string',      'string without placeholder is untouched' );
is( env_subst(undef),               undef,               'undef is untouched' );
is( env_subst('${SMTP_PASS}'),      's3cr3t',            'single placeholder' );
is( env_subst('x-${SMTP_PASS}-y'),  'x-s3cr3t-y',        'placeholder inside a string' );
is( env_subst('${BASE_URL}tpl/'),   'https://templates.example.com/tpl/', 'url prefix' );
is( env_subst('${SMTP_PASS}${BASE_URL}'), 's3cr3t' . 'https://templates.example.com/', 'two placeholders' );

is( env_subst('${MISSING:-fallback}'), 'fallback', 'default is used when unset' );
is( env_subst('${EMPTY:-fallback}'),   'fallback', 'default is used when set but empty' );
is( env_subst('${SMTP_PASS:-fallback}'), 's3cr3t', 'default is ignored when set' );
is( env_subst('${MISSING:-}'),         '',         'empty default is allowed' );
is( env_subst('${MISSING:-http://a/b?c=1}'), 'http://a/b?c=1', 'default may contain punctuation' );

is( env_subst('$${SMTP_PASS}'), '${SMTP_PASS}', '$$ escapes the expansion' );

eval { env_subst('${MISSING}') };
like( $@, qr/\$\{MISSING\} used but \$ENV\{MISSING\} is unset or empty/, 'dies when unset' );

eval { env_subst('${EMPTY}') };
like( $@, qr/\$ENV\{EMPTY\} is unset or empty/, 'dies when set but empty' );

eval { env_subst( '${MISSING}', context => 'emaildb_config.id=7 email_transporter_config' ) };
like( $@, qr/in emaildb_config\.id=7 email_transporter_config/, 'error tells which config is broken' );

# deep

is_deeply(
    env_subst_deep(
        {
            host          => 'smtp.example.com',
            sasl_password => '${SMTP_PASS}',
            port          => 587,
            headers       => [ 'authorization', 'Bearer ${SMTP_PASS}' ],
            nested        => { a => '${MISSING:-b}' },
        }
    ),
    {
        host          => 'smtp.example.com',
        sasl_password => 's3cr3t',
        port          => 587,
        headers       => [ 'authorization', 'Bearer s3cr3t' ],
        nested        => { a => 'b' },
    },
    'env_subst_deep walks hashes and arrays'
);

is_deeply( env_subst_deep( { '${SMTP_PASS}' => 1 } ), { '${SMTP_PASS}' => 1 }, 'keys are never expanded' );

my $bool = JSON::false();
is_deeply( env_subst_deep( { flag => $bool } ), { flag => $bool }, 'json booleans survive' );

done_testing();
