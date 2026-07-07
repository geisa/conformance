#!/bin/bash
#
# GEISA Application & Device Management Conformance functions
# Copyright (C) 2026 Southern California Edison
#
# GEISA Conformance is free software, distributed under the Apache License
# version 2.0. See LICENSE for details.

# This file is intended to be sourced by ADM conformance test launcher scripts.
# It provides helper functions to set up the Leshan EMS server, connect to the
# board under test via SSH, run the Cukinia test suite, and clean up afterwards.

# Terminal color codes used in error messages.
RED="\e[31m"
ENDCOLOR="\e[0m"

# Extra SSH/SCP arguments (e.g. -p port, -i key). Populated by the caller
# before sourcing this file; left empty by default.
declare CONFORMANCE_SSH_ARGS
declare CONFORMANCE_SCP_ARGS

# SSH wrapper: run a command on the board as ${board_user}@${board_ip}.
# Relies on ${board_password}, ${board_user}, ${board_ip}, and CONFORMANCE_SSH_ARGS.
SSH() {
	#shellcheck disable=SC2086
	sshpass -p "${board_password}" ssh ${CONFORMANCE_SSH_ARGS} -o LogLevel=QUIET -o StrictHostKeyChecking=no "${board_user}@${board_ip}" "$@"
}

# SCP wrapper: copy files to/from the board. Uses the same credentials as SSH().
SCP() {
	#shellcheck disable=SC2086
	sshpass -p "${board_password}" scp ${CONFORMANCE_SCP_ARGS} -o StrictHostKeyChecking=no "$@"
}

# Generate a random 16-byte PSK as a lowercase hex string.
generate_gadm_psk() {
	hexdump -vn 16 -e '/1 "%02x"' /dev/urandom
}

# Build a minimal squashfs package containing a stub test application.
# Args:   package_dir - directory where the squashfs will be created.
# Prints: path to the created squashfs file.
create_gadm_test_squashfs() {
	local package_dir="$1"
	local rootfs_dir="${package_dir}/rootfs"
	local bin_dir="${rootfs_dir}/usr/bin"
	local package_name="geisa-app-1-1.0.1.squashfs"
	local package_path="${package_dir}/${package_name}"

	mkdir -p "${bin_dir}"

	cat > "${bin_dir}/geisa-app-1" <<'EOF'
#!/bin/sh
echo "Hello, GEISA!"
EOF

	chmod +x "${bin_dir}/geisa-app-1"
	mksquashfs "${rootfs_dir}" "${package_path}" -noappend -quiet > /dev/null 2>&1 || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to create squashfs for ADM client package"
		exit 1
	}
	rm -rf "${rootfs_dir}"

	echo "${package_path}"
}

# Remove the test squashfs package created by create_gadm_test_squashfs().
# Args: package_dir - directory that contains the squashfs file.
cleanup_gadm_test_squashfs() {
	local package_dir="$1"
	local package_path="${package_dir}/geisa-app-1-1.0.1.squashfs"

	if [[ -f "${package_path}" ]]; then
		rm -f "${package_path}"
	fi
}

# Determine the host's IP address as seen by the board by reading $SSH_CLIENT.
# Prints: host IP string, or an empty string if it cannot be determined.
deduce_host_ip_from_ssh() {
	local ssh_client
	ssh_client=$(SSH "echo \$SSH_CLIENT")
	echo "${ssh_client}" | awk '{print $1}'
}

# Poll the Leshan server URL until it responds or the attempt limit is reached.
# Args: server_url - base URL of the Leshan server (e.g. http://localhost:8080).
wait_for_gadm_server() {
	local server_url="$1"
	local attempts=30
	local attempt=0

	while (( attempt < attempts )); do
		if curl --silent --output /dev/null --fail --max-time 5 "${server_url}"; then
			return
		fi
		sleep 1
		attempt=$((attempt + 1))
	done

	echo -e "${RED}Error:${ENDCOLOR} Leshan server did not become ready"
	exit 1
}

# Start the Leshan EMS server jar in the background and export its PID as server_pid.
# Args: ems_server_path - path to the Leshan server jar file.
start_gadm_server() {
	local ems_server_path="$1"

	echo ""
	echo "Starting Leshan EMS server"
	java -jar "${ems_server_path}" >/dev/null 2>&1 &
	server_pid=$!

	export server_pid
}

