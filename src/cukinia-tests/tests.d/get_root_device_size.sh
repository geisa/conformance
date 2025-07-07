#!/bin/sh
#
# Copyright (C) 2025 Southern California Edison

ROOT_DEVICE_MAJOR=$(mountpoint -d / | awk '{ split($1, x, ":"); print x[1] }')
if [ "${ROOT_DEVICE_MAJOR}" -eq 0 ]; then
	ROOT_DEVICE=$(cat /proc/mounts | awk '$2 == "/" { print $1 }')

	if [ $(echo "${ROOT_DEVICE}" | grep -c "mapper") -eq 1 ]; then
		ROOT_DEVICE=$(readlink -f "${ROOT_DEVICE}")
	fi
	if [ -d "/sys/class/block/$(basename ${ROOT_DEVICE})" ]; then
		ROOT_DEVICE="/dev/$(ls /sys/class/block/$(basename ${ROOT_DEVICE})/slaves)"
	fi
	ROOT_DEVICE_MAJOR=$(mountpoint -x "${ROOT_DEVICE}" | awk '{ split($1, x, ":"); print x[1] }')
fi
DEVICE_SIZE=$(awk '$1 == '${ROOT_DEVICE_MAJOR}' && $2 == "0" { print $3 }' /proc/partitions)
