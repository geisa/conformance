# Copyright (C) 2025 Southern California Edison

objects = gapi_cmdline
all: $(objects)

CFLAGS := -O2 -Wall -std=c11 -Wextra -pedantic
LDLIBS := -lmosquitto

$(objects): %: %.c gapi_mosquitto.o
