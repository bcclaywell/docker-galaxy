#!/bin/bash
set -e

# "Production"-style docker-galaxy entrypoint
#
# Galaxy in its default configuration has a tendency to hang for a bit
# when e.g. submitting complex workflow jobs because of the Python
# GIL. Galaxy's way around that is to spawn dedicated web and job
# handlers. This script makes it easy to spawn these processes, as
# well as the mountpoint hooks and barebones nginx load balancer in
# front of the web processes from the base image, inside the
# container.
#
# The excess of scripting is because I'd rather avoid including the
# config files themselves in this repo, instead preferring to modify
# the default config one line at a time in either the Dockerfile
# (baking the change into the image) or the docker entrypoint script
# (making the change as needed just before starting the server).

# usage: galaxy_config database_connection "$DB_CONN"
galaxy_config() {
    sed -i 's|^#\?\('"$1"'\) = .*$|\1 = '"$2"'|' /galaxy/stable/universe_wsgi.ini
}

# usage: wait_for_ok http://example.com
wait_for_ok() {
    echo -n "waiting for 200 OK..."
    until wget -qO /dev/null $1; do
        if [[ $? > 0 && $? < 8 ]]; then
            echo " error"
            break
        fi
        echo -n "."
        sleep 5
    done
    echo " ok"
}

#####

service nginx start

cd /galaxy/stable

# Set up a connection string for a database on a linked container.
# Default: postgresql://galaxy:galaxy@HOST:PORT/galaxy
if [ -n "${DB_PORT_5432_TCP_ADDR}" ]; then
    DB_CONN="postgresql://${DB_USER:=galaxy}:${DB_PASS:=galaxy}@${DB_PORT_5432_TCP_ADDR}:${DB_PORT_5432_TCP_PORT}/${DB_DATABASE:=galaxy}"
fi

# Configure a postgres db if $DB_CONN is set, here or otherwise.
if [ -n "${DB_CONN}" ]; then
    galaxy_config database_connection "${DB_CONN}"
    galaxy_config database_engine_option_server_side_cursors "True"
    galaxy_config database_engine_option_strategy "threadlocal"
fi

# Configure Galaxy admin users if $GALAXY_ADMINS is set.
if [ -n "${GALAXY_ADMINS}" ]; then
    galaxy_config admin_users "${GALAXY_ADMINS}"
fi

# If a volume directory is empty (e.g., if a new volume was
# passed to `docker run`), initialize it from a skeleton.

if [ -z "$(ls -A /galaxy/stable/database)" ]; then
    tar xvpf database_skel.tar.gz
fi

if [ -z "$(ls -A /galaxy/stable/tool-data)" ]; then
    tar xvpf tool-data_skel.tar.gz
fi

# Start a Galaxy process and wait for a 200 OK.
su -c "sh run.sh --daemon" galaxy
wait_for_ok http://127.0.0.1:80

# Stop Galaxy again so we can finish setting up.
su -c "sh run.sh --stop-daemon" galaxy

# usage: galaxy_server <ID> <PORT> <WORKERS>
define_galaxy_server() {
    cat <<EOF

[server:$1]
use = egg:Paste#http
host = 127.0.0.1
port = $2
use_threadpool = True
threadpool_workers = $3
EOF
}

# TODO dynamic
if grep -q web0 universe_wsgi.ini; then
    echo "servers already defined in universe_wsgi.ini, skipping"
else
    define_galaxy_server web0 8080 7 >> universe_wsgi.ini
    define_galaxy_server web1 8081 7 >> universe_wsgi.ini
    define_galaxy_server worker0 8090 5 >> universe_wsgi.ini
    define_galaxy_server worker1 8091 5 >> universe_wsgi.ini
fi

cat <<EOF > job_conf.xml
<?xml version="1.0"?>
<job_conf>
    <plugins workers="4">
        <plugin id="local" type="runner" load="galaxy.jobs.runners.local:LocalJobRunner"/>
    </plugins>
    <handlers default="workers">
EOF

# TODO dynamic
cat <<EOF >> job_conf.xml
        <handler id="worker0" tags="workers"/>
        <handler id="worker1" tags="workers"/>
EOF

cat <<EOF >> job_conf.xml
    </handlers>
    <destinations>
        <destination id="local" runner="local"/>
    </destinations>
</job_conf>
EOF

# TODO use start-stop-daemon?
GALAXY_SERVERS="web0 web1 worker0 worker1"
for SERVER in ${GALAXY_SERVERS}; do
    echo -n "Starting ${SERVER}... "
    su -c "python ./scripts/paster.py serve universe_wsgi.ini --server-name=${SERVER} --pid-file=${SERVER}.pid --log-file=${SERVER}.log --daemon" galaxy
    echo "ok"
done

# Reconfigure nginx for the new web processes.
# TODO dynamic
if grep -q 'server 127\.0\.0\.1:8081' /etc/nginx/nginx.conf; then
    echo "servers already defined in nginx.conf, skipping"
else
    sed -i 's|\(server 127\.0\.0\.1:8080\);|\1; server 127.0.0.1:8081;|' /etc/nginx/nginx.conf
    service nginx reload
fi

# Trap SIGINT so we can try to shut down cleanly.
trap '{ echo -n "Shutting down... "; pkill -INT -f paster.py; sleep 10; echo " ok"; exit 0; }' SIGINT EXIT
tail -f web*.log worker*.log

# Turn over this process to a shell for testing.
#exec /bin/bash
