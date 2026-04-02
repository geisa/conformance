#!/bin/bash
#
# GEISA Conformance Launch script
# Copyright (C) 2025 Southern California Edison
#
# GEISA Conformance is free software, distributed under the Apache License
# version 2.0. See LICENSE for details.

RED="\e[31m"
ORANGE="\e[33m"
ENDCOLOR="\e[0m"

ABSOLUTE_PATH="$(readlink -f "$0")"
TOPDIR="$(dirname "${ABSOLUTE_PATH}")"
NO_REPORTS=false
bandwidth_test_exit_code=0
lee_test_exit_code=0
adm_test_exit_code=0
api_test_exit_code=0

source "${TOPDIR}"/src/launch_glee_conformance_tests_ssh.sh
source "${TOPDIR}"/src/launch_gapi_conformance_tests.sh
source "${TOPDIR}"/src/launch_gadm_conformance_tests.sh

usage()
{
	cat <<EOF

GEISA Conformance Launch script

Usage: $0 [options]

Required options:
  --ip <board_ip>     				Specify the IP address of the board to run tests on
or
  --serial <serial_port>  			Specify the serial port of the board to run tests on

Optional options:
  --user <username>   				Specify the username for the target device (default: root)
  --password <password>  			Specify the password for the target device (default: empty)
  --no-reports        				Do not generate test reports (only run tests and display results)
  --baudrate <baudrate> 			Specify the baudrate for the serial port of the board (default: 115200)
  --no-glee-tests        			Do not run GEISA Linux Execution Environment Conformance tests
  --no-gadm-tests        			Do not run GEISA Application & Device Management Conformance tests
  --no-gapi-tests        			Do not run GEISA Application Programming Interface Conformance tests
  --help              				Show this help message

GADM test options (optional):
  --host-ip <host_ip>				IP address of the host running the EMS server.
									If not specified, the host IP is automatically deduced from the active SSH
									session (i.e. the IP the board sees as the SSH client). In that case the
									EMS server must run on the same host as the one initiating the SSH connection.
  --api-endpoint <endpoint>			EMS API endpoint (default: <server-url>/api)
  --client-name <name>				ADM client endpoint name (default: geisa_adm_client)
  --client-path <path>				Path to ADM client binary on the board (default: /usr/bin/adm_client)
  --client-psk-identity <id>		PSK identity for the ADM client (default: <client-name>)
  --client-psk-value <value>		PSK secret for the ADM client (default: auto-generated hex string of length 16)
  --client-params <p>				Parameters to start the ADM client (use case: <client-path> <client-params>)
  --package-path <path>				Path to the ADM package to test (a squashfs file containing the client binary for the current implementation)
  --server-url <url>				EMS server URL (default: http://localhost:8080)
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
		--serial)
		BOARD_SERIAL="$2"
		if [[ -z "${BOARD_SERIAL}" ]]; then
			echo -e "${RED}Error:${ENDCOLOR} Serial port cannot be empty"
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
		--baudrate)
		BAUDRATE="$2"
		if [[ -z "${BAUDRATE}" ]]; then
			echo -e "${RED}Error:${ENDCOLOR} Baudrate cannot be empty"
			usage
		fi
		shift 2
		;;
		--host-ip)
		HOST_IP="$2"
		shift 2
		;;
		--package-path)
		PACKAGE_PATH="$2"
		shift 2
		;;
		--server-url)
		ADM_SERVER_URL="$2"
		shift 2
		;;
		--api-endpoint)
		ADM_API_ENDPOINT="$2"
		shift 2
		;;
		--client-name)
		ADM_CLIENT_NAME="$2"
		shift 2
		;;
		--client-path)
		ADM_CLIENT_PATH="$2"
		shift 2
		;;
		--client-psk-identity)
		ADM_CLIENT_PSK_IDENTITY="$2"
		shift 2
		;;
		--client-psk-value)
		ADM_CLIENT_PSK_VALUE="$2"
		shift 2
		;;
		--client-params)
		ADM_CLIENT_PARAMS="$2"
		shift 2
		;;
		--no-glee-tests)
		NO_GLEE_TESTS=true
		shift
		;;
		--no-gadm-tests)
		NO_GADM_TESTS=true
		shift
		;;
		--no-gapi-tests)
		NO_GAPI_TESTS=true
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

if [[ -n ${NO_GLEE_TESTS} && -n ${NO_GADM_TESTS} && -n ${NO_GAPI_TESTS} ]]; then
	echo -e "${RED}Error:${ENDCOLOR} At least one test suite must be executed. Please remove one of the --no-*-tests options."
	usage
fi

if [[ -z ${BOARD_IP} && -z ${BOARD_SERIAL} ]]; then
	echo -e "${RED}Error:${ENDCOLOR} Board IP address or serial port is required."
	usage
fi

if [[ -n ${BOARD_IP} && -n ${BOARD_SERIAL} ]]; then
	echo -e "${ORANGE}Warning:${ENDCOLOR} Board IP address and serial port specified, launching test with ssh connection."
fi

