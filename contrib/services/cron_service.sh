#!/bin/sh
# /etc/litin/services/cron/service.sh
#
# System cron daemon (vixie-cron / cronie compatible).

name="cron"
description="System cron daemon"
command="/usr/sbin/cron -f -L 15"
user="root"
type="simple"
restart="always"
restart_sec="5"
timeout_stop="10"
target="default"

cgroup_memory_max="64M"
cgroup_pids_max="64"

depend() {
	require localfs
	after syslog
	after network
}

pre_start() {
	# Ensure spool directories exist.
	mkdir -p /var/spool/cron/crontabs
	chmod 1730 /var/spool/cron/crontabs
	return 0
}

reload() {
	kill -HUP "$MAINPID"
}
