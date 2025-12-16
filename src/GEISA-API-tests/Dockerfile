# Copyright (C) 2025 Southern California Edison
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND noninteractive

RUN apt update && apt install -y --no-install-recommends \
      gcc \
      make \
      libmosquitto-dev \
      libc6-dev \
      && rm -rf /var/lib/apt/lists/* \
      && rm -rf /var/cache/apt/archives

WORKDIR /geisa-api-conformance-tests
COPY GEISA-API-tests/src/* /geisa-api-conformance-tests

RUN make -j"$(nproc)"
RUN make install
