#!/bin/bash
#
# GEISA Linux Execution Environment Conformance functions for SSH-based execution
# Copyright (C) 2025 Southern California Edison
#
# GEISA Conformance is free software, distributed under the Apache License
# version 2.0. See LICENSE for details.

RED="\e[31m"
ENDCOLOR="\e[0m"
declare CONFORMANCE_SSH_ARGS
declare CONFORMANCE_SCP_ARGS

SSH() {
	#shellcheck disable=SC2086
	sshpass -p "${board_password}" ssh ${CONFORMANCE_SSH_ARGS} -tt -o LogLevel=QUIET -o StrictHostKeyChecking=no "${board_user}@${board_ip}" "$@"
}

SCP() {
	#shellcheck disable=SC2086
	sshpass -p "${board_password}" scp ${CONFORMANCE_SCP_ARGS} -o StrictHostKeyChecking=no "$@"
}

connect_and_transfer_with_ssh() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local topdir="$4"

	echo ""
	echo "Starting GEISA Linux Execution Environment Conformance Tests on board at ${board_ip}"
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
	SCP -r "${topdir}"/src "${board_user}@[${board_ip}]:/tmp/conformance_tests" 1>/dev/null || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to copy test files to board"
		exit 1
	}
}

launch_glee_tests_with_report_ssh() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local topdir="$4"

	# Get host date for NTP test
	CURRENT_DATE_UTC=$(date -u +"%Y-%m-%d_%H:%M")

	echo ""
	echo "Launching tests..."
	SSH "CURRENT_DATE_UTC=${CURRENT_DATE_UTC} GLEE_TESTS=\"${GLEE_TESTS}\" /tmp/conformance_tests/cukinia/cukinia -f junitxml -o /tmp/conformance_tests/GEISA-LEE-tests/geisa-lee-conformance-report.xml /tmp/conformance_tests/GEISA-LEE-tests/cukinia.conf"
	lee_test_exit_code=$?

	echo ""
	echo "Copying tests report on host"
	mkdir -p "${topdir}"/reports
	SCP "${board_user}@[${board_ip}]:/tmp/conformance_tests/GEISA-LEE-tests/geisa-lee-conformance-report.xml" "${topdir}"/reports 1>/dev/null || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to copy test report from board"
		exit 1
	}

	export lee_test_exit_code
}

launch_glee_tests_without_report_ssh() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"

	# Get host date for NTP test
	CURRENT_DATE_UTC=$(date -u +"%Y-%m-%d_%H:%M")

	echo ""
	echo "Launching tests..."
	SSH "CURRENT_DATE_UTC=${CURRENT_DATE_UTC} GLEE_TESTS=\"${GLEE_TESTS}\" /tmp/conformance_tests/cukinia/cukinia /tmp/conformance_tests/GEISA-LEE-tests/cukinia.conf"
	lee_test_exit_code=$?

	export lee_test_exit_code
}

launch_bandwidth_test_with_report_ssh() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local topdir="$4"

	bandwidth_test_exit_code=0

	if [[ -z "${GLEE_TESTS}" ]] || echo "${GLEE_TESTS}" | grep -Eq "(^| )connectivity_tests_bandwidth($| )"; then
		echo ""
		echo "Launching bandwidth test..."
		(sleep 5; iperf3 -c "${board_ip}" --logfile /tmp/iperf.log) &
		SSH "/tmp/conformance_tests/cukinia/cukinia -f junitxml -o /tmp/conformance_tests/GEISA-LEE-tests/geisa-lee-conformance-report-bandwidth.xml /tmp/conformance_tests/GEISA-LEE-tests/connectivity_tests_bandwidth.conf"
		bandwidth_test_exit_code=$?

		echo ""
		echo "Copying bandwidth test report on host"
		mkdir -p "${topdir}"/reports
		SCP "${board_user}@[${board_ip}]:/tmp/conformance_tests/GEISA-LEE-tests/geisa-lee-conformance-report-bandwidth.xml" "${topdir}"/reports 1>/dev/null || {
			echo -e "${RED}Error:${ENDCOLOR} Failed to copy bandwidth test report from board"
			exit 1
		}
	fi

	export bandwidth_test_exit_code
}

launch_bandwidth_test_without_report_ssh() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"

	bandwidth_test_exit_code=0

	if [[ -z "${GLEE_TESTS}" ]] || echo "${GLEE_TESTS}" | grep -Eq "(^| )connectivity_tests_bandwidth($| )"; then
		echo ""
		echo "Launching bandwidth test..."
		(sleep 5; iperf3 -c "${board_ip}" --logfile /tmp/iperf.log) &
		SSH "/tmp/conformance_tests/cukinia/cukinia /tmp/conformance_tests/GEISA-LEE-tests/connectivity_tests_bandwidth.conf"
		bandwidth_test_exit_code=$?
	fi

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
