.DEFAULT_GOAL := help
SHELL := /bin/bash

# A wrapper over CMake, which is the canonical build. Everything here forwards;
# nothing here knows how the engine is assembled, so there is one description
# of that rather than two to keep in step.

PRESET ?= macos-arm64-dev
OUT    := out/$(PRESET)
LUA    := $(OUT)/lua
BIN    := $(OUT)/bin/tecs
TL     := $(CURDIR)/vendor/bin/tl

# Development tools are installed into the ignored vendor rock tree at exact
# commits. Teal and Cerulean both move ahead of releases that understand the
# syntax used here, so floating development rocks are not reproducible.
#
# Read out of cmake/Revisions.cmake rather than declared here, because Teal and
# Cerulean are compiled into the `tecs` binary, and a tree formatted by one
# version and checked by another is the failure this pin exists to prevent.
# tealdoc is named there for company rather than because it is linked: it
# renders the reference section of every module page, which is committed and
# diffed against a fresh render, so an unpinned one would fail the diff on
# somebody else's machine rather than on the change that moved a name.
#
# Matched on the variable name alone and split on the quotes, because make
# counts parentheses inside `$(shell ...)` and a regex holding one does not
# survive being written here.
REVISIONS     := cmake/Revisions.cmake
TL_REF        ?= $(shell grep TECS_TL_REF $(REVISIONS) | cut -d'"' -f2)
CERULEAN_REF  ?= $(shell grep TECS_CERULEAN_REF $(REVISIONS) | cut -d'"' -f2)
TEALDOC_REF   ?= $(shell grep TECS_TEALDOC_REF $(REVISIONS) | cut -d'"' -f2)

# The build system owns these locations, so it passes them rather than having
# the engine guess where its own output went.
export TECS_LUA := $(CURDIR)/$(LUA)
export TECS_LIB := $(CURDIR)/$(OUT)/lib

# A development run reads content out of the build tree. Nothing resolves
# against the working directory, so this is how the shader pack and any other
# asset are found without installing a package first.
export TECS_ASSETS := $(CURDIR)/$(LUA)
export TECS_SPEC := $(CURDIR)/$(OUT)/spec

# The same four pointed at an installed tree instead, so the suite can be run
# against what a package carries rather than against a build tree. The specs
# themselves are not installed, since a package is not a place to run them
# from, so that one still comes out of the build.
#
# Then one override per library, which is not tidiness. `loader.library` tries
# a library's plain soname before any directory it was told about, so
# `ffi.load("SDL3")` reaches whatever the machine has installed even from
# inside a package carrying its own, while the C that was linked resolves the
# packaged one through @rpath. Two SDL3 images end up in one process, and what
# that looks like is the Objective-C runtime writing duplicate-class warnings
# onto a spec's stdout. The explicit path is consulted first, so these are what
# make a packaged run test the packaged libraries.
#
# DYLD_LIBRARY_PATH would cover all of them at once and is deliberately not
# used: the headless specs reach their subject through io.popen, and macOS
# strips every DYLD_ variable when it spawns /bin/sh.
PACKAGE     := $(CURDIR)/out/package
PACKAGE_LUA := $(PACKAGE)/share/tecs/lua
PACKAGE_LIB := $(PACKAGE)/lib
PACKAGE_ENV  = TECS_LUA=$(PACKAGE_LUA) TECS_LIB=$(PACKAGE_LIB) \
               TECS_ASSETS=$(PACKAGE_LUA) TECS_SPEC=$(CURDIR)/$(OUT)/spec \
               TECS_SDL3_PATH=$(PACKAGE_LIB)/libSDL3.dylib \
               TECS_SDL3MIXER_PATH=$(PACKAGE_LIB)/libSDL3_mixer.dylib \
               TECS_ZLIB_PATH=$(PACKAGE_LIB)/libz.dylib \
               TECS_SHADERC_PATH=$(PACKAGE_LIB)/libshaderc_shared.dylib \
               TECS_SPVC_PATH=$(PACKAGE_LIB)/libspirvcrossc.dylib

