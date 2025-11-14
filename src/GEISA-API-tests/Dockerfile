# Copyright (C) 2025 Southern California Edison
FROM alpine:3.22

RUN apk update && apk add --no-cache \
      gcc \
      make \
      mosquitto-dev \
      musl-dev \
      && rm -rf /var/lib/apt/lists/*

WORKDIR /geisa-api-conformance-tests
COPY GEISA-API-tests/src/* /geisa-api-conformance-tests

RUN make -j"$(nproc)"
RUN make install

FROM alpine:3.22

RUN apk update && apk add --no-cache \
    mosquitto-libs \
    && rm -rf /var/lib/apt/lists/*

COPY --from=0 /usr/local/bin/ /usr/local/bin/

COPY GEISA-API-tests/cukinia.conf /etc/GEISA-API-tests/cukinia.conf

COPY GEISA-API-tests/tests.d /etc/GEISA-API-tests/tests.d

COPY GEISA-API-tests/tests_configuration.conf /etc/GEISA-API-tests/tests_configuration.conf

COPY cukinia/cukinia /etc/cukinia/cukinia

CMD ["/etc/cukinia/cukinia", "-f", "junitxml", "-o", "/etc/GEISA-API-tests/geisa-api-conformance-report.xml", "/etc/GEISA-API-tests/cukinia.conf"]
