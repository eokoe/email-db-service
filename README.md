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

- Remove Redis as a dep (add CHI instead?!)
- Optional Mojo::Template instead of Text::Xslate ?
- Configure docker

# Starting this service

as a script

    perl script/process-emails.pl

as a daemon

    ./script/process-emails start

with docker

    # TODO
    docker run emaildb....

# caveats

This module uses Parallel::Prefork when 'pulling' the database queue; It came configured with `max_workers => 1`;
Only increase this number if you are sending more than 400 emails/second (aproximation based on speed of Text::Xslate),
because the more workers you have, more 'skiped rows' each worker will 'not get', so it will only wast CPU time.

# ENV configuration

- $ENV{EMAILDB_MAX_WORKERS}=1 # max workers for Parallel::Prefork

- $ENV{EMAILDB_FETCH_ROWS}=100 # number of rows each work try to lock each time it query the database

    *WARNING* having `EMAILDB_FETCH_ROWS` > 1 may delivery more than one e-mail
    in case of a failure in the middle of the batch processing (power down, kill -9, database down).
    We could implement a Redis/Memcached of already sent ids with success in case **exactly once** delivery is wishful with minimal impact on performance.
    But I do not think double emails is too bad for having this feature performance hit now, only no-email or receiving invalid-email is bad.