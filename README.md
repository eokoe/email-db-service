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

# deps

Shypper::TemplateResolvers::HTTP needs Redis for caching

# TODO

- Optional Mojo::Template instead of Text::Xslate ?
- Daemon to remove sent emails from database

# Configuring

You need to setup those env vars:

    EMAILDB_DB_HOST
    EMAILDB_DB_PASS
    EMAILDB_DB_PORT
    EMAILDB_DB_USER
    EMAILDB_DB_NAME


# Starting this service

as a script

    perl script/process-emails.pl

as a daemon

    ./script/process-emails start

with docker

    ./build_container.sh

    After this, you may edit and then run

    ./sample--run_container.sh

If you are using `EMAILDB_DB_HOST=172.17.0.1` you may have to configure your firewall to allow connections from containers to your database.

# caveats

This module uses Parallel::Prefork when 'pulling' the database queue; It is configured with `max_workers => 1`;
Only increase this number if you are sending more than 400 emails/second (approximation based on speed of Text::Xslate),
because the more workers you have, more 'skiped rows' each worker will 'not get', so it will only wast CPU time.

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

- $ENV{USE_MIME_Q_DEFAULT}=''

    Set to 1 to enable mimi-q on subject by default

- $ENV{USE_TXT_DEFAULT}=''

    Set to 1 to generate text from text by default


# Reserved Variables

    reply-to - set reply-to header
    :cc - set Cc header
    :bcc - set Bcc header
    :txt - generate text version from HTML using HTML::FormatText::WithLinks, [may reduce spamassassin score ~ 1 point]
    :qmq - encode subject with MIMI-Q instead of UTF8 [may reduce spamassassin score ~ 0.1 point]

