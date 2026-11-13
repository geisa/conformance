#!/bin/bash

# Copyright (C) 2026 Southern California Edison

set -eu

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
test_board_ip="192.0.2.1"
trap 'rm -rf "${test_dir}"' EXIT

mkdir -p "${test_dir}/src/GEISA-LEE-tests" "${test_dir}/src/test-report-pdf" \
    "${test_dir}/bin"
cp "${project_dir}/launch_conformance_tests.sh" "${test_dir}/"
: > "${test_dir}/src/GEISA-LEE-tests/tests_configuration.conf"
: > "${test_dir}/src/GEISA-LEE-tests/user_configuration.conf"
export TEST_PROJECT_DIR="${project_dir}"

# The real LEE and GAPI functions are used, with board access stubbed out.
cat > "${test_dir}/src/launch_glee_conformance_tests_ssh.sh" <<'EOF'
manifest_application_name() {
    echo test-application
}

source "${TEST_PROJECT_DIR}/src/launch_glee_conformance_tests_ssh.sh"

connect_and_transfer_with_ssh() {
    return 0
}

provision_glee_apps_with_ssh() {
    return 0
}

prepare_glee_reboot_with_ssh() {
    return "${TEST_REBOOT_PREPARATION_EXIT_CODE:-0}"
}

cleanup_glee_ssh() {
    if [[ -n "${TEST_CLEANUP_LOG:-}" ]]; then
        printf 'lee %s\n' "$*" >> "${TEST_CLEANUP_LOG}"
    fi
    return "${TEST_LEE_CLEANUP_EXIT_CODE:-0}"
}
EOF

cat > "${test_dir}/src/launch_gapi_conformance_tests.sh" <<'EOF'
source "${TEST_PROJECT_DIR}/src/launch_gapi_conformance_tests.sh"

create_gapi_test_squashfs() {
    return 0
}

connect_and_transfer_gapi_with_ssh() {
    return 0
}

transfer_launch_gapi_tests_script() {
    return 0
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

# This file is sourced last, so its SSH and SCP stubs replace the ones
# defined by the LEE and GAPI files.
cat > "${test_dir}/src/launch_gadm_conformance_tests.sh" <<'EOF'
SSH() {
    case "$*" in
    *'GLEE_TESTS="reboot"'*) return "${TEST_LEE_REBOOT_EXIT_CODE:-0}" ;;
    *cukinia/cukinia*) return "${TEST_LEE_EXIT_CODE}" ;;
    *launch_gapi_test_app.sh*) return "${TEST_API_EXIT_CODE}" ;;
    esac
}

SCP() {
    [[ -z "${TEST_FAILING_REPORT:-}" || "$*" != *"/${TEST_FAILING_REPORT}"* ]]
}

launch_gadm_tests_without_report() {
    adm_test_exit_code="${TEST_ADM_EXIT_CODE}"
}

launch_gadm_tests_with_report() {
    launch_gadm_tests_without_report
}

cleanup_gadm_ssh() {
    if [[ -n "${TEST_CLEANUP_LOG:-}" ]]; then
        printf 'gadm %s\n' "$*" >> "${TEST_CLEANUP_LOG}"
    fi
    return "${TEST_GADM_CLEANUP_EXIT_CODE:-0}"
}
EOF

cat > "${test_dir}/src/test-report-pdf/compile.py" <<'EOF'
#!/bin/sh
[ "${TEST_REPORT_EXIT_CODE:-0}" -eq 0 ] && touch test-report.pdf
EOF
chmod +x "${test_dir}/src/test-report-pdf/compile.py"

# Serial launcher stub
cat > "${test_dir}/bin/python3" <<'EOF'
#!/bin/sh
exit "${TEST_LEE_EXIT_CODE}"
EOF
chmod +x "${test_dir}/bin/python3"
export PATH="${test_dir}/bin:${PATH}"

