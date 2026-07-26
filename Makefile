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
        deps package check-package presets shaders bench bench-physics

help: ## List targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk -F':.*?## ' '{printf "  %-12s %s\n", $$1, $$2}'
	@echo
	@echo "  PRESET=$(PRESET)   (make presets to list them)"

presets: ## List available CMake presets
	@cmake --list-presets

deps: ## Install development dependencies (macOS/Homebrew)
	brew install cmake pkg-config sdl3 sdl3_image box2d shaderc spirv-cross luajit

configure: ## Configure the selected preset
	@cmake --preset $(PRESET)

all: build ## Configure and build everything

build: ## Build the selected preset
	@test -d $(OUT) || cmake --preset $(PRESET)
	@cmake --build --preset $(PRESET)

check: ## Type-check Teal sources
	@tl check $(TL_FLAGS) $(SOURCE_TL) $(BENCH_TL) main.tl

test: build $(LUA)/main.lua ## Run the spec suite
	@busted

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

run: build $(LUA)/main.lua ## Run the demo
	@$(BIN) --entry $(LUA)/main.lua

package: build shaders $(LUA)/main.lua ## Install a tree into out/package
	@cmake --install $(OUT) --prefix $(CURDIR)/out/package

check-package: package ## Verify a package carries its own dependencies
	@python3 scripts/checkpackage.py $(CURDIR)/out/package --allow-compiler

clean: ## Remove build output
	@rm -rf out build bin

rebuild: clean all ## Clean and rebuild
