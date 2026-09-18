#!/bin/bash

# Copyright (C) 2026 Southern California Edison
#
# Helper functions for GEISA Linux Execution Environment conformance checks.

APPLICATIONS="${APPLICATIONS:-}"
LXC_PATH="${LXC_PATH:-}"
REFERENCE_APPLICATION="${REFERENCE_APPLICATION:-}"
LEE_TESTS_DIR="${LEE_TESTS_DIR:-}"
APPLICATION_IMAGE_PATH="${APPLICATION_IMAGE_PATH:-}"
APPLICATION_MANIFEST_PATH="${APPLICATION_MANIFEST_PATH:-}"
REFERENCE_LXC_CPUSET_CPUS="${REFERENCE_LXC_CPUSET_CPUS:-}"
REFERENCE_LXC_CPU_WEIGHT="${REFERENCE_LXC_CPU_WEIGHT:-}"
ROOTFS_PATH="${ROOTFS_PATH:-}"
BASE_LAYER_PATH="${BASE_LAYER_PATH:-}"
APPLICATION_LAYER_PATH="${APPLICATION_LAYER_PATH:-}"
REBOOT_PERSISTENCE_MARKER="${REBOOT_PERSISTENCE_MARKER:-}"
PERSISTENT_IMAGE_PATH="${PERSISTENT_IMAGE_PATH:-}"
PRIVILEGED_COMMAND="${PRIVILEGED_COMMAND:-}"

# Mount points and journaling filesystem expectations are mandated by the GEISA
# specification and are not configurable.
CONTAINER_PERSISTENT_MOUNT="/home/geisa"
CONTAINER_NONPERSISTENT_MOUNT="/tmp"
CONTAINER_STATE_FILE="${LEE_TESTS_DIR}/.container-states"
JOURNALING_FILESYSTEMS="ext3 ext4 xfs jfs btrfs f2fs zfs"
CONTAINER_LIBRARY_DIRECTORIES="/lib /usr/lib /lib64 /usr/lib64 /usr/local/lib"
CONTAINER_SIZED_MOUNTS="/ ${CONTAINER_NONPERSISTENT_MOUNT} ${CONTAINER_PERSISTENT_MOUNT}"

#######################################
# Run a command that needs platform privilege, under PRIVILEGED_COMMAND.
#######################################
host_exec() {
    local -a wrapper
    if test -z "${PRIVILEGED_COMMAND}"; then
        "$@"
        return
    fi
    read -r -a wrapper <<< "${PRIVILEGED_COMMAND}"
    "${wrapper[@]}" "$@"
}

#######################################
# Report whether the test account can inspect host and container state.
#######################################
check_privileged_access() {
    host_exec readlink /proc/1/ns/pid >/dev/null 2>&1 || return 1
    host_exec lxc-info --version >/dev/null 2>&1
}

#######################################
# Run a test only when host and container inspection is available.
#######################################
privileged_test_id() {
    local test_identifier="$1" test_description="$3"
    if has_privileged_access && [[ -z "${__skip_condition:-}" ]]; then
        test_id "$@"
        return
    fi
    if [[ -n "${__skip_condition:-}" ]]; then
        test_id "${test_identifier}" as "${test_description}" cukinia_cmd true
    else
        when "has_privileged_access" test_id "${test_identifier}" \
            as "${test_description}" cukinia_cmd true
    fi
}

#######################################
# Report whether privileged tests are qualified to run.
#######################################
has_privileged_access() {
    test "${PRIVILEGED_ACCESS_AVAILABLE:-false}" = true
}

#######################################
# Attach and run a command inside an application container.
#######################################
container_exec() {
    local app="$1"
    shift
    host_exec lxc-attach -P "${LXC_PATH}" -n "${app}" -- "$@"
}

#######################################
# Run a shell command inside an application container.
#######################################
container_run_command() {
    local app="$1" command="$2"
    container_exec "${app}" /bin/sh -c "${command}"
}

#######################################
# Build the command that checks whether the container root is read-only.
#######################################
container_root_read_only_command() {
    cat <<'EOF'
awk '
$2 == "/" {
    found = 1
    exit ($4 ~ /(^|,)ro(,|$)/) ? 0 : 1
}
END {
    if (found == 0) exit 1
}' /proc/mounts
EOF
}

