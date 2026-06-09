# Copyright (C) 2025 Southern California Edison
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc \
      make \
      nanopb \
      libmosquitto-dev \
      libc6-dev \
      libnanopb-dev \
      protobuf-compiler

WORKDIR /geisa-api-conformance-tests
COPY GEISA-API-tests/src/ /geisa-api-conformance-tests

RUN make -j"$(nproc)"
RUN make install

# Install runtime dependencies of the application
RUN mkdir -p /usr/local/etc/ld.so.conf.d/ \
      && echo "/usr/lib/aarch64-linux-gnu" > /usr/local/etc/ld.so.conf.d/multiarch.conf

RUN apt-get download coreutils \
      && dpkg -x coreutils_*.deb /usr/local \
      && apt-get download libselinux1 \
      && dpkg -x libselinux1_*.deb /usr/local \
      && apt-get download libpcre2-8-0 \
      && dpkg -x libpcre2-8-0_*.deb /usr/local \
      && rm -f *.deb \
      && rm -rf /var/lib/apt/lists/* \
      && rm -rf /var/cache/apt/archives