if ! ${NO_REPORTS}; then
	echo "Cleaning previous reports"
	rm -rf "${TOPDIR}"/reports/*
fi

BOARD_USER=${BOARD_USER:-root}

if [[ -z ${NO_GLEE_TESTS} ]]; then
	if [[ -n ${BOARD_IP} ]]; then
		connect_and_transfer_with_ssh "${BOARD_IP}" "${BOARD_USER}" "${BOARD_PASSWORD}" "${TOPDIR}"
		if ! ${NO_REPORTS}; then
			launch_glee_tests_with_report_ssh "${BOARD_IP}" "${BOARD_USER}" "${BOARD_PASSWORD}" "${TOPDIR}"
			launch_bandwidth_test_with_report_ssh "${BOARD_IP}" "${BOARD_USER}" "${BOARD_PASSWORD}" "${TOPDIR}"
		else
			launch_glee_tests_without_report_ssh "${BOARD_IP}" "${BOARD_USER}" "${BOARD_PASSWORD}"
			launch_bandwidth_test_without_report_ssh "${BOARD_IP}" "${BOARD_USER}" "${BOARD_PASSWORD}"
		fi
		cleanup_ssh "${BOARD_IP}" "${BOARD_USER}" "${BOARD_PASSWORD}"
	else
		echo "Starting GEISA Conformance Tests on board via ${BOARD_SERIAL}"
		args=(--serial "${BOARD_SERIAL}" \
			--user "${BOARD_USER}" \
			--password "${BOARD_PASSWORD:-}" \
			--baudrate "${BAUDRATE:-115200}")
		if ${NO_REPORTS}; then
			args+=(--no-reports)
		fi
		python3 "${TOPDIR}"/src/launch_glee_conformance_tests_serial.py "${args[@]}"
		lee_test_exit_code=$?
		if [[ ${lee_test_exit_code} -eq 255 ]]; then
			echo -e "${RED}Error:${ENDCOLOR} Failed to launch tests on board via serial port"
			exit "${lee_test_exit_code}"
		fi
	fi
fi

if [[ -z ${NO_GAPI_TESTS} ]]; then
	create_gapi_test_squashfs "${TOPDIR}"

	if [[ -n ${BOARD_IP} ]]; then
		connect_and_transfer_gapi_with_ssh "${BOARD_IP}" "${BOARD_USER}" "${BOARD_PASSWORD}" "${TOPDIR}"
		if ! ${NO_REPORTS}; then
			launch_gapi_tests_with_report "${BOARD_IP}" "${BOARD_USER}" "${BOARD_PASSWORD}" "${TOPDIR}"
		else
			launch_gapi_tests_without_report "${BOARD_IP}" "${BOARD_USER}" "${BOARD_PASSWORD}" "${TOPDIR}"
		fi
		cleanup_api_ssh "${BOARD_IP}" "${BOARD_USER}" "${BOARD_PASSWORD}" "${TOPDIR}"
	else
		echo -e "${ORANGE}Warning:${ENDCOLOR} API test through serial is not supported yet."
	fi
fi

if [[ -z ${NO_GADM_TESTS} ]]; then
	if ! ${NO_REPORTS}; then
		launch_gadm_tests_with_report \
			"${BOARD_IP}" "${BOARD_USER}" "${BOARD_PASSWORD}" \
			"${TOPDIR}" "${HOST_IP}" "${PACKAGE_PATH}" \
			"${ADM_SERVER_URL}" "${ADM_API_ENDPOINT}" "${ADM_CLIENT_NAME}" \
			"${ADM_CLIENT_PATH}" "${ADM_CLIENT_PSK_IDENTITY}" \
			"${ADM_CLIENT_PSK_VALUE}" "${ADM_CLIENT_PARAMS}"
		else
		launch_gadm_tests_without_report \
			"${BOARD_IP}" "${BOARD_USER}" "${BOARD_PASSWORD}" \
			"${TOPDIR}" "${HOST_IP}" "${PACKAGE_PATH}" \
			"${ADM_SERVER_URL}" "${ADM_API_ENDPOINT}" "${ADM_CLIENT_NAME}" \
			"${ADM_CLIENT_PATH}" "${ADM_CLIENT_PSK_IDENTITY}" \
			"${ADM_CLIENT_PSK_VALUE}" "${ADM_CLIENT_PARAMS}"
	fi
fi

if ! ${NO_REPORTS}; then
	echo "Generating PDF report"
	# shellcheck disable=SC2015
	cd "${TOPDIR}"/src/test-report-pdf && \
	./compile.py -i "${TOPDIR}"/reports/ -p 'GEISA conformance tests' -d "${TOPDIR}"/src/pdf_themes -c "${TOPDIR}"/src/GEISA-LEE-tests/GEISA-LEE-matrix.csv --allow_absent && \
	mv "${TOPDIR}"/src/test-report-pdf/test-report.pdf "${TOPDIR}"/reports/geisa-conformance-report.pdf || {
		echo -e "${RED}Error:${ENDCOLOR} Failed to create PDF report"
		exit 1
	}
	cd "${TOPDIR}" || exit 1
fi

exit $(("${lee_test_exit_code}" || "${bandwidth_test_exit_code}" || "${adm_test_exit_code}" || "${api_test_exit_code}"))