#######################################
# Build the command that checks writable paths outside the allowed mounts.
#######################################
container_root_write_policy_command() {
    cat <<'EOF'
find / -xdev \
    \( -path /dev -o -path "/dev/*" \
    -o -path /proc -o -path "/proc/*" \
    -o -path /sys -o -path "/sys/*" \
    -o -path /tmp -o -path "/tmp/*" \
    -o -path /home/geisa -o -path "/home/geisa/*" \) -prune -o \
    -type d -print | \
while IFS= read -r directory; do
    test_path="$directory/.geisa-write-test-$$"
    if touch "$test_path" 2>/dev/null; then
        rm -f "$test_path"
        exit 1
    fi
done
EOF
}

#######################################
# Get the init PID for an application container.
#######################################
container_init_pid() {
    host_exec lxc-info -P "${LXC_PATH}" -n "$1" -pH
}

#######################################
# Get the LXC state for an application container.
#######################################
container_state() {
    host_exec lxc-info -P "${LXC_PATH}" -n "$1" -sH
}

#######################################
# Get the host path for an LXC application resource.
#######################################
container_path() {
    printf '%s\n' "${LXC_PATH}/$1"
}

#######################################
# Restart an application container and wait for it to run.
#######################################
container_restart() {
    host_exec lxc-stop -P "${LXC_PATH}" -n "$1" -k || return 1
    host_exec lxc-start -P "${LXC_PATH}" -n "$1" -d || return 1
    host_exec lxc-wait -P "${LXC_PATH}" -n "$1" -s RUNNING -t 30
}

#######################################
# Run a Python check for host-side LXC or cgroup state.
#######################################
container_backend() {
    APPLICATIONS="${APPLICATIONS}" \
        LXC_PATH="${LXC_PATH}" \
    APPLICATION_MANIFEST_PATH="${APPLICATION_MANIFEST_PATH}" \
        REFERENCE_APPLICATION="${REFERENCE_APPLICATION}" \
        host_exec python3 "${LEE_TESTS_DIR}/tests.d/check-lxc-container.py" "$@"
}

#######################################
# Run one command in every configured application container.
#######################################
check_all_containers() {
    local command="$1" app
    for app in ${APPLICATIONS}; do
        container_run_command "${app}" "${command}" || return 1
    done
    return 0
}

#######################################
# Check one filesystem layout item in every application container.
#
# The first call checks each container and saves successful results. Later calls
# will reuse the results, while each Cukinia test still gets its own result.
#######################################
check_all_containers_file_layout_entry() {
    local checks="$1" expected="$2" app command output check
    if [[ "${FILE_LAYOUT_CHECK_CACHE_KEY:-}" != "${APPLICATIONS}|${checks}" ]]; then
        FILE_LAYOUT_CHECK_CACHE=""
        for app in ${APPLICATIONS}; do
            command="
        for check in ${checks}; do
            case \"\$check\" in
                d:*) test -d \"\${check#d:}\" ;;
                f:*) test -f \"\${check#f:}\" ;;
                e:*) test -e \"\${check#e:}\" ;;
                V:*) variable=\${check#V:}
                     test -n \"\$(printenv \"\$variable\")\" ;;
                hosts-localhost) grep -qF localhost /etc/hosts ;;
                proc-mounted) test \"\$(stat -fc %T /proc)\" = proc ;;
                dev-mounted) mountpoint -q /dev ;;
                sys-mounted) test \"\$(stat -fc %T /sys)\" = sysfs ;;
                tmp-writable) test -d /tmp && test -w /tmp ;;
                root-read-only)
                    awk '\$2 == \"/\" { found = 1; exit (\$4 ~ /(^|,)ro(,|\$)/) ? 0 : 1 } END { if (found == 0) exit 1 }' /proc/mounts ;;
            esac && printf '%s\\n' \"\$check\"
        done
        exit 0
    "
            output="$(container_run_command "${app}" "${command}")" || return 1
            while IFS= read -r check; do
                [[ -n "${check}" ]] || continue
                FILE_LAYOUT_CHECK_CACHE="${FILE_LAYOUT_CHECK_CACHE}${app}|${check}
"
            done <<EOF
${output}
EOF
        done
        FILE_LAYOUT_CHECK_CACHE_KEY="${APPLICATIONS}|${checks}"
        case " ${checks} " in
            *" root-read-only "*) FILE_LAYOUT_ROOT_CHECKED=true ;;
            *) FILE_LAYOUT_ROOT_CHECKED=false ;;
        esac
    fi
    for app in ${APPLICATIONS}; do
        printf '%s\n' "${FILE_LAYOUT_CHECK_CACHE}" |
            awk -F '|' -v app="${app}" -v expected="${expected}" \
                '$1 == app && $2 == expected { found=1; exit } END { exit !found }' ||
            return 1
    done
    return 0
}

#######################################
# Check that every application container provides a named shared library.
#
# Build one library list per application set and reuse it for later checks. The
# list is built from inside each container.
#######################################
check_all_containers_have_library() {
    local library="$1" app library_inventory_command library_paths path
    if [[ "${LIBRARY_INVENTORY_APPS:-}" != "${APPLICATIONS}" ]]; then
        LIBRARY_INVENTORY=""
        for app in ${APPLICATIONS}; do
            library_inventory_command="
        for directory in ${CONTAINER_LIBRARY_DIRECTORIES}; do
            test -d \"\$directory\" || continue
            find \"\$directory\" -xdev \\
                \\( -type f -o -type l \\) \\
                -name 'lib*.so*' -print
        done
    "
            library_paths="$(container_run_command "${app}" "${library_inventory_command}")" || return 1
            while IFS= read -r path; do
                [[ -n "${path}" ]] || continue
                LIBRARY_INVENTORY="${LIBRARY_INVENTORY}${app}|${path}
"
            done <<EOF
${library_paths}
EOF
        done
        LIBRARY_INVENTORY_APPS="${APPLICATIONS}"
    fi
    for app in ${APPLICATIONS}; do
        printf '%s\n' "${LIBRARY_INVENTORY}" |
            awk -F '|' -v app="${app}" -v library="${library}" \
                '$1 == app && index($2, "/" library ".so") { found=1; exit } END { exit !found }' ||
            return 1
    done
    return 0
}

#######################################
# Run manage_package.py with the conformance configuration loaded.
#######################################
manage_package() {
    (
        export APPLICATIONS LXC_PATH REFERENCE_APPLICATION
        export CONTAINER_BASE_IMAGE CONTAINER_BASE_IMAGE_DIR CONTAINER_BASE_IMAGE_GLOB
        export CONTAINER_IMAGE_FSTYPE CONTAINER_PERSISTENT_FSTYPE
        export LXC_NETWORK_BRIDGE LXC_NETWORK_GATEWAY LXC_NETWORK_PREFIX
        export REFERENCE_LXC_CPUSET_CPUS REFERENCE_LXC_CPUSET_MEMS
        export REFERENCE_LXC_CPU_PERCENT REFERENCE_LXC_CPU_WEIGHT REFERENCE_LXC_MEMORY_KIB
        export REFERENCE_LXC_PERSISTENT_KIB REFERENCE_LXC_NONPERSISTENT_KIB
        export BASE_LAYER_PATH APPLICATION_LAYER_PATH CONFIGURATION_LAYER_PATH
        export UPPER_PATH WORK_PATH ROOTFS_PATH APPLICATION_IMAGE_PATH PERSISTENT_IMAGE_PATH
        host_exec python3 "${LEE_TESTS_DIR}/manage_package.py" "$@"
    ) >/dev/null 2>&1
}

#######################################
# Run manage_package.py for an isolated peer with separate absolute resources.
#######################################
manage_isolation_peer_package() {
    local peer="$1" peer_root
    local BASE_LAYER_PATH APPLICATION_LAYER_PATH CONFIGURATION_LAYER_PATH
    local UPPER_PATH WORK_PATH ROOTFS_PATH APPLICATION_IMAGE_PATH PERSISTENT_IMAGE_PATH
    shift
    peer_root="$(container_path "${peer}")"
    export BASE_LAYER_PATH="${peer_root}/base"
    export APPLICATION_LAYER_PATH="${peer_root}/application"
    export CONFIGURATION_LAYER_PATH="${peer_root}/configuration"
    export UPPER_PATH="${peer_root}/upper"
    export WORK_PATH="${peer_root}/work"
    export ROOTFS_PATH="${peer_root}/rootfs"
    export APPLICATION_IMAGE_PATH="${peer_root}/packages/application.squashfs"
    export PERSISTENT_IMAGE_PATH="${peer_root}/persistent.img"
    manage_package "$@"
}

