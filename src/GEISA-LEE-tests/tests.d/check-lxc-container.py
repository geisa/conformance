#!/usr/bin/env python3

# Copyright (C) 2026 Southern California Edison

import argparse
from functools import lru_cache
import json
import os
from pathlib import Path
import re
import select
import shlex
import socket
import subprocess
import sys

LXC_PATH = Path(os.environ.get("LXC_PATH", "/platform/conformance/lxc"))
REFERENCE_APPLICATION = os.environ.get("REFERENCE_APPLICATION")
MANIFEST_PATH = os.environ.get("APPLICATION_MANIFEST_PATH")
STORAGE_FIELDS = ("persistent", "nonpersistent")
# Container mount point and geisa-test probe for each storage field.
STORAGE_PROBES = {
    "persistent": ("/home/geisa", "persistent_storage", "GEISA_TEST_PERSISTENT_STORAGE_DIR"),
    "nonpersistent": ("/tmp", "transient_storage", "GEISA_TEST_TRANSIENT_STORAGE_DIR"),
}
# geisa-test needs a few seconds to connect and complete discovery before a
# probe starts. It keeps running after the probe, so it is stopped after that.
PROBE_STARTUP_S = 5
PROBE_CPU_DURATION_MS = 5000
PROBE_MEMORY_DURATION_MS = 3000
# Storage probes ignore the duration and write until they reach their target.
# It only sets how long the writes may take before the probe is stopped.
PROBE_STORAGE_DURATION_MS = 3000
# Bytes sent past the daily volume, so that the quota is surely used up.
VOLUME_MARGIN = 4096
# transport:address:port notation of the manifest schema.
PERMISSION_PATTERN = re.compile(r"(tcp:|udp:|)([0-9a-f:.]+|\[[0-9a-f:.]+\]|):([0-9]+)", re.IGNORECASE)


def is_reference(app_name: str) -> bool:
    """Check whether an application is the configured reference application.

    Args:
        app_name: Application name to compare with the reference name.
    """
    return app_name == REFERENCE_APPLICATION


def exercise_limit(app_name: str, limit: str, exercise, *arguments) -> None:
    """Exercise a limit of an application with geisa-test, then stop its container.

    Only the reference application is exercised, and only when it is geisa-test.
    Otherwise, warn that the exercise is skipped. The probes replace the running
    application, so the caller activates it again with manage_package.py, which
    also restores its network policy.

    Args:
        app_name: Installed application name.
        limit: Name of the limit, for the warning.
        exercise: Function that runs the probes, given the application name first.
        arguments: Other arguments of the exercise.
    """
    if not is_reference(app_name):
        return
    if REFERENCE_APPLICATION != "geisa-test":
        print(
            f"check-lxc-container: warning: the {limit} limit is not exercised, which is "
            "only supported with geisa-test as the reference application for now",
            file=sys.stderr,
        )
        return
    try:
        exercise(app_name, *arguments)
    finally:
        subprocess.run(
            ("lxc-stop", "-P", str(LXC_PATH), "-n", app_name, "-k"),
            check=True,
            capture_output=True,
        )


# --------------------------------------------------------------------------- #
# Application manifest
# --------------------------------------------------------------------------- #


def application_manifest_path() -> Path:
    """Return the configured target-side manifest path."""
    if not MANIFEST_PATH:
        raise ValueError("APPLICATION_MANIFEST_PATH must be set")
    configured = Path(MANIFEST_PATH)
    if not configured.is_absolute():
        raise ValueError("APPLICATION_MANIFEST_PATH must be absolute")
    return configured


@lru_cache(maxsize=1)
def read_manifest(app_name: str) -> dict:
    """Read an application's manifest.

    The manifest is parsed on the first call and kept in memory, so repeated
    checks do not access the filesystem again.

    Args:
        app_name: Installed application name.
    """
    path = application_manifest_path()
    with path.open(encoding="utf-8") as stream:
        document = json.load(stream)
    manifest = document["geisa-application-manifest"]["manifest"]
    return manifest


def storage_limit(app_name: str, field: str) -> object:
    """Read a storage limit from an application's manifest.

    Args:
        app_name: Installed application name.
        field: Storage field suffix, such as persistent or nonpersistent.
    """
    limit = read_manifest(app_name)["resources"][f"storage-{field}"]
    return limit


