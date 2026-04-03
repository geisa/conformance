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

transfer_launch_gapi_tests_script() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local topdir="$4"

	if [[ ! -f "${topdir}"/launch_gapi_test_app.sh ]]; then
		echo -e "${RED}Error:${ENDCOLOR} No API launching script found. Create a launch_gapi_test_app.sh script (see launch_gapi_test_app.sh.template or read the README)"
		exit 1
	fi

	SSH "mkdir -p /tmp/GAPI-tests" || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to create test directory on board"
		exit 1
	}

	SCP "${topdir}"/launch_gapi_test_app.sh "${board_user}@[${board_ip}]:/tmp/GAPI-tests/launch_gapi_test_app.sh" 1>/dev/null || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to transfer API test launch script to board"
		exit 1
	}
}

create_gapi_test_squashfs() {
	local topdir="$1"

	echo ""
	echo "Creating GEISA Application Programming Interface Conformance Test Container"

	rm -rf "${topdir}"/src/GEISA-API-tests/build_rootfs

	# shellcheck disable=SC2015
	mkdir -p "${topdir}"/src/GEISA-API-tests/build_rootfs/etc/GEISA-API-tests && \
	mkdir -p "${topdir}"/src/GEISA-API-tests/build_rootfs/etc/cukinia && \
	mkdir -p "${topdir}"/src/GEISA-API-tests/build_rootfs/usr/bin && \
	mkdir -p "${topdir}"/src/GEISA-API-tests/build_rootfs/etc && \
	mkdir -p "${topdir}"/src/GEISA-API-tests/build_rootfs/usr/lib && \
	cp "${topdir}"/src/GEISA-API-tests/cukinia.conf "${topdir}"/src/GEISA-API-tests/build_rootfs/etc/GEISA-API-tests/cukinia.conf && \
	cp -r "${topdir}"/src/GEISA-API-tests/tests.d "${topdir}"/src/GEISA-API-tests/build_rootfs/etc/GEISA-API-tests/tests.d && \
	cp "${topdir}"/src/GEISA-API-tests/tests_configuration.conf "${topdir}"/src/GEISA-API-tests/build_rootfs/etc/GEISA-API-tests/tests_configuration.conf && \
	cp "${topdir}"/src/cukinia/cukinia "${topdir}"/src/GEISA-API-tests/build_rootfs/etc/cukinia/cukinia &&
	cp "${topdir}"/src/GEISA-API-tests/gapi-conformance-tests "${topdir}"/src/GEISA-API-tests/build_rootfs/usr/bin/gapi-conformance-tests || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to copy configuration files for API tests"
		exit 1
	}

	podman build -t gapi-conformance-tests:latest --arch arm64 \
		-v "${topdir}"/src/GEISA-API-tests/build_rootfs/usr/bin:/usr/local/bin/ \
		-v "${topdir}"/src/GEISA-API-tests/build_rootfs/etc:/usr/local/etc/ \
		-v "${topdir}"/src/GEISA-API-tests/build_rootfs/usr/lib:/usr/local/usr/lib \
		-f "${topdir}"/src/GEISA-API-tests/Dockerfile "${topdir}"/src || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to build API test container"
		exit 1
	}

	mksquashfs "${topdir}"/src/GEISA-API-tests/build_rootfs "${topdir}"/gapi-conformance-tests.squashfs -noappend -quiet || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to create squashfs for API tests"
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
	cleanup_api_ssh "${board_ip}" "${board_user}" "${board_password}" "${topdir}"

	SSH mkdir -p /tmp/GAPI-tests/{upper,work,base,app,rootfs} || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to create test directory on board"
		exit 1
	}

	echo "Transferring test squashfs to board"
	SCP "${topdir}"/gapi-conformance-tests.squashfs "${board_user}@[${board_ip}]:/tmp/GAPI-tests" 1>/dev/null || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to copy test files to board"
		exit 1
	}

}

launch_gapi_tests_with_report() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local topdir="$4"

	echo ""
	echo "Launching tests..."

	transfer_launch_gapi_tests_script "${board_ip}" "${board_user}" "${board_password}" "${topdir}" || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to transfer API test launch script to board"
		exit 1
	}

	SSH "chmod +x /tmp/GAPI-tests/launch_gapi_test_app.sh && /tmp/GAPI-tests/launch_gapi_test_app.sh report"
	api_test_exit_code=$?

	echo ""
	echo "Copying tests report on host"
	mkdir -p "${topdir}"/reports
	SCP "${board_user}@[${board_ip}]:/tmp/GAPI-tests/rootfs/geisa-api-conformance-report.xml" "${topdir}"/reports/ 1>/dev/null || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to retrieve test reports from board"
		exit 1
	}
	export api_test_exit_code
}

launch_gapi_tests_without_report() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local topdir="$4"

	echo ""
	echo "Launching tests..."

	transfer_launch_gapi_tests_script "${board_ip}" "${board_user}" "${board_password}" "${topdir}" || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to transfer API test launch script to board"
		exit 1
	}

	SSH "chmod +x /tmp/GAPI-tests/launch_gapi_test_app.sh && /tmp/GAPI-tests/launch_gapi_test_app.sh no-report"
	api_test_exit_code=$?

	export api_test_exit_code
}

cleanup_api_ssh() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local topdir="$4"

	echo ""
	echo "Cleaning up test files on board"

	transfer_launch_gapi_tests_script "${board_ip}" "${board_user}" "${board_password}" "${topdir}" || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to transfer API test launch script to board"
		exit 1
	}

	SSH "chmod +x /tmp/GAPI-tests/launch_gapi_test_app.sh && /tmp/GAPI-tests/launch_gapi_test_app.sh clean" || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to clean up test files on board"
		exit 1
	}

	SSH "rm -rf /tmp/GAPI-tests" || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to clean up test files on board"
		exit 1
	}
}
