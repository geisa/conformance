# Copyright (C) 2025 Southern California Edison

BUILDIR ?= build
PROTOS := $(wildcard schemas/*.proto)
PB_C := $(PROTOS:schemas/%.proto=$(BUILDIR)/schemas/%.pb-c.c)

objects = gapi_cmdline gapi_connection
all: $(objects)

DESTDIR ?= /usr/local/bin
CFLAGS := -O2 -Wall -std=c11 -Wextra -pedantic -Werror -I$(BUILDIR) $(shell pkg-config --cflags 'libprotobuf-c >= 1.0.0')
LDLIBS := -lmosquitto $(shell pkg-config --libs 'libprotobuf-c >= 1.0.0')

.PHONY: build_dir

build_dir:
	@mkdir -p $(BUILDIR)

$(BUILDIR)/schemas/%.pb-c.c: schemas/%.proto | build_dir
	protoc --c_out=$(BUILDIR) $<

$(BUILDIR)/schemas/%.pb-c.o: $(BUILDIR)/schemas/%.pb-c.c | build_dir
	$(CC) $(CFLAGS) -c $< -o $@

$(objects): %: %.c gapi_mosquitto.o $(PB_C:.c=.o)

install: $(objects)
	install -D -m 755 $(objects) $(DESTDIR)
