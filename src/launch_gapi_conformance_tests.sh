#!/bin/bash
#
# GEISA Application Programming Interface Conformance functions
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

launch_gapi_tests_with_report() {
	local topdir="$1"

	echo ""
	echo "Starting GEISA Application Programming Interface Conformance Tests"
	"${topdir}"/src/cukinia/cukinia -f junitxml -o "${topdir}"/reports/geisa-api-conformance-report.xml "${topdir}"/src/GEISA-API-tests/cukinia.conf
	api_test_exit_code=$?

	export api_test_exit_code
}

launch_gapi_tests_without_report() {
	local topdir="$1"

	echo ""
	echo "Starting GEISA Application Programming Interface Conformance Tests"
	"${topdir}"/src/cukinia/cukinia "${topdir}"/src/GEISA-API-tests/cukinia.conf
	api_test_exit_code=$?

	export api_test_exit_code
}
