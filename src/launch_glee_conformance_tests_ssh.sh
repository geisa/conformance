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
APPLICATIONS="${APPLICATIONS:-}"
GLEE_TESTS="${GLEE_TESTS:-}"
REFERENCE_APPLICATION="${REFERENCE_APPLICATION:-}"
NO_REBOOT="${NO_REBOOT:-false}"
REBOOT_PERSISTENCE_MARKER="${REBOOT_PERSISTENCE_MARKER:-}"

SSH() {
	local status

	#shellcheck disable=SC2086
	ssh ${CONFORMANCE_SSH_ARGS} -tt -o BatchMode=yes -o PreferredAuthentications=publickey -o LogLevel=QUIET -o StrictHostKeyChecking=no "${board_user}@${board_ip}" "$@"
	status=$?
	if [[ ${status} -ne 255 || -z "${board_password:-}" ]]; then
		return "${status}"
	fi
	command -v sshpass >/dev/null 2>&1 || {
		echo -e "${RED}Error:${ENDCOLOR} sshpass is required for password authentication"
		return 127
	}
	#shellcheck disable=SC2086
	SSHPASS="${board_password}" sshpass -e ssh ${CONFORMANCE_SSH_ARGS} -tt -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no -o LogLevel=QUIET -o StrictHostKeyChecking=no "${board_user}@${board_ip}" "$@"
}

SCP() {
	local status

	#shellcheck disable=SC2086
	scp ${CONFORMANCE_SCP_ARGS} -o BatchMode=yes -o PreferredAuthentications=publickey -o StrictHostKeyChecking=no "$@"
	status=$?
	if [[ ${status} -ne 255 || -z "${board_password:-}" ]]; then
		return "${status}"
	fi
	command -v sshpass >/dev/null 2>&1 || {
		echo -e "${RED}Error:${ENDCOLOR} sshpass is required for password authentication"
		return 127
	}
	#shellcheck disable=SC2086
	SSHPASS="${board_password}" sshpass -e scp ${CONFORMANCE_SCP_ARGS} -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no -o StrictHostKeyChecking=no "$@"
}

prepare_external_application() {
	#TODO: Implement this function to prepare external/non-reference GEISA applications for testing on the board.
	:
}

provision_reference_application() {
	local board_ip="$1" board_user="$2" board_password="$3" topdir="$4" target_arch="$5" app_name="$6"
	local source_dir build_output built_name image built_manifest manifest_path manifest_directory
	manifest_path="${APPLICATION_MANIFEST_PATH:-}"
	if [[ -z "${manifest_path}" || "${manifest_path:0:1}" != "/" ]]; then
		echo -e "${RED}Error:${ENDCOLOR} APPLICATION_MANIFEST_PATH must be an absolute path"
		return 1
	fi

	source_dir="${topdir}/src/GEISA-LEE-tests/src/community/applications/${app_name}"
	if [[ ! -d "${source_dir}" ]]; then
		echo -e "${RED}Error:${ENDCOLOR} Reference application source not found: ${source_dir}"
		return 1
	fi
	build_output="$(bash "${topdir}/src/GEISA-LEE-tests/tests.d/build-reference-application.sh" \
		"${source_dir}" "${target_arch}" "${topdir}/build/glee-apps")" || return 1
	IFS=$'\t' read -r built_name image built_manifest <<< "${build_output}"
	if [[ "${built_name}" != "${app_name}" ]]; then
		echo -e "${RED}Error:${ENDCOLOR} ${source_dir} builds '${built_name}', expected '${app_name}'"
		return 1
	fi
	manifest_directory="${manifest_path%/*}"
	manifest_directory="${manifest_directory:-/}"
	SSH "mkdir -p -- '${manifest_directory}'" || return 1
	SCP "${image}" \
		"${board_user}@[${board_ip}]:/tmp/conformance_tests/glee-apps/" 1>/dev/null || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to transfer ${app_name}"
		return 1
	}
	SCP "${built_manifest}" \
		"${board_user}@[${board_ip}]:${manifest_path}" 1>/dev/null || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to transfer ${manifest_path}"
		return 1
	}
	SSH "set -a; . /tmp/conformance_tests/GEISA-LEE-tests/tests_configuration.conf; \
		. /tmp/conformance_tests/GEISA-LEE-tests/user_configuration.conf; set +a; \
		python3 /tmp/conformance_tests/GEISA-LEE-tests/manage_package.py install \
		'/tmp/conformance_tests/glee-apps/$(basename "${image}")' \
		'${manifest_path}'" || return 1
	SSH "set -a; . /tmp/conformance_tests/GEISA-LEE-tests/tests_configuration.conf; \
		. /tmp/conformance_tests/GEISA-LEE-tests/user_configuration.conf; set +a; \
		python3 /tmp/conformance_tests/GEISA-LEE-tests/manage_package.py activate '${app_name}'"
}

connect_and_transfer_with_ssh() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local topdir="$4"
	local include_reboot_suite="${5:-false}"
	local runtime_archive
	local tar_excludes=(--exclude='GEISA-LEE-tests/src/community')

	if ! ${include_reboot_suite}; then
		tar_excludes+=(--exclude='*reboot.conf')
	fi

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
	echo "Copying LEE runtime files to board"
	runtime_archive="$(mktemp)" || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to create local LEE runtime archive"
		exit 1
	}
	tar -C "${topdir}/src" "${tar_excludes[@]}" \
		-czf "${runtime_archive}" cukinia GEISA-LEE-tests || {
		rm -f "${runtime_archive}"
		echo -e "${RED}Error:${ENDCOLOR} Failed to archive LEE runtime files"
		exit 1
	}
	SSH "mkdir -p /tmp/conformance_tests" || {
		rm -f "${runtime_archive}"
		echo -e "${RED}Error:${ENDCOLOR} Failed to create LEE runtime directory on board"
		exit 1
	}
	SCP "${runtime_archive}" \
		"${board_user}@[${board_ip}]:/tmp/conformance_tests/lee-runtime.tar.gz" 1>/dev/null || {
		rm -f "${runtime_archive}"
		echo -e "${RED}Error:${ENDCOLOR} Failed to copy LEE runtime files to board"
		exit 1
	}
	SSH "tar -C /tmp/conformance_tests -xzf /tmp/conformance_tests/lee-runtime.tar.gz && \
		rm /tmp/conformance_tests/lee-runtime.tar.gz" || {
		rm -f "${runtime_archive}"
		echo -e "${RED}Error:${ENDCOLOR} Failed to extract LEE runtime files on board"
		exit 1
	}
	rm -f "${runtime_archive}"
}

provision_glee_apps_with_ssh() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local topdir="$4"
	local target_arch app_name

	local remote_arch
	remote_arch="$(SSH "uname -m")" || return 1
	remote_arch="${remote_arch//$'\r'/}"
	target_arch="${remote_arch##*$'\n'}"
	SSH "mkdir -p /tmp/conformance_tests/glee-apps"

	for app_name in ${APPLICATIONS}; do
		if [[ "${app_name}" == "${REFERENCE_APPLICATION}" ]]; then
			provision_reference_application "${board_ip}" "${board_user}" "${board_password}" "${topdir}" "${target_arch}" "${app_name}" || exit 1
		fi
	done
}

wait_for_board_down() {
	local board_ip="$1"
	for _attempt in $(seq 1 30); do
		if ! ping -c 1 -W 2 "${board_ip}" >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
	done
	return 1
}

wait_for_board_up() {
	local board_ip="$1"
	for _attempt in $(seq 1 20); do
		if ping -c 1 -W 2 "${board_ip}" >/dev/null 2>&1; then
			return 0
		fi
		sleep 3
	done
	return 1
}

request_board_reset() {
	local board_ip="$1" board_user="$2" board_password="$3" method="$4" command

	case "${method}" in
		command)
			command="command -v systemctl >/dev/null 2>&1 && systemctl reboot -i || reboot || reboot -f"
			;;
		sysrq)
			command="echo 1 > /proc/sys/kernel/sysrq && echo b > /proc/sysrq-trigger"
			;;
		*)
			return 1
			;;
	esac

	SSH "sync; nohup sh -c 'sleep 1; ${command}' >/dev/null 2>&1 &" >/dev/null 2>&1 || true
}

reset_board_with_ssh() {
	local board_ip="$1" board_user="$2" board_password="$3"

	echo ""
	echo "Resetting board"
	request_board_reset "${board_ip}" "${board_user}" "${board_password}" command
	if ! wait_for_board_down "${board_ip}"; then
		echo "Board did not reset with a shutdown command, using SysRq"
		request_board_reset "${board_ip}" "${board_user}" "${board_password}" sysrq
		wait_for_board_down "${board_ip}" || {
			echo -e "${RED}Error:${ENDCOLOR} Board did not reset"
			return 1
		}
	fi
	echo "Waiting for board to boot"
	wait_for_board_up "${board_ip}" || {
		echo -e "${RED}Error:${ENDCOLOR} Board did not come back after reset"
		return 1
	}
	SSH "true" >/dev/null 2>&1 || {
		echo -e "${RED}Error:${ENDCOLOR} Board came back after reset, but SSH is not ready"
		return 1
	}
}

restore_glee_apps_with_ssh() {
	local board_ip="$1" board_user="$2" board_password="$3" app_name

	for app_name in ${APPLICATIONS}; do
		if SSH "test \"\$(lxc-info -P '${LXC_PATH:-}' -n '${app_name}' -sH)\" = RUNNING"; then
			continue
		fi
		SSH "set -a; . /tmp/conformance_tests/GEISA-LEE-tests/tests_configuration.conf; \
			. /tmp/conformance_tests/GEISA-LEE-tests/user_configuration.conf; set +a; \
			python3 /tmp/conformance_tests/GEISA-LEE-tests/manage_package.py activate '${app_name}'" || {
			echo -e "${RED}Error:${ENDCOLOR} Application did not restart after reset: ${app_name}"
			return 1
		}
	done
}

deactivate_glee_apps_with_ssh() {
	local board_ip="$1" board_user="$2" board_password="$3" app_name

	for app_name in ${APPLICATIONS}; do
		SSH "set -a; . /tmp/conformance_tests/GEISA-LEE-tests/tests_configuration.conf; \
			. /tmp/conformance_tests/GEISA-LEE-tests/user_configuration.conf; set +a; \
			python3 /tmp/conformance_tests/GEISA-LEE-tests/manage_package.py deactivate '${app_name}'" || {
			echo -e "${RED}Error:${ENDCOLOR} Application did not deactivate before reset: ${app_name}"
			return 1
		}
	done
}

# Prepare the board for the LEE reboot suite: seed each application's persistent
# storage with a marker, reset the board, then bring the applications back up.
prepare_glee_reboot_with_ssh() {
	local board_ip="$1" board_user="$2" board_password="$3" topdir="$4" marker marker_hex

	marker_hex=$(od -An -N16 -tx1 /dev/urandom) || return 1
	marker=".geisa-${marker_hex// /}"
	echo ""
	echo "Seeding persistent storage before board reset"
	SSH "set -a; . /tmp/conformance_tests/GEISA-LEE-tests/tests_configuration.conf; \
		. /tmp/conformance_tests/GEISA-LEE-tests/user_configuration.conf; set +a; \
		LEE_TESTS_DIR=/tmp/conformance_tests/GEISA-LEE-tests; \
		. \"\${LEE_TESTS_DIR}/tests.d/check-container.sh\"; \
		seed_container_reboot_persistence '${marker}'" || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to seed persistent storage before board reset"
		return 1
	}

	deactivate_glee_apps_with_ssh "${board_ip}" "${board_user}" "${board_password}" || return 1
	reset_board_with_ssh "${board_ip}" "${board_user}" "${board_password}" || return 1
	connect_and_transfer_with_ssh "${board_ip}" "${board_user}" "${board_password}" "${topdir}" true
	restore_glee_apps_with_ssh "${board_ip}" "${board_user}" "${board_password}" || return 1

	REBOOT_PERSISTENCE_MARKER="${marker}"
	export REBOOT_PERSISTENCE_MARKER
}

launch_glee_tests_with_report_ssh() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local topdir="$4"
	local remote_dir=/tmp/conformance_tests/GEISA-LEE-tests

	echo ""
	echo "Launching tests..."
	SSH "GLEE_TESTS=\"${GLEE_TESTS}\" /tmp/conformance_tests/cukinia/cukinia -f junitxml -o ${remote_dir}/geisa-lee-conformance-report.xml ${remote_dir}/cukinia.conf"
	lee_test_exit_code=$?

	echo ""
	echo "Copying tests report on host"
	mkdir -p "${topdir}"/reports
	SCP "${board_user}@[${board_ip}]:${remote_dir}/geisa-lee-conformance-report.xml" "${topdir}"/reports 1>/dev/null || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to copy test report from board"
		exit 1
	}

	if ! ${NO_REBOOT}; then
		if prepare_glee_reboot_with_ssh "${board_ip}" "${board_user}" "${board_password}" "${topdir}"; then
			echo ""
			echo "Launching reboot tests..."
			SSH "GLEE_TESTS=\"reboot\" REBOOT_PERSISTENCE_MARKER=\"${REBOOT_PERSISTENCE_MARKER}\" /tmp/conformance_tests/cukinia/cukinia -f junitxml -o ${remote_dir}/geisa-lee-reboot-conformance-report.xml ${remote_dir}/cukinia.conf" ||
				lee_test_exit_code=1

			echo ""
			echo "Copying reboot tests report on host"
			SCP "${board_user}@[${board_ip}]:${remote_dir}/geisa-lee-reboot-conformance-report.xml" "${topdir}"/reports 1>/dev/null || {
				echo -e "${RED}Error:${ENDCOLOR} Failed to copy reboot test report from board"
				exit 1
			}
		else
			echo -e "${RED}Error:${ENDCOLOR} Reboot tests could not run"
			lee_test_exit_code=1
		fi
	fi

	export lee_test_exit_code
}

