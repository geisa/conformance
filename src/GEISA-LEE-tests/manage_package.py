#!/usr/bin/env python3

# Copyright (C) 2026 Southern California Edison

import argparse
import glob
import hashlib
import ipaddress
import json
import os
import re
import shlex
import shutil
import subprocess
import sys

from pathlib import Path

LXC_PATH = Path(os.environ["LXC_PATH"])
BASE_IMAGE_DIR = Path(os.environ["CONTAINER_BASE_IMAGE_DIR"])
BASE_IMAGE_GLOB = os.environ["CONTAINER_BASE_IMAGE_GLOB"]
IMAGE_FSTYPE = os.environ["CONTAINER_IMAGE_FSTYPE"]
PERSISTENT_FSTYPE = os.environ["CONTAINER_PERSISTENT_FSTYPE"]
BASE_LAYER_PATH = os.environ["BASE_LAYER_PATH"]
APPLICATION_LAYER_PATH = os.environ["APPLICATION_LAYER_PATH"]
CONFIGURATION_LAYER_PATH = os.environ["CONFIGURATION_LAYER_PATH"]
UPPER_PATH = os.environ["UPPER_PATH"]
WORK_PATH = os.environ["WORK_PATH"]
ROOTFS_PATH = os.environ["ROOTFS_PATH"]
APPLICATION_IMAGE_PATH = os.environ["APPLICATION_IMAGE_PATH"]
PERSISTENT_IMAGE_PATH = os.environ["PERSISTENT_IMAGE_PATH"]

PERSISTENT_MOUNT = "home/geisa"
NONPERSISTENT_MOUNT = "tmp"
NETWORK_POLICY_TABLE = "geisa_conformance"
NETWORK_POLICY_QUOTA = "network_volume"

NAME_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+$")
CPUSET_PATTERN = re.compile(r"^[0-9]+(?:-[0-9]+)?(?:,[0-9]+(?:-[0-9]+)?)*$")

def environment_integer(name: str) -> int:
    """Read and validate an integer setting from the process environment.

    Args:
        name: Environment-variable name to read.
    """
    try:
        return int(os.environ[name])
    except ValueError as error:
        raise ValueError(f"{name} must be an integer") from error


def resource_integer(resources: dict, field: str, fallback: str) -> int:
    """Select an integer resource limit from the manifest or its environment default.

    Args:
        resources: Manifest resource settings to inspect.
        field: Manifest resource field to prefer.
        fallback: Environment-variable name used when the manifest omits the field.
    """
    if field in resources:
        return int(resources[field])
    return environment_integer(fallback)


def conformance_network_address(app_name: str, gateway: str, prefix: int) -> str:
    """Derive a stable, non-gateway IPv4 address for an application container.

    Args:
        app_name: Application name used to derive the host address.
        gateway: IPv4 gateway address for the container network.
        prefix: CIDR prefix length for the container network.
    """
    interface = ipaddress.IPv4Interface(f"{gateway}/{prefix}")
    network = interface.network
    first_host = 20
    last_host = network.num_addresses - 2
    if last_host < first_host:
        raise ValueError("LXC_NETWORK_PREFIX does not provide enough host addresses")
    digest = int.from_bytes(hashlib.sha256(app_name.encode()).digest()[:4], "big")
    host_number = first_host + digest % (last_host - first_host + 1)
    address = ipaddress.IPv4Address(int(network.network_address) + host_number)
    if address == interface.ip:
        address = ipaddress.IPv4Address(int(address) + (1 if host_number < last_host else -1))
    return str(address)


def manifest_network_policy(communication: dict) -> dict:
    """Translate manifest communication permissions into an enforceable network policy.

    Args:
        communication: Manifest communication section to validate and interpret.
    """
    # Network access is denied by default, following the principle of least privilege.
    denied = {
        "network_access": False,
        "network_transport": None,
        "network_port": 0,
        "network_daily_volume_bytes": 0,
    }
    if not isinstance(communication, dict) or communication.get("HAN") is not True:
        return denied
    local = communication.get("local")
    if not isinstance(local, dict):
        return denied
    outbound = local.get("outbound")
    if not isinstance(outbound, list) or not outbound:
        return denied
    permission = outbound[0]
    if not isinstance(permission, str):
        raise ValueError("local outbound network permission must be a string")
    match = re.fullmatch(r"(?:(tcp|udp):)?.*:([0-9]+)", permission, re.IGNORECASE)
    if not match:
        raise ValueError(f"invalid local outbound network permission: {permission}")
    transport_group = match.group(1)
    port_group = match.group(2)
    transport = transport_group.lower() if transport_group else None    # None here (when network access is allowed) means both TCP and UDP are allowed
    port = int(port_group)
    daily_volume = int(local["daily-volume"])
    return {
        "network_access": True,
        "network_transport": transport,
        "network_port": port,
        "network_daily_volume_bytes": daily_volume,
    }


