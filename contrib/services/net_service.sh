#!/bin/sh
# /etc/litin/services/network/service.sh
#
# Basic network interface bringup (oneshot).
# For production use, replace this with your network manager of choice.

name="network"
description="Basic network interface configuration"
command="/sbin/ip link set lo up && /sbin/ip link set eth0 up"
type="oneshot"
restart="no"
target="boot"

depend() {
	after localfs
}

pre_start() {
	# Load network kernel modules if needed.
	modprobe af_packet 2>/dev/null || true
	return 0
}

post_stop() {
	return 0
}
