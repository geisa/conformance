#!/bin/bash
#
# GEISA Conformance functions for SSH-based execution
# Copyright (C) 2025 Southern California Edison
#
# GEISA Conformance is free software, distributed under the Apache License
# version 2.0. See LICENSE for details.

RED="\e[31m"
ENDCOLOR="\e[0m"

SSH() {
	sshpass -p "${board_password}" ssh -tt -o LogLevel=QUIET -o StrictHostKeyChecking=no "${board_user}@${board_ip}" "$@"
}

SCP() {
	sshpass -p "${board_password}" scp -O -o StrictHostKeyChecking=no "$@"
}

connect_and_transfer_with_ssh() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local topdir="$4"

	echo ""
	echo "Starting GEISA Conformance Tests on board at ${board_ip}"
	if ! ping -c 1 -W 2 "${board_ip}" >/dev/null 2>&1; then
		echo -e "${RED}Error:${ENDCOLOR} Unable to reach board at ${board_ip}"
		exit 1
	fi

	echo "Connecting to board as user '${board_user}'"

	echo ""
	echo "Cleaning previous test results on board"
	SSH "rm -rf /tmp/conformance_tests" || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to clean previous test results on board"
		exit 1
	}

	echo ""
	echo "Copying conformance test files to board"
	SCP -r "${topdir}"/src "${board_user}@${board_ip}:/tmp/conformance_tests" 1>/dev/null || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to copy test files to board"
		exit 1
	}
}

launch_tests_with_report_ssh() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local topdir="$4"

	echo ""
	echo "Launching tests..."
	SSH "/tmp/conformance_tests/cukinia/cukinia -f junitxml -o /tmp/conformance_tests/cukinia-tests/geisa-conformance-report.xml /tmp/conformance_tests/cukinia-tests/cukinia.conf"
	test_exit_code=$?

	echo ""
	echo "Copying tests report on host"
	mkdir -p "${topdir}"/reports
	SCP "${board_user}@${board_ip}:/tmp/conformance_tests/cukinia-tests/geisa-conformance-report.xml" "${topdir}"/reports 1>/dev/null || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to copy test report from board"
		exit 1
	}

	export test_exit_code
}

launch_tests_without_report_ssh() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"

	echo ""
	echo "Launching tests..."
	SSH "/tmp/conformance_tests/cukinia/cukinia /tmp/conformance_tests/cukinia-tests/cukinia.conf"
	test_exit_code=$?

	export test_exit_code
}

launch_bandwidth_test_with_report_ssh() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local topdir="$4"

	echo ""
	echo "Launching bandwidth test..."
	(sleep 5; iperf3 -c "${board_ip}" --logfile /tmp/iperf.log) &
	SSH "/tmp/conformance_tests/cukinia/cukinia -f junitxml -o /tmp/conformance_tests/cukinia-tests/geisa-conformance-report-bandwidth.xml /tmp/conformance_tests/cukinia-tests/connectivity_tests_bandwidth.conf"
	bandwidth_test_exit_code=$?

	echo ""
	echo "Copying bandwidth test report on host"
	mkdir -p "${topdir}"/reports
	SCP "${board_user}@[${board_ip}]:/tmp/conformance_tests/cukinia-tests/geisa-conformance-report-bandwidth.xml" "${topdir}"/reports 1>/dev/null || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to copy bandwidth test report from board"
		exit 1
	}

	export bandwidth_test_exit_code
}

launch_bandwidth_test_without_report_ssh() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"

	echo ""
	echo "Launching bandwidth test..."
	(sleep 5; iperf3 -c "${board_ip}" --logfile /tmp/iperf.log) &
	SSH "/tmp/conformance_tests/cukinia/cukinia /tmp/conformance_tests/cukinia-tests/connectivity_tests_bandwidth.conf"
	bandwidth_test_exit_code=$?

	export bandwidth_test_exit_code
}

cleanup_ssh() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"

	echo ""
	echo "Cleaning up test files on board"
	SSH "rm -rf /tmp/conformance_tests" || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to clean up test files on board"
		exit 1
	}
}
