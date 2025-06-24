#!/bin/bash
#
# GEISA Conformance Launch script
# Copyright (C) 2025 Southern California Edison
#
# GEISA Conformance is free software, distributed under the Apache License
# version 2.0. See LICENSE for details.

RED="\e[31m"
ENDCOLOR="\e[0m"

ABSOLUTE_PATH="$(readlink -f "$0")"
TOPDIR="$(dirname "${ABSOLUTE_PATH}")"
NO_REPORTS=false

usage()
{
	cat <<EOF

GEISA Conformance Launch script

Usage: $0 --ip <board_ip> [options]

Required options:
  --ip <board_ip>     Specify the IP address of the board to run tests on

Optional options:
  --user <username>   Specify the username for SSH connection (default: root)
  --password <password>  Specify the password for SSH connection (default: empty)
  --no-reports        Do not generate test reports (only run tests and display results)
  --help              Show this help message
EOF
	exit 1
}

while [[ "$#" -gt 0 ]]; do
	case "$1" in
		--ip)
		BOARD_IP="$2"
		if [[ -z "${BOARD_IP}" ]]; then
			echo -e "${RED}Error:${ENDCOLOR} IP address cannot be empty"
			usage
		fi
		shift 2
		;;
		--user)
		BOARD_USER="$2"
		if [[ -z "${BOARD_USER}" ]]; then
			echo -e "${RED}Error:${ENDCOLOR} Username cannot be empty"
			usage
		fi
		shift 2
		;;
		--password)
		BOARD_PASSWORD="$2"
		if [[ -z "${BOARD_PASSWORD}" ]]; then
			echo -e "${RED}Error:${ENDCOLOR} Password cannot be empty"
			usage
		fi
		shift 2
		;;
		--no-reports)
		NO_REPORTS=true
		shift
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

if [[ -z ${BOARD_IP} ]]; then
	echo -e "${RED}Error:${ENDCOLOR} Board IP address is required."
	usage
fi

echo ""
echo "Starting GEISA Conformance Tests on board at ${BOARD_IP} ${NO_REPORTS+without reports}"
if ! ping -c 1 -W 2 "${BOARD_IP}" >/dev/null 2>&1; then
	echo -e "${RED}Error:${ENDCOLOR} Unable to reach board at ${BOARD_IP}"
	exit 1
fi

BOARD_USER=${BOARD_USER:-root}

echo "Connecting to board as user '${BOARD_USER}'"

echo ""
echo "Cleaning previous test results on board"
sshpass -p "${BOARD_PASSWORD}" ssh -o StrictHostKeyChecking=no "${BOARD_USER}@${BOARD_IP}" "rm -rf /tmp/conformance_tests" || {
	echo -e "${RED}Error:${ENDCOLOR} Failed to clean previous test results on board"
	exit 1
}

echo ""
echo "Copying conformance test files to board"
sshpass -p "${BOARD_PASSWORD}" scp -o StrictHostKeyChecking=no -r "${TOPDIR}"/src "${BOARD_USER}@${BOARD_IP}:/tmp/conformance_tests" 1>/dev/null || {
	echo -e "${RED}Error:${ENDCOLOR} Failed to copy test files to board"
	exit 1
}

if ! ${NO_REPORTS}; then
	echo ""
	echo "Launching tests..."
	sshpass -p "${BOARD_PASSWORD}" ssh -tt -o LogLevel=QUIET -o StrictHostKeyChecking=no "${BOARD_USER}@${BOARD_IP}" "/tmp/conformance_tests/cukinia/cukinia -f junitxml -o /tmp/conformance_tests/cukinia-tests/geisa-conformance-report.xml /tmp/conformance_tests/cukinia-tests/cukinia.conf"
	test_exit_code=$?


	echo ""
	echo "Copying tests report on host"
	mkdir -p "${TOPDIR}"/reports
	sshpass -p "${BOARD_PASSWORD}" scp -o StrictHostKeyChecking=no "${BOARD_USER}@${BOARD_IP}:/tmp/conformance_tests/cukinia-tests/geisa-conformance-report.xml" "${TOPDIR}"/reports 1>/dev/null || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to copy test report from board"
		exit 1
	}
	# shellcheck disable=SC2015
	cd "${TOPDIR}"/src/test-report-pdf && \
	./compile.py -i "${TOPDIR}"/reports/ -p 'GEISA conformance tests' -d "${TOPDIR}"/src/pdf_themes && \
	mv "${TOPDIR}"/src/test-report-pdf/test-report.pdf "${TOPDIR}"/reports/geisa-conformance-report.pdf || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to create PDF report"
		exit 1
	}
	cd "${TOPDIR}" || exit 1
else
	echo ""
	echo "Launching tests..."
	sshpass -p "${BOARD_PASSWORD}" ssh -tt -o LogLevel=QUIET -o StrictHostKeyChecking=no "${BOARD_USER}@${BOARD_IP}" "/tmp/conformance_tests/cukinia/cukinia /tmp/conformance_tests/cukinia-tests/cukinia.conf"
	test_exit_code=$?
fi

echo ""
echo "Cleaning up test files on board"
sshpass -p "${BOARD_PASSWORD}" ssh -o StrictHostKeyChecking=no "${BOARD_USER}@${BOARD_IP}" "rm -rf /tmp/conformance_tests" || {
	echo -e "${RED}Error:${ENDCOLOR} Failed to clean up test files on board"
	exit 1
}

exit "${test_exit_code}"