SOURCE_TL := $(shell find src -name '*.tl' 2>/dev/null)
SPEC_TL   := $(shell find spec -name '*.tl' 2>/dev/null)
BENCH_TL  := $(shell find bench -name '*.tl' 2>/dev/null)
# The CLI, minus its templates. Those are a generated project's sources rather
# than this tree's: they are written against the `tecs` global, which this
# tree's own check does not declare, and nothing here ever runs them.
CLI_TL    := $(shell find cli -name '*.tl' -not -path 'cli/tecscli/templates/*' 2>/dev/null)
# tl searches include paths last-first, so ours come last and win.
TL_FLAGS  := -I $(CURDIR)/vendor/share/lua/5.1 -I $(CURDIR)/vendor/tl -I $(CURDIR)/cli

.PHONY: help all configure build check test test-package abi-check run clean single \
        rebuild deps dev-tools package check-package presets shaders \
        bench bench-physics \
        bench-sprites bench-text bench-particles bench-latency bench-alloc \
        bench-ecs \
        bench-json \
        bench-snapshot bench-bitset format format-check docs-check \
        docs-dev docs-build

help: ## List targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk -F':.*?## ' '{printf "  %-12s %s\n", $$1, $$2}'
	@echo
	@echo "  PRESET=$(PRESET)   (make presets to list them)"

presets: ## List available CMake presets
	@cmake --list-presets

deps: ## Install development dependencies (macOS/Homebrew)
	brew install cmake pkg-config sdl3 sdl3_mixer \
	  shaderc spirv-cross luajit \
	  clang-format stylua ruff gersemi prettier luarocks
	@$(MAKE) dev-tools

dev-tools: ## Install pinned Teal, Cerulean and tealdoc into vendor
	@TL_REF="$(TL_REF)" CERULEAN_REF="$(CERULEAN_REF)" \
	  TEALDOC_REF="$(TEALDOC_REF)" scripts/install-dev-tools.sh

configure: ## Configure the selected preset
	@cmake --preset $(PRESET)

all: build ## Configure and build everything

build: ## Build the selected preset
	@test -d $(OUT) || cmake --preset $(PRESET)
	@cmake --build --preset $(PRESET)

check: ## Type-check Teal sources
	@$(TL) check $(TL_FLAGS) $(SOURCE_TL) $(BENCH_TL) $(CLI_TL) main.tl

# Formatting needs no build, so these call the script rather than going through
# CMake. It is the same script the CMake targets of these names run, so there is
# one description of what is formatted and by what.
format: ## Format sources in place
	@python3 scripts/format.py

format-check: ## Report unformatted sources, writing nothing
	@python3 scripts/format.py --check

# The site and the offline reference the CLI is planned to serve are one content
# tree, and a page's `description:` is what labels it in both, so a page without
# one is invisible in the index rather than merely undocumented. Checked here
# because it needs no build, like the two above it.
docs-check: ## Verify the documentation against the API it describes
	@bash scripts/check-docs-descriptions.sh
	@bash docs/scripts/checkpages.sh
	@python3 docs/scripts/checklinks.py
	@python3 docs/scripts/reference.py --check

# The site's own tooling, which needs node rather than anything this build
# owns. Kept here so the commands sit beside the rest rather than being
# something you have to know to look for in docs/package.json. The install runs
# only when there is nothing to run from, so an ordinary serve costs nothing.
docs-dev: ## Serve the documentation site with hot reload
	@cd docs && [ -d node_modules ] || npm install
	@cd docs && npm run docs:dev

docs-build: ## Build the documentation site into docs/.vitepress/dist
	@cd docs && [ -d node_modules ] || npm install
	@cd docs && npm run docs:build

# Two runs, because the headless specs fork. `io.popen` forks this process, and
# by the time the rest of the suite has run there are live threads in it: the
# solver's pool, asset workers, the graphics driver's own. Forking a
# multithreaded process is unsafe between the fork and the exec, and the child
# dies there often enough to fail about one run in five, with its output buffer
# unflushed so the failure reads as a program that printed nothing. Running them
# first, in a process that has not started a thread yet, is the fix.
test: build $(LUA)/main.lua ## Run the spec suite
	@busted --pattern=headless_spec
	@busted --exclude-pattern=headless_spec

shaders: build ## Build the shader pack a target without a compiler consumes
	@luajit scripts/buildshaders.lua

abi-check: build ## Verify generated cdefs against the C ABI
	@python3 scripts/abicheck.py $(LUA)/tecs/ffi

$(LUA)/main.lua: main.tl
	@$(TL) gen $(TL_FLAGS) main.tl -o $@

$(OUT)/bench/%.lua: bench/%.tl
	@mkdir -p $(OUT)/bench
	@$(TL) gen $(TL_FLAGS) $< -o $@

