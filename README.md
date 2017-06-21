# HTTP callback service
This service is a simple way to make http callback with automatic retry and scheduling.

Speed is not a primary goal, but it works using async http. It pull database 2 each seconds for new callbacks, or for callbacks that need rework.,
When a new callback is detected, the ĺoop get restarted and this event is pulled close to 10ms (using PostgreSQL Notify/Listen), and have very low cpu utilization.

It's intended to be used inside an secure network (as it does not have any authorization by now).

As a user, you may do an (guess what, http) request with, at least:

    method  = POST, GET, PUT or HEAD
    url     = http or https + host + (maybe a port) and path_query

Return an HTTP 201 with header Location, where you can GET to check for verifying success

## Optional parameters

    headers           = Header-Name: Value, add many using \n
    body              = utf8 text only
    wait_until        = unix-timestamp (UTC 0); default no waiting
    retry_until       = unix-timestamp (UTC 0); default 5 days
    retry_each        = in seconds; default 15
    retry_exp_base    = real ( retry_exp_base ^ LEAST(http_request_status.try_num, 10) * retry_each); default 2

# Usage

linux with curl:

    curl -X POST 'http://127.0.0.1:2626/schedule?method=post&url=http%3a%2f%2fexemple.com%3ffoo%3dbar&headers=X-token%3a+100%0d%0ax-api-secret%3a+bar&body=HELO'

# Endpoints

    POST /schedule
    GET  /schedule/$UID

    Both returns an JSON like:

        {
           "retry_each" : 15,
           "id" : "c8bf9d56-3390-4859-8b8f-095432271a4a",
           "http_response" : {
              "response" : "200 OK\nCache-Control: private, max-age=0\nConnection: close\n......</html>\n",
              "took" : 0.183862,
              "created_at" : 1470752200
           },
           "headers" : null,
           "retry_until" : 1471184190,
           "retry_exp_base" : 2,
           "created_at" : 1470752190,
           "success" : 1,
           "try_num" : 1,
           "method" : "get",
           "body" : null,
           "url" : "http://google.com/",
           "response_took" : 0,
           "wait_until" : 1470752199
        }

        Please note that http_response may be null


# Requirements

- perl 5.16 and newer
- postgres 9.1 and newer
- start-stop-daemon 1.17.5 and newer
- cpanm

> It's tested on ubuntu 14.04 LTS, but may work on lot of others linux distributions

# Configuration files

- **sqitch.conf**

    have the databae settings for the Sqitch (database versioning)

- **deploy/envs.sample.sh**

    have the default ENVs. Copy it to **deploy/envs_local.sh**; if you do that, run it before running anything

# Setup

Before starting the server, you need to configure the database.
If you need change database settings, edit on sqitch.conf

    createdb emaildb_dev -h 127.0.0.1 -U postgres
    sqitch deploy -t local

## Installing modules deps

    cpanm --installdeps . # -n


## Starting / gracefully reloading

    EMAILDB_ENV_FILE=deploy/env_local.sh deploy/restart_services.sh

> When EMAILDB_DB_* is changed, you will need to run `fuser $EMAILDB_API_PORT/tcp -k`. This is not gracefully, but needed as the server_starter fork don't get fresh ENV before starting the new code.

## Running tests

As fast as possible, hard to read output.

    forkprove -MShypper::API::Schedule -lr -j 4 t/

Good speed vs readability

    DBIC_TRACE=1 TRACE=1 forkprove -MShypper::API::Schedule -lvr -j 1 t/

Slower, but does not need forkprove

    prove -lvr t/

## TODO

- authorization
- way to configure when to delete requests from database
- .deb install?
