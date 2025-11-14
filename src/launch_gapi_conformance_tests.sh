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

create_gapi_test_container() {
	local topdir="$1"

	echo ""
	echo "Creating GEISA Application Programming Interface Conformance Test Container"

	rm -f "${topdir}"/gapi-conformance-tests.tar
	podman build -t gapi-conformance-tests:latest --arch arm64 -f "${topdir}"/src/GEISA-API-tests/Dockerfile "${topdir}"/src || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to build API test container"
		exit 1
	}
	podman save -o gapi-conformance-tests.tar gapi-conformance-tests:latest || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to save API test container"
		exit 1
	}
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
