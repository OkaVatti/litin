#!/bin/sh
# /etc/litin/services/sshd/service.sh
#
# OpenSSH server service definition for Litin.

name="sshd"
description="OpenSSH server daemon"
command="/usr/sbin/sshd -D -e"
user="root"
type="simple"
restart="on-failure"
restart_sec="5"
timeout_start="30"
timeout_stop="20"
target="default"

cgroup_memory_max="128M"
cgroup_pids_max="128"

depend() {
	require network
	require localfs
	want logger
	conflicts dropbear
}

pre_start() {
	# Generate host keys if missing.
	if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
		ssh-keygen -A || return 1
	fi
	# Ensure privilege separation directory exists.
	mkdir -p /run/sshd
	chmod 755 /run/sshd
	return 0
}

reload() {
	kill -HUP "$MAINPID"
}

healthcheck() {
	kill -0 "$MAINPID" 2>/dev/null
}
