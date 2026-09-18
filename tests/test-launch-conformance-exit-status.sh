#!/bin/bash

# Copyright (C) 2026 Southern California Edison

set -eu

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
test_board_ip="192.0.2.1"
trap 'rm -rf "${test_dir}"' EXIT

mkdir -p "${test_dir}/src/GEISA-LEE-tests"
cp "${project_dir}/launch_conformance_tests.sh" "${test_dir}/"
: > "${test_dir}/src/GEISA-LEE-tests/tests_configuration.conf"
: > "${test_dir}/src/GEISA-LEE-tests/user_configuration.conf"

cat > "${test_dir}/src/launch_glee_conformance_tests_ssh.sh" <<'EOF'
connect_and_transfer_with_ssh() {
    return 0
}

provision_glee_apps_with_ssh() {
    return 0
}

launch_glee_tests_without_report_ssh() {
    lee_test_exit_code="${TEST_LEE_EXIT_CODE}"
}

cleanup_glee_ssh() {
    if [[ -n "${TEST_CLEANUP_LOG:-}" ]]; then
        printf 'lee %s\n' "$*" >> "${TEST_CLEANUP_LOG}"
    fi
    return "${TEST_LEE_CLEANUP_EXIT_CODE:-0}"
}
EOF

cat > "${test_dir}/src/launch_gapi_conformance_tests.sh" <<'EOF'
create_gapi_test_squashfs() {
    return 0
}

connect_and_transfer_gapi_with_ssh() {
    return 0
}

launch_gapi_tests_without_report() {
    api_test_exit_code="${TEST_API_EXIT_CODE}"
}

cleanup_api_ssh() {
    if [[ -n "${TEST_CLEANUP_LOG:-}" ]]; then
        printf 'gapi %s\n' "$*" >> "${TEST_CLEANUP_LOG}"
    fi
    if [[ "${TEST_GAPI_CLEANUP_EXIT_CODE:-0}" -ne 0 ]]; then
        exit "${TEST_GAPI_CLEANUP_EXIT_CODE}"
    fi
    return 0
}
EOF

cat > "${test_dir}/src/launch_gadm_conformance_tests.sh" <<'EOF'
launch_gadm_tests_without_report() {
    adm_test_exit_code="${TEST_ADM_EXIT_CODE}"
}

cleanup_gadm_ssh() {
    if [[ -n "${TEST_CLEANUP_LOG:-}" ]]; then
        printf 'gadm %s\n' "$*" >> "${TEST_CLEANUP_LOG}"
    fi
    return "${TEST_GADM_CLEANUP_EXIT_CODE:-0}"
}
EOF

check_exit_code() {
    local expected="$1"
    local lee="$2"
    local adm="$3"
    local api="$4"
    local actual

    if TEST_LEE_EXIT_CODE="${lee}" \
       TEST_ADM_EXIT_CODE="${adm}" \
       TEST_API_EXIT_CODE="${api}" \
       "${test_dir}/launch_conformance_tests.sh" \
           --ip 192.0.2.1 --no-reports >/dev/null 2>&1; then
        actual=0
    else
        actual=$?
    fi

    if [[ "${actual}" != "${expected}" ]]; then
        echo "expected exit code ${expected}, got ${actual}" >&2
        return 1
    fi
}

check_exit_code 0 0 0 0
check_exit_code 1 2 0 0
check_exit_code 1 0 2 0
check_exit_code 1 0 0 2

cleanup_log="${test_dir}/cleanup.log"
: > "${cleanup_log}"
TEST_CLEANUP_LOG="${cleanup_log}" \
"${test_dir}/launch_conformance_tests.sh" \
    --ip "${test_board_ip}" --user root --clean-up
grep -Fq "lee ${test_board_ip} root " "${cleanup_log}"
grep -Fq "gapi ${test_board_ip} root " "${cleanup_log}"
grep -Fq "gadm ${test_board_ip} root " "${cleanup_log}"

check_cleanup_selection() {
    local excluded_suite="$1"
    local excluded_option="$2"
    local suite

    : > "${cleanup_log}"
    TEST_CLEANUP_LOG="${cleanup_log}" \
    "${test_dir}/launch_conformance_tests.sh" \
        --ip "${test_board_ip}" --clean-up "${excluded_option}"
    if grep -q "^${excluded_suite} " "${cleanup_log}"; then
        echo "disabled ${excluded_suite} cleanup was called" >&2
        exit 1
    fi
    for suite in lee gapi gadm; do
        if [[ "${suite}" != "${excluded_suite}" ]]; then
            grep -q "^${suite} " "${cleanup_log}"
        fi
    done
}

check_cleanup_selection lee --no-glee-tests
check_cleanup_selection gapi --no-gapi-tests
check_cleanup_selection gadm --no-gadm-tests

: > "${cleanup_log}"
TEST_CLEANUP_LOG="${cleanup_log}" \
"${test_dir}/launch_conformance_tests.sh" \
    --ip "${test_board_ip}" --clean-up --no-gapi-tests --no-gadm-tests
grep -q '^lee ' "${cleanup_log}"
if grep -q '^\(gapi\|gadm\) ' "${cleanup_log}"; then
    echo "disabled suite cleanup was called" >&2
    exit 1
fi

rm -f "${cleanup_log}"
if TEST_CLEANUP_LOG="${cleanup_log}" \
    TEST_GAPI_CLEANUP_EXIT_CODE=1 \
    "${test_dir}/launch_conformance_tests.sh" \
        --ip "${test_board_ip}" --clean-up >/dev/null 2>&1; then
    echo "cleanup failure returned success" >&2
    exit 1
fi
grep -q '^lee ' "${cleanup_log}"
grep -q '^gapi ' "${cleanup_log}"
grep -q '^gadm ' "${cleanup_log}"