def start_string(app_name: str) -> str:
    """Read the exact start command an application declares in its manifest.

    Args:
        app_name: Installed application name.
    """
    launch = read_manifest(app_name)["default-launch-strategy"]
    return launch.get("start-string", "/sbin/init")


def launch_command(app_name: str) -> str:
    """Read the entry point of the start command an application declares in its manifest.

    Args:
        app_name: Installed application name.
    """
    words = shlex.split(start_string(app_name))
    if not words:
        raise ValueError("application start-string cannot be empty")
    return words[0]


# --------------------------------------------------------------------------- #
# cgroup v2 constraints
# --------------------------------------------------------------------------- #


def read_integer(path: Path) -> int:
    """Read an integer from a text file.

    Args:
        path: File containing the integer value.
    """
    return int(path.read_text(encoding="utf-8").strip())


def parse_cpu_list(value: str) -> set[int]:
    """Parse a Linux CPU-list string into a set of CPU numbers.

    Args:
        value: CPU numbers and ranges separated by commas.
    """
    cpus: set[int] = set()
    for item in value.strip().split(","):
        if not item:
            continue
        if "-" in item:
            first, last = (int(part) for part in item.split("-", 1))
            if last < first:
                raise ValueError(f"invalid CPU range: {item}")
            cpus.update(range(first, last + 1))
        else:
            cpus.add(int(item))
    return cpus


def cgroup_path(pid: int) -> Path:
    """Find the cgroup v2 path for a process.

    Args:
        pid: Process ID whose cgroup should be located.
    """
    for line in Path(f"/proc/{pid}/cgroup").read_text(encoding="utf-8").splitlines():
        hierarchy, controllers, relative = line.split(":", 2)
        if hierarchy == "0" and not controllers:
            path = Path("/sys/fs/cgroup") / relative.lstrip("/")
            return path
    raise RuntimeError("process has no cgroup v2 entry")


def check_cpu_count(pid: int, policy: dict) -> None:
    """Check the configured and effective CPU sets for a process.

    Args:
        pid: Container init process ID.
        policy: Expected cgroup values for the application.
    """
    root = cgroup_path(pid)
    configured = parse_cpu_list((root / "cpuset.cpus").read_text(encoding="utf-8"))
    if not configured:
        raise RuntimeError("CPU set is not explicitly constrained")
    expected = policy.get("cpuset_cpus")
    if expected is not None and configured != expected:
        raise RuntimeError(f"CPU set is {sorted(configured)}, expected {sorted(expected)}")
    effective_path = root / "cpuset.cpus.effective"
    if effective_path.is_file():
        effective = parse_cpu_list(effective_path.read_text(encoding="utf-8"))
        if not effective:
            raise RuntimeError("effective CPU set is empty")
        if expected is not None and effective != expected:
            raise RuntimeError(f"effective CPU set is {sorted(effective)}, expected {sorted(expected)}")


def check_cpu_percent(pid: int, policy: dict) -> None:
    """Check the cgroup CPU quota against the application policy.

    Args:
        pid: Container init process ID.
        policy: Expected cgroup values for the application.
    """
    expected = policy.get("cpu_percent")
    maximum = cgroup_path(pid) / "cpu.max"
    quota_text, period_text = maximum.read_text(encoding="utf-8").split()
    if quota_text == "max":
        raise RuntimeError("CPU quota is unlimited")
    quota, period = int(quota_text), int(period_text)
    if quota <= 0:
        raise RuntimeError(f"CPU quota is invalid: {quota}/{period}")
    if expected is not None and quota * 100 != expected * period:
        raise RuntimeError(f"CPU quota is {quota}/{period}, expected {expected}%")


def check_cpu_priority(pid: int, policy: dict) -> None:
    """Check the cgroup CPU weight against the application policy.

    Args:
        pid: Container init process ID.
        policy: Expected cgroup values for the application.
    """
    actual = read_integer(cgroup_path(pid) / "cpu.weight")
    if not 1 <= actual <= 10000:
        raise RuntimeError(f"CPU priority is outside the cgroup v2 range: {actual}")
    expected = policy.get("cpu_weight")
    if expected is not None and actual != expected:
        raise RuntimeError(f"CPU priority is {actual}, expected {expected}")


