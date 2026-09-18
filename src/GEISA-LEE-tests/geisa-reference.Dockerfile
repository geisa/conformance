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
RUN make setup-dev && \
    make && \
    make test

FROM scratch
COPY --from=builder /src/build/geisa-app /geisa-app
