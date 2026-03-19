#!/bin/sh
# /etc/litin/services/postgresql/service.sh
#
# PostgreSQL database server — forking type, PID file readiness.

name="postgresql"
description="PostgreSQL database server"
command="/usr/lib/postgresql/15/bin/pg_ctl start -D /var/lib/postgresql/15/main -l /var/log/postgresql/postgresql.log -s -w"
user="postgres"
group="postgres"
type="forking"
pid_file="/var/run/postgresql/15-main.pid"
restart="on-failure"
restart_sec="5"
timeout_start="60"
timeout_stop="30"
target="default"

cgroup_memory_max="2G"
cgroup_pids_max="512"

depend() {
	require localfs
	require network
	after syslog
}

pre_start() {
	# Ensure PostgreSQL can write its runtime files.
	install -d -o postgres -g postgres -m 02775 /var/run/postgresql
	return 0
}

post_stop() {
	# Clean up stale PID file if pg_ctl left one.
	rm -f /var/run/postgresql/15-main.pid
}

reload() {
	/usr/lib/postgresql/15/bin/pg_ctl reload -D /var/lib/postgresql/15/main -s
}

healthcheck() {
	pg_isready -q -U postgres
}
