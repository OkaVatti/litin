#!/bin/sh
# /etc/litin/services/syslog/service.sh
#
# System syslog daemon.
# Works with syslog-ng, rsyslog, or busybox syslogd (change command as needed).
#
# This service is a boot-critical dependency for many other services.
# It uses type=notify so litind waits for it to signal readiness before
# starting dependents.  If your syslog daemon does not support sd_notify,
# change type to "simple".

name="syslog"
description="System syslog daemon"

# Choose one of the following lines for your syslog implementation:
# command="/usr/sbin/syslog-ng --foreground --no-caps"
# command="/usr/sbin/rsyslogd -n"
# command="/sbin/syslogd -n -O /var/log/messages"
command="/usr/sbin/syslog-ng --foreground --no-caps"

type="simple"
restart="on-failure"
restart_sec="3"
timeout_start="30"
timeout_stop="10"
target="boot"

cgroup_memory_max="64M"
cgroup_pids_max="32"

depend() {
	require localfs
	after udev
}

pre_start() {
	mkdir -p /var/log
	touch /var/log/messages /var/log/syslog 2>/dev/null || true
	return 0
}

reload() {
	kill -HUP "$MAINPID"
}

healthcheck() {
	kill -0 "$MAINPID" 2>/dev/null
}
