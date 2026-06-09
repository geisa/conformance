# Copyright (C) 2025 Southern California Edison

include nanopb/extra/nanopb.mk

BUILDIR ?= build
PROTOS := $(wildcard schemas/*.proto)
PB_C := $(PROTOS:schemas/%.proto=$(BUILDIR)/schemas/%.pb.c)

objects = gapi_connection gapi_discovery gapi_instantaneous
all: schemas $(objects)

DESTDIR ?= /usr/local/bin
CFLAGS := -O2 -Wall -std=c11 -Wextra -pedantic -Werror -I$(BUILDIR) -I/usr/include/nanopb -DPB_ENABLE_MALLOC
LDLIBS := -lmosquitto

.PHONY: build_dir schemas

build_dir:
	@mkdir -p $(BUILDIR)

$(BUILDIR)/schemas/%.pb.c: schemas/%.proto | build_dir
	@mkdir -p $(BUILDIR)/schemas
	protoc --nanopb_out=$(BUILDIR)/schemas -I schemas --nanopb_opt='-Inanopb_options' $<

schemas: $(PB_C)

$(BUILDIR)/schemas/%.pb.o: $(BUILDIR)/schemas/%.pb.c | build_dir
	$(CC) $(CFLAGS) -c $< -o $@

gapi_mosquitto.o gapi_discovery_common.o $(PB_C:.c=.o) $(NANOPB_CORE:.c=.o): | schemas

$(objects): %: %.c gapi_mosquitto.o $(PB_C:.c=.o) $(NANOPB_CORE:.c=.o)

install: $(objects)
	install -D -m 755 $(objects) $(DESTDIR)