def check_memory(pid: int, policy: dict) -> None:
    """Check the cgroup memory limit against the application policy.

    Args:
        pid: Container init process ID.
        policy: Expected cgroup values for the application.
    """
    maximum = cgroup_path(pid) / "memory.max"
    expected = int(policy["memory_kib"]) * 1024
    value = maximum.read_text(encoding="utf-8").strip()
    if value == "max":
        raise RuntimeError("memory limit is unlimited")
    actual = int(value)
    if actual != expected:
        raise RuntimeError(f"memory limit is {actual} bytes, expected {expected}")


CGROUP_CHECKS = {
    "cpu-count": check_cpu_count,
    "cpu-percent": check_cpu_percent,
    "cpu-priority": check_cpu_priority,
    "memory": check_memory,
}


# --------------------------------------------------------------------------- #
# cgroup v2 enforcement with the geisa-test reference application
# --------------------------------------------------------------------------- #


def read_counters(path: Path) -> dict[str, int]:
    """Read a cgroup file made of name and value pairs, such as cpu.stat.

    Args:
        path: cgroup file to read.
    """
    lines = path.read_text(encoding="utf-8").splitlines()
    return {name: int(value) for name, value in (line.split() for line in lines)}


def geisa_test_command(app_name: str, seconds: int, **settings: object) -> tuple[str, ...]:
    """Build the command that replaces the running reference application with geisa-test.

    The running instance is stopped, then the exact manifest start-string is run
    again from the container root, like the platform does, with the geisa-test
    settings in its environment. After the given time geisa-test gets SIGTERM
    by name, so that it prints its summary whatever shell wraps the start-string.

    Args:
        app_name: Installed application name.
        seconds: Time before the application is stopped.
        settings: geisa-test environment variables.
    """
    entry_point = shlex.quote(Path(launch_command(app_name)).name)
    variables = " ".join(f"{name}={shlex.quote(str(value))}" for name, value in settings.items())
    script = (
        f"killall -q {entry_point}; cd / && "
        f"env {variables} /bin/sh -c {shlex.quote(start_string(app_name))} & app=$!; "
        f"{{ sleep {seconds}; killall -q -TERM {entry_point}; }} & timer=$!; "
        'wait "$app"; kill "$timer" 2>/dev/null'
    )
    return ("lxc-attach", "-P", str(LXC_PATH), "-n", app_name, "--", "/bin/sh", "-c", script)


def run_geisa_test(app_name: str, seconds: int, **settings: object) -> str:
    """Replace the running reference application with a geisa-test run.

    Args:
        app_name: Installed application name.
        seconds: Time before the application is stopped.
        settings: geisa-test environment variables.

    Returns:
        The geisa-test standard output.
    """
    result = subprocess.run(
        geisa_test_command(app_name, seconds, **settings),
        check=False,
        text=True,
        capture_output=True,
    )
    return result.stdout


def geisa_test_summary(output: str) -> dict | None:
    """Find the summary in the geisa-test output.

    Args:
        output: geisa-test standard output.

    Returns:
        The geisa-test summary, or None when the application did not exit cleanly.
    """
    for line in output.splitlines():
        if line.startswith('{"geisa-test-summary"'):
            return json.loads(line)["geisa-test-summary"]
    return None


def run_probe(app_name: str, test: str, duration_ms: int, **settings: object) -> dict | None:
    """Replace the running reference application with a geisa-test probe run.

    The probe starts after discovery and runs for the given duration.

    Args:
        app_name: Installed application name.
        test: geisa-test probe name, such as cpu or memory.
        duration_ms: Probe duration in milliseconds.
        settings: Extra geisa-test environment variables.

    Returns:
        The geisa-test summary, or None when the application did not exit cleanly.
    """
    output = run_geisa_test(
        app_name,
        duration_ms // 1000 + PROBE_STARTUP_S,
        GEISA_TEST_APP_MODE="test",
        GEISA_TEST_APP_TEST=test,
        GEISA_TEST_APP_TEST_DURATION_MS=duration_ms,
        **settings,
    )
    return geisa_test_summary(output)


