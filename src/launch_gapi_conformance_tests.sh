#!/bin/bash
#
# GEISA Application Programming Interface Conformance functions
# Copyright (C) 2025 Southern California Edison
#
# GEISA Conformance is free software, distributed under the Apache License
# version 2.0. See LICENSE for details.

RED="\e[31m"
ENDCOLOR="\e[0m"
OCI_ENGINE="podman docker"
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

connect_and_transfer_gapi_with_ssh() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local topdir="$4"

	echo ""
	echo "Starting GEISA API Conformance Tests on board at ${board_ip}"
	if ! ping -c 1 -W 2 "${board_ip}" >/dev/null 2>&1; then
		echo -e "${RED}Error:${ENDCOLOR} Unable to reach board at ${board_ip}"
		exit 1
	fi

	echo "Connecting to board as user '${board_user}'"

	echo ""
	echo "Cleaning previous test results on board"
	SSH "rm -rf /tmp/GAPI-tests" || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to clean previous test results on board"
		exit 1
	}

	SSH mkdir -p /tmp/GAPI-tests || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to create test directory on board"
		exit 1
	}

	echo "Transferring test files to board"
	SCP "${topdir}"/gapi-conformance-tests.tar "${board_user}@[${board_ip}]:/tmp/GAPI-tests" 1>/dev/null || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to copy test files to board"
		exit 1
	}

}

verify_oci_engine_on_board() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"

	for oci_engine in ${OCI_ENGINE}; do
		SSH command -v "${oci_engine}" 1>/dev/null 2>&1 && {
			echo "${oci_engine}"
			return 0
		}
	done
}

launch_gapi_tests_with_report() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local topdir="$4"
	local oci_engine=""

	echo ""
	echo "Launching tests..."

	echo ""
	echo "Verifying OCI engine on board"

	oci_engine=$(verify_oci_engine_on_board "${board_ip}" "${board_user}" "${board_password}")

	if [[ -z "${oci_engine}" ]]; then
		echo -e "${RED}Error:${ENDCOLOR} No OCI engine found on board between ${OCI_ENGINE}"
		exit 1
	fi
	echo "Using ${oci_engine} as OCI engine on board"

	SSH "${oci_engine}" load -i /tmp/GAPI-tests/gapi-conformance-tests.tar 1>/dev/null || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to load test container on board"
		exit 1
	}
	SSH "${oci_engine}" run --rm --network host -v /tmp/GAPI-tests/:/reports localhost/gapi-conformance-tests:latest
	api_test_exit_code=$?

	echo ""
	echo "Copying tests report on host"
	mkdir -p "${topdir}"/reports
	SCP "${board_user}@[${board_ip}]:/tmp/GAPI-tests/geisa-api-conformance-report.xml" "${topdir}"/reports/ 1>/dev/null || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to retrieve test reports from board"
		exit 1
	}
	export api_test_exit_code
}

launch_gapi_tests_without_report() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local oci_engine=""

	echo ""
	echo "Launching tests..."

	echo ""
	echo "Verifying OCI engine on board"

	oci_engine=$(verify_oci_engine_on_board "${board_ip}" "${board_user}" "${board_password}")

	if [[ -z "${oci_engine}" ]]; then
		echo -e "${RED}Error:${ENDCOLOR} No OCI engine found on board between ${OCI_ENGINE}"
		exit 1
	fi
	echo "Using ${oci_engine} as OCI engine on board"

	SSH "${oci_engine}" load -i /tmp/GAPI-tests/gapi-conformance-tests.tar 1>/dev/null || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to load test container on board"
		exit 1
	}

	SSH "${oci_engine}" run -t --rm --network host localhost/gapi-conformance-tests:latest /etc/cukinia/cukinia /etc/GEISA-API-tests/cukinia.conf
	api_test_exit_code=$?

	export api_test_exit_code
}

cleanup_api_ssh() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"

	echo ""
	echo "Cleaning up test files on board"
	SSH "rm -rf /tmp/GAPI-tests" || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to clean up test files on board"
		exit 1
	}
}
