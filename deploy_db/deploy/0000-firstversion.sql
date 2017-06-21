-- Deploy emaildb:0000-firstversion to pg
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

BEGIN;

create table emaildb_config   (
    id serial not null PRIMARY key,
    "from" varchar not null,
    html_server varchar not null,
    html_authorization varchar,
    delete_after interval not null default '7 days'
);

create table emaildb_queue   (
    id uuid NOT NULL DEFAULT uuid_generate_v4() PRIMARY KEY,
    created_at timestamp without time zone not null default now(),

    config_id int not null references emaildb_config(id),

    "template" varchar not null,
    "to" varchar not null,
    variables json not null,

    sent boolean DEFAULT false,
    sent_at timestamp without time zone

);


COMMIT;
