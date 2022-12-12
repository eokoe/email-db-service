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

Use `$ sqitch deploy` to deploy the necessary tables on your database. Or copy/paste from [email-db-service/deploy_db/deploy/0000-firstversion.sql](email-db-service/deploy_db/deploy/0000-firstversion.sql) and run on your postgres.

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
| email_transporter_config | {"sasl_password":"...","sasl_username":"apikey","port":"587","host":"smtp.sendgrid.net"} | args to  email_transporter_class |
| delete_after             | 180 days | not implemented, emails are kept forever on docker version |

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

    Set to 1 to disable log files (useful for k8s)

# Reserved Variables (emaildb_queue ones, not env)

    reply-to - set reply-to header
    :cc - set Cc header
    :bcc - set Bcc header
    :txt - generate text version from HTML using HTML::FormatText::WithLinks, [may reduce spamassassin score ~ 1 point]

Any variable starting with ':' should be also considered reserved for future use

# Caveats

This module uses Parallel::Prefork when 'pulling' the database queue; It is configured with `max_workers => 1`;
Only increase this number if you are sending more than 400 emails/second (approximation based on speed of Text::Xslate, network on STMP may affect performance as well),
because the more workers you have, the more 'skiped rows' each worker will have, so it will only waste CPU.


# TODO

- Optional Mojo::Template instead of Text::Xslate ?
- Daemon to remove sent emails from database
