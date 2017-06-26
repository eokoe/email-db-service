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