#!/usr/bin/env sh
set -e

EXITCODE=0

# bits of this were adapted from check-config.sh of moby
# see also https://github.com/moby/moby/blob/master/contrib/check-config.sh

kernelVersion="$(uname -r)"

possibleConfigs="
	/proc/config.gz
	/boot/config-${kernelVersion}
	/usr/src/linux-${kernelVersion}/.config
	/usr/src/linux/.config
"

if [ $# -gt 0 ]; then
	CONFIG="$1"
else
	: "${CONFIG:=/proc/config.gz}"
fi

if ! command -v zgrep > /dev/null 2>&1; then
	zgrep() {
		zcat "$2" | grep "$1"
	}
fi

useColor=true
# shellcheck disable=SC2154
if [ "${NO_COLOR}" = "1" ] || [ ! -t 1 ]; then
	useColor=false
fi
kernelMajor="${kernelVersion%%.*}"
kernelMinor="${kernelVersion#"${kernelMajor}".}"
kernelMinor="${kernelMinor%%.*}"

is_set_in_kernel() {
	zgrep "CONFIG_$1=y" "${CONFIG}" > /dev/null
}
is_set_as_module() {
	zgrep "CONFIG_$1=m" "${CONFIG}" > /dev/null
}

color() {
	# if stdout is not a terminal, then don't do color codes.
	if [ "${useColor}" = "false" ]; then
		return 0
	fi
	codes=
	if [ "$1" = 'bold' ]; then
		codes='1'
		shift
	fi
	if [ "$#" -gt 0 ]; then
		code=
		case "$1" in
			# see https://en.wikipedia.org/wiki/ANSI_escape_code#Colors
			black) code=30 ;;
			red) code=31 ;;
			green) code=32 ;;
			yellow) code=33 ;;
			blue) code=34 ;;
			magenta) code=35 ;;
			cyan) code=36 ;;
			white) code=37 ;;
			*) code= ;;
		esac
		if [ -n "${code}" ]; then
			codes="${codes:+${codes};}${code}"
		fi
	fi
	printf '\033[%sm' "${codes}"
}
wrap_color() {
	text="$1"
	shift
	color "$@"
	printf '%s' "${text}"
	color reset
	echo
}

wrap_good() {
	# shellcheck disable=SC2312
	echo "$(wrap_color "$1" white): $(wrap_color "$2" green)"
}
wrap_bad() {
	# shellcheck disable=SC2312
	echo "$(wrap_color "$1" bold): $(wrap_color "$2" bold red)"
}
wrap_warning() {
	wrap_color >&2 "$*" red
}

check_flag() {
# shellcheck disable=SC2310
	if is_set_in_kernel "$1"; then
		wrap_good "CONFIG_$1" 'enabled'
	elif is_set_as_module "$1"; then
		wrap_good "CONFIG_$1" 'enabled (as module)'
	else
		wrap_bad "CONFIG_$1" 'missing'
		EXITCODE=1
	fi
}

check_flags() {
	for flag in "$@"; do
		printf -- '- '
		check_flag "${flag}"
	done
}

if [ ! -e "${CONFIG}" ]; then
	wrap_warning "warning: ${CONFIG} does not exist, searching other paths for kernel config ..."
	for tryConfig in ${possibleConfigs}; do
		if [ -e "${tryConfig}" ]; then
			CONFIG="${tryConfig}"
			break
		fi
	done
	if [ ! -e "${CONFIG}" ]; then
		wrap_warning "error: cannot find kernel config"
		wrap_warning "  try running this script again, specifying the kernel config:"
		wrap_warning "    CONFIG=/path/to/kernel/.config $0 or $0 /path/to/kernel/.config"
		exit 1
	fi
fi

wrap_color "info: reading kernel config from ${CONFIG} ..." white
echo

echo 'Generally Necessary:'

printf -- '- '
#shellcheck disable=SC2312
if [ "$(stat -f -c %t /sys/fs/cgroup 2> /dev/null)" = '63677270' ]; then
	wrap_good 'cgroup hierarchy' 'cgroupv2'
	cgroupv2ControllerFile='/sys/fs/cgroup/cgroup.controllers'
	if [ -f "${cgroupv2ControllerFile}" ]; then
		echo '  Controllers:'
		for controller in cpu cpuset io memory pids; do
			if grep -qE '(^| )'"${controller}"'($| )' "${cgroupv2ControllerFile}"; then
				echo "  - $(wrap_good "${controller}" 'available')"
			else
				echo "  - $(wrap_bad "${controller}" 'missing')"
			fi
		done
	else
		wrap_bad "${cgroupv2ControllerFile}" 'nonexistent??'
	fi
	# TODO find an efficient way to check if cgroup.freeze exists in subdir
