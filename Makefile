# SPDX-License-Identifier: GPL-2.0-only
# The magica command-line tool, built with the vendored libusb (no Homebrew needed)
CC      ?= cc
CFLAGS  ?= -O2 -g
CFLAGS  += -std=gnu11 -Wall -Isrc/include -Isrc/core -Ivendor/libusb/include
LDLIBS  += -framework IOKit -framework CoreFoundation -framework Security

SRCS := $(wildcard src/cli/*.c) $(wildcard src/core/*.c)
LIBUSB_SRCS := $(wildcard vendor/libusb/src/*.c) $(wildcard vendor/libusb/src/os/*.c)
OBJS := $(SRCS:src/%.c=build/%.o)
LIBUSB_OBJS := $(LIBUSB_SRCS:vendor/libusb/src/%.c=build/libusb/%.o)

magica: $(OBJS) $(LIBUSB_OBJS)
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)

build/%.o: src/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -MMD -MP -c -o $@ $<

# libusb's own warnings are upstream's business
build/libusb/%.o: vendor/libusb/src/%.c
	@mkdir -p $(dir $@)
	$(CC) -O2 -g -std=gnu11 -w -Ivendor/libusb/include -Ivendor/libusb/src -Ivendor/libusb/src/os -MMD -MP -c -o $@ $<

compile_commands.json: Makefile
	@printf '[\n' > $@; sep=''; for s in $(SRCS); do \
	  printf '%s{"directory":"%s","file":"%s","command":"%s %s -c %s"}\n' \
	    "$$sep" "$(CURDIR)" "$$s" "$(CC)" "$(CFLAGS)" "$$s" >> $@; sep=','; done; printf ']\n' >> $@

clean:
	rm -rf build magica

.PHONY: clean
-include $(OBJS:.o=.d) $(LIBUSB_OBJS:.o=.d)
