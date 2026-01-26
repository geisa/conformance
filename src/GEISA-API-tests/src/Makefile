# Copyright (C) 2025 Southern California Edison

objects = gapi_cmdline gapi_connection
all: $(objects)

DESTDIR ?= /usr/local/bin
CFLAGS := -O2 -Wall -std=c11 -Wextra -pedantic -Werror
LDLIBS := -lmosquitto

$(objects): %: %.c gapi_mosquitto.o

install: $(objects)
	install -D -m 755 $(objects) $(DESTDIR)
