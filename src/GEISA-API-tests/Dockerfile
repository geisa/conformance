# Copyright (C) 2025 Southern California Edison
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc \
      make \
      libmosquitto-dev \
      libc6-dev \
      libnanopb-dev \
      protobuf-compiler \
      python3-pip

RUN pip3 install --no-cache-dir --break-system-packages \
      nanopb

WORKDIR /geisa-api-conformance-tests
COPY GEISA-API-tests/src/ /geisa-api-conformance-tests

RUN make -j"$(nproc)"
RUN make install

# Install runtime dependencies of the application
RUN apt-get download libc6 \
      && dpkg-deb -x libc6_*.deb /usr/local/ \
      && rm -f *.deb \
      && rm -rf /var/lib/apt/lists/* \
      && rm -rf /var/cache/apt/archives
