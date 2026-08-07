package Shypper::EnvSubst;
use strict;
use warnings;
use utf8;
use Carp qw/croak/;

require Exporter;

our @ISA = qw(Exporter);

our @EXPORT_OK = qw(env_subst env_subst_deep);

=head1 NAME

Shypper::EnvSubst - expand ${ENV_VAR} placeholders inside emaildb_config values

=head1 DESCRIPTION

This is only used for the B<config> side of the service (the json columns of
emaildb_config, the "from" and the variables webhook url), so an operator can
keep secrets and urls in the environment instead of writing them in the
database.

It is B<never> applied to emaildb_queue.variables nor to the templates: the
environment must not be reachable from an e-mail.

Supported syntax:

    ${NAME}             dies at boot if NAME is unset or empty
    ${NAME:-fallback}   uses fallback if NAME is unset or empty
    $${NAME}            escape, expands to the literal ${NAME}

=cut

sub env_subst {
    my ($str, %opts) = @_;

    return $str unless defined $str;
    return $str if ref $str;
    return $str unless $str =~ /\$\{/;

    my $where = $opts{context} ? " (in $opts{context})" : '';

    $str =~ s{
        (\$\$?)                             # $ or $$ (escape)
        \{
            ([A-Za-z_][A-Za-z0-9_]*)        # var name
            (?: :- ([^{}]*) )?              # optional :-default
        \}
    }{
        my ($sigil, $name, $default) = ($1, $2, $3);

        if ($sigil eq '$$') {
            '${' . $name . (defined $default ? ':-' . $default : '') . '}';
        }
        elsif (defined $ENV{$name} && $ENV{$name} ne '') {
            $ENV{$name};
        }
        elsif (defined $default) {
            $default;
        }
        else {
            croak "\${$name} used$where but \$ENV{$name} is unset or empty";
        }
    }gex;

    return $str;
}

# walks hashes/arrays, expanding values only (never keys)
sub env_subst_deep {
    my ($data, %opts) = @_;

    if (ref $data eq 'HASH') {
        return {map { $_ => env_subst_deep($data->{$_}, %opts) } keys %$data};
    }
    elsif (ref $data eq 'ARRAY') {
        return [map { env_subst_deep($_, %opts) } @$data];
    }
    elsif (ref $data) {

        # JSON::PP::Boolean and friends are left alone
        return $data;
    }

    return env_subst($data, %opts);
}

1;
