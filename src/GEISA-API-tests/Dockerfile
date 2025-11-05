# Copyright (C) 2025 Southern California Edison
FROM alpine:3.22

RUN apk update && apk add --no-cache \
      gcc \
      make \
      mosquitto-dev \
      musl-dev \
      && rm -rf /var/lib/apt/lists/*

WORKDIR /geisa-api-conformance-tests
COPY src/* /geisa-api-conformance-tests

RUN make -j"$(nproc)"

FROM alpine:3.22

RUN apk update && apk add --no-cache \
    mosquitto-libs \
    && rm -rf /var/lib/apt/lists/*

COPY --from=0 /geisa-api-conformance-tests/gapi_cmdline /usr/local/bin/gapi_cmdline
CMD ["/usr/local/bin/gapi_cmdline", "sub", "localhost", "test/topic"]