# Start the ADM client on the board via SSH and export its PID as client_pid.
# Any previously running instance of the client is stopped first.
# Args: host_ip - IP address of the host, client_path - path to the ADM client binary,
#       client_psk_identity - PSK identity for the client, client_psk_value - PSK value for the client,
#       client_start_params - additional parameters for starting the client.
start_gadm_client_on_board() {
	local host_ip="$1"
	local client_path="$2"
	local client_psk_identity="$3"
	local client_psk_value="$4"
	local client_start_params="$5"

	echo ""
	echo "Starting ADM client on board"
	SSH "pkill -f '${client_path}' >/dev/null 2>&1 || true"
	SSH "nohup ${client_path} ${client_start_params} >/dev/null 2>/tmp/adm_client.log &"
	sleep 5 	# Allow some time for DTLS handshake
	client_pid=$(SSH "pgrep -f '${client_path}'")

	if [[ -z "${client_pid}" ]]; then
		echo -e "${RED}Error:${ENDCOLOR} Failed to start ADM client on board"
		exit 1
	fi

	export client_pid
}

# Stop the ADM client on the board and the Leshan server on the host.
cleanup_gadm_ssh() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local client_pid="$4"
	local server_pid="$5"

	echo ""
	echo "Cleaning up ADM test client and server processes"
	echo ""
	if [[ -n "${client_pid}" ]]; then
		SSH "kill ${client_pid} >/dev/null 2>&1 || true"
	fi

	if [[ -n "${server_pid}" ]] && kill -0 "${server_pid}" >/dev/null 2>&1; then
		kill "${server_pid}" >/dev/null 2>&1 || true
		wait "${server_pid}" 2>/dev/null || true
	fi
}

# Register PSK credentials for the ADM client with the Leshan server REST API.
# Args: api_endpoint, endpoint (client name registered with Leshan), identity, key.
provision_gadm_client_credentials() {
	local api_endpoint="$1"
	local endpoint="$2"
	local identity="$3"
	local key="$4"

	curl -s -X PUT \
		-H "Content-Type: application/json" \
		-d "{\"endpoint\":\"${endpoint}\",\"tls\":{\"mode\":\"psk\",\"details\":{\"identity\":\"${identity}\",\"key\":\"${key}\"}}}" \
		"${api_endpoint}/security/clients/"
}

# Create the test output directory and set the execute permission on cukinia.
# Args: topdir — root of the conformance test repository.
prepare_gadm_test_files() {
	local topdir="$1"

	echo ""
	echo "Preparing GEISA ADM conformance test files"
	mkdir -p "${topdir}/reports" || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to create test directory"
		exit 1
	}
	chmod +x "${topdir}/src/cukinia/cukinia" || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to set execute permission on cukinia"
		exit 1
	}
}

# A full ADM conformance test run consists of the following steps:
#   1. Start the Leshan server and register client credentials.
#   2. Deploy and start the ADM client on the board.
#   3. Run the Cukinia test suite.
#   4. Clean up processes and temporary files.
#	5. If launched with report generation enabled,
#	   the test results will be saved in JUnit XML format to the reports directory.
#  	   (see the 2 helper functions below)

