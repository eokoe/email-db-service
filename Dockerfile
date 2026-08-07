# ---------------------------------------------------------------------------
# build stage: has the compilers and the -dev headers, and is thrown away.
# the official perl image already ships a perl + cpanm, so nothing is compiled
# from source here except the XS modules themselves.
# ---------------------------------------------------------------------------
FROM perl:5.40-slim-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libssl-dev \
    libpq-dev \
    zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY cpanfile /build/cpanfile

RUN cpanm --notest --no-man-pages --installdeps . \
 && rm -rf /root/.cpanm

# ---------------------------------------------------------------------------
# runtime stage: only the shared libraries the XS modules link against
# ---------------------------------------------------------------------------
FROM perl:5.40-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    libssl3 \
    zlib1g \
    ca-certificates \
    postgresql-client \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/lib/perl5/site_perl /usr/local/lib/perl5/site_perl

RUN useradd -ms /bin/bash -u 1000 app \
 && mkdir -p /data/log \
 && chown -R app:app /data

ENV VARIABLES_JSON_IS_UTF8=1

# logs go to stdout, so no /data mount is needed. set USE_STDOUT= (empty) to get
# the old /data/log/email.log files back - that one does need the volume.
ENV USE_STDOUT=1

COPY --chown=app:app . /src/

WORKDIR /src
USER app

# no runit/my_init anymore: the daemon is pid 1 and already traps TERM/HUP.
# run the container with --init (or `init: true` on compose) so zombies from
# Parallel::Prefork children are reaped.
CMD ["/src/start-server.sh"]
