# Copyright (C) 2025 Southern California Edison
FROM alpine:3.22

RUN apk update && apk add --no-cache \
      gcc \
      mosquitto-dev \
      musl-dev \
      && rm -rf /var/lib/apt/lists/*

WORKDIR /geisa-api-conformance-tests
COPY src/* /geisa-api-conformance-tests

RUN gcc -o /usr/local/bin/gapi_conformance_tests gapi_mosquitto.c -lmosquitto

FROM alpine:3.22

RUN apk update && apk add --no-cache \
    mosquitto-libs \
    && rm -rf /var/lib/apt/lists/*

COPY --from=0 /usr/local/bin/gapi_conformance_tests /usr/local/bin/gapi_conformance_tests
CMD ["/usr/local/bin/gapi_conformance_tests", "sub", "localhost", "test/topic"]
