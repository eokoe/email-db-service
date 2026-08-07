#!/bin/bash

cd /src;

if [[ -z "${USE_STDOUT}" ]]; then
    mkdir -p /data/
    mkdir -p /data/log

    exec perl script/process-emails.pl 1>>/data/log/email.log 2>>/data/log/email.error.log
else
    exec perl script/process-emails.pl
fi