def exercise_cpu_percent(app_name: str, pid: int, policy: dict) -> None:
    """Check that a full CPU load is throttled down to the CPU quota.

    Worst case with a 100 ms period and a 20% quota (Q = 20 ms per period):
    the probe starts at t=80 and stops at t=320, so elapsed_ms = 240.
    It runs 80-100, 100-120, 200-220 and 300-320, so 80 ms of CPU, while 20% of 240 is only 48.
    The first and last periods each add up to Q, so the bound is 20% of elapsed_ms + 2 * Q = 88.

    Args:
        app_name: Installed application name.
        pid: Container init process ID.
        policy: Expected cgroup values for the application.
    """
    stat = cgroup_path(pid) / "cpu.stat"
    period_ms = int((cgroup_path(pid) / "cpu.max").read_text(encoding="utf-8").split()[1]) / 1000
    throttled = read_counters(stat)["nr_throttled"]
    summary = run_probe(app_name, "cpu", PROBE_CPU_DURATION_MS)
    if summary is None or summary["probe"]["result"] != "completed":
        raise RuntimeError("geisa-test CPU probe did not complete")
    probe = summary["probe"]
    # The quota is granted once per cpu.max period. The probe might not start or
    # end exactly on a period boundary, so it may get a full quota in each partial
    # period at both ends.
    allowed_ms = policy["cpu_percent"] * (probe["elapsed_ms"] + 2 * period_ms) / 100
    if probe["cpu_time_ms"] > allowed_ms:
        usage = probe["cpu_time_ms"] * 100 / probe["elapsed_ms"]
        raise RuntimeError(
            f"CPU probe used {usage:.1f}% of a CPU, above the {policy['cpu_percent']}% quota"
        )
    if read_counters(stat)["nr_throttled"] <= throttled:
        raise RuntimeError("CPU probe was never throttled")


def exercise_memory(app_name: str, pid: int, policy: dict) -> None:
    """Check that allocating past the memory limit gets the application killed.

    Args:
        app_name: Installed application name.
        pid: Container init process ID.
        policy: Expected cgroup values for the application.
    """
    events = cgroup_path(pid) / "memory.events"
    killed = read_counters(events)["oom_kill"]
    # Allocating app-ram is enough to go over the limit, because the process
    # already uses memory for its code and buffers.
    target = policy["memory_kib"] * 1024
    summary = run_probe(
        app_name, "memory", PROBE_MEMORY_DURATION_MS, GEISA_TEST_APP_TEST_TARGET_BYTES=target
    )
    if summary is not None:
        if summary["probe"]["target_bytes"] != target:
            raise RuntimeError(f"geisa-test cannot allocate {target} bytes, the manifest app-ram")
        raise RuntimeError(
            f"memory probe touched {summary['probe']['touched_bytes']} bytes "
            f"with a limit of {policy['memory_kib']} KiB and was not stopped"
        )
    if read_counters(events)["oom_kill"] <= killed:
        raise RuntimeError("memory probe was not stopped by the cgroup OOM killer")


CGROUP_EXERCISES = {
    "cpu-percent": exercise_cpu_percent,
    "memory": exercise_memory,
}


def exercise_storage(app_name: str, field: str) -> None:
    """Check that writing past a storage limit fails once the limit is reached.

    Args:
        app_name: Installed application name.
        field: Storage field suffix, such as persistent or nonpersistent.
    """
    mount, test, directory_variable = STORAGE_PROBES[field]
    limit = int(storage_limit(app_name, field)) * 1024
    # One MiB past the limit, so the write cannot fit even with no filesystem overhead.
    target = limit + 1024 * 1024
    summary = run_probe(
        app_name,
        test,
        PROBE_STORAGE_DURATION_MS,
        GEISA_TEST_APP_TEST_TARGET_BYTES=target,
        **{directory_variable: mount},
    )
    if summary is None:
        raise RuntimeError(f"geisa-test {test} probe did not report a result")
    probe = summary["probe"]
    if probe["target_bytes"] != target:
        raise RuntimeError(f"geisa-test cannot write {target} bytes, past the manifest limit")
    if probe["result"] == "completed":
        raise RuntimeError(
            f"{test} probe wrote {probe['touched_bytes']} bytes in {mount} "
            f"with a limit of {limit} bytes and was not stopped"
        )
    # Some data must have been written, or the probe failed for another reason.
    if not 0 < probe["touched_bytes"] <= limit:
        raise RuntimeError(
            f"{test} probe wrote {probe['touched_bytes']} bytes in {mount} "
            f"with a limit of {limit} bytes ({probe['error']})"
        )


