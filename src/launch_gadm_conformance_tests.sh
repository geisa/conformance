#!/bin/bash
#
# GEISA Application & Device Management Conformance functions
# Copyright (C) 2025 Southern California Edison
#
# GEISA Conformance is free software, distributed under the Apache License
# version 2.0. See LICENSE for details.

launch_gadm_tests_with_report() {
	local topdir="$1"

	echo ""
	echo "Starting GEISA Application & Device Management Conformance Tests"
	"${topdir}"/src/cukinia/cukinia -f junitxml -o "${topdir}"/reports/geisa-adm-conformance-report.xml "${topdir}"/src/GEISA-ADM-tests/cukinia.conf
	adm_test_exit_code=$?

	export adm_test_exit_code
}

launch_gadm_tests_without_report() {
	local topdir="$1"

	echo ""
	echo "Starting GEISA Application & Device Management Conformance Tests"
	"${topdir}"/src/cukinia/cukinia "${topdir}"/src/GEISA-ADM-tests/cukinia.conf
	adm_test_exit_code=$?

	export adm_test_exit_code
}
