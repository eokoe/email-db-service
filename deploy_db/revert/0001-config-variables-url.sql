-- Revert emaildb:0001-config-variables-url from pg

BEGIN;

ALTER TABLE emaildb_config
    DROP COLUMN variables_url,
    DROP COLUMN variables_url_config;

COMMIT;