def run(*command: str, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess[str]:
    """Run a system command with consistent error handling and optional output capture.

    Args:
        command: Command and arguments to execute.
        check: Whether a nonzero exit status raises an exception.
        capture: Whether to capture standard output and error streams.
    """
    return subprocess.run(
        command,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.DEVNULL if capture else None,
    )


def mounted(path: Path) -> bool:
    """Determine whether a path is currently a mount point.

    Args:
        path: Filesystem path to check.
    """
    return run("mountpoint", "-q", str(path), check=False).returncode == 0


def read_manifest(path: Path, application_name: str | None = None) -> dict:
    """Read a manifest and construct the validated metadata needed to provision it.

    Args:
        path: Manifest JSON file to load.
        application_name: Optional installed name that overrides the manifest name.
    """
    with path.open(encoding="utf-8") as stream:
        document = json.load(stream)
    try:
        manifest = document["geisa-application-manifest"]["manifest"]
        name = application_name or manifest["name"]
        resources = manifest["resources"]
        launch = manifest["default-launch-strategy"]
        communication = manifest.get("communication", {})
        network_gateway = os.environ["LXC_NETWORK_GATEWAY"]
        network_prefix = environment_integer("LXC_NETWORK_PREFIX")
        values = {
            "application_id": manifest["app-id"],
            "name": name,
            "version": manifest["app-version"],
            "start_command": launch.get("start-string", "/sbin/init"),
            "uses_default_init": "start-string" not in launch,
            "start_timeout": int(launch.get("start-timeout", 30)),
            "start_background": bool(launch.get("start-background", False)),
            "stop_command": launch.get("stop-string"),
            "stop_timeout": int(launch.get("stop-timeout", 30)),
            "notify_timeout": int(launch.get("notify-timeout", 30)),
            "auto_restart": bool(launch.get("auto-restart", False)),
            "max_restarts": int(launch.get("max-restarts", 0)),
            "restart_period": int(launch.get("restart-period", 0)),
            "watchdog": bool(launch.get("watchdog", False)),
            "memory_kib": resource_integer(
                resources, "app-ram", "REFERENCE_LXC_MEMORY_KIB"
            ),
            "cpu_percent": resource_integer(
                resources, "app-cpu", "REFERENCE_LXC_CPU_PERCENT"
            ),
            "cpu_weight": environment_integer("REFERENCE_LXC_CPU_WEIGHT"),
            "cpuset_cpus": os.environ["REFERENCE_LXC_CPUSET_CPUS"],
            "cpuset_mems": os.environ["REFERENCE_LXC_CPUSET_MEMS"],
            "persistent_kib": resource_integer(
                resources,
                "storage-persistent",
                "REFERENCE_LXC_PERSISTENT_KIB",
            ),
            "nonpersistent_kib": resource_integer(
                resources,
                "storage-nonpersistent",
                "REFERENCE_LXC_NONPERSISTENT_KIB",
            ),
            "communication": communication,
            "api_access": manifest.get("api-access", {}),
            "network_bridge": os.environ["LXC_NETWORK_BRIDGE"],
            "network_gateway": network_gateway,
            "network_prefix": network_prefix,
            "network_address": conformance_network_address(
                name, network_gateway, network_prefix
            ),
        }
        values.update(manifest_network_policy(communication))
        if "threads" in resources:
            values["threads"] = int(resources["threads"])
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError(f"invalid GEISA application manifest: {error}") from error

    if not NAME_PATTERN.fullmatch(values["name"]):
        raise ValueError(f"invalid application name: {values['name']}")
    if not NAME_PATTERN.fullmatch(values["version"]):
        raise ValueError(f"invalid application version: {values['version']}")
    if not values["start_command"]:
        raise ValueError("application start-string cannot be empty")
    for field in (
        "start_timeout",
        "stop_timeout",
        "notify_timeout",
        "max_restarts",
        "restart_period",
        "memory_kib",
        "cpu_percent",
        "cpu_weight",
        "persistent_kib",
        "nonpersistent_kib",
        "network_daily_volume_bytes",
    ):
        if values[field] < 0:
            raise ValueError(f"{field} cannot be negative")
    if values["memory_kib"] == 0 or values["cpu_percent"] == 0:
        raise ValueError("memory and CPU percentage constraints must be greater than zero")
    if not 1 <= values["cpu_weight"] <= 10000:
        raise ValueError("cpu_weight must be between 1 and 10000")
    if values["network_access"]:
        if not 1 <= values["network_port"] <= 65535:
            raise ValueError("network_port must be between 1 and 65535")
    for field in ("cpuset_cpus", "cpuset_mems"):
        if not CPUSET_PATTERN.fullmatch(values[field]):
            raise ValueError(f"invalid {field}: {values[field]}")
    return values


def app_directory(name: str) -> Path:
    """Construct the validated on-disk location for an installed application.

    Args:
        name: Application name used as the installation directory name.
    """
    if not NAME_PATTERN.fullmatch(name):
        raise ValueError(f"invalid application name: {name}")
    return LXC_PATH / name


def load_application(name: str) -> dict:
    """Load metadata for an application that is already installed.

    Args:
        name: Installed application name.
    """
    path = app_directory(name) / "manifest.json"
    if not path.is_file():
        raise RuntimeError(f"application is not installed: {name}")
    return read_manifest(path, name)


def find_base_image() -> Path:
    """Locate the configured or first matching base filesystem image."""
    configured = os.environ.get("CONTAINER_BASE_IMAGE")
    if configured:
        path = Path(configured)
        if path.is_file():
            return path
        raise RuntimeError(f"GEISA application base image not found: {path}")
    matches = sorted(glob.glob(str(BASE_IMAGE_DIR / BASE_IMAGE_GLOB)))
    if not matches:
        raise RuntimeError(
            f"no GEISA application base image matching {BASE_IMAGE_GLOB} found under {BASE_IMAGE_DIR}"
        )
    return Path(matches[0])


def paths(metadata: dict) -> dict[str, Path]:
    """Construct all filesystem paths used to provision an application container.

    Args:
        metadata: Validated application metadata constructed from its manifest.
    """
    root = app_directory(metadata["name"])
    return {
        "root": root,
        "base": Path(BASE_LAYER_PATH),
        "application": Path(APPLICATION_LAYER_PATH),
        "configuration": Path(CONFIGURATION_LAYER_PATH),
        "upper": Path(UPPER_PATH),
        "work": Path(WORK_PATH),
        "rootfs": Path(ROOTFS_PATH),
        "persistent": Path(PERSISTENT_IMAGE_PATH),
        "image": Path(APPLICATION_IMAGE_PATH),
    }


def write_launcher(configuration: Path, metadata: dict) -> None:
    """Write the container init script that starts and stops the application process.

    Args:
        configuration: Writable configuration layer for the application container.
        metadata: Validated application metadata constructed from its manifest.
    """
    launcher = configuration / "geisa-conformance-init"
    if metadata["uses_default_init"]:
        launcher.write_text(
            "#!/bin/sh\n"
            "exec /sbin/init\n",
            encoding="utf-8",
        )
        launcher.chmod(0o755)
        return
    stop_command = metadata["stop_command"]
    stop_action = (
        f"    /bin/sh -c {shlex.quote(stop_command)} || true\n" if stop_command else ""
    )
    launcher.write_text(
        "#!/bin/sh\n"
        "cd /\n"
        f"/bin/sh -c {shlex.quote(metadata['start_command'])} &\n"
        "app_pid=$!\n"
        "shutdown() {\n"
        f"{stop_action}"
        "    kill \"$app_pid\" 2>/dev/null || true\n"
        "    exit 0\n"
        "}\n"
        "trap shutdown TERM INT PWR\n"
        "wait \"$app_pid\" || true\n"
        "exec /bin/sh -c 'while :; do sleep 3600; done'\n",
        encoding="utf-8",
    )
    launcher.chmod(0o755)


def write_lxc_config(metadata: dict, root: Path) -> None:
    """Write the LXC configuration that applies the application's runtime limits and mounts.

    Args:
        metadata: Validated application metadata constructed from its manifest.
        root: Application container directory that receives the configuration file.
    """
    memory_bytes = metadata["memory_kib"] * 1024
    rootfs = Path(ROOTFS_PATH)
    log_socket = Path("/dev/log").resolve()
    lines = [
        f"lxc.rootfs.path = {rootfs}",
        f"lxc.uts.name = {metadata['name']}",
        "lxc.init.cmd = /geisa-conformance-init",
        "lxc.autodev = 1",
        "lxc.mount.auto = proc sys",
        "lxc.environment = SHELL=/bin/sh",
        f"lxc.environment = HOME=/{PERSISTENT_MOUNT}",
        "lxc.environment = USER=geisa",
        "lxc.environment = PATH=/usr/local/bin:/usr/bin:/bin",
        f"lxc.mount.entry = {log_socket} dev/log none bind,optional,create=file 0 0",
    ]
    if metadata["network_access"]:
        lines.extend(
            (
                "lxc.net.0.type = veth",
                f"lxc.net.0.link = {metadata['network_bridge']}",
                "lxc.net.0.flags = up",
                "lxc.net.0.name = eth0",
                (
                    "lxc.net.0.ipv4.address = "
                    f"{metadata['network_address']}/{metadata['network_prefix']}"
                ),
                f"lxc.net.0.ipv4.gateway = {metadata['network_gateway']}",
            )
        )
    lines.extend(
        (
            f"lxc.cgroup2.cpuset.mems = {metadata['cpuset_mems']}",
            f"lxc.cgroup2.cpuset.cpus = {metadata['cpuset_cpus']}",
            f"lxc.cgroup2.cpu.weight = {metadata['cpu_weight']}",
            f"lxc.cgroup2.memory.max = {memory_bytes}",
        )
    )
    if metadata["cpu_percent"]:
        quota = metadata["cpu_percent"] * 1000
        lines.append(f"lxc.cgroup2.cpu.max = {quota} 100000")
    (root / "config").write_text("\n".join(lines) + "\n", encoding="utf-8")


def mount_application(metadata: dict) -> None:
    """Mount the layered application filesystem and its writable storage areas.

    Args:
        metadata: Validated application metadata constructed from its manifest.
    """
    item = paths(metadata)
    for key in ("base", "application", "configuration", "upper", "work", "rootfs"):
        item[key].mkdir(parents=True, exist_ok=True)
    if not mounted(item["base"]):
        run("mount", "-t", IMAGE_FSTYPE, "-o", "loop,ro", metadata["base_image"], str(item["base"]))
    if not mounted(item["application"]):
        run("mount", "-t", IMAGE_FSTYPE, "-o", "loop,ro", str(item["image"]), str(item["application"]))
    if not mounted(item["rootfs"]):
        (item["upper"] / NONPERSISTENT_MOUNT).mkdir(parents=True, exist_ok=True)
        (item["upper"] / PERSISTENT_MOUNT).mkdir(parents=True, exist_ok=True)
        lower = f"{item['configuration']}:{item['application']}:{item['base']}"
        options = f"ro,lowerdir={lower},upperdir={item['upper']},workdir={item['work']}"
        run("mount", "-t", "overlay", "overlay", "-o", options, str(item["rootfs"]))
    for mount_point in (item["rootfs"] / NONPERSISTENT_MOUNT, item["rootfs"] / PERSISTENT_MOUNT):
        if not mount_point.is_dir():
            raise RuntimeError(f"base filesystem lacks {mount_point.relative_to(item['rootfs'])}")
    temporary = item["rootfs"] / NONPERSISTENT_MOUNT
    if not mounted(temporary):
        if metadata["nonpersistent_kib"]:
            options = f"size={metadata['nonpersistent_kib']}k,mode=1777"
        else:
            options = "size=4k,mode=0555,ro"
        run("mount", "-t", "tmpfs", "-o", options, "tmpfs", str(temporary))
    persistent = item["rootfs"] / PERSISTENT_MOUNT
    if not mounted(persistent):
        if metadata["persistent_kib"]:
            run("mount", "-o", "loop,rw", str(item["persistent"]), str(persistent))
        else:
            run(
                "mount",
                "-t",
                "tmpfs",
                "-o",
                "size=4k,mode=0555,ro",
                "tmpfs",
                str(persistent),
            )


def unmount_application(metadata: dict) -> None:
    """Unmount every filesystem layer associated with an application container.

    Args:
        metadata: Validated application metadata constructed from its manifest.
    """
    item = paths(metadata)
    order = (
        item["rootfs"] / PERSISTENT_MOUNT,
        item["rootfs"] / NONPERSISTENT_MOUNT,
        item["rootfs"],
        item["application"],
        item["base"],
    )
    for path in order:
        if mounted(path):
            run("umount", str(path))


def container_state(name: str) -> str:
    """Query the current LXC lifecycle state for an application container.

    Args:
        name: Installed application name.
    """
    return run(
        "lxc-info", "-P", str(LXC_PATH), "-n", name, "-sH", check=False, capture=True
    ).stdout.strip()


def container_init_pid(name: str) -> int:
    """Find the running container init process needed to enter its namespaces.

    Args:
        name: Installed application name.
    """
    result = run(
        "lxc-info", "-P", str(LXC_PATH), "-n", name, "-pH", capture=True
    )
    pid = int(result.stdout.strip())
    if pid <= 0:
        raise RuntimeError(f"container has no running init process: {name}")
    return pid


def run_in_network_namespace(
    name: str, *command: str, input_text: str | None = None, check: bool = True
) -> subprocess.CompletedProcess[str]:
    """Run a command inside an application's network namespace.

    Args:
        name: Installed application name.
        command: Command and arguments to run inside the network namespace.
        input_text: Optional standard input supplied to the command.
        check: Whether a nonzero exit status raises an exception.
    """
    return subprocess.run(
        ("nsenter", "--target", str(container_init_pid(name)), "--net", *command),
        check=check,
        text=True,
        input=input_text,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def network_policy_rules(metadata: dict) -> str:
    """Build the nftables rules that enforce an application's permitted network traffic.

    Args:
        metadata: Validated application metadata constructed from its manifest.
    """
    gateway = metadata["network_gateway"]
    port = metadata["network_port"]
    volume = metadata["network_daily_volume_bytes"]
    transport = metadata["network_transport"]
    protocols = ("tcp", "udp") if transport is None else (transport,)
    output_lines = []
    input_lines = []
    for protocol in protocols:
        output_lines.append(
            f"        ip daddr {gateway} {protocol} dport {port} "
            f"quota name \"{NETWORK_POLICY_QUOTA}\" drop"
        )
        output_lines.append(
            f"        ip daddr {gateway} {protocol} dport {port} accept"
        )
        input_lines.append(
            f"        ip saddr {gateway} {protocol} sport {port} "
            f"quota name \"{NETWORK_POLICY_QUOTA}\" drop"
        )
        input_lines.append(
            f"        ip saddr {gateway} {protocol} sport {port} "
            f"ct state established accept"
        )
    output_rules = "\n".join(output_lines)
    input_rules = "\n".join(input_lines)
    return f"""table inet {NETWORK_POLICY_TABLE} {{
    quota {NETWORK_POLICY_QUOTA} {{ over {volume} bytes }}
    chain output {{
        type filter hook output priority 0; policy drop;
{output_rules}
    }}
    chain input {{
        type filter hook input priority 0; policy drop;
{input_rules}
    }}
}}
"""


def network_quota_supported(name: str) -> bool:
    """Probe whether the container kernel supports nftables byte quotas.

    Args:
        name: Installed application name.
    """
    probe_table = f"{NETWORK_POLICY_TABLE}_probe"
    probe = (
        f"add table inet {probe_table}\n"
        f"add quota inet {probe_table} {NETWORK_POLICY_QUOTA} {{ over 1 bytes }}\n"
    )
    result = run_in_network_namespace(
        name, "nft", "-f", "-", input_text=probe, check=False
    )
    run_in_network_namespace(
        name, "nft", "delete", "table", "inet", probe_table, check=False
    )
    return result.returncode == 0


def install_network_policy(metadata: dict) -> None:
    """Replace the application's active nftables policy with its manifest-derived policy.

    Args:
        metadata: Validated application metadata constructed from its manifest.
    """
    name = metadata["name"]
    if not network_quota_supported(name):
        raise RuntimeError(
            "the kernel lacks nftables quota support (CONFIG_NFT_QUOTA)"
        )
    existing = run_in_network_namespace(
        name,
        "nft",
        "list",
        "table",
        "inet",
        NETWORK_POLICY_TABLE,
        check=False,
    )
    if existing.returncode == 0:
        run_in_network_namespace(
            name, "nft", "delete", "table", "inet", NETWORK_POLICY_TABLE
        )
    run_in_network_namespace(
        name, "nft", "-f", "-", input_text=network_policy_rules(metadata)
    )


def deactivate(name: str) -> None:
    """Stop an application, if running, and detach its mounted filesystems.

    Args:
        name: Installed application name.
    """
    metadata = load_application(name)
    state = container_state(name)
    if state == "RUNNING":
        timeout = str(metadata["stop_timeout"])
        stopped = run(
            "lxc-stop", "-P", str(LXC_PATH), "-n", name, "-t", timeout, check=False
        )
        if stopped.returncode:
            run("lxc-stop", "-P", str(LXC_PATH), "-n", name, "-k")
    unmount_application(metadata)


def uninstall(name: str) -> None:
    """Remove an installed application and all of its provisioned storage.

    Args:
        name: Installed application name.
    """
    root = app_directory(name)
    if not (root / "manifest.json").is_file():
        shutil.rmtree(root, ignore_errors=True)
        return
    metadata = load_application(name)
    deactivate(name)
    unmount_application(metadata)
    shutil.rmtree(root)


def install(image: Path, manifest_path: Path, application_name: str | None = None) -> None:
    """Provision an application image, manifest, runtime configuration, and storage.

    Args:
        image: Application filesystem image to install.
        manifest_path: Manifest JSON file that defines the application.
        application_name: Optional installed name that overrides the manifest name.
    """
    if not image.is_file() or not manifest_path.is_file():
        raise ValueError("application image or manifest is missing")
    metadata = read_manifest(manifest_path, application_name)
    metadata["base_image"] = str(find_base_image())
    root = app_directory(metadata["name"])
    if root.exists():
        uninstall(metadata["name"])
    item = paths(metadata)
    item["image"].parent.mkdir(parents=True, exist_ok=True)
    (item["configuration"] / "etc/geisa").mkdir(parents=True)
    shutil.copy2(image, item["image"])
    shutil.copy2(manifest_path, root / "manifest.json")
    (item["configuration"] / "etc/geisa/mqtt.conf").write_text(
        f"HOST=127.0.0.1\nPORT=1883\nUSERID={metadata['name']}\n"
        "PASSWORD=geisa-conformance\n",
        encoding="utf-8",
    )
    write_launcher(item["configuration"], metadata)
    persistent = item["persistent"]
    persistent.touch()
    os.truncate(persistent, metadata["persistent_kib"] * 1024)
    if metadata["persistent_kib"]:
        run(f"mkfs.{PERSISTENT_FSTYPE}", "-q", "-F", str(persistent))
    write_lxc_config(metadata, root)
    try:
        mount_application(metadata)
    except (OSError, RuntimeError, subprocess.CalledProcessError):
        try:
            unmount_application(metadata)
        finally:
            shutil.rmtree(root, ignore_errors=True)
        raise


def activate(name: str) -> None:
    """Mount and start an installed application, then enforce its network policy.

    Args:
        name: Installed application name.
    """
    metadata = load_application(name)
    metadata["base_image"] = str(find_base_image())
    mount_application(metadata)
    state = container_state(name)
    if state != "RUNNING":
        run("lxc-start", "-P", str(LXC_PATH), "-n", name, "-d")
        run(
            "lxc-wait",
            "-P",
            str(LXC_PATH),
            "-n",
            name,
            "-s",
            "RUNNING",
            "-t",
            str(metadata["start_timeout"]),
        )
    if metadata["network_access"]:
        install_network_policy(metadata)


def parse_arguments() -> argparse.Namespace:
    """Define and parse the command-line interface for package operations."""
    parser = argparse.ArgumentParser(description="Provision GEISA applications with LXC")
    subparsers = parser.add_subparsers(dest="operation", required=True)
    install_parser = subparsers.add_parser("install")
    install_parser.add_argument("--name")
    install_parser.add_argument("image", type=Path)
    install_parser.add_argument("manifest", type=Path)
    for operation in ("activate", "deactivate", "uninstall"):
        command = subparsers.add_parser(operation)
        command.add_argument("name")
    return parser.parse_args()


def main() -> int:
    """Dispatch the requested package operation and report operational failures."""
    arguments = parse_arguments()
    try:
        if arguments.operation == "install":
            install(arguments.image, arguments.manifest, arguments.name)
        elif arguments.operation == "activate":
            activate(arguments.name)
        elif arguments.operation == "deactivate":
            deactivate(arguments.name)
        elif arguments.operation == "uninstall":
            uninstall(arguments.name)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"manage_package: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
