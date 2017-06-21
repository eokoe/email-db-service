#!/bin/bash

[ -z "$EMAILDB_ENV_FILE" ] && echo "Need to set EMAILDB_ENV_FILE env before run this." && exit 1;


source $EMAILDB_ENV_FILE


if /bin/fuser $EMAILDB_API_PORT/tcp ; then
    echo "http callback is running"
else
    cd $EMAILDB_APP_DIR;

    EMAILDB_ENV_FILE=deploy/envs.sh ./deploy/restart_services.sh
fi

cd $EMAILDB_APP_DIR/script
# WOKRERS
./process-requests start

