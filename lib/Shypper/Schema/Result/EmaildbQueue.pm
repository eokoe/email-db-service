use utf8;
package Shypper::Schema::Result::EmaildbQueue;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Shypper::Schema::Result::EmaildbQueue

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

=head1 TABLE: C<emaildb_queue>

=cut

__PACKAGE__->table("emaildb_queue");

=head1 ACCESSORS

=head2 id

  data_type: 'uuid'
  default_value: uuid_generate_v4()
  is_nullable: 0
  size: 16

=head2 created_at

  data_type: 'timestamp'
  default_value: current_timestamp
  is_nullable: 0
  original: {default_value => \"now()"}

=head2 config_id

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 template

  data_type: 'text'
  is_nullable: 0
  original: {data_type => "varchar"}

=head2 to

  data_type: 'text'
  is_nullable: 0
  original: {data_type => "varchar"}

=head2 variables

  data_type: 'json'
  is_nullable: 0

=head2 sent

  data_type: 'boolean'
  default_value: false
  is_nullable: 1

=head2 sent_at

  data_type: 'timestamp'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "id",
  {
    data_type => "uuid",
    default_value => \"uuid_generate_v4()",
    is_nullable => 0,
    size => 16,
  },
  "created_at",
  {
    data_type     => "timestamp",
    default_value => \"current_timestamp",
    is_nullable   => 0,
    original      => { default_value => \"now()" },
  },
  "config_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "template",
  {
    data_type   => "text",
    is_nullable => 0,
    original    => { data_type => "varchar" },
  },
  "to",
  {
    data_type   => "text",
    is_nullable => 0,
    original    => { data_type => "varchar" },
  },
  "variables",
  { data_type => "json", is_nullable => 0 },
  "sent",
  { data_type => "boolean", default_value => \"false", is_nullable => 1 },
  "sent_at",
  { data_type => "timestamp", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 config

Type: belongs_to

Related object: L<Shypper::Schema::Result::EmaildbConfig>

=cut

__PACKAGE__->belongs_to(
  "config",
  "Shypper::Schema::Result::EmaildbConfig",
  { id => "config_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07047 @ 2017-06-21 19:22:04
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:ifR1QPUf/S9OKg9Rz+CxGQ


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