else
	cgroupSubsystemDir="$(sed -rne '/^[^ ]+ ([^ ]+) cgroup ([^ ]*,)?(cpu|cpuacct|cpuset|devices|freezer|memory)[, ].*$/ { s//\1/p; q }' /proc/mounts)"
	cgroupDir="$(dirname "${cgroupSubsystemDir}")"
	if [ -d "${cgroupDir}/cpu" ] || [ -d "${cgroupDir}/cpuacct" ] || [ -d "${cgroupDir}/cpuset" ] || [ -d "${cgroupDir}/devices" ] || [ -d "${cgroupDir}/freezer" ] || [ -d "${cgroupDir}/memory" ]; then
		echo "$(wrap_good 'cgroup hierarchy' 'properly mounted') [${cgroupDir}]"
	else
		if [ -n "${cgroupSubsystemDir}" ]; then
			echo "$(wrap_bad 'cgroup hierarchy' 'single mountpoint!') [${cgroupSubsystemDir}]"
		else
			wrap_bad 'cgroup hierarchy' 'nonexistent??'
		fi
		EXITCODE=1
		echo "    $(wrap_color '(see https://github.com/tianon/cgroupfs-mount)' yellow)"
	fi
fi

#shellcheck disable=SC2312
if [ "$(cat /sys/module/apparmor/parameters/enabled 2> /dev/null)" = 'Y' ]; then
	printf -- '- '
	if command -v apparmor_parser > /dev/null 2>&1; then
		wrap_good 'apparmor' 'enabled and tools installed'
	else
		wrap_bad 'apparmor' 'enabled, but apparmor_parser missing'
		printf '    '
		if command -v apt-get > /dev/null 2>&1; then
			wrap_color '(use "apt-get install apparmor" to fix this)'
		elif command -v yum > /dev/null 2>&1; then
			wrap_color '(your best bet is "yum install apparmor-parser")'
		else
			wrap_color '(look for an "apparmor" package for your distribution)'
		fi
		EXITCODE=1
	fi
fi

check_flags \
	NAMESPACES NET_NS PID_NS IPC_NS UTS_NS \
	CGROUPS CGROUP_CPUACCT CGROUP_DEVICE CGROUP_FREEZER CGROUP_SCHED CPUSETS MEMCG \
	KEYS \
	VETH BRIDGE BRIDGE_NETFILTER \
	IP_NF_FILTER IP_NF_MANGLE IP_NF_TARGET_MASQUERADE \
	IP6_NF_FILTER IP6_NF_MANGLE IP6_NF_TARGET_MASQUERADE \
	NETFILTER_XT_MATCH_ADDRTYPE \
	NETFILTER_XT_MATCH_CONNTRACK \
	NETFILTER_XT_MATCH_IPVS \
	NETFILTER_XT_MARK \
	IP_NF_RAW IP_NF_NAT NF_NAT \
	IP6_NF_RAW IP6_NF_NAT NF_NAT \
	POSIX_MQUEUE
# (POSIX_MQUEUE is required for bind-mounting /dev/mqueue into containers)

if [ "${kernelMajor}" -lt 4 ] || { [ "${kernelMajor}" -eq 4 ] && [ "${kernelMinor}" -lt 8 ]; }; then
	check_flags DEVPTS_MULTIPLE_INSTANCES
fi

if [ "${kernelMajor}" -lt 5 ] || { [ "${kernelMajor}" -eq 5 ] && [ "${kernelMinor}" -le 1 ]; }; then
	check_flags NF_NAT_IPV4
fi

if [ "${kernelMajor}" -lt 5 ] || { [ "${kernelMajor}" -eq 5 ] && [ "${kernelMinor}" -le 2 ]; }; then
	check_flags NF_NAT_NEEDED
fi
# check availability of BPF_CGROUP_DEVICE support
if [ "${kernelMajor}" -ge 5 ] || { [ "${kernelMajor}" -eq 4 ] && [ "${kernelMinor}" -ge 15 ]; }; then
	check_flags CGROUP_BPF
fi

echo

exit "${EXITCODE}"