def check_storage_enforcement(arguments: argparse.Namespace) -> None:
    """Exercise a storage limit of the reference application.

    Args:
        arguments: Parsed command-line arguments for the storage-enforcement command.
    """
    # A limit of zero means a read-only mount, which the configured-value check
    # already covers.
    if int(storage_limit(arguments.application, arguments.field)) == 0:
        return
    exercise_limit(
        arguments.application, f"{arguments.field} storage", exercise_storage, arguments.field
    )


def check_cgroup(arguments: argparse.Namespace) -> None:
    """Run the selected cgroup check for an application.

    Args:
        arguments: Parsed command-line arguments for the cgroup command.
    """
    # Are the cgroup v2 limits present and configured as expected?
    resources = read_manifest(arguments.application)["resources"]
    policy = {
        "memory_kib": int(resources["app-ram"]),
        "cpu_percent": int(resources["app-cpu"]) if "app-cpu" in resources else None,
    }
    # app-cpu is optional: without it there is no percentage to check or exercise.
    if arguments.constraint == "cpu-percent" and policy["cpu_percent"] is None:
        return
    if is_reference(arguments.application):
        policy["cpuset_cpus"] = parse_cpu_list(arguments.reference_cpuset)
        policy["cpu_weight"] = int(arguments.reference_cpu_weight)
    CGROUP_CHECKS[arguments.constraint](arguments.pid, policy)

    # Are the cgroup v2 limits enforced by the platform as expected?
    # Note: enforcement checks are currently only available for the geisa-test reference application.
    exercise = CGROUP_EXERCISES.get(arguments.constraint)
    if exercise:
        exercise_limit(arguments.application, arguments.constraint, exercise, arguments.pid, policy)


# --------------------------------------------------------------------------- #
# Network policy
# --------------------------------------------------------------------------- #

def network_policy(app_name: str) -> dict | None:
    """Read direct network permissions from an application manifest.

    Returns one entry per granted section (local under HAN, operator and
    internet under FAN) with its inbound and outbound permissions and daily
    volume, or None when no section grants anything.

    Args:
        app_name: Installed application name.
    """
    manifest = read_manifest(app_name)
    communication = manifest.get("communication", {})
    granted = []
    if communication.get("HAN") is True:
        granted.append("local")
    if communication.get("FAN") is True:
        granted.extend(("operator", "internet"))
    sections = {}
    for section in granted:
        requirements = communication.get(section)
        if not isinstance(requirements, dict):
            continue
        permissions = {"inbound": [], "outbound": []}
        for direction in permissions:
            for permission in requirements.get(direction, []):
                match = PERMISSION_PATTERN.fullmatch(permission)
                if not match:
                    raise ValueError(f"invalid {section} {direction} network permission: {permission}")
                transport, address, port = match.groups()
                permissions[direction].append(
                    {
                        "transport": transport.rstrip(":").lower() or None,
                        "address": address.strip("[]"),
                        "port": int(port),
                    }
                )
        if not permissions["inbound"] and not permissions["outbound"]:
            continue
        permissions["daily_volume"] = int(requirements["daily-volume"])
        sections[section] = permissions
    return sections or None


def policy_permissions(policy: dict):
    """Yield the inbound and outbound permissions of every section.

    Args:
        policy: Parsed network policy.
    """
    for section in policy.values():
        yield from section["inbound"]
        yield from section["outbound"]


def init_pid(app_name: str) -> int:
    """Get the init process ID for an application container.

    Args:
        app_name: Installed application name.
    """
    result = subprocess.run(
        ("lxc-info", "-P", str(LXC_PATH), "-n", app_name, "-pH"),
        check=True,
        text=True,
        capture_output=True,
    )
    return int(result.stdout.strip())


def in_network_namespace(
    app_name: str, *command: str, check: bool = True
) -> subprocess.CompletedProcess[str]:
    """Run a command inside an application's network namespace.

    Args:
        app_name: Installed application name.
        command: Command and arguments to run in the namespace.
        check: Whether a nonzero exit status raises an exception.
    """
    return subprocess.run(
        ("nsenter", "--target", str(init_pid(app_name)), "--net", *command),
        check=check,
        text=True,
        capture_output=True,
    )