#######################################
# Create and activate a temporary peer for the isolation test.
#######################################
provision_isolation_peer() {
    local source_app="$1" peer="$2" image manifest
    image="${APPLICATION_IMAGE_PATH}"
    manifest="$(container_path "${source_app}")/manifest.json"
    test -f "${image}" && test -f "${manifest}" || return 1
    manage_isolation_peer_package "${peer}" install --name "${peer}" "${image}" "${manifest}" || return 1
    if ! manage_isolation_peer_package "${peer}" activate "${peer}"; then
        deprovision_isolation_peer "${peer}"
        return 1
    fi
    return 0
}

#######################################
# Remove a temporary isolation-test peer.
#######################################
deprovision_isolation_peer() {
    manage_isolation_peer_package "$1" uninstall "$1"
}

#######################################
# Compare namespaces and process visibility for two application containers.
#######################################
compare_container_namespaces() {
    local first_app="$1" second_app="$2"
    local first_pid second_pid namespace host_namespace first_namespace second_namespace
    local first_state second_state
    local proc_namespace_command
    first_state="$(container_state "${first_app}")" || return 1
    second_state="$(container_state "${second_app}")" || return 1
    test "${first_state}" = RUNNING || return 1
    test "${second_state}" = RUNNING || return 1
    first_pid="$(container_init_pid "${first_app}")" || return 1
    second_pid="$(container_init_pid "${second_app}")" || return 1
    for namespace in mnt pid ipc uts net; do
        host_namespace="$(host_exec readlink "/proc/1/ns/${namespace}")" || return 1
        first_namespace="$(host_exec readlink "/proc/${first_pid}/ns/${namespace}")" || return 1
        second_namespace="$(host_exec readlink "/proc/${second_pid}/ns/${namespace}")" || return 1
        test "${first_namespace}" != "${host_namespace}" || return 1
        test "${second_namespace}" != "${host_namespace}" || return 1
        test "${first_namespace}" != "${second_namespace}" || return 1
    done
    proc_namespace_command="test \"\$(readlink /proc/1/ns/pid)\" = \"\$(readlink /proc/self/ns/pid)\""
    container_run_command "${first_app}" "${proc_namespace_command}" || return 1
    container_run_command "${second_app}" "${proc_namespace_command}" || return 1
    check_container_cannot_see_process "${first_app}" "${second_pid}" || return 1
    check_container_cannot_see_process "${second_app}" "${first_pid}" || return 1
    return 0
}

#######################################
# Verify that an application cannot see a peer's container-init PID.
#######################################
check_container_cannot_see_process() {
    local app="$1" hidden_pid="$2" process_visibility_command
    process_visibility_command="test ! -e '/proc/${hidden_pid}'"
    container_run_command "${app}" "${process_visibility_command}"
}

#######################################
# Verify namespace isolation for the configured applications.
#######################################
check_container_namespaces_are_isolated() {
    local first_app second_app peer="" result=0
    local -a applications
    read -r -a applications <<< "${APPLICATIONS}"
    set -- "${applications[@]}"
    first_app="$1"
    if test "$#" -ge 2; then
        second_app="$2"
    else
        peer="${first_app}-isolation-peer"
        provision_isolation_peer "${first_app}" "${peer}" || return 1
        second_app="${peer}"
    fi
    compare_container_namespaces "${first_app}" "${second_app}" || result=1
    test -n "${peer}" && deprovision_isolation_peer "${peer}"
    return "${result}"
}