launch_glee_tests_without_report_ssh() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local topdir="$4"
	local remote_dir=/tmp/conformance_tests/GEISA-LEE-tests

	echo ""
	echo "Launching tests..."
	SSH "GLEE_TESTS=\"${GLEE_TESTS}\" /tmp/conformance_tests/cukinia/cukinia ${remote_dir}/cukinia.conf"
	lee_test_exit_code=$?

	if ! ${NO_REBOOT}; then
		if prepare_glee_reboot_with_ssh "${board_ip}" "${board_user}" "${board_password}" "${topdir}"; then
			echo ""
			echo "Launching reboot tests..."
			SSH "GLEE_TESTS=\"reboot\" REBOOT_PERSISTENCE_MARKER=\"${REBOOT_PERSISTENCE_MARKER}\" /tmp/conformance_tests/cukinia/cukinia ${remote_dir}/cukinia.conf" ||
				lee_test_exit_code=1
		else
			echo -e "${RED}Error:${ENDCOLOR} Reboot tests could not run"
			lee_test_exit_code=1
		fi
	fi

	export lee_test_exit_code
}

cleanup_ssh() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local topdir="$4"
	local app_name cleanup_input app_dir status=0
	app_dir="${LXC_PATH}/${REFERENCE_APPLICATION}"

	print_cleanup_paths() {
		printf '  Application directory: %s\n' "${app_dir}"
		printf '  Manifest path: %s\n' "${APPLICATION_MANIFEST_PATH:-}"
		printf '  Base layer path: %s\n' "${BASE_LAYER_PATH:-}"
		printf '  Application layer path: %s\n' "${APPLICATION_LAYER_PATH:-}"
		printf '  Configuration layer path: %s\n' "${CONFIGURATION_LAYER_PATH:-}"
		printf '  Upper path: %s\n' "${UPPER_PATH:-}"
		printf '  Work path: %s\n' "${WORK_PATH:-}"
		printf '  Rootfs path: %s\n' "${ROOTFS_PATH:-}"
		printf '  Application image path: %s\n' "${APPLICATION_IMAGE_PATH:-}"
		printf '  Persistent image path: %s\n' "${PERSISTENT_IMAGE_PATH:-}"
		printf '  Test runtime directory: /tmp/conformance_tests\n'
	}

	echo ""
	echo "Cleaning up LEE test artifacts on board"
	print_cleanup_paths
	if ! wait_for_board_up "${board_ip}"; then
		echo "Warning: Board at ${board_ip} is not reachable. Cleanup failed." >&2
		echo "Manual cleanup required: de-provision '${REFERENCE_APPLICATION}' and unmount its filesystems, then remove '${app_dir}' and '/tmp/conformance_tests' on the board." >&2
		print_cleanup_paths >&2
		return 1
	fi
	for app_name in ${APPLICATIONS}; do
		if [[ "${app_name}" == "${REFERENCE_APPLICATION}" ]]; then
			cleanup_input="$({
				echo "set -a"
				cat "${topdir}/src/GEISA-LEE-tests/tests_configuration.conf"
				cat "${topdir}/src/GEISA-LEE-tests/user_configuration.conf"
				echo "set +a"
				echo "python3 - uninstall '${app_name}' <<'PYTHON'"
				cat "${topdir}/src/GEISA-LEE-tests/manage_package.py"
				echo "PYTHON"
			})"
			SSH "sh -s" <<< "${cleanup_input}" || status=1
		fi
	done
	SSH "rm -rf /tmp/conformance_tests '${APPLICATION_MANIFEST_PATH}' '${LXC_PATH}'" || status=1
	if [[ ${status} -ne 0 ]]; then
		echo -e "${RED}Error:${ENDCOLOR} Failed to clean up LEE test artifacts on board"
		echo "Manual cleanup required: de-provision '${REFERENCE_APPLICATION}' and unmount its filesystems, then remove '${app_dir}' and '/tmp/conformance_tests' on the board."
		print_cleanup_paths
		return 1
	fi
	return 0
}
