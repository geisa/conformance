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

COPY --exclude=*.h --exclude=*.c --exclude=Makefile --from=0 \
    /geisa-api-conformance-tests/ /usr/local/bin/

CMD ["/usr/local/bin/gapi_cmdline", "sub", "localhost", "test/topic"]