#######################################
# Check one cgroup constraint for every configured application.
#######################################
check_all_container_cgroup_constraints() {
    local constraint="$1" app pid cgroup cgroup_entries
    for app in ${APPLICATIONS}; do
        pid="$(container_init_pid "${app}")" || return 1
        cgroup_entries="$(host_exec cat "/proc/${pid}/cgroup")" || return 1
        cgroup="$(awk -F: '$1 == "0" && $2 == "" { print $3; exit }' <<< "${cgroup_entries}")"
        test -n "${cgroup}" && test "${cgroup}" != / || return 1
        container_backend cgroup \
            "${constraint}" "${pid}" "${app}" \
            "${REFERENCE_LXC_CPUSET_CPUS}" \
            "${REFERENCE_LXC_CPU_WEIGHT}" || return 1
    done
    return 0
}

#######################################
# Verify that each application has a distinct container and PID namespace.
#######################################
check_containers_are_isolated() {
    local app pid namespace host_namespace roots root container_state_value
    host_namespace="$(host_exec readlink /proc/1/ns/pid)"
    roots=""
    for app in ${APPLICATIONS}; do
        container_state_value="$(container_state "${app}")" || return 1
        test "${container_state_value}" = RUNNING || return 1
        pid="$(container_init_pid "${app}")" || return 1
        namespace="$(host_exec readlink "/proc/${pid}/ns/pid")" || return 1
        test "${namespace}" != "${host_namespace}" || return 1
        root="${ROOTFS_PATH}"
        test -d "${root}" || return 1
        case " ${roots} " in
            *" ${root} "*) return 1 ;;
            *) : ;;
        esac
        roots="${roots:+${roots} }${root}"
    done
    return 0
}

#######################################
# Read every configured storage limit from the deployment manifest.
#
# The limits are collected in a single manifest access and kept in memory, so
# later lookups do not read the manifest again.
#######################################
collect_application_limits() {
    local limits
    if [[ -n "${STORAGE_LIMITS:-}" ]]; then
        return 0
    fi
    limits="$(container_backend storage-limits)" || return 1
    STORAGE_LIMITS=$'\n'"${limits}"$'\n'
    return 0
}

#######################################
# Return a collected storage limit for an application.
#######################################
get_application_limit() {
    local app="$1" field="$2" key limit
    key=$'\n'"${app}|${field}|"
    case "${STORAGE_LIMITS:-}" in
        *"${key}"*) : ;;
        *) return 1 ;;
    esac
    limit="${STORAGE_LIMITS##*"${key}"}"
    limit="${limit%%$'\n'*}"
    printf '%s\n' "${limit}"
}

#######################################
# Check whether an application's container root mount is read-only.
#######################################
is_container_root_read_only() {
    local app="$1" root_read_only_command
    if [[ "${FILE_LAYOUT_ROOT_CHECKED:-}" = true ]]; then
        printf '%s\n' "${FILE_LAYOUT_CHECK_CACHE}" |
            awk -F '|' -v app="${app}" \
                '$1 == app && $2 == "root-read-only" { found=1; exit } END { exit !found }'
        return
    fi
    root_read_only_command="$(container_root_read_only_command)"
    container_run_command "${app}" "${root_read_only_command}"
}

#######################################
# Verify root read-only policy or permissions outside writable mounts.
#######################################
check_container_root_policy() {
    local app root_write_policy_command root_read_write=false
    root_write_policy_command="$(container_root_write_policy_command)"
    for app in ${APPLICATIONS}; do
        if is_container_root_read_only "${app}"; then
            continue
        fi
        root_read_write=true
    done
    ANY_CONTAINER_ROOT_READ_WRITE="${root_read_write}"
    ROOT_WRITE_STATE_KNOWN=true
    [[ "${root_read_write}" = true ]] || return 0
    for app in ${APPLICATIONS}; do
        if is_container_root_read_only "${app}"; then
            continue
        fi
        # Only the container root filesystem is checked, virtual filesystem mount points
        # and the two specified writable paths (/home/geisa and /tmp) are excluded.
        container_run_command "${app}" "${root_write_policy_command}" || return 1
    done
    return 0
}

#######################################
# Run the root-policy check for the read-write-root case.
#######################################
check_container_read_write_permissions() {
    check_container_root_policy
}

