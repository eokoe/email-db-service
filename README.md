# Emaildb

Emaildb uses a postgres database as a queue for (~~probably~~ *in theory* transactional 😉) emails,
so, if you rollback a transaction, you don't send any e-mail!

Use `$ sqitch deploy` to deploy the necessary tables on your database.

Insert on `public.emaildb_config` to your needs.

When an insert occurs on `emaildb_queue` this service will send it.

# backend

- PostgreSQL 9.5+ for queue
- Text::Xslate for parsing / templating
- Email::Sender::Transport:** for *sending* e-mails
- Shypper::TemplateResolvers::* for getting texts to pass to Text::Xslate

# deps (REMOVED Redis at 2022-04-27 - file cache is used instead)

# tables

#### emaildb_config

    -- id for the config - changes on this table needs to restart the container
    id                       | 1
    from                     | "FooBar" <user@example.com>
    -- Shypper::TemplateResolvers::HTTP only supported on the docker image
    template_resolver_class  | Shypper::TemplateResolvers::HTTP
    -- where to download the templates from
    template_resolver_config | {"base_url":"https://example.com/static/template-emails/" }
    -- Email::Sender::Transport::SMTP is also installed on docker
    email_transporter_class  | Email::Sender::Transport::SMTP::Persistent
    -- args to email_transporter_class
    email_transporter_config | {"sasl_password":"...","sasl_username":"apikey","port":"587","host":"smtp.sendgrid.net"}
    -- not implemented, emails are kept forever on docker version
    delete_after             | 180 days

#### emaildb_queue

    -- random uuid is fine
    id            | uuid
    -- FK to emaildb_config
    config_id     | integer
    -- when email was first created
    created_at    | timestamp without time zone
    -- template to be passed to template_resolver_class
    template      | character varying
    -- mailto
    to            | character varying
    -- subject (auto encoded to utf8)
    subject       | character varying
    -- variables for interpolation on the template
        if using double-encoded utf8, set VARIABLES_JSON_IS_UTF8=0
    variables     | json
    -- is message sent?
        NULL = not tried yet
        true - sent
        false - failed
    sent          | boolean
    -- last changed at
    updated_at    | timestamp without time zone
    -- wait until this timestmap before seding
    visible_after | timestamp without time zone
    -- if failed, whats the error message
    errmsg        | character varying

To retry or resend, set both `errmsg` and `sent` to NULL, then trigger `NOTIFY newemail` or wait the next minute

# TODO

- Optional Mojo::Template instead of Text::Xslate ?
- Daemon to remove sent emails from database

# Configuring

You need to setup those env vars (check file .env if using docker-compose):

    EMAILDB_DB_HOST
    EMAILDB_DB_PASS
    EMAILDB_DB_PORT
    EMAILDB_DB_USER
    EMAILDB_DB_NAME


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

# caveats

This module uses Parallel::Prefork when 'pulling' the database queue; It is configured with `max_workers => 1`;
Only increase this number if you are sending more than 400 emails/second (approximation based on speed of Text::Xslate),
because the more workers you have, the more 'skiped rows' each worker will have, so it will only waste CPU.

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


# Reserved Variables (emaildb_queue)

    reply-to - set reply-to header
    :cc - set Cc header
    :bcc - set Bcc header
    :txt - generate text version from HTML using HTML::FormatText::WithLinks, [may reduce spamassassin score ~ 1 point]

Any variable starting with ':' should be also considered reserved for future use


