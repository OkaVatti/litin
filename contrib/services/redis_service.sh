#!/bin/sh
# /etc/litin/services/redis/service.sh
#
# Redis in-memory data store.
# Demonstrates type=notify with a custom wrapper that sends READY=1.

name="redis"
description="Redis in-memory data store"
command="/usr/bin/redis-server /etc/redis/redis.conf --daemonize no"
user="redis"
group="redis"
type="simple"
restart="on-failure"
restart_sec="3"
timeout_start="30"
timeout_stop="15"
target="default"

cgroup_memory_max="512M"
cgroup_pids_max="64"

depend() {
	require localfs
	want network
	after syslog
}

pre_start() {
	mkdir -p /var/lib/redis /var/log/redis /run/redis
	chown redis:redis /var/lib/redis /var/log/redis /run/redis 2>/dev/null || true
	return 0
}

reload() {
	# Redis supports CONFIG REWRITE + BGSAVE via SIGTERM is too blunt.
	# Send a custom signal that triggers config reload.
	redis-cli CONFIG REWRITE 2>/dev/null || true
	kill -HUP "$MAINPID"
}

healthcheck() {
	redis-cli PING 2>/dev/null | grep -q PONG
}