check_exit_code() {
    local expected="$1"
    local lee="$2"
    local adm="$3"
    local api="$4"
    local actual
    shift 4
    if [[ "$#" -eq 0 ]]; then
        set -- "${ssh_args[@]}"
    fi

    if TEST_LEE_EXIT_CODE="${lee}" \
       TEST_ADM_EXIT_CODE="${adm}" \
       TEST_API_EXIT_CODE="${api}" \
       "${test_dir}/launch_conformance_tests.sh" \
           "$@" >"${test_dir}/output" 2>&1; then
        actual=0
    else
        actual=$?
    fi

    if [[ "${actual}" != "${expected}" ]]; then
        echo "expected exit code ${expected}, got ${actual}" >&2
        cat "${test_dir}/output" >&2
        return 1
    fi
}

cleanup_log="${test_dir}/cleanup.log"

# The LEE and GAPI suites have separate functions with and without reports.
for with_reports in false true; do
    ssh_args=(--ip "${test_board_ip}")
    if ! ${with_reports}; then
        ssh_args+=(--no-reports)
    fi

    check_exit_code 0 0 0 0
    check_exit_code 1 1 0 0
    check_exit_code 1 0 1 0
    check_exit_code 1 0 0 1
    check_exit_code 2 255 0 0
    check_exit_code 2 0 2 0
    check_exit_code 2 0 0 127
    check_exit_code 2 1 0 255

    TEST_LEE_REBOOT_EXIT_CODE=1 check_exit_code 1 0 0 0
    TEST_LEE_REBOOT_EXIT_CODE=255 check_exit_code 2 1 0 0
    TEST_LEE_REBOOT_EXIT_CODE=1 check_exit_code 2 255 0 0
    TEST_REBOOT_PREPARATION_EXIT_CODE=1 check_exit_code 2 0 0 0

    TEST_LEE_CLEANUP_EXIT_CODE=1 check_exit_code 2 1 0 0
    TEST_GAPI_CLEANUP_EXIT_CODE=2 check_exit_code 2 1 0 0

    # Execution errors stop the launcher only after the suite's cleanup.
    : > "${cleanup_log}"
    TEST_CLEANUP_LOG="${cleanup_log}" check_exit_code 2 255 0 0
    grep -q '^lee ' "${cleanup_log}"
    if grep -q '^gapi ' "${cleanup_log}"; then
        echo "GAPI tests ran after a LEE execution error" >&2
        exit 1
    fi
    : > "${cleanup_log}"
    TEST_CLEANUP_LOG="${cleanup_log}" check_exit_code 2 0 0 255
    grep -q '^gapi ' "${cleanup_log}"
done

report_args=(--ip "${test_board_ip}")
TEST_REPORT_EXIT_CODE=1 check_exit_code 2 0 0 0 "${report_args[@]}"
for report in geisa-lee-conformance-report.xml \
    geisa-lee-reboot-conformance-report.xml geisa-api-conformance-report.xml; do
    TEST_FAILING_REPORT="${report}" check_exit_code 2 0 0 0 "${report_args[@]}"
done

serial_args=(--serial /dev/test --no-reports)
check_exit_code 0 0 0 0 "${serial_args[@]}"
check_exit_code 1 1 0 0 "${serial_args[@]}"
check_exit_code 2 255 0 0 "${serial_args[@]}"

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
actual=0
TEST_CLEANUP_LOG="${cleanup_log}" \
    TEST_GAPI_CLEANUP_EXIT_CODE=1 \
    "${test_dir}/launch_conformance_tests.sh" \
        --ip "${test_board_ip}" --clean-up >/dev/null 2>&1 || actual=$?
if [[ "${actual}" -ne 2 ]]; then
    echo "cleanup failure: expected exit code 2, got ${actual}" >&2
    exit 1
fi
grep -q '^lee ' "${cleanup_log}"
grep -q '^gapi ' "${cleanup_log}"
grep -q '^gadm ' "${cleanup_log}"
