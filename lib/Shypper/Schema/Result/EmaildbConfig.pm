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

=head2 html_server

  data_type: 'text'
  is_nullable: 0
  original: {data_type => "varchar"}

=head2 html_authorization

  data_type: 'text'
  is_nullable: 1
  original: {data_type => "varchar"}

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
  "html_server",
  {
    data_type   => "text",
    is_nullable => 0,
    original    => { data_type => "varchar" },
  },
  "html_authorization",
  {
    data_type   => "text",
    is_nullable => 1,
    original    => { data_type => "varchar" },
  },
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


# Created by DBIx::Class::Schema::Loader v0.07047 @ 2017-06-21 19:22:04
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:B4MAahjIS74Ri+OVWCxkiQ

use Moo;
use Shypper::TemplateResolvers::HTTP;

has 'template_resolver'  => ( is => 'rw', lazy => 1, builder => '_build_template_resolver' );

use JSON qw/decode_json/;
sub _build_template_resolver {
    my ($self) = @_;

    my $r;

    if ($self->html_server =~ /^http/i){
        $r = Shypper::TemplateResolvers::HTTP->new(
            base_url => $self->html_server,
             %{decode_json(   $self->html_authorization || '{}' )}
         )
    }else{
        die 'Cannot find a TemplateResolvers for ' . $self->html_server;
    }

    return $r;
}

sub get_template {
    my ($self, $template_name) = @_;

    return $self->template_resolver->get_template( $template_name );
}

# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
