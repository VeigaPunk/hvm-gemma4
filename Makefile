# Override: make HVM_ROOT=/path/to/hvm-2.0.22
HVM_ROOT ?= $(shell find $(or $(CARGO_HOME),$(HOME)/.cargo)/registry/src -type d -name 'hvm-2.0.22' 2>/dev/null | head -1)
ifeq ($(strip $(HVM_ROOT)),)
$(error HVM_ROOT not found — set HVM_ROOT to the hvm-2.0.22 crate source dir)
endif
HVM_BIN := $(HVM_ROOT)/target/debug/hvm
CFLAGS := -O2 -fPIC -Wall -Wextra -I$(HVM_ROOT)/src $(shell pkg-config --cflags libcurl json-c)
LDLIBS := $(shell pkg-config --libs libcurl json-c)

.PHONY: all check run clean

all: build/libhvm_gemma.so

build/libhvm_gemma.so: hvm_gemma.c
	mkdir -p build
	$(CC) $(CFLAGS) -shared -Wl,--unresolved-symbols=ignore-all -o $@ $< $(LDLIBS)

check:
	bend check main.bend

run: all check
	./run.sh "Explain why mixture-of-experts models activate only some experts."

clean:
	rm -f build/libhvm_gemma.so
	rmdir build 2>/dev/null || true