def network_ruleset(app_name: str) -> list:
    """Read the nftables ruleset from an application network namespace.

    Args:
        app_name: Installed application name.
    """
    result = in_network_namespace(app_name, "nft", "-j", "list", "ruleset")
    ruleset = json.loads(result.stdout)["nftables"]
    return ruleset


def hook_policy(ruleset: list, hook: str) -> str | None:
    """Find the default policy for a named nftables hook.

    Args:
        ruleset: Parsed nftables ruleset.
        hook: Hook name to find, such as output or input.
    """
    for item in ruleset:
        chain = item.get("chain")
        if chain and chain.get("hook") == hook:
            return chain.get("policy")
    return None


def granted_matches(ruleset: list):
    """Yield protocol and port pairs accepted by nftables rules.

    Args:
        ruleset: Parsed nftables ruleset.
    """
    for item in ruleset:
        rule = item.get("rule")
        if not rule:
            continue
        expressions = rule.get("expr", [])
        if not any(isinstance(expr, dict) and "accept" in expr for expr in expressions):
            continue
        for expr in expressions:
            match = expr.get("match") if isinstance(expr, dict) else None
            if not match:
                continue
            left = match.get("left", {})
            payload = left.get("payload", {}) if isinstance(left, dict) else {}
            if payload.get("field") in ("dport", "sport"):
                yield payload.get("protocol"), match.get("right")


def rule_grants(ruleset: list, protocol: str, port: int) -> bool:
    """Check whether a ruleset accepts a protocol and port pair.

    Args:
        ruleset: Parsed nftables ruleset.
        protocol: Transport protocol to find.
        port: Network port to find.
    """
    return any(
        candidate == protocol and value == port
        for candidate, value in granted_matches(ruleset)
    )


def granted_ports(ruleset: list) -> set:
    """Return all ports accepted by the ruleset.

    Args:
        ruleset: Parsed nftables ruleset.
    """
    ports = {value for _, value in granted_matches(ruleset) if isinstance(value, int)}
    return ports


def expected_protocols(permission: dict) -> tuple:
    """Return the protocols allowed by a network permission.

    Args:
        permission: Parsed network permission.
    """
    transport = permission["transport"]
    protocols = ("tcp", "udp") if transport is None else (transport,)
    return protocols


def check_standard_sockets(app_name: str) -> None:
    """Check that every inbound and outbound manifest port is allowed for its protocols.

    Args:
        app_name: Installed application name.
    """
    policy = network_policy(app_name)
    if policy is None:
        return
    ruleset = network_ruleset(app_name)
    for permission in policy_permissions(policy):
        for protocol in expected_protocols(permission):
            if not rule_grants(ruleset, protocol, permission["port"]):
                raise RuntimeError(
                    f"no rule grants socket connectivity to {protocol} port {permission['port']}"
                )


def check_acl(app_name: str) -> None:
    """Check that network hooks deny traffic outside the manifest policy and the MQTT port.

    Args:
        app_name: Installed application name.
    """
    policy = network_policy(app_name)
    if policy is None:
        return
    ruleset = network_ruleset(app_name)
    for hook in ("output", "input"):
        if hook_policy(ruleset, hook) != "drop":
            raise RuntimeError(
                f"the {hook} hook does not deny traffic by default "
                "(principle of least privilege)"
            )
    allowed = {permission["port"] for permission in policy_permissions(policy)}
    allowed.add(mqtt_address(app_name)[1])
    extra = granted_ports(ruleset) - allowed
    if extra:
        raise RuntimeError(
            f"ports {sorted(extra)} are granted but are absent from the manifest's network policy"
        )


def volume_quotas(ruleset: list) -> list:
    """Return byte limits declared by nftables quota objects.

    Args:
        ruleset: Parsed nftables ruleset.
    """
    quotas = []
    for item in ruleset:
        quota = item.get("quota")
        if not isinstance(quota, dict):
            continue
        limit = quota.get("bytes")
        if isinstance(limit, int):
            quotas.append(limit)
    return quotas