launch_gadm_tests() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local topdir="$4"
	local host_ip="${5:-}"
	local package_path="$6"
	local server_url="${7:-http://localhost:8080}"
	local api_endpoint="${8:-${server_url}/api}"
	local client_name="${9:-geisa_adm_client}"
	local client_path="${10:-/usr/bin/adm_client}"		# Default path to ADM client running on LEE-mockup platform
	local client_psk_identity="${11:-${client_name}}"
	local client_psk_value="${12:-$(generate_gadm_psk)}"
	local client_start_params="${13:-}"
	local with_report="${14:-false}"

	local ems_server_path="${topdir}/src/leshan/leshan_ems_server.jar"
	local server_pid=""
	local client_pid=""
	local adm_test_exit_code=0

	if ! ping -c 1 -W 2 "${board_ip}" >/dev/null 2>&1; then
		echo -e "${RED}Error:${ENDCOLOR} Unable to reach board at ${board_ip}"
		exit 1
	fi

	# If host_ip is not provided, deduce it from the SSH session.
	# This requires the EMS server to be running on the same host as the one
	# initiating the SSH connection to the board.
	# Note that this is specific to a Wakaama-based ADM client. Other implementation may not
	# require the host IP to be specified at all, or may require a different method of deducing it.
	if [[ -z "${host_ip}" ]]; then
		echo ""
		echo "No host IP provided, deducing from SSH session..."
		host_ip=$(deduce_host_ip_from_ssh)
		if [[ -z "${host_ip}" ]]; then
			echo -e "${RED}Error:${ENDCOLOR} Could not deduce host IP from SSH session. Please specify --host-ip explicitly."
			exit 1
		fi
		echo "Deduced host IP: ${host_ip}"
	fi

	client_start_params="${client_start_params:-"-4 -h ${host_ip} -p 5684 -i ${client_psk_identity} -s ${client_psk_value}"}"

	if [[ -z "${package_path}" ]]; then
		echo ""
		echo "No package specified, creating GEISA ADM test package squashfs..."
		package_path=$(create_gadm_test_squashfs "${topdir}")
	fi

	if [[ ! -f "${ems_server_path}" ]]; then
		echo -e "${RED}Error:${ENDCOLOR} Leshan jar not found at ${ems_server_path}"
		exit 1
	fi

	echo ""
	echo "Starting GEISA Application & Device Management Conformance Tests on board at ${board_ip}"
	echo "Connecting to board as user '${board_user}'"

	# Exporting variables for cukinia
	export topdir api_endpoint client_name package_path
	prepare_gadm_test_files "${topdir}"

	# Leshan server and ADM client setup
	start_gadm_server "${ems_server_path}"
	wait_for_gadm_server "${server_url}"
	provision_gadm_client_credentials "${api_endpoint}" "${client_name}" "${client_psk_identity}" "${client_psk_value}"
	sleep 3
	start_gadm_client_on_board "${host_ip}" "${client_path}" "${client_psk_identity}" "${client_psk_value}" "${client_start_params}"

	echo ""
	echo "Launching tests..."
	if [[ "${with_report}" == "true" ]]; then
		"${topdir}"/src/cukinia/cukinia -f junitxml -o "${topdir}/reports/geisa-adm-conformance-report.xml" "${topdir}/src/GEISA-ADM-tests/cukinia.conf"
	else
		"${topdir}"/src/cukinia/cukinia "${topdir}/src/GEISA-ADM-tests/cukinia.conf"
	fi
	adm_test_exit_code=$?

	cleanup_gadm_ssh "${board_ip}" "${board_user}" "${board_password}" "${client_pid}" "${server_pid}"
	cleanup_gadm_test_squashfs "${topdir}"

	export adm_test_exit_code
}

launch_gadm_tests_with_report() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local topdir="$4"
	local host_ip="$5"
	local package_path="$6"
	local server_url="$7"
	local api_endpoint="$8"
	local client_name="${9}"
	local client_path="${10}"
	local client_psk_identity="${11}"
	local client_psk_value="${12}"
	local client_start_params="${13}"

	launch_gadm_tests "${board_ip}" \
		"${board_user}" \
		"${board_password}" \
		"${topdir}" \
		"${host_ip}" \
		"${package_path}" \
		"${server_url}" \
		"${api_endpoint}" \
		"${client_name}" \
		"${client_path}" \
		"${client_psk_identity}" \
		"${client_psk_value}" \
		"${client_start_params}" \
		"true"
}

launch_gadm_tests_without_report() {
	local board_ip="$1"
	local board_user="$2"
	local board_password="$3"
	local topdir="$4"
	local host_ip="$5"
	local package_path="$6"
	local server_url="$7"
	local api_endpoint="$8"
	local client_name="${9}"
	local client_path="${10}"
	local client_psk_identity="${11}"
	local client_psk_value="${12}"
	local client_start_params="${13}"

	launch_gadm_tests "${board_ip}" \
		"${board_user}" \
		"${board_password}" \
		"${topdir}" \
		"${host_ip}" \
		"${package_path}" \
		"${server_url}" \
		"${api_endpoint}" \
		"${client_name}" \
		"${client_path}" \
		"${client_psk_identity}" \
		"${client_psk_value}" \
		"${client_start_params}" \
		"false"
}
