# Emaildb

Emaildb uses a postgres database as a queue for (~~probably~~ *in theory* transactional 😉) emails,
so, if you rollback a transaction, you don't send any e-mail!

Use `$ sqitch deploy` to deploy the necessary tables on your database.

Insert on `public.emaildb_config` to your needs.

When an insert occurs on `emaildb_queue` this service will send it.

# Starting this service

as a script

    perl script/process-emails.pl

as a daemon

    ./script/process-emails start

with docker

    # TODO
    docker run emaildb....