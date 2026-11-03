#!/bin/sh
#
# GEISA Conformance board script printing the platform details the
# specification relies on. The launchers copy it to the board and run it
# with sh before the tests start.
# Copyright (C) 2026 Southern California Edison
#
# GEISA Conformance is free software, distributed under the Apache License
# version 2.0. See LICENSE for details.

# Every probe is best-effort, so masked return values are intended.
# shellcheck disable=SC2312
exec 2>/dev/null
export LC_ALL=C
detail() {
	if [ -n "$3" ]; then
		echo "$1: $3"
	elif [ -n "$2" ] && ! command -v "$2" >/dev/null; then
		echo "$1: unknown, $2 not found"
	else
		echo "$1: unknown"
	fi
}
detail "Board" "" "$(tr -d '\0' < /proc/device-tree/model)"
detail "Architecture" uname "$(uname -m)"
detail "CPU" lscpu "$(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -n 1)"
detail "CPU cores" nproc "$(nproc)"
detail "Memory" awk "$(awk '/^MemTotal:/ {print int($2 / 1024) " MiB"}' /proc/meminfo)"
detail "Persistent storage" df "$(df -Pk /platform | awk 'NR == 2 {print int($2 / 1024) " MiB total, " int($4 / 1024) " MiB free (" $1 ")"}')"
detail "Root storage" df "$(df -Pk / | awk 'NR == 2 {print int($2 / 1024) " MiB total, " int($4 / 1024) " MiB free (" $1 ")"}')"
detail "Distribution" "" "$([ -r /etc/os-release ] && . /etc/os-release && echo "${PRETTY_NAME}")"
detail "Kernel" uname "$(uname -sr)"
detail "C library" ldd "$(getconf GNU_LIBC_VERSION || { command -v ldd >/dev/null && ldd --version 2>&1 | head -n 1; })"
detail "cgroups" stat "$(stat -fc %T /sys/fs/cgroup)"
detail "Container engine" lxc-info "$(lxc-info --version | sed 's/^/lxc /')"
detail "nftables" nft "$(nft --version)"
detail "iptables" iptables "$(iptables --version)"
filesystems=""
for fs in overlay squashfs; do
if grep -qw "${fs}" /proc/filesystems || modinfo "${fs}" >/dev/null; then
filesystems="${filesystems:+${filesystems} }${fs}"
fi
done
detail "Filesystems" "" "${filesystems}"