#######################################
# Determine whether any configured application has a read-write root mount.
#
# The result is cached because both conditional filesystem tests use it.
#######################################
is_any_container_root_read_write() {
    local app
    has_privileged_access || return 1
    if [[ "${ROOT_WRITE_STATE_KNOWN:-}" = true ]]; then
        [[ "${ANY_CONTAINER_ROOT_READ_WRITE:-}" = true ]]
        return
    fi
    for app in ${APPLICATIONS}; do
        if ! is_container_root_read_only "${app}"; then
            ANY_CONTAINER_ROOT_READ_WRITE=true
            ROOT_WRITE_STATE_KNOWN=true
            return 0
        fi
    done
    ANY_CONTAINER_ROOT_READ_WRITE=false
    ROOT_WRITE_STATE_KNOWN=true
    return 1
}

#######################################
# Measure the container-visible size of every sized mount.
#
# Attaching to a container is expensive, so all sizes are measured in a single
# access per application and reused by later checks.
#######################################
collect_container_mount_sizes() {
    local app output line mount_size_command
    if [[ "${MOUNT_SIZE_CACHE_APPS:-}" = "${APPLICATIONS}" ]]; then
        return 0
    fi
    mount_size_command="
        for mount in ${CONTAINER_SIZED_MOUNTS}; do
            printf '%s|%s\\n' \"\$mount\" \"\$(df -Pk \"\$mount\" | awk 'NR == 2 { print \$2 }')\"
        done
    "
    MOUNT_SIZE_CACHE=""
    for app in ${APPLICATIONS}; do
        output="$(container_run_command "${app}" "${mount_size_command}")" || return 1
        while IFS= read -r line; do
            [[ -n "${line}" ]] || continue
            MOUNT_SIZE_CACHE="${MOUNT_SIZE_CACHE}${app}|${line}
"
        done <<EOF
${output}
EOF
    done
    MOUNT_SIZE_CACHE_APPS="${APPLICATIONS}"
    return 0
}

#######################################
# Return a collected mount size, in kibibytes.
#######################################
get_container_mount_size() {
    local app="$1" path="$2"
    printf '%s\n' "${MOUNT_SIZE_CACHE:-}" |
        awk -F '|' -v app="${app}" -v path="${path}" \
            '$1 == app && $2 == path && $3 ~ /^[0-9]+$/ { print $3; found=1; exit } END { exit !found }'
}

#######################################
# Check the size of a read-write root against its non-persistent limit.
#######################################
check_container_read_write_size() {
    local app limit size
    collect_application_limits || return 1
    collect_container_mount_sizes || return 1
    for app in ${APPLICATIONS}; do
        if is_container_root_read_only "${app}"; then
            continue
        fi
        limit="$(get_application_limit "${app}" nonpersistent)" || return 1
        size="$(get_container_mount_size "${app}" /)" || return 1
        test "${size}" -le "${limit}" || return 1
    done
    return 0
}

#######################################
# Check a container-visible mount size against its manifest limit.
#######################################
check_container_mount_limit() {
    local path="$1" field="$2" app limit size
    collect_application_limits || return 1
    collect_container_mount_sizes || return 1
    for app in ${APPLICATIONS}; do
        limit="$(get_application_limit "${app}" "${field}")" || return 1
        size="$(get_container_mount_size "${app}" "${path}")" || return 1
        test "${size}" -le "${limit}" || return 1
    done
    return 0
}

