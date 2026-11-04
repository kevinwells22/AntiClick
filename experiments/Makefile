# Alternative implementations, built only to compare their cost with the C
# agent (see ../README.md and ./bench.sh).
SWIFTC ?= swiftc
SWIFTFLAGS ?= -O -swift-version 5

.PHONY: all clean
all: build/avengine build/menubar build/silence-60s.aiff

build/avengine: avengine.swift
	@mkdir -p build
	$(SWIFTC) $(SWIFTFLAGS) -o $@ $<

build/menubar: menubar.swift
	@mkdir -p build
	$(SWIFTC) $(SWIFTFLAGS) -o $@ $<

# 60 s of digital silence for the "afplay in a loop" approach.
build/silence-60s.aiff:
	@mkdir -p build
	say -o $@ "[[slnc 60000]]"

clean:
	rm -rf build
