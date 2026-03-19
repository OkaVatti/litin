#!/bin/sh
# /etc/litin/services/udev/service.sh
#
# udev device manager.
#
# udev must start early in the boot sequence before any services that
# depend on device nodes being available.  It is a hard requirement for
# most device-facing services.
#
# On systems using eudev or mdev, replace the command accordingly.

name="udev"
description="udev device manager"
command="/sbin/udevd --daemon=0"
type="simple"
restart="on-failure"
restart_sec="2"
timeout_start="30"
timeout_stop="10"
target="boot"

cgroup_memory_max="128M"
cgroup_pids_max="64"

depend() {
	require localfs
	before network
	before syslog
}

pre_start() {
	# Mount devtmpfs if not already mounted.
	if ! mountpoint -q /dev 2>/dev/null; then
		mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
	fi
	mkdir -p /dev/pts /dev/shm
	return 0
}

post_start() {
	# Trigger udev events for devices already present.
	udevadm trigger --action=add 2>/dev/null || true
	udevadm settle --timeout=5 2>/dev/null || true
	return 0
}

reload() {
	udevadm control --reload-rules
}

healthcheck() {
	udevadm control --ping 2>/dev/null
}