# TODO: ensure threshold is really enforced after workload done (and check if is
# actually throttled)
# test workload will be given with geisa-test
#######################################
# Check host-side storage mounts against their manifest limits.
#
# This is separate from check_container_mount_limit(), which checks the path
# from inside the application container.
#######################################
check_container_storage_limit() {
    local storage_kind="$1" app mount_path mount_point mount_target declared_kib actual_kib
    local mount_target_real mount_point_real df_output
    case "${storage_kind}" in
        persistent) mount_path="${CONTAINER_PERSISTENT_MOUNT}" ;;
        nonpersistent) mount_path="${CONTAINER_NONPERSISTENT_MOUNT}" ;;
        *) return 2 ;;
    esac
    collect_application_limits || return 1
    for app in ${APPLICATIONS}; do
        mount_point="${ROOTFS_PATH}${mount_path}"
        declared_kib="$(get_application_limit "${app}" "${storage_kind}")" || return 1
        case "${declared_kib}" in
            *[!0-9]*|'') return 1 ;;
            *) : ;;
        esac
        mount_target="$(host_exec findmnt -n -o TARGET --target "${mount_point}")" || return 1
        mount_target_real="$(host_exec readlink -f "${mount_target}")" || return 1
        mount_point_real="$(host_exec readlink -f "${mount_point}")" || return 1
        test "${mount_target_real}" = "${mount_point_real}" || return 1
        if test "${declared_kib}" -eq 0; then
            case "$(host_exec findmnt -n -o OPTIONS --target "${mount_point}")" in
                ro|ro,*) continue ;;
                *) return 1 ;;
            esac
        fi
        df_output="$(host_exec df -Pk "${mount_point}")" || return 1
        actual_kib="$(awk 'END {print $2}' <<< "${df_output}")"
        case "${actual_kib}" in
            *[!0-9]*|'') return 1 ;;
            *) : ;;
        esac
        test "${actual_kib}" -le "${declared_kib}" || return 1
    done
    return 0
}

#######################################
# Verify that a required image layer is mounted in every container.
#######################################
check_container_image_layer() {
    local layer_kind="$1" layer_path app layer container_state_value
    case "${layer_kind}" in
        base) layer_path="${BASE_LAYER_PATH}" ;;
        application) layer_path="${APPLICATION_LAYER_PATH}" ;;
        *) return 2 ;;
    esac
    for app in ${APPLICATIONS}; do
        container_state_value="$(container_state "${app}")" || return 1
        test "${container_state_value}" = RUNNING || return 1
        layer="${layer_path}"
        test -d "${layer}" || return 1
        mountpoint -q "${layer}" || return 1
    done
    return 0
}

#######################################
# Check that declared network access exposes standard sockets.
#######################################
check_container_network_standard_sockets() {
    container_backend network standard-sockets
    # TODO: Add geisa-test traffic assertions for allowed socket connectivity
}

#######################################
# Check the per-application network access-control policy.
#######################################
check_container_network_acl() {
    container_backend network acl
    # TODO: Add geisa-test traffic assertions for denied undeclared network access
}

#######################################
# Check the per-application network volume limit policy.
#######################################
check_container_network_volume_limit() {
    container_backend network volume-limit
    # TODO: Add geisa-test traffic assertions for quota exhaustion.
}

#######################################
# Determine whether any application manifest grants direct network access.
#######################################
has_container_network_grant() {
    has_privileged_access || return 1
    container_backend has-network-grant
}

#######################################
# Send a marker through each container's logging interface and find it on host.
#######################################
check_container_logging() {
    local app marker logging_command
    for app in ${APPLICATIONS}; do
        marker="geisa-conformance-${app}-$$"
        logging_command="test -S /dev/log && logger -t geisa-conformance '${marker}'"
        container_run_command "${app}" "${logging_command}" || return 1
        { host_exec journalctl --no-pager -n 200 2>/dev/null || true; host_exec cat /var/log/messages /var/log/syslog 2>/dev/null || true; } |
            grep -qF "${marker}" || return 1
    done
    return 0
}

#######################################
# Record container states for each GEISA application under test.
#######################################
save_container_states() {
    local app state
    : > "${CONTAINER_STATE_FILE}" || return 1
    for app in ${APPLICATIONS}; do
        state="$(container_state "${app}")"
        printf '%s %s\n' "${app}" "${state}" >> "${CONTAINER_STATE_FILE}"
    done
}

#######################################
# Return each application to the previous state recorded by save_container_states.
#######################################
restore_container_states() {
    local app state
    test -f "${CONTAINER_STATE_FILE}" || return 0
    while read -r app state; do
        if test "${state}" = RUNNING; then
            manage_package activate "${app}"
        else
            manage_package deactivate "${app}"
        fi
    done < "${CONTAINER_STATE_FILE}"
    rm -f "${CONTAINER_STATE_FILE}"
}

