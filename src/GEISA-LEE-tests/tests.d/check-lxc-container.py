#!/usr/bin/env python3

# Copyright (C) 2026 Southern California Edison

import argparse
from functools import lru_cache
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

LXC_PATH = Path(os.environ.get("LXC_PATH", "/platform/conformance/lxc"))
REFERENCE_APPLICATION = os.environ.get("REFERENCE_APPLICATION", "geisa-simple")
MANIFEST_PATH = os.environ.get("APPLICATION_MANIFEST_PATH")
STORAGE_FIELDS = ("persistent", "nonpersistent")


def is_reference(app_name: str) -> bool:
    """Check whether an application is the configured reference application.

    Args:
        app_name: Application name to compare with the reference name.
    """
    return app_name == REFERENCE_APPLICATION


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


def launch_command(app_name: str) -> str:
    """Read the entry point an application declares in its manifest.

    Args:
        app_name: Installed application name.
    """
    launch = read_manifest(app_name)["default-launch-strategy"]
    words = shlex.split(launch.get("start-string", "/sbin/init"))
    if not words:
        raise ValueError("application start-string cannot be empty")
    return words[0]


def storage_limits() -> list[str]:
    """Return every configured application's storage limits as text records."""
    records = [
        f"{app_name}|{field}|{storage_limit(app_name, field)}"
        for app_name in configured_applications()
        for field in STORAGE_FIELDS
    ]
    return records


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


# TODO: ensure threshold is really enforced after workload done (and check if is actually throttled)
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

# TODO: ensure memory threshold is really enforced after workload done (and check if is actually throttled)
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


def check_cgroup(arguments: argparse.Namespace) -> None:
    """Run the selected cgroup check for an application.

    Args:
        arguments: Parsed command-line arguments for the cgroup command.
    """
    resources = read_manifest(arguments.application)["resources"]
    policy = {
        "memory_kib": int(resources["app-ram"]),
        "cpu_percent": int(resources["app-cpu"]) if "app-cpu" in resources else None,
    }
    if is_reference(arguments.application):
        policy["cpuset_cpus"] = parse_cpu_list(arguments.reference_cpuset)
        policy["cpu_weight"] = int(arguments.reference_cpu_weight)
    CGROUP_CHECKS[arguments.constraint](arguments.pid, policy)


# --------------------------------------------------------------------------- #
# Network policy
# --------------------------------------------------------------------------- #

# Note: Stage 1 validates the nftables policy installed for each
# application's deployed manifest. Stage 2 will use geisa-test to attempt
# allowed and disallowed traffic and to intentionally violate the configured quota.
# TODO: Implement the geisa-test enforcement stage.
def network_policy(app_name: str) -> dict | None:
    """Read direct network permissions from an application manifest.

    Args:
        app_name: Installed application name.
    """
    manifest = read_manifest(app_name)
    communication = manifest.get("communication", {})
    local = communication.get("local") if communication.get("HAN") is True else None
    if not isinstance(local, dict) or not local.get("outbound"):
        return None
    permission = local["outbound"][0]
    match = re.fullmatch(r"(?:(tcp|udp):)?.*:([0-9]+)", permission, re.IGNORECASE)
    if not match:
        raise ValueError(f"invalid local outbound network permission: {permission}")
    transport_group = match.group(1)
    port_group = match.group(2)
    transport = transport_group.lower() if transport_group else None
    port = int(port_group)
    policy = {
        "transport": transport,
        "port": port,
        "daily_volume": int(local["daily-volume"]),
    }
    return policy


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


def expected_protocols(policy: dict) -> tuple:
    """Return the protocols allowed by a network policy.

    Args:
        policy: Parsed application network policy.
    """
    transport = policy["transport"]
    protocols = ("tcp", "udp") if transport is None else (transport,)
    return protocols


def check_standard_sockets(app_name: str) -> None:
    """Check that the manifest port is allowed for its expected protocols.

    Args:
        app_name: Installed application name.
    """
    policy = network_policy(app_name)
    if policy is None:
        return
    ruleset = network_ruleset(app_name)
    for protocol in expected_protocols(policy):
        if not rule_grants(ruleset, protocol, policy["port"]):
            raise RuntimeError(
                f"no rule grants socket connectivity to {protocol} port {policy['port']}"
            )


def check_acl(app_name: str) -> None:
    """Check that network hooks deny traffic outside the manifest policy.

    Args:
        app_name: Installed application name.
    """
    policy = network_policy(app_name)
    if policy is None:
        return
    ruleset = network_ruleset(app_name)
    for hook in ("output", "input"):
        if hook_policy(ruleset, hook) != "drop":
            raise RuntimeError(f"the {hook} hook is not deny-by-default")
    for port in granted_ports(ruleset):
        if port != policy["port"]:
            raise RuntimeError(
                f"port {port} is granted but is absent from the manifest's network policy"
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
    """Check that the manifest daily volume matches an nftables quota.

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
    if policy["daily_volume"] not in limits:
        raise RuntimeError(
            "no volume quota matches the manifest limit of "
            f"{policy['daily_volume']} bytes (found {sorted(limits)})"
        )


NETWORK_CHECKS = {
    "standard-sockets": check_standard_sockets,
    "acl": check_acl,
    "volume-limit": check_volume_limit,
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

    commands.add_parser(
        "storage-limits", help="print every application storage limit as application|field|value"
    )

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
        elif arguments.command == "storage-limits":
            print("\n".join(storage_limits()))
        elif arguments.command == "launch-command":
            print(launch_command(arguments.application))
    except (KeyError, OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f"check-lxc-container: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
