# Copyright (C) 2025 Southern California Edison.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND noninteractive

RUN set -x \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        iputils-ping \
        openssh-server \
        python3 \
        python3-junitparser \
        ruby-asciidoctor-pdf \
        shellcheck \
        sshpass \
    && rm -rf /var/lib/apt/lists/
