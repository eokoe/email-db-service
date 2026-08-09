package Shypper::SchemaFeatures;
use strict;
use utf8;

use Shypper::Logger;
require Exporter;

our @ISA = qw(Exporter);

our @EXPORT = qw(detect_schema_features has_schema_feature);

# `sqitch deploy` is not run automatically, so a database copied from an older
# install can be behind the code talking to it. Every feature added after the
# first version declares the columns it needs: when they are missing the feature
# stays off and the columns are dropped from the result source, so the service
# keeps delivering e-mail instead of failing every query with a 42703.
my %FEATURES = (
    config_variables => {
        source  => 'EmaildbConfig',
        table   => 'emaildb_config',
        columns => [qw/variables_url variables_url_config/],
        change  => '0001-config-variables-url',
        what    => 'the per-config variables webhook',
    },
);

my %enabled;
my $detected = 0;

sub has_schema_feature {
    my ($name) = @_;

    die "unknown schema feature '$name'" unless exists $FEATURES{$name};

    # nobody called detect_schema_features: assume the database is up to date,
    # which is what a plain `$schema->resultset(...)` would have assumed anyway
    return 1 unless $detected;

    return $enabled{$name} ? 1 : 0;
}

sub detect_schema_features {
    my ($schema) = @_;

    return \%enabled if $detected;

    my %seen;
    my @tables = grep { !$seen{$_}++ } map { $_->{table} } values %FEATURES;

    my $rows = $schema->storage->dbh_do(
        sub {
            my ( undef, $dbh ) = @_;

            return $dbh->selectall_arrayref(
                'SELECT table_name, column_name FROM information_schema.columns'
                  . ' WHERE table_schema = ANY (current_schemas(false))'
                  . ' AND table_name IN (' . join( ',', ('?') x @tables ) . ')',
                undef, @tables
            );
        }
    );

    my %present;
    $present{ $_->[0] }{ $_->[1] } = 1 for @$rows;

    foreach my $name ( sort keys %FEATURES ) {
        my $feature = $FEATURES{$name};
        my @missing = grep { !$present{ $feature->{table} }{$_} } @{ $feature->{columns} };

        unless (@missing) {
            $enabled{$name} = 1;
            next;
        }

        $enabled{$name} = 0;

        log_warn sprintf(
            "%s is disabled: %s has no column %s. Run `sqitch deploy` (change %s) to enable it.",
            $feature->{what}, $feature->{table}, join( ', ', @missing ), $feature->{change},
        );

        $schema->source( $feature->{source} )->remove_columns( @{ $feature->{columns} } );
    }

    $detected = 1;

    return \%enabled;
}

# for the tests, which detect against more than one database shape per process
sub _reset_schema_features {
    %enabled  = ();
    $detected = 0;

    return 1;
}

1;
