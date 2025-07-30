#!/bin/bash
#
# GEISA Application Programming Interface Conformance functions
# Copyright (C) 2025 Southern California Edison
#
# GEISA Conformance is free software, distributed under the Apache License
# version 2.0. See LICENSE for details.

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