def check_volume_limit(app_name: str) -> None:
    """Check that the daily volume of every manifest section matches an nftables quota.

    Args:
        app_name: Installed application name.
    """
    policy = network_policy(app_name)
    if policy is None:
        return
    ruleset = network_ruleset(app_name)
    limits = volume_quotas(ruleset)
    if not limits:
        raise RuntimeError("no volume quota defined")
    for name, section in policy.items():
        if section["daily_volume"] not in limits:
            raise RuntimeError(
                f"no volume quota matches the {name} daily volume of "
                f"{section['daily_volume']} bytes (found {sorted(limits)})"
            )


NETWORK_CHECKS = {
    "standard-sockets": check_standard_sockets,
    "acl": check_acl,
    "volume-limit": check_volume_limit,
}


def mqtt_address(app_name: str) -> tuple[str, int]:
    """Read the MQTT host and port that the platform gives to an application.

    Args:
        app_name: Installed application name.
    """
    path = Path(f"/proc/{init_pid(app_name)}/root/etc/geisa/mqtt.conf")
    settings = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        name, _, value = line.partition("=")
        settings[name.strip()] = value.strip()
    if "HOST" not in settings or "PORT" not in settings:
        raise RuntimeError(f"{path} has no HOST or PORT")
    return settings["HOST"], int(settings["PORT"])


def granted_host_ports(app_name: str) -> tuple[str, dict[int, int]]:
    """Return the MQTT host and the outbound TCP ports that the manifest grants on it.

    geisa-test only opens TCP connections to its MQTT host, but
    GEISA_TEST_APP_PORT changes the port. The test listens on that host as a
    stand-in for any peer the application may reach, so only these ports can
    be tried. The MQTT port itself is left out, since the broker uses it. Each
    port maps to the daily volume of the section that grants it.

    Args:
        app_name: Installed application name.
    """
    host, mqtt_port = mqtt_address(app_name)
    ports = {}
    for section in network_policy(app_name).values():
        for permission in section["outbound"]:
            if "tcp" in expected_protocols(permission) and permission["address"] in ("", host):
                ports[permission["port"]] = section["daily_volume"]
    ports.pop(mqtt_port, None)
    if not ports:
        raise RuntimeError(f"the manifest grants no outbound TCP port on {host} to try")
    return host, ports


def connects(app_name: str, host: str, listener: socket.socket) -> bool:
    """Run geisa-test on the port of a listener and tell whether it got through.

    Args:
        app_name: Installed application name.
        host: MQTT host of the application, where the listener listens.
        listener: Listening socket.
    """
    port = listener.getsockname()[1]
    output = run_geisa_test(app_name, PROBE_STARTUP_S, GEISA_TEST_APP_PORT=port)
    if f"host={host} port={port} " not in output:
        raise RuntimeError(f"geisa-test did not try to connect to {host}:{port}")
    return bool(select.select([listener], [], [], 0)[0])


def exercise_standard_sockets(app_name: str) -> None:
    """Check that the application reaches each TCP port that its manifest grants on the MQTT host.

    Args:
        app_name: Installed application name.
    """
    host, ports = granted_host_ports(app_name)
    for port in sorted(ports):
        # A listener on the granted port sees the connection that the policy lets through.
        with socket.create_server((host, port)) as listener:
            if not connects(app_name, host, listener):
                raise RuntimeError(f"the application could not reach {host}:{port}, which its manifest grants")


def exercise_acl(app_name: str) -> None:
    """Check that the application cannot reach a port that its manifest does not grant.

    Args:
        app_name: Installed application name.
    """
    host = mqtt_address(app_name)[0]
    # A listener on the MQTT host, on a free port that the manifest does not
    # grant, sees any connection that the policy lets through.
    with socket.create_server((host, 0)) as listener:
        port = listener.getsockname()[1]
        if connects(app_name, host, listener):
            raise RuntimeError(f"the application reached {host}:{port}, which its manifest does not grant")


