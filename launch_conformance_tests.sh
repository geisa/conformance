#!/bin/bash
#
# GEISA Conformance Launch script
# Copyright (C) 2025 Southern California Edison
#
# GEISA Conformance is free software, distributed under the Apache License
# version 2.0. See LICENSE for details.

RED="\e[31m"
ENDCOLOR="\e[0m"

usage()
{
	cat <<EOF

GEISA Conformance Launch script

Usage: $0 --ip <board_ip> [options]

Required options:
  --ip <board_ip>     Specify the IP address of the board to run tests on

Optional options:
  --user <username>   Specify the username for SSH connection (default: root)
  --help              Show this help message
EOF
	exit 1
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--ip)
		BOARD_IP="$2"
		if [[ -z "$BOARD_IP" ]]; then
			echo -e "${RED}Error:${ENDCOLOR} IP address cannot be empty"
			usage
		fi
		shift 2
		;;
		--user)
		BOARD_USER="$2"
		if [[ -z "$BOARD_USER" ]]; then
			echo -e "${RED}Error:${ENDCOLOR} Username cannot be empty"
			usage
		fi
		shift 2
		;;
		--help)
		usage
		;;
		*)
		echo -e "${RED}Error:${ENDCOLOR} Unknown option '$1'"
		usage
		;;
	esac
done

if [[ -z $BOARD_IP ]]; then
	echo -e "${RED}Error:${ENDCOLOR} Board IP address is required."
	usage
fi

echo ""
echo "Starting GEISA Conformance Tests on board at $BOARD_IP"
if ! ping -c 1 -W 2 "$BOARD_IP" >/dev/null 2>&1; then
	echo -e "${RED}Error:${ENDCOLOR} Unable to reach board at $BOARD_IP"
	exit 1
fi
