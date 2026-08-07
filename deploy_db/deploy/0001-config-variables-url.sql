-- Deploy emaildb:0001-config-variables-url to pg
-- requires: 0000-firstversion

BEGIN;

ALTER TABLE emaildb_config
    ADD COLUMN variables_url varchar,
    ADD COLUMN variables_url_config json NOT NULL DEFAULT '{}'::json;

COMMENT ON COLUMN emaildb_config.variables_url IS
    'optional http(s) endpoint answering a json object with config-wide template variables, polled once per boot; supports ${ENV_VAR}';

COMMENT ON COLUMN emaildb_config.variables_url_config IS
    'options for variables_url: namespace (default "cfg"), headers, timeout, required, defaults';

COMMIT;