def exercise_volume_limit(app_name: str) -> None:
    """Check that the application cannot reach a granted port once its daily volume is used.

    geisa-test connects to a granted port and the test sends it more than the
    daily volume. Received bytes count in the volume like sent ones. Then
    geisa-test must no longer reach that port.

    Args:
        app_name: Installed application name.
    """
    host, ports = granted_host_ports(app_name)
    port = min(ports)
    volume = ports[port]
    # A CONNACK header that announces the whole length keeps the MQTT client of
    # geisa-test reading until it has received everything.
    length = volume + VOLUME_MARGIN
    header = bytearray([0x20])
    remaining = length
    while True:
        remaining, digit = divmod(remaining, 128)
        header.append(digit | (0x80 if remaining else 0))
        if not remaining:
            break
    with socket.create_server((host, port)) as listener:
        command = geisa_test_command(app_name, PROBE_STARTUP_S, GEISA_TEST_APP_PORT=port)
        with subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as probe:
            while not select.select([listener], [], [], 0.1)[0]:
                if probe.poll() is not None:
                    raise RuntimeError(f"the application could not reach {host}:{port}, which its manifest grants")
            connection, _ = listener.accept()
            with connection:
                connection.settimeout(PROBE_STARTUP_S)
                connection.sendall(bytes(header) + bytes(length))
            probe.wait()
    # A new listener, so that a reconnection made while the volume was not
    # used up yet is not counted.
    with socket.create_server((host, port)) as listener:
        if connects(app_name, host, listener):
            raise RuntimeError(
                f"the application still reached {host}:{port} after receiving {length} bytes, "
                f"more than its daily volume of {volume} bytes"
            )


NETWORK_EXERCISES = {
    "standard-sockets": exercise_standard_sockets,
    "acl": exercise_acl,
    "volume-limit": exercise_volume_limit,
}


def configured_applications() -> list[str]:
    """Read the configured application names from the environment."""
    applications = os.environ.get("APPLICATIONS", "").split()
    if not applications:
        raise RuntimeError("APPLICATIONS is empty")
    return applications


def network_enabled_applications() -> list[str]:
    """Return configured applications that have direct network access."""
    applications = [
        app_name
        for app_name in configured_applications()
        if network_policy(app_name) is not None
    ]
    return applications


def check_network(arguments: argparse.Namespace) -> None:
    """Run the selected network check for each enabled application.

    Args:
        arguments: Parsed command-line arguments for the network command.
    """
    applications = network_enabled_applications()
    if not applications:
        raise RuntimeError("no application manifest grants direct network access")
    for app_name in applications:
        NETWORK_CHECKS[arguments.check](app_name)
        exercise = NETWORK_EXERCISES.get(arguments.check)
        if exercise:
            exercise_limit(app_name, f"network {arguments.check}", exercise)


# --------------------------------------------------------------------------- #
# Command parsing and dispatch
# --------------------------------------------------------------------------- #


def parse_arguments() -> argparse.Namespace:
    """Define and parse the command-line interface."""
    parser = argparse.ArgumentParser(description="Check GEISA LXC container conformance")
    commands = parser.add_subparsers(dest="command", required=True)

    cgroup = commands.add_parser("cgroup", help="check a live cgroup v2 constraint")
    cgroup.add_argument("constraint", choices=tuple(CGROUP_CHECKS))
    cgroup.add_argument("pid", type=int)
    cgroup.add_argument("application")
    cgroup.add_argument("reference_cpuset")
    cgroup.add_argument("reference_cpu_weight")

    storage = commands.add_parser("storage-limit", help="print a manifest storage limit")
    storage.add_argument("application")
    storage.add_argument("field")

    enforcement = commands.add_parser(
        "storage-enforcement", help="exercise a storage limit of the reference application"
    )
    enforcement.add_argument("application")
    enforcement.add_argument("field", choices=STORAGE_FIELDS)

    launch = commands.add_parser(
        "launch-command", help="print the entry point declared in an application manifest"
    )
    launch.add_argument("application")

    network = commands.add_parser("network", help="check direct network policy")
    network.add_argument("check", choices=tuple(NETWORK_CHECKS))

    commands.add_parser(
        "has-network-grant", help="succeed when a manifest grants direct network access"
    )
    arguments = parser.parse_args()
    return arguments


def main() -> int:
    """Dispatch a check and report operational failures."""
    arguments = parse_arguments()
    try:
        if arguments.command == "has-network-grant":
            return 0 if network_enabled_applications() else 1
        if arguments.command == "cgroup":
            check_cgroup(arguments)
        elif arguments.command == "network":
            check_network(arguments)
        elif arguments.command == "storage-limit":
            print(storage_limit(arguments.application, arguments.field))
        elif arguments.command == "storage-enforcement":
            check_storage_enforcement(arguments)
        elif arguments.command == "launch-command":
            print(launch_command(arguments.application))
    except (KeyError, OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f"check-lxc-container: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
