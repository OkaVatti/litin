#!/bin/sh
# /etc/litin/services/nginx/service.sh
#
# Nginx web server service definition for Litin.
# Drop this directory at /etc/litin/services/nginx/
# then: litinctl enable nginx && litinctl start nginx

name="nginx"
description="Nginx HTTP server"
command="/usr/sbin/nginx -g 'daemon off;'"
user="nginx"
group="nginx"
type="simple"
restart="on-failure"
restart_sec="2"
timeout_start="30"
timeout_stop="30"
working_dir="/var/lib/nginx"
target="default"

# cgroup resource limits
cgroup_memory_max="256M"
cgroup_pids_max="256"
cgroup_cpu_max="80000 100000"

depend() {
	require network
	require localfs
	want logger
	after firewall
}

pre_start() {
	# Ensure runtime directories exist with correct ownership.
	mkdir -p /run/nginx /var/log/nginx /var/lib/nginx/tmp
	chown -R nginx:nginx /run/nginx /var/log/nginx 2>/dev/null || true
	# Validate config before starting.
	/usr/sbin/nginx -t -q || return 1
	return 0
}

post_stop() {
	rm -f /run/nginx/*.pid
}

reload() {
	# Graceful config reload — no dropped connections.
	kill -HUP "$MAINPID"
}

healthcheck() {
	# Verify the HTTP server is accepting connections.
	if command -v curl >/dev/null 2>&1; then
		curl -sf --max-time 5 http://127.0.0.1/ >/dev/null || return 1
	else
		kill -0 "$MAINPID" 2>/dev/null || return 1
	fi
	return 0
}
