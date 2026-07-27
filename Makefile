.DEFAULT_GOAL := help
SHELL := /bin/bash

# A wrapper over CMake, which is the canonical build. Everything here forwards;
# nothing here knows how the engine is assembled, so there is one description
# of that rather than two to keep in step.

PRESET ?= macos-arm64-dev
OUT    := out/$(PRESET)
LUA    := $(OUT)/lua
BIN    := $(OUT)/bin/tecs

# The build system owns these locations, so it passes them rather than having
# the engine guess where its own output went.
export TECS_LUA := $(CURDIR)/$(LUA)
export TECS_LIB := $(CURDIR)/$(OUT)/lib

# A development run reads content out of the build tree. Nothing resolves
# against the working directory, so this is how the shader pack and any other
# asset are found without installing a package first.
export TECS_ASSETS := $(CURDIR)/$(LUA)
export TECS_SPEC := $(CURDIR)/$(OUT)/spec

SOURCE_TL := $(shell find src -name '*.tl' 2>/dev/null)
SPEC_TL   := $(shell find spec -name '*.tl' 2>/dev/null)
BENCH_TL  := $(shell find bench -name '*.tl' 2>/dev/null)
# tl searches include paths last-first, so ours come last and win.
TL_FLAGS  := -I $(CURDIR)/vendor/share/lua/5.1 -I $(CURDIR)/vendor/tl

.PHONY: help all configure build check test abi-check run clean rebuild \
        deps package check-package presets shaders bench bench-physics \
        bench-latency bench-ecs bench-json bench-snapshot bench-bitset \
        format format-check

help: ## List targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk -F':.*?## ' '{printf "  %-12s %s\n", $$1, $$2}'
	@echo
	@echo "  PRESET=$(PRESET)   (make presets to list them)"

presets: ## List available CMake presets
	@cmake --list-presets

deps: ## Install development dependencies (macOS/Homebrew)
	brew install cmake pkg-config sdl3 sdl3_image sdl3_mixer sdl3_net box2d \
	  shaderc spirv-cross luajit \
	  clang-format stylua ruff gersemi prettier

configure: ## Configure the selected preset
	@cmake --preset $(PRESET)

all: build ## Configure and build everything

build: ## Build the selected preset
	@test -d $(OUT) || cmake --preset $(PRESET)
	@cmake --build --preset $(PRESET)

check: ## Type-check Teal sources
	@tl check $(TL_FLAGS) $(SOURCE_TL) $(BENCH_TL) main.tl

# Formatting needs no build, so these call the script rather than going through
# CMake. It is the same script the CMake targets of these names run, so there is
# one description of what is formatted and by what.
format: ## Format sources in place
	@python3 scripts/format.py

format-check: ## Report unformatted sources, writing nothing
	@python3 scripts/format.py --check

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
	@tl gen $(TL_FLAGS) main.tl -o $@

$(OUT)/bench/%.lua: bench/%.tl
	@mkdir -p $(OUT)/bench
	@tl gen $(TL_FLAGS) $< -o $@

bench: build $(OUT)/bench/shapes.lua ## Run the shapes benchmark
	@$(BIN) --entry $(OUT)/bench/shapes.lua

bench-physics: build $(OUT)/bench/physics.lua ## Run the physics benchmark
	@$(BIN) --entry $(OUT)/bench/physics.lua

bench-text: build $(OUT)/bench/text.lua ## Run the text benchmark
	@$(BIN) --entry $(OUT)/bench/text.lua

bench-latency: build $(OUT)/bench/latency.lua ## Measure event-to-photon latency
	@$(BIN) --entry $(OUT)/bench/latency.lua

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
	@cmake --install $(OUT) --prefix $(CURDIR)/out/package

check-package: package ## Verify a package carries its own dependencies
	@python3 scripts/checkpackage.py $(CURDIR)/out/package --allow-compiler

clean: ## Remove build output
	@rm -rf out build bin

rebuild: clean all ## Clean and rebuild
