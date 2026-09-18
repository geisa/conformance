#!/bin/bash

# Copyright (C) 2026 Southern California Edison

set -euo pipefail

if [[ $# -ne 3 ]]; then
	echo "Usage: $0 <application-directory> <target-architecture> <output-directory>" >&2
	exit 2
fi

APPLICATION_DIR="$(readlink -f "$1")"
TARGET_ARCH="$2"
OUTPUT_DIR="$(readlink -m "$3")"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "${SCRIPT_PATH}")"

if [[ -n "${CONTAINER_CLI:-}" ]]; then
	command -v "${CONTAINER_CLI}" >/dev/null 2>&1 || {
		echo "Container runtime not found: ${CONTAINER_CLI}" >&2
		exit 2
	}
elif command -v docker >/dev/null 2>&1; then
	CONTAINER_CLI=docker
elif command -v podman >/dev/null 2>&1; then
	CONTAINER_CLI=podman
else
	echo "No supported container runtime found (docker or podman)" >&2
	exit 2
fi

case "${TARGET_ARCH}" in
	aarch64|arm64) PLATFORM_ARCH=arm64 ;;
	x86_64|amd64) PLATFORM_ARCH=amd64 ;;
	armv7l|armhf) PLATFORM_ARCH=arm/v7 ;;
	*)
		echo "Unsupported target architecture: ${TARGET_ARCH}" >&2
		exit 2
		;;
esac

[[ -d "${APPLICATION_DIR}" ]] || {
	echo "Application directory not found: ${APPLICATION_DIR}" >&2
	exit 2
}

MANIFEST="$(find "${APPLICATION_DIR}" -maxdepth 1 -type f -name '*-manifest.json' -print -quit)"
[[ -n "${MANIFEST}" ]] || {
	echo "No *-manifest.json found in ${APPLICATION_DIR}" >&2
	exit 2
}
MANIFEST_METADATA="$(
	python3 - "${MANIFEST}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
	manifest = json.load(stream)["geisa-application-manifest"]["manifest"]
print(manifest["name"], manifest["app-version"], sep="\t")
PY
)" || {
	echo "Failed to read application manifest: ${MANIFEST}" >&2
	exit 2
}
IFS=$'\t' read -r APP_NAME APP_VERSION <<< "${MANIFEST_METADATA}"

[[ "${APP_NAME}" =~ ^[A-Za-z0-9_.-]+$ ]] || {
	echo "Invalid application name in manifest: ${APP_NAME}" >&2
	exit 2
}
[[ "${APP_VERSION}" =~ ^[A-Za-z0-9_.-]+$ ]] || {
	echo "Invalid application version in manifest: ${APP_VERSION}" >&2
	exit 2
}

APP_OUTPUT_DIR="${OUTPUT_DIR}/${APP_NAME}"
STAGE_DIR="${APP_OUTPUT_DIR}/rootfs"
IMAGE="${APP_OUTPUT_DIR}/${APP_NAME}-${APP_VERSION}.squashfs"
OUTPUT_MANIFEST="${APP_OUTPUT_DIR}/manifest.json"

rm -rf "${APP_OUTPUT_DIR}"
mkdir -p "${STAGE_DIR}"

"${CONTAINER_CLI}" build \
	--platform "linux/${PLATFORM_ARCH}" \
	--file "${SCRIPT_DIR}/../geisa-reference.Dockerfile" \
	--output "type=local,dest=${STAGE_DIR}" \
	"${APPLICATION_DIR}" >&2

chmod 0755 "${STAGE_DIR}/geisa-app"
cp "${MANIFEST}" "${OUTPUT_MANIFEST}"
mksquashfs "${STAGE_DIR}" "${IMAGE}" -all-root -noappend -quiet >&2
rm -rf "${STAGE_DIR}"

printf '%s\t%s\t%s\n' "${APP_NAME}" "${IMAGE}" "${OUTPUT_MANIFEST}"
