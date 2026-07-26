.DEFAULT_GOAL := help
SHELL := /bin/bash

# Dependency prefixes are discovered, not hardcoded, so the same Makefile
# works on a Homebrew mac and a Linux box with pkg-config.
BREW        := $(shell command -v brew 2>/dev/null)
ifdef BREW
SDL3_PREFIX    ?= $(shell brew --prefix sdl3)
BOX2D_PREFIX   ?= $(shell brew --prefix box2d)
SHADERC_PREFIX ?= $(shell brew --prefix shaderc)
SPVC_PREFIX    ?= $(shell brew --prefix spirv-cross)
LUAJIT_PREFIX  ?= $(shell brew --prefix luajit)
else
SDL3_PREFIX    ?= /usr/local
BOX2D_PREFIX   ?= /usr/local
SHADERC_PREFIX ?= /usr/local
SPVC_PREFIX    ?= /usr/local
LUAJIT_PREFIX  ?= /usr/local
endif

BUILD   := build
BIN     := bin
GEN     := $(BUILD)/tecs2d/ffi
HOST    := $(BIN)/tecs2d

LUAJIT_INC := $(LUAJIT_PREFIX)/include/luajit-2.1
CFLAGS  := -std=c99 -O2 -Wall -Wextra -I$(LUAJIT_INC)
LDFLAGS := -L$(LUAJIT_PREFIX)/lib -lluajit-5.1

UNAME := $(shell uname -s)
ifeq ($(UNAME),Darwin)
ARCH := $(shell uname -m)
ifeq ($(ARCH),x86_64)
# LuaJIT on x64 macOS needs its allocations below 2GB.
LDFLAGS += -pagezero_size 10000 -image_base 100000000
endif
endif

SOURCE_TL := $(shell find src -name '*.tl' 2>/dev/null)
CDEFS     := $(GEN)/sdl3cdef.lua $(GEN)/box2dcdef.lua $(GEN)/shaderccdef.lua $(GEN)/spvccdef.lua
CONSTS    := $(GEN)/sdl3const.lua $(GEN)/box2dconst.lua $(GEN)/shadercconst.lua $(GEN)/spvcconst.lua
SPVC_LIB  := $(BUILD)/lib/libspirvcrossc.dylib

export TECS2D_SDL3_PATH    := $(SDL3_PREFIX)/lib/libSDL3.dylib
export TECS2D_BOX2D_PATH   := $(BOX2D_PREFIX)/lib/libbox2d.dylib
export TECS2D_SHADERC_PATH := $(SHADERC_PREFIX)/lib/libshaderc_shared.dylib
export TECS2D_SPVC_PATH     := $(CURDIR)/$(SPVC_LIB)

.PHONY: help all cdef host build run clean rebuild check abi-check deps test

help: ## List targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk -F':.*?## ' '{printf "  %-14s %s\n", $$1, $$2}'

all: cdef spvc build host ## Generate cdefs, link deps, compile Teal, build the host

deps: ## Install native dependencies (macOS/Homebrew)
	brew install sdl3 box2d shaderc spirv-cross luajit

cdef: $(GEN)/.sdl3.stamp $(GEN)/.box2d.stamp $(GEN)/.shaderc.stamp $(GEN)/.spvc.stamp ## Regenerate FFI cdefs from installed headers

# Each generator run emits both a cdef and a constants table. macOS ships GNU
# Make 3.81, which has no grouped-target syntax, so a stamp file stands in for
# the pair.
$(CDEFS) $(CONSTS): %: ;

$(GEN)/.sdl3.stamp: $(SDL3_PREFIX)/include/SDL3/SDL.h scripts/gencdef.py
	@python3 scripts/gencdef.py \
	  --header SDL3/SDL.h --include $(SDL3_PREFIX)/include \
	  --keep /SDL3/ --define-prefix SDL_ \
	  --defines-out $(GEN)/sdl3const.lua --out $(GEN)/sdl3cdef.lua
	@touch $@

$(GEN)/.box2d.stamp: $(BOX2D_PREFIX)/include/box2d/box2d.h scripts/gencdef.py
	@python3 scripts/gencdef.py \
	  --header box2d/box2d.h --include $(BOX2D_PREFIX)/include \
	  --keep /box2d/ --define-prefix B2_ --define-prefix b2_ \
	  --defines-out $(GEN)/box2dconst.lua --out $(GEN)/box2dcdef.lua
	@touch $@

$(GEN)/.shaderc.stamp: $(SHADERC_PREFIX)/include/shaderc/shaderc.h scripts/gencdef.py
	@python3 scripts/gencdef.py \
	  --header shaderc/shaderc.h --include $(SHADERC_PREFIX)/include \
	  --keep /shaderc/ --define-prefix shaderc_ \
	  --defines-out $(GEN)/shadercconst.lua --out $(GEN)/shaderccdef.lua
	@touch $@

$(GEN)/.spvc.stamp: $(SPVC_PREFIX)/include/spirv_cross/spirv_cross_c.h scripts/gencdef.py
	@python3 scripts/gencdef.py \
	  --header spirv_cross/spirv_cross_c.h --include $(SPVC_PREFIX)/include \
	  --keep /spirv_cross/ --define-prefix SPVC_ \
	  --defines-out $(GEN)/spvcconst.lua --out $(GEN)/spvccdef.lua
	@touch $@

# Homebrew ships SPIRV-Cross as static archives only, and the FFI needs a
# shared object. Linking one here keeps the dependency declarative rather than
# asking every developer to build SPIRV-Cross by hand.
spvc: $(SPVC_LIB) ## Link SPIRV-Cross into a shared library

$(SPVC_LIB): $(SPVC_PREFIX)/lib/libspirv-cross-c.a
	@mkdir -p $(BUILD)/lib
	@$(CC) -dynamiclib -o $@ -Wl,-all_load \
	  $(SPVC_PREFIX)/lib/libspirv-cross-c.a $(SPVC_PREFIX)/lib/libspirv-cross-cpp.a \
	  $(SPVC_PREFIX)/lib/libspirv-cross-msl.a $(SPVC_PREFIX)/lib/libspirv-cross-glsl.a \
	  $(SPVC_PREFIX)/lib/libspirv-cross-hlsl.a $(SPVC_PREFIX)/lib/libspirv-cross-reflect.a \
	  $(SPVC_PREFIX)/lib/libspirv-cross-util.a $(SPVC_PREFIX)/lib/libspirv-cross-core.a -lc++

host: $(HOST) ## Build the C host

$(HOST): host/main.c
	@mkdir -p $(BIN)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

build: cdef $(BUILD)/main.lua ## Compile src/*.tl into build/
	@tl -q gen --root src --output-dir $(BUILD) $(SOURCE_TL)

$(BUILD)/main.lua: main.tl
	@mkdir -p $(BUILD)
	@tl gen main.tl -o $@

check: cdef ## Type-check Teal sources
	@tl check $(SOURCE_TL) main.tl

abi-check: cdef ## Verify generated cdefs match the C ABI
	@python3 scripts/abicheck.py

test: build spvc ## Run the spec suite
	@busted --lua=luajit spec/

run: all ## Run the demo app
	@$(HOST) --entry $(BUILD)/main.lua

clean: ## Remove build artifacts
	@rm -rf $(BUILD) $(BIN)

rebuild: clean all ## Clean and rebuild
