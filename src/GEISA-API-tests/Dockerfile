# Copyright (C) 2025 Southern California Edison
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc \
      make \
      libmosquitto-dev \
      libc6-dev \
      libprotobuf-c-dev \
      pkg-config \
      protobuf-compiler \
      protobuf-c-compiler

WORKDIR /geisa-api-conformance-tests
COPY GEISA-API-tests/src/ /geisa-api-conformance-tests

RUN make -j"$(nproc)"
RUN make install

# Install runtime dependencies of the application
RUN apt-get download libc6 \
      && dpkg-deb -x libc6_*.deb /usr/local/ \
      && apt-get download libprotobuf-c1 \
      && dpkg-deb -x libprotobuf-c1_*.deb /usr/local/ \
      && rm -f *.deb \
      && rm -rf /var/lib/apt/lists/* \
      && rm -rf /var/cache/apt/archives