#######################################
# Verify persistence of /home/geisa across an application restart.
#######################################
check_container_restart_persistence() {
    local app marker marker_path write_marker_command verify_marker_command status=0
    save_container_states || return 1
    trap 'restore_container_states
        exit 1' INT TERM HUP QUIT
    for app in ${APPLICATIONS}; do
        marker="geisa-conformance-restart-${app}-$$"
        marker_path="${CONTAINER_PERSISTENT_MOUNT}/.geisa-restart-test"
        write_marker_command="printf '%s' '${marker}' > '${marker_path}'"
        container_run_command "${app}" "${write_marker_command}" || status=1
        test "${status}" -eq 0 || break
        container_restart "${app}" || status=1
        test "${status}" -eq 0 || break
        verify_marker_command="grep -qF '${marker}' '${marker_path}' && rm -f '${marker_path}'"
        container_run_command "${app}" "${verify_marker_command}" || status=1
        test "${status}" -eq 0 || break
    done
    trap - INT TERM HUP QUIT
    restore_container_states
    return "${status}"
}

#######################################
# Create the marker file before the host launcher resets the device.
#
# The launcher keeps the name and passes it back to Cukinia after the reset.
#######################################
seed_container_reboot_persistence() {
    local marker="$1" app
    test -n "${marker}" || return 1
    for app in ${APPLICATIONS}; do
        container_run_command "${app}" "touch '${CONTAINER_PERSISTENT_MOUNT}/${marker}'" || return 1
    done
    sync
    sync
    return 0
}

#######################################
# Check that the reboot marker survived the host launcher reset.
#
# The marker is removed whether or not it was found.
#######################################
check_container_reboot_persistence() {
    local app marker_path verify_marker_command
    test -n "${REBOOT_PERSISTENCE_MARKER}" || return 1
    for app in ${APPLICATIONS}; do
        marker_path="${CONTAINER_PERSISTENT_MOUNT}/${REBOOT_PERSISTENCE_MARKER}"
        verify_marker_command="test -f '${marker_path}'
            status=\$?
            rm -f '${marker_path}'
            exit \${status}"
        container_run_command "${app}" "${verify_marker_command}" || return 1
    done
    return 0
}

#######################################
# Determine whether a filesystem type provides journaling.
#######################################
is_journaling_filesystem() {
    case " ${JOURNALING_FILESYSTEMS} " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

#######################################
# Verify journaling and metadata-integrity settings for persistent storage.
#######################################
check_container_persistent_journaling() {
    local app mount_point mount_source filesystem mount_options image filesystem_metadata checksum
    for app in ${APPLICATIONS}; do
        mount_point="${ROOTFS_PATH}${CONTAINER_PERSISTENT_MOUNT}"
        mount_source="$(awk -v path="${mount_point}" '$2 == path { print $1; exit }' /proc/mounts)"
        filesystem="$(awk -v path="${mount_point}" '$2 == path { print $3; exit }' /proc/mounts)"
        mount_options="$(awk -v path="${mount_point}" '$2 == path { print $4; exit }' /proc/mounts)"
        test -n "${mount_source}" && test -n "${filesystem}" || return 1
        is_journaling_filesystem "${filesystem}" || return 1

        case ",${mount_options}," in
            *,noload,*|*,norecovery,*|*,nolog,*|*,disable_checkpoint,*) return 1 ;;
            *) : ;;
        esac

        case "${filesystem}" in
            ext3|ext4)
                image="${PERSISTENT_IMAGE_PATH}"
                if command -v dumpe2fs >/dev/null 2>&1; then
                    filesystem_metadata="$(host_exec dumpe2fs -h "${image}" 2>/dev/null)" || return 1
                elif command -v tune2fs >/dev/null 2>&1; then
                    filesystem_metadata="$(host_exec tune2fs -l "${image}" 2>/dev/null)" || return 1
                else
                    return 1
                fi
                printf '%s\n' "${filesystem_metadata}" |
                    awk -F: '$1 ~ /^Filesystem features/ && $2 ~ /(^|[[:space:]])has_journal([[:space:]]|$)/ { found=1 } END { exit !found }' ||
                    return 1
                ;;
            zfs)
                command -v zfs >/dev/null 2>&1 || return 1
                checksum="$(host_exec zfs get -H -o value checksum "${mount_source}" 2>/dev/null)" || return 1
                test "${checksum}" != "off" || return 1
                ;;
            *) : ;;
        esac
    done
    return 0
}
