#!/bin/bash
source /home/app/perl5/perlbrew/etc/bashrc

cd /src;

if [[ -z "${USE_STDOUT}" ]]; then
    mkdir -p /data/
    mkdir -p /data/log

    perl script/process-emails.pl 1>>/data/log/email.log 2>>/data/log/email.error.log
else
    perl script/process-emails.pl
fi