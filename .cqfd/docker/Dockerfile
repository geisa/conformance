# Copyright (C) 2025 Southern California Edison.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND noninteractive

RUN set -x \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        shellcheck \
    && rm -rf /var/lib/apt/lists/
