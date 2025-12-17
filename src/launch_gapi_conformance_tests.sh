#!/bin/bash
#
# GEISA Application Programming Interface Conformance functions
# Copyright (C) 2025 Southern California Edison
#
# GEISA Conformance is free software, distributed under the Apache License
# version 2.0. See LICENSE for details.

RED="\e[31m"
ENDCOLOR="\e[0m"
CONTAINER_ENGINE="lxc-execute"
LXC_ARGS="-f /etc/lxc/default.conf -s lxc.uts.name=GAPI-tests -s lxc.rootfs.path=dir:/tmp/GAPI-tests/rootfs --share-net 1"
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

create_gapi_test_squashfs() {
	local topdir="$1"

	echo ""
	echo "Creating GEISA Application Programming Interface Conformance Test Container"

	rm -rf "${topdir}"/src/GEISA-API-tests/build_rootfs

	# shellcheck disable=SC2015
	mkdir -p "${topdir}"/src/GEISA-API-tests/build_rootfs/etc/GEISA-API-tests && \
	mkdir -p "${topdir}"/src/GEISA-API-tests/build_rootfs/etc/cukinia && \
	mkdir -p "${topdir}"/src/GEISA-API-tests/build_rootfs/usr/bin && \
	cp "${topdir}"/src/GEISA-API-tests/cukinia.conf "${topdir}"/src/GEISA-API-tests/build_rootfs/etc/GEISA-API-tests/cukinia.conf && \
	cp -r "${topdir}"/src/GEISA-API-tests/tests.d "${topdir}"/src/GEISA-API-tests/build_rootfs/etc/GEISA-API-tests/tests.d && \
	cp "${topdir}"/src/GEISA-API-tests/tests_configuration.conf "${topdir}"/src/GEISA-API-tests/build_rootfs/etc/GEISA-API-tests/tests_configuration.conf && \
	cp "${topdir}"/src/cukinia/cukinia "${topdir}"/src/GEISA-API-tests/build_rootfs/etc/cukinia/cukinia || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to copy configuration files for API tests"
		exit 1
	}

	podman build -t gapi-conformance-tests:latest --arch arm64 -v "${topdir}"/src/GEISA-API-tests/build_rootfs/usr/bin:/usr/local/bin/ -f "${topdir}"/src/GEISA-API-tests/Dockerfile "${topdir}"/src || {
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
	cleanup_api_ssh "${board_ip}" "${board_user}" "${board_password}"

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

verify_container_engine_on_board() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"

	for container_engine in ${CONTAINER_ENGINE}; do
		SSH command -v "${container_engine}" 1>/dev/null 2>&1 && {
			echo "${container_engine}"
			return 0
		}
	done
}

mount_overlayfs_on_board() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"

	echo ""
	echo "Mounting overlay filesystem on board"

	SSH mount -t squashfs -o loop /etc/geisa/*.squashfs /tmp/GAPI-tests/base || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to mount base filesystem on board"
		exit 1
	}
	SSH mount -t squashfs -o loop /tmp/GAPI-tests/gapi-conformance-tests.squashfs /tmp/GAPI-tests/app || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to mount app filesystem on board"
		exit 1
	}
	SSH mount -t overlay overlay -o lowerdir=/tmp/GAPI-tests/base:/tmp/GAPI-tests/app,upperdir=/tmp/GAPI-tests/upper,workdir=/tmp/GAPI-tests/work /tmp/GAPI-tests/rootfs || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to mount overlay filesystem on board"
		exit 1
	}
}

launch_gapi_tests_with_report() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local topdir="$4"
	local container_engine=""

	echo ""
	echo "Launching tests..."

	echo ""
	echo "Verifying container engine on board"

	container_engine=$(verify_container_engine_on_board "${board_ip}" "${board_user}" "${board_password}")

	if [[ -z "${container_engine}" ]]; then
		echo -e "${RED}Error:${ENDCOLOR} No container engine found on board between ${CONTAINER_ENGINE}"
		exit 1
	fi
	echo "Using ${container_engine} as container engine on board"

	mount_overlayfs_on_board "${board_ip}" "${board_user}" "${board_password}"

	SSH "${container_engine}" "${LXC_ARGS}" -n GAPI-tests -- /etc/cukinia/cukinia -f junitxml -o /geisa-api-conformance-report.xml /etc/GEISA-API-tests/cukinia.conf
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
	local container_engine=""

	echo ""
	echo "Launching tests..."

	echo ""
	echo "Verifying container engine on board"

	container_engine=$(verify_container_engine_on_board "${board_ip}" "${board_user}" "${board_password}")

	if [[ -z "${container_engine}" ]]; then
		echo -e "${RED}Error:${ENDCOLOR} No container engine found on board between ${CONTAINER_ENGINE}"
		exit 1
	fi
	echo "Using ${container_engine} as container engine on board"


	mount_overlayfs_on_board "${board_ip}" "${board_user}" "${board_password}"

	SSH "${container_engine}" "${LXC_ARGS}" -n GAPI-tests -- /etc/cukinia/cukinia /etc/GEISA-API-tests/cukinia.conf
	api_test_exit_code=$?

	export api_test_exit_code
}

cleanup_api_ssh() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local container_engine=""

	echo ""
	echo "Cleaning up test files on board"
	if SSH mountpoint -q /tmp/GAPI-tests/rootfs; then
		SSH "umount /tmp/GAPI-tests/rootfs" || {
			echo -e "${RED}Error:${ENDCOLOR} Failed to unmount test filesystem on board"
			exit 1
		}
	fi
	if SSH mountpoint -q /tmp/GAPI-tests/base; then
		SSH "umount /tmp/GAPI-tests/base" || {
			echo -e "${RED}Error:${ENDCOLOR} Failed to unmount base filesystem on board"
			exit 1
		}
	fi
	if SSH mountpoint -q /tmp/GAPI-tests/app; then
		SSH "umount /tmp/GAPI-tests/app" || {
			echo -e "${RED}Error:${ENDCOLOR} Failed to unmount app filesystem on board"
			exit 1
		}
	fi
	SSH "rm -rf /tmp/GAPI-tests" || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to clean up test files on board"
		exit 1
	}
}
