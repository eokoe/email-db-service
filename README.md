# Emaildb

Emaildb uses a postgres database as a queue for (~~probably~~ *in theory* transactional 😉) emails,
so, if you rollback a transaction, you don't send any e-mail!

It also decouples email templates from your backend, you can host your templates anywhere with HTTP/HTTPS.

# Remote deps

- PostgreSQL >= 9.5 - used as queue (requires SKIP LOCKED feature)

Other than that, you need an an SMTP server

> Redis dep was removed on 2022-04-27 - file cache is used instead

# Backend overview

- written in perl, uses cpanfile to control perl deps
- Text::Xslate for parsing / templating
- Email::Sender::Transport:** for *sending* e-mails
- Shypper::TemplateResolvers::* for getting texts to pass to Text::Xslate

## Shypper::TemplateResolvers

Classes on this namespace downloads and render the templates for the Email::Sender::Transport class

### Shypper::TemplateResolvers::HTTP

The bellow configs are available:

    base_url - required
    cache_path - default '/tmp/'
    cache_prefix - default 'shypper-template-' - prefix for file name
    cache_timeout - default '60', files older or equal to this setting will be discarted and fetched again from source
    headers - no default, set as array, eg: ["authorization", "Basic 123"]

> obs: it supports HTTPS

# Configuring

All ops setting are set via env variables ([check file](.env)) for more info or keep reading.

Dynamic configs are set via tables, see bellow:

Use `$ sqitch deploy` to deploy the necessary tables on your database. Or copy/paste from [email-db-service/deploy_db/deploy/0000-firstversion.sql](email-db-service/deploy_db/deploy/0000-firstversion.sql) and run on your postgres, followed by [0001-config-variables-url.sql](deploy_db/deploy/0001-config-variables-url.sql).

Insert on `public.emaildb_config` to your needs.

When an insert occurs on `emaildb_queue` this service will send it.

# Starting this service

with docker-compose

    docker-compose build

    # edit .env

    # check config
    docker-compose config

    # run
    docker-compose up -d

as a script

    # install deps with cpanm

    perl script/process-emails.pl

as a daemon

    ./script/process-emails start

with docker

    ./build_container.sh

    After this, you may edit and then run

    ./sample--run_container.sh

The image is a two stage build on top of the official `perl:5.40-slim-bookworm`:
the compilers and the `-dev` headers live in the build stage and only the
installed modules are copied to the runtime one. Nothing compiles perl itself,
so a cold build takes a few minutes instead of the perlbrew build it replaced.

There is no runit/my_init supervisor anymore, the daemon is pid 1 (it already
traps TERM/HUP). Run it with `--init` - or `init: true`, already set on
docker-compose.yml - so the Parallel::Prefork children get reaped.

Run the test suite against a postgres of your own with:

    docker run --rm --network host -e EMAILDB_DB_HOST=127.0.0.1 -e EMAILDB_DB_PORT=5432 \
        -e EMAILDB_DB_USER=postgres -e EMAILDB_DB_PASS=... -e EMAILDB_DB_NAME=emaildb_dev \
        <image> prove -Ilib t/

If you are using `EMAILDB_DB_HOST=172.17.0.1` you may have to configure your firewall to allow connections from containers to your database.
Starting the database before `dockerd` is enssenstial for this to work reliably, prefer to use dedicated host or move db to a docker container.

# Tables detail

#### emaildb_config

| column | eg | comment |
| ----- |----|-------|
| id                       | 1 | id for the config - changes on this table needs to restart the container |
| from                     | "FooBar" <user@example.com> | Set FROM name and email |
| template_resolver_class  | Shypper::TemplateResolvers::HTTP | Shypper::TemplateResolvers::HTTP only supported on the docker image |
| template_resolver_config | {"base_url":"https://example.com/static/template-emails/" } | args to template_resolver_class |
| email_transporter_class  | Email::Sender::Transport::SMTP::Persistent | Email::Sender::Transport::SMTP is also installed on docker |
| email_transporter_config | {"sasl_password":"${SMTP_PASS}","sasl_username":"apikey","port":"587","host":"smtp.sendgrid.net"} | args to  email_transporter_class |
| variables_url            | https://example.com/emaildb-vars.json | optional, polled once per boot for config-wide template variables |
| variables_url_config     | {"namespace":"cfg"} | options for variables_url |
| delete_after             | 180 days | not implemented, emails are kept forever on docker version |

## Config variables (variables_url)

Values that belong to the config and not to each e-mail - the site base url, the
domain, the support address - do not need to be repeated on every insert of
`emaildb_queue.variables`.

Point `variables_url` at an endpoint answering a json object and it is polled
**once per boot** (during prewarm, before forking), then exposed to every
template of that config under its own namespace:

    variables_url        = https://example.com/emaildb-vars.json
    variables_url_config = {"namespace":"cfg"}

    the endpoint answers  {"site_url":"https://app.example.com","support":"help@example.com"}

    template: <a href="[% cfg.site_url %]/u/[% user_id %]">open</a> - [% cfg.support %]
                          ^ from the webhook       ^ from emaildb_queue.variables

Domains are stable, so polling at boot is enough - restart the container (or
`docker-compose restart`) to pick up a change.

`variables_url_config` options:

    namespace - default 'cfg' - the key the object is exposed under
    headers   - no default, array, eg: ["authorization", "Bearer ${API_TOKEN}"]
    timeout   - default 30 - seconds
    required  - default true - when false, a failed poll only logs and uses 'defaults'
    defaults  - no default, hash, values for the keys the webhook did not answer

