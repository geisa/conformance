# Copyright (C) 2025 Southern California Edison.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN set -x \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        black \
        bsdmainutils \
        clang-format \
        clang-tidy \
        curl \
        default-jre-headless \
        fuse-overlayfs \
        iperf3 \
        iputils-ping \
        lrzsz \
        libmosquitto-dev \
        libprotobuf-c-dev \
        openssh-server \
        podman \
        protobuf-compiler \
        protobuf-c-compiler \
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

# Remove default dialout group allowing creating it with the host GID
RUN groupdel dialout