bench: build $(OUT)/bench/shapes.lua ## Run the shapes benchmark
	@$(BIN) --entry $(OUT)/bench/shapes.lua

bench-physics: build $(OUT)/bench/physics.lua ## Run the physics benchmark
	@$(BIN) --entry $(OUT)/bench/physics.lua

bench-sprites: build $(OUT)/bench/sprites.lua ## Run the sprite benchmark
	@$(BIN) --entry $(OUT)/bench/sprites.lua

bench-text: build $(OUT)/bench/text.lua ## Run the text benchmark
	@$(BIN) --entry $(OUT)/bench/text.lua

bench-particles: build $(OUT)/bench/particles.lua ## Run the particle benchmark
	@$(BIN) --entry $(OUT)/bench/particles.lua

bench-latency: build $(OUT)/bench/latency.lua ## Measure event-to-photon latency
	@$(BIN) --entry $(OUT)/bench/latency.lua

bench-alloc: build $(OUT)/bench/allocation.lua ## Measure allocation per frame
	@$(BIN) --entry $(OUT)/bench/allocation.lua

# The ECS benchmarks run under a plain interpreter rather than the host, since
# none of them draw. They still need TECS_LIB, which the exports above set:
# requiring tecs loads the engine too, and the engine loads native libraries.
#
# All four accept the same filters:
#   CASE=<n>            run only the case at that 1-based index
#   VARIANTS=a,b        run only the named variants
#   PARAMS='k=v,k=v'    run only expansions matching every given parameter
BENCH_FILTERS = BENCH_CASE="$(CASE)" BENCH_VARIANTS="$(VARIANTS)" \
                BENCH_PARAMS="$(PARAMS)"

# Set EVOLVED_PATH to a checkout of https://github.com/BlackMATov/evolved.lua
# (defaults to ~/projects/evolved.lua).
bench-ecs: build ## Run the ECS benchmarks
	@cd benches/ecs-bench && $(BENCH_FILTERS) luajit main.lua

bench-json: build ## Run the JSON benchmarks
	@cd benches/json-bench && $(BENCH_FILTERS) luajit main.lua

bench-snapshot: build ## Run the snapshot benchmarks
	@cd benches/snapshot-bench && $(BENCH_FILTERS) luajit main.lua

bench-bitset: build ## Run the bitset benchmarks
	@cd benches/bitset && $(BENCH_FILTERS) luajit main.lua

run: build $(LUA)/main.lua ## Run the demo
	@$(BIN) --entry $(LUA)/main.lua

package: build shaders $(LUA)/main.lua ## Install a tree into out/package
	@cmake --install $(OUT) --prefix $(PACKAGE) --component tecs

# The command line tool as one executable, which is its own preset rather than
# a flag on the packaged one: every dependency is linked in, so a spec under a
# plain interpreter has nothing to load and `make test` would be testing a
# configuration nobody ships.
#
# Not a `package` variant either, because that target builds a shader pack
# first, and building one runs the engine under a plain `luajit`. A single-file
# build carries a shader compiler and compiles at run time, so there is no pack
# to build and no interpreter to build it with.
SINGLE     := macos-arm64-single
SINGLE_OUT := out/single
single: ## Build the one-file command line tool into out/single/bin/tecs
	@test -d out/$(SINGLE) || cmake --preset $(SINGLE)
	@cmake --build --preset $(SINGLE) --parallel
	@cmake --install out/$(SINGLE) --prefix $(CURDIR)/$(SINGLE_OUT) --component tecs
	@ls -l $(SINGLE_OUT)/bin/tecs

# The suite against an installed tree. `make test` runs against a build tree,
# which on a development preset means against the machine's own SDL family and
# zlib rather than against the revisions a release ships. This is what runs
# it against those, and it needs a packaged preset to be worth anything:
# PRESET=macos-arm64 make test-package.
test-package: package ## Run the spec suite against out/package
	@$(PACKAGE_ENV) busted --pattern=headless_spec
	@$(PACKAGE_ENV) busted --exclude-pattern=headless_spec

check-package: package ## Verify a package carries its own dependencies
	@python3 scripts/checkpackage.py $(CURDIR)/out/package --allow-compiler \
	  --teal-types $(CURDIR)/vendor/share/lua/5.1

clean: ## Remove build output
	@rm -rf out build bin

rebuild: clean all ## Clean and rebuild
