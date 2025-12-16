# Copyright (C) 2025 Southern California Edison.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN set -x \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        black \
        clang-format \
        clang-tidy \
        fuse-overlayfs \
        iperf3 \
        iputils-ping \
        lrzsz \
        libmosquitto-dev \
        openssh-server \
        podman \
        pylint \
        python3 \
        python3-pip \
        python3-junitparser \
        python3-serial \
        python3-pexpect \
        ruby-asciidoctor-pdf \
        shellcheck \
        squashfs-tools \
        sshpass \
        uidmap \
    && rm -rf /var/lib/apt/lists/

# Remove default dialout group alowing creating it with the host GID
RUN groupdel dialout
