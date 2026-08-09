use utf8;
package Shypper::Schema::Result::EmaildbConfig;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Shypper::Schema::Result::EmaildbConfig

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 COMPONENTS LOADED

=over 4

=item * L<DBIx::Class::InflateColumn::DateTime>

=back

=cut

__PACKAGE__->load_components("InflateColumn::DateTime");

=head1 TABLE: C<emaildb_config>

=cut

__PACKAGE__->table("emaildb_config");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'emaildb_config_id_seq'

=head2 from

  data_type: 'text'
  is_nullable: 0
  original: {data_type => "varchar"}

=head2 template_resolver_class

  data_type: 'varchar'
  is_nullable: 0
  size: 60

=head2 template_resolver_config

  data_type: 'json'
  default_value: '{}'
  is_nullable: 0

=head2 email_transporter_class

  data_type: 'varchar'
  is_nullable: 0
  size: 60

=head2 email_transporter_config

  data_type: 'json'
  default_value: '{}'
  is_nullable: 0

=head2 delete_after

  data_type: 'interval'
  default_value: '7 days'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "id",
  {
    data_type         => "integer",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "emaildb_config_id_seq",
  },
  "from",
  {
    data_type   => "text",
    is_nullable => 0,
    original    => { data_type => "varchar" },
  },
  "template_resolver_class",
  { data_type => "varchar", is_nullable => 0, size => 60 },
  "template_resolver_config",
  { data_type => "json", default_value => "{}", is_nullable => 0 },
  "email_transporter_class",
  { data_type => "varchar", is_nullable => 0, size => 60 },
  "email_transporter_config",
  { data_type => "json", default_value => "{}", is_nullable => 0 },
  "delete_after",
  { data_type => "interval", default_value => "7 days", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 emaildb_queues

Type: has_many

Related object: L<Shypper::Schema::Result::EmaildbQueue>

=cut

__PACKAGE__->has_many(
  "emaildb_queues",
  "Shypper::Schema::Result::EmaildbQueue",
  { "foreign.config_id" => "self.id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07047 @ 2017-06-29 15:57:37
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:JsbyMKflrqllTTLA8Q0RFQ

use Moo;
use Shypper;
use Shypper::TemplateResolvers::HTTP;
use Shypper::Logger;
use Shypper::EnvSubst qw/env_subst env_subst_deep/;
use Shypper::SchemaFeatures qw/has_schema_feature/;

use Email::Simple;

use Class::Load qw/load_class/;
use JSON qw/decode_json/;
use Furl;

# added after the schema was first generated (sqitch change 0001-config-variables-url).
# Shypper::SchemaFeatures removes them again from the result source when the
# database is older than the code, see has_schema_feature('config_variables').
__PACKAGE__->add_columns(
    "variables_url",
    { data_type => "varchar", is_nullable => 1 },
    "variables_url_config",
    { data_type => "json", default_value => "{}", is_nullable => 0 },
);

has 'template_resolver' => ( is => 'rw', lazy => 1, builder => '_build_template_resolver' );

sub _build_template_resolver {
    my ($self) = @_;

    my $class = $self->template_resolver_class;
    my $cnf   = decode_json( $self->template_resolver_config );

    die 'template_resolver_config must be a hash ref' unless ref $cnf eq 'HASH';

    $cnf = env_subst_deep( $cnf, context => 'emaildb_config.id=' . $self->id . ' template_resolver_config' );

    load_class($class);

    return $class->new( %{$cnf} );

}


has 'email_transporter' => ( is => 'rw', lazy => 1, builder => '_build_email_transporter' );

sub _build_email_transporter {
    my ($self) = @_;

    my $class = $self->email_transporter_class;
    my $cnf   = decode_json( $self->email_transporter_config );

    die 'email_transporter_config must be a hash ref' unless ref $cnf eq 'HASH';

    $cnf = env_subst_deep( $cnf, context => 'emaildb_config.id=' . $self->id . ' email_transporter_config' );

    load_class($class);

    return $class->new( %{$cnf} );

}

# the From: header, with ${ENV_VAR} expanded
sub from_env {
    my ($self) = @_;

    return env_subst( $self->from, context => 'emaildb_config.id=' . $self->id . ' from' );
}

=head2 config_variables

Variables that belong to the config itself (base urls, domain names, support
address...) instead of to each e-mail. They come from the C<variables_url>
webhook, polled B<once per boot> (during ConfigBridge prewarm, before forking).

C<variables_url_config> options:

    namespace - default 'cfg' - key the hash is exposed under to the template
    headers   - no default, array, eg: ["authorization", "Bearer ${API_TOKEN}"]
    timeout   - default 30 - seconds
    required  - default true - when false, a failed poll logs and falls back to 'defaults'
    defaults  - no default, hash, values used for the keys the webhook did not return

${ENV_VAR} is expanded on 'url', 'headers' and 'timeout' only. It is B<not>
expanded on 'defaults' nor on whatever the webhook answers: those are template
variables, and the environment must not leak into an e-mail.

On a database that never got the C<0001-config-variables-url> sqitch change this
returns an empty hash and nothing is polled - see L<Shypper::SchemaFeatures>.

=cut

has 'config_variables' => ( is => 'rw', lazy => 1, builder => '_build_config_variables' );

sub variables_options {
    my ($self) = @_;

    return {} unless has_schema_feature('config_variables');

    my $opts = decode_json( $self->variables_url_config || '{}' );
    die 'variables_url_config must be a hash ref' unless ref $opts eq 'HASH';

    return $opts;
}

sub variables_namespace {
    my ($self) = @_;

    return $self->variables_options->{namespace} || 'cfg';
}

sub _build_config_variables {
    my ($self) = @_;

    return {} unless has_schema_feature('config_variables');

    my $url = $self->variables_url;
    return {} unless defined $url && $url =~ /\S/;

    my $logger  = get_logger;
    my $context = 'emaildb_config.id=' . $self->id . ' variables_url';
    my $opts    = $self->variables_options;

    my $defaults = $opts->{defaults} || {};
    die 'variables_url_config.defaults must be a hash ref' unless ref $defaults eq 'HASH';

    my $required = exists $opts->{required} ? $opts->{required} ? 1 : 0 : 1;

    $url = env_subst( $url, context => $context );
    my $headers = env_subst_deep( $opts->{headers} || [], context => $context . '_config.headers' );
    my $timeout = env_subst( $opts->{timeout} || 30, context => $context . '_config.timeout' );

    my $vars = eval {
        $logger->info("Polling config variables of emaildb_config.id=${\$self->id} from '$url'");

        my $res = Furl->new(
            timeout => $timeout,
            agent   => 'Emaildb/ConfigVariables ' . $Shypper::VERSION,
        )->get( $url, $headers );

        die sprintf( "http status %s: %s\n", $res->code, $res->decoded_content ) unless $res->is_success;

        # json is utf8 by definition, so the raw body is what decode_json wants
        my $parsed = decode_json( $res->content );
        die "webhook must answer a json object\n" unless ref $parsed eq 'HASH';

        $parsed;
    };

    if ($@) {
        my $err = "Cannot poll $context '$url': $@";
        $logger->logcroak($err) if $required;

        $logger->error( $err . ' - falling back to variables_url_config.defaults' );
        $vars = {};
    }

    return { %$defaults, %$vars };
}

# forces the next read to poll the webhook again
sub refresh_config_variables {
    my ($self) = @_;

    $self->config_variables( $self->_build_config_variables );

    return $self->config_variables;
}

sub get_template {
    my ( $self, $template_name ) = @_;

    return $self->template_resolver->get_template($template_name);
}

# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
