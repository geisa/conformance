# Copyright (C) 2026 Southern California Edison

FROM debian:bookworm AS builder

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential \
    git \
    libmosquitto-dev \
    pkg-config \
    protobuf-compiler \
    python3 \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .
# A reference application builds build/<APP_BINARY> or build/<SOURCE_NAME>,
# where SOURCE_NAME is its folder name. It is shipped as /<APP_BINARY>, next to
# /toolchain, which gives the toolchain id and version for its manifest.
ARG APP_BINARY=geisa-app
ARG SOURCE_NAME=geisa-app
# geisa-test only: its probe target is capped by the #define MAX_PROBE_TARGET_BYTES
# (64 MiB) that -D cannot override, so the cap is rewritten in place before the build.
# The probe smoke test hardcodes the default cap, so make test is skipped in that case.
ARG PROBE_TARGET_BYTES=
RUN if [ -n "${PROBE_TARGET_BYTES}" ]; then \
        sed -i "s/^#define MAX_PROBE_TARGET_BYTES .*/#define MAX_PROBE_TARGET_BYTES ${PROBE_TARGET_BYTES}/" src/geisa-test.c && \
        grep -q "^#define MAX_PROBE_TARGET_BYTES ${PROBE_TARGET_BYTES}$" src/geisa-test.c; \
    fi && \
    make setup-dev && \
    make && \
    if [ -z "${PROBE_TARGET_BYTES}" ]; then make test; fi && \
    if [ ! -f "build/${APP_BINARY}" ]; then cp "build/${SOURCE_NAME}" "build/${APP_BINARY}"; fi && \
    printf '%s\t%s\n' "$(cc -dumpmachine)" "$(cc -dumpfullversion)" > build/toolchain

FROM scratch
ARG APP_BINARY=geisa-app
COPY --from=builder /src/build/${APP_BINARY} /${APP_BINARY}
COPY --from=builder /src/build/toolchain /toolchain