The namespace key is written *after* the row variables are read, so an e-mail
cannot forge `cfg` by inserting a variable with that name.

## ${ENV_VAR} on the config columns

So a url or a password does not have to be written in the database, the config
columns expand shell-like placeholders from the daemon environment:

    ${NAME}             dies at boot, naming the variable, if NAME is unset or empty
    ${NAME:-fallback}   uses fallback if NAME is unset or empty
    $${NAME}            escape, stays the literal ${NAME}

It is applied to `from`, `template_resolver_config`, `email_transporter_config`,
`variables_url` and to the `headers`/`timeout` of `variables_url_config`.

It is **never** applied to `emaildb_queue.variables`, to `variables_url_config.defaults`,
to whatever the webhook answers, nor to the templates: those are e-mail content,
and the environment must not be reachable from an e-mail. The two features are
separate on purpose.

    "from":                     '"${MAIL_BRAND} Notifications" <no-reply@example.com>'
    "email_transporter_config": {"host":"smtp.sendgrid.net","sasl_username":"apikey","sasl_password":"${SMTP_PASS}"}
    "template_resolver_config": {"base_url":"${TEMPLATE_BASE_URL}"}

#### emaildb_queue

| column | type | comment |
| ----- |----|-------|
| id            | uuid |random uuid is fine |
| config_id     | integer | FK to emaildb_config |
| created_at    | timestamp without time zone |when email was first created |
| template      | character varying |template to be passed to template_resolver_class |
| to            | character varying |mailto |
| subject       | character varying |subject (auto encoded to utf8) |
| variables     | json | variables for interpolation on the template
    if using double-encoded utf8, set VARIABLES_JSON_IS_UTF8=0 |
| sent          | boolean | is message sent?
    NULL = not tried yet
    true - sent
    false - failed |
|updated_at    | timestamp without time zone | last changed at |
|visible_after | timestamp without time zone | wait until this timestmap before seding |
|errmsg        | character varying | if failed, whats the error message |

To retry or resend, set both `errmsg` and `sent` to NULL, then trigger `NOTIFY newemail` or wait the next minute


# ENV configuration

- $ENV{EMAILDB_MAX_WORKERS}=1 # max workers for Parallel::Prefork

- $ENV{EMAILDB_FETCH_ROWS}=100 # number of rows each work try to lock each time it query the database

    * **WARNING** *

    Having `EMAILDB_FETCH_ROWS` > 1 may delivery more than one e-mail
    in case of a failure in the middle of the batch processing (power down, kill -9, database down).

    We could use Redis to keep a list of sent ids, pull requests are wellcome, just remember that we would need to clear this list sometime.
    Nevertheless, I do not think receiving an email twice is too bad. so I'm leaving this feature by now.

- $ENV{EXIT_WORKER_AFTER}=''

    Set this if you want to recycle workers after that many emails have been processed.

    Included after option have text email generated from html, as a potentially memory-leak module was added to make this conversion (HTML::FormatText::WithLinks / HTML::TreeBuilder)

- $ENV{USE_TXT_DEFAULT}=''

    Set to 1 to generate text from text by default

- $ENV{VARIABLES_JSON_IS_UTF8}=''

    Set to 1 to if you are saving variables fields with correct UTF8 encoding

- USE_STDOUT

    Set to 1 to disable log files (useful for k8s and docker in general)

    **The docker image sets it to 1**, so logs go to stdout and no `/data` mount
    is needed. Set it to an empty value if you want the old
    `/data/log/email.log` + `/data/log/email.error.log` files back - then you do
    need a writable `/data` volume.

# Reserved Variables (emaildb_queue ones, not env)

    reply-to - set reply-to header
    :cc - set Cc header
    :bcc - set Bcc header
    :txt - generate text version from HTML using HTML::FormatText::WithLinks, [may reduce spamassassin score ~ 1 point]
    attachments_config - {"files":[{"name":"a.pdf","content_type":"application/pdf","content":"<base64>","disposition":"attachment"}]}
        disposition is optional and defaults to 'inline' (what this service always sent);
        use "attachment" for the paperclip instead of a part inlined in the body

Any variable starting with ':' should be also considered reserved for future use

The `variables_url` namespace (`cfg` by default) is reserved as well: it is
overwritten with the config variables right before rendering.

# Template syntax

Templates are rendered by Text::Xslate in `TTerse` syntax, which is a subset of
Template Toolkit - `[% var %]`, `[% obj.field %]`, `[% x | raw %]`,
`[% IF %]/[% ELSIF %]/[% ELSE %]/[% END %]` and `[% FOREACH x IN list %]` all
behave like TT2.

The one difference worth remembering: **methods need the parenthesis**.

    [% IF orders.size > 0 %]     renders nothing, silently takes the ELSE branch
    [% IF orders.size() > 0 %]   works

# Caveats

This module uses Parallel::Prefork when 'pulling' the database queue; It is configured with `max_workers => 1`;
Only increase this number if you are sending more than 400 emails/second (approximation based on speed of Text::Xslate, network on STMP may affect performance as well),
because the more workers you have, the more 'skiped rows' each worker will have, so it will only waste CPU.


# TODO

- Optional Mojo::Template instead of Text::Xslate ?
- Daemon to remove sent emails from database
