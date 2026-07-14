.PHONY: all build build-tecs build-tecs2d test test-love test-no-ffi clean dev install-type-deps compile compile-tecs compile-tecs2d check find-busted trim-whitespace \
	coverage coverage-report coverage-xml coverage-lcov coverage-html \
	check-examples build-examples new-example \
	example-text-bench example-sprite-collision example-assets example-audio example-ball-bench example-circles \
	example-controller example-lighting example-love-interop example-orbiting-shapes example-particles \
	example-physics example-physics-bench example-shape-bench example-sprite-bench \
	example-sprite-onloop example-tiled example-transform-demo example-ui example-mesh-demo example-layer-fx \
	example-camera-target example-material-demo example-camera-multi example-msdf-text example-tween-demo \
	example-save-game \
	newrock test-rockspec typecheck rebuild help rockspecs docs docs-dev docs-debug docs-api \
	docs-descriptions \
	json-bench ecs-bench snapshot-bench bitset-bench download-love12 check-love12

.SILENT: clean test test-no-ffi find-busted

VERSION=0.2.0
LUA_CMD ?= luajit

# Love2D 12 (nightly) for GPU rendering features
LOVE12_DIR := $(CURDIR)/bin/love2d
# Nightly build URLs (via nightly.link for unauthenticated access)
NIGHTLY_BASE := https://nightly.link/love2d/love/workflows/main/main
# Detect OS
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
	LOVE12_BIN := $(LOVE12_DIR)/love.app/Contents/MacOS/love
else ifeq ($(UNAME_S),Linux)
	LOVE12_BIN := $(LOVE12_DIR)/love
else
	# Windows (MSYS/MinGW)
	LOVE12_BIN := $(LOVE12_DIR)/love.exe
endif

# Paths
SPEC_DIR=./spec
LUA_DIR=./build
TL_SRC_DIR=./src
VENDOR_BIN=$(CURDIR)/vendor/bin
VENDOR_LUA=$(CURDIR)/vendor/share/lua/5.1
VENDOR_CLIB=$(CURDIR)/vendor/lib/lua/5.1

# Love executable - default to Love2D 12 for GPU rendering
LOVE := $(LOVE12_BIN)

# Environment for running tl - use local vendor tree, fall back to system paths
TEAL_LUA_PATH := $(VENDOR_LUA)/?.lua;$(VENDOR_LUA)/?/init.lua;;
TEAL_LUA_CPATH := $(VENDOR_CLIB)/?.so;;
TEAL_ENV = PATH="$(VENDOR_BIN):$$PATH" LUA_PATH="$(TEAL_LUA_PATH)$$LUA_PATH" LUA_CPATH="$(TEAL_LUA_CPATH)$$LUA_CPATH" LOVE="$(LOVE)"

# Commands - prefer local vendor busted, fallback to system busted
BUSTED_CMD ?= $(shell [ -x "$(VENDOR_BIN)/busted" ] && echo "$(VENDOR_BIN)/busted" || which busted 2>/dev/null)
LUACOV_COBERTURA_CMD ?= $(shell which luacov-cobertura 2>/dev/null || echo "$(LUAROCKS_BIN)/luacov-cobertura")

# Common LUA paths for coverage targets
COVERAGE_LUA_PATH="../$(LUA_DIR)/?.lua;../$(LUA_DIR)/?/init.lua;$(VENDOR_LUA)/?.lua;$(VENDOR_LUA)/?/init.lua;"
COVERAGE_LUA_CPATH="$(VENDOR_CLIB)/?.so;"

# Source files for dependency tracking
SOURCE_TL := $(shell find $(TL_SRC_DIR) -name "*.tl" 2>/dev/null || true)
TECS_SOURCE_TL := $(shell find $(TL_SRC_DIR)/tecs -name "*.tl" 2>/dev/null || true)
TECS2D_SOURCE_TL := $(shell find $(TL_SRC_DIR)/tecs2d -name "*.tl" 2>/dev/null || true)
SOURCE_GLSL := $(shell find $(TL_SRC_DIR) -name "*.glsl" 2>/dev/null || true)
TECS2D_FONT_ASSETS := examples/shared/assets/tiny-font.fnt examples/shared/assets/tiny-font.png

# Test deps live under build/test_deps and are compiled by the post-build
# script scripts/compile_specs.tl in a single Lua process (much faster than
# forking `tl gen` per file).
TEST_BUILD_DIR=$(LUA_DIR)/test_deps

all: build test

build: compile

# The core rock must not require Tecs2D's LÖVE global environment while
# LuaRocks is still resolving the tecs2d dependency tree.
build-tecs: compile-tecs

compile-tecs: $(TECS_SOURCE_TL) tlconfig.lua
	@if $(TEAL_ENV) tl gen --help 2>&1 | grep -q -- '--root'; then \
		$(TEAL_ENV) tl --global-env-def teal.default.prelude -q gen \
			--root src --output-dir build $(TECS_SOURCE_TL); \
	else \
		for src in $(TECS_SOURCE_TL); do \
			out="$(LUA_DIR)/$${src#$(TL_SRC_DIR)/}"; \
			out="$${out%.tl}.lua"; \
			mkdir -p "$$(dirname "$$out")"; \
			$(TEAL_ENV) tl --global-env-def teal.default.prelude -q gen "$$src" -o "$$out"; \
		done; \
	fi

build-tecs2d: compile-tecs2d

compile-tecs2d: $(TECS2D_SOURCE_TL) $(SOURCE_GLSL) $(TECS2D_FONT_ASSETS) tlconfig.lua
	@if $(TEAL_ENV) tl gen --help 2>&1 | grep -q -- '--root'; then \
		$(TEAL_ENV) tl -q gen --root src --output-dir build $(TECS2D_SOURCE_TL); \
	else \
		for src in $(TECS2D_SOURCE_TL); do \
			out="$(LUA_DIR)/$${src#$(TL_SRC_DIR)/}"; \
			out="$${out%.tl}.lua"; \
			mkdir -p "$$(dirname "$$out")"; \
			$(TEAL_ENV) tl -q gen "$$src" -o "$$out"; \
		done; \
	fi
	@cd src && find tecs2d/gfx/internal -name "*.glsl" -exec sh -c 'mkdir -p "../$(LUA_DIR)/$$(dirname {})" && cp {} "../$(LUA_DIR)/{}"' \;
	@mkdir -p $(LUA_DIR)/tecs2d/assets/fonts
	@cp $(TECS2D_FONT_ASSETS) $(LUA_DIR)/tecs2d/assets/fonts/
	@echo "Synced $(words $(SOURCE_GLSL)) shader files"

install-type-deps:
	luarocks install --tree=vendor --lua-version=5.1 luajit-tl-type 0.0.2-1
	luarocks install --tree=vendor --lua-version=5.1 luasocket-tl-type 0.0.2-1
	luarocks install --tree=vendor --lua-version=5.1 busted-tl-type 0.0.1-1
	luarocks install --tree=vendor --lua-version=5.1 luassert-tl-type 0.0.1-1
	luarocks install --tree=vendor --lua-version=5.1 tecs-love2d-tl-type

dev: install-type-deps
	@echo "Installing development dependencies..."
	@echo "Installing Teal development release..."
	luarocks --dev install --tree=vendor --lua-version=5.1 tl
	luarocks install --tree=vendor --lua-version=5.1 busted
	luarocks install --tree=vendor --lua-version=5.1 luacov
	luarocks install --tree=vendor --lua-version=5.1 luacov-cobertura
	luarocks install --tree=vendor --lua-version=5.1 luacov-reporter-lcov
	luarocks install --tree=vendor --lua-version=5.1 luafilesystem
	luarocks install --tree=vendor --lua-version=5.1 luasocket
	@echo "Installing documentation dependencies..."
	cd docs && npm install
	@echo "Development dependencies installed!"
	@echo "Running initial build..."
	$(MAKE) build

find-busted:
	luarocks path --lr-path
	echo "Checking possible Busted locations:"
	find ~/.luarocks -name "runner.lua" | grep busted

check:
	$(TEAL_ENV) tl check $(SOURCE_TL)

compile: $(SOURCE_TL) $(SOURCE_GLSL) $(TECS2D_FONT_ASSETS) tlconfig.lua
	@if $(TEAL_ENV) tl gen --help 2>&1 | grep -q -- '--root'; then \
		$(TEAL_ENV) tl -q gen --root src --output-dir build $(SOURCE_TL); \
	else \
		for src in $(SOURCE_TL); do \
			out="$(LUA_DIR)/$${src#$(TL_SRC_DIR)/}"; \
			out="$${out%.tl}.lua"; \
			mkdir -p "$$(dirname "$$out")"; \
			$(TEAL_ENV) tl -q gen "$$src" -o "$$out"; \
		done; \
	fi
	@# Copy shader files (always sync from source, preserving directory structure)
	@cd src && find tecs2d/gfx/internal -name "*.glsl" -exec sh -c 'mkdir -p "../$(LUA_DIR)/$$(dirname {})" && cp {} "../$(LUA_DIR)/{}"' \;
	@mkdir -p $(LUA_DIR)/tecs2d/assets/fonts
	@cp $(TECS2D_FONT_ASSETS) $(LUA_DIR)/tecs2d/assets/fonts/
	@echo "Synced $(words $(SOURCE_GLSL)) shader files"
	@$(TEAL_ENV) luajit scripts/compile_specs.lua

# Force full rebuild
rebuild: clean compile

test: compile
	@echo "Running tests..."
	LUA_PATH="$(LUA_DIR)/?.lua;$(LUA_DIR)/?/init.lua;$(TEST_BUILD_DIR)/?.lua;$(TEST_BUILD_DIR)/?/init.lua;$(VENDOR_LUA)/?.lua;$(VENDOR_LUA)/?/init.lua;;" $(BUSTED_CMD) --no-auto-insulate $(TEST_BUILD_DIR)

# Love2D integration tests: launch real LÖVE fixture apps and drive them over
# the tecs2d MCP HTTP server. Opt-in (needs LÖVE, a display, and sockets);
# integration specs use the *_lovespec.tl suffix so the fast suite's default
# _spec pattern never picks them up.
LOVE_FIXTURE_DIR=$(TEST_BUILD_DIR)/spec/integration/apps
FILE_MATCH ?= _lovespec
# Busted matches --pattern against basenames only, and the fixture apps
# symlink the whole engine tree (whose module names can collide with a
# FILE_MATCH like "layer_effects"). Require the _lovespec suffix in the
# effective pattern so only spec files ever load.
LOVE_FILE_PATTERN := $(if $(findstring _lovespec,$(FILE_MATCH)),$(FILE_MATCH),$(FILE_MATCH).*_lovespec)
LOVE_TEST_FILTER := $(if $(MATCH),--filter="$(MATCH)",)
test-love: compile $(LOVE12_BIN)
	@echo "Running Love2D integration tests..."
	@if [ -n "$(MATCH)" ]; then echo "Filtering test names with Lua pattern: $(MATCH)"; fi
	@if [ "$(FILE_MATCH)" != "_lovespec" ]; then echo "Filtering test files with Lua pattern: $(FILE_MATCH)"; fi
	@for app in $(LOVE_FIXTURE_DIR)/*/; do \
		ln -sfn $(CURDIR)/build/tecs "$$app/tecs"; \
		ln -sfn $(CURDIR)/build/tecs2d "$$app/tecs2d"; \
		ln -sfn $(CURDIR)/build/tecs2d/assets/internal "$$app/internal"; \
		ln -sfn $(CURDIR)/examples/shared/assets "$$app/assets"; \
	done
	LUA_PATH="$(LUA_DIR)/?.lua;$(LUA_DIR)/?/init.lua;$(TEST_BUILD_DIR)/?.lua;$(TEST_BUILD_DIR)/?/init.lua;$(VENDOR_LUA)/?.lua;$(VENDOR_LUA)/?/init.lua;;" \
	LUA_CPATH="$(VENDOR_CLIB)/?.so;;" \
	LOVE="$(LOVE)" \
	$(BUSTED_CMD) --no-auto-insulate --pattern="$(LOVE_FILE_PATTERN)" $(LOVE_TEST_FILTER) $(TEST_BUILD_DIR)/spec/integration

# Love2D performance benches: run scenario apps under real LÖVE and record
# steady-state frame times + per-frame Lua allocation. Results land in
# benches/love2d/results/<scenario>.json and print as TECS_BENCH_RESULT
# lines. Usage:
#   make bench-love SCENARIO=lights      # one scenario
#   make bench-love                      # all scenarios
#   make bench-love SCENARIO=lights FRAMES=600 WARMUP=200
BENCH_LOVE_APP := benches/love2d/app
BENCH_LOVE_RESULTS := benches/love2d/results
BENCH_SCENARIOS := $(basename $(notdir $(wildcard $(BENCH_LOVE_APP)/scenarios/*.lua)))
bench-love: compile $(LOVE12_BIN)
	@ln -sfn $(CURDIR)/build/tecs $(BENCH_LOVE_APP)/tecs
	@ln -sfn $(CURDIR)/build/tecs2d $(BENCH_LOVE_APP)/tecs2d
	@ln -sfn $(CURDIR)/build/tecs2d/assets/internal $(BENCH_LOVE_APP)/internal
	@ln -sfn $(CURDIR)/examples/shared/assets $(BENCH_LOVE_APP)/assets
	@mkdir -p $(BENCH_LOVE_RESULTS)
	@for s in $(if $(SCENARIO),$(SCENARIO),$(BENCH_SCENARIOS)); do \
		$(if $(FRAMES),TECS_BENCH_FRAMES=$(FRAMES),) \
		$(if $(WARMUP),TECS_BENCH_WARMUP=$(WARMUP),) \
		sh scripts/bench_love.sh "$(LOVE)" $(BENCH_LOVE_APP) $$s \
			$(CURDIR)/$(BENCH_LOVE_RESULTS)/$$s.json $(or $(RUNS),3) || exit 1; \
	done

clean:
	rm -rf build
	rm -rf examples/*/build

# Install target for luarocks (called by luarocks make/build)
# LUADIR is set by luarocks. ROCK selects which rock is being installed:
#   ROCK=tecs   -> renderer-agnostic ECS core only
#   ROCK=tecs2d -> LÖVE2D engine layer only (depends on the tecs rock)
install:
ifdef LUADIR
	@# SAFETY: refuse to install if LUADIR/tecs is a symlink. Some downstream
	@# projects (e.g. tecs-space-example) symlink their vendor/tecs to this repo's
	@# src/tecs for fast dev iteration. luarocks's install-time cleanup
	@# resolves through such symlinks and would destroy this source tree.
	@if [ -L "$(LUADIR)/tecs" ] || [ -L "$(LUADIR)/tecs2d" ]; then \
		echo "Refusing to install: $(LUADIR)/tecs or tecs2d is a symlink (likely a downstream project's dev mode pointing at this source tree)."; \
		echo "Remove the symlinks before running luarocks install/make against this rockspec."; \
		exit 1; \
	fi
	@if [ -z "$(ROCK)" ]; then \
		echo "ROCK not specified - this Makefile is invoked by luarocks with ROCK=tecs or ROCK=tecs2d."; \
		echo "Set ROCK explicitly when running 'make install' by hand."; \
		exit 1; \
	fi
	@echo "Installing $(ROCK) to $(LUADIR)..."
	@case "$(ROCK)" in \
		tecs) \
			mkdir -p $(LUADIR)/tecs/internal/ffi $(LUADIR)/tecs/internal/world \
			         $(LUADIR)/tecs/utils/json/internal; \
			cp -r build/tecs/* $(LUADIR)/tecs/; \
			rsync -a --include='*/' --include='*.tl' --exclude='*' src/tecs/ $(LUADIR)/tecs/; \
			;; \
		tecs2d) \
			mkdir -p $(LUADIR)/tecs2d/internal $(LUADIR)/tecs2d/assets/internal \
			         $(LUADIR)/tecs2d/gfx/internal $(LUADIR)/tecs2d/gfx/bmfont \
			         $(LUADIR)/tecs2d/audio/internal $(LUADIR)/tecs2d/ui/internal \
			         $(LUADIR)/tecs2d/mcp $(LUADIR)/tecs2d/tiled/internal; \
			cp -r build/tecs2d/* $(LUADIR)/tecs2d/; \
			rsync -a --include='*/' --include='*.tl' --exclude='*' src/tecs2d/ $(LUADIR)/tecs2d/; \
			;; \
		*) \
			echo "Unknown rock: $(ROCK)"; \
			exit 1; \
			;; \
	esac
	@echo "Installation complete"
else
	@echo "LUADIR not set - skipping installation"
endif

trim-whitespace:
	@find src spec -name "*.tl" -exec sed -i.bak 's/[[:space:]]*$$//' {} \;
	@find src spec -name "*.tl.bak" -exec rm {} \;
	@find docs -name "*.md" -exec sed -i.bak 's/[[:space:]]*$$//' {} \;
	@find docs -name "*.md.bak" -exec rm {} \;
	@echo "Trimmed trailing whitespace from .tl and .md files"

# Run tests with coverage collection
coverage: clean compile
	@echo "Running tests with code coverage..."
	# Clean up any existing coverage files
	@rm -f build/luacov.stats.out build/luacov.report.out build/coverage.*
	@rm -f luacov.stats.out luacov.report.out coverage.info
	# Run tests with coverage enabled
	LUA_PATH="$(LUA_DIR)/?.lua;$(LUA_DIR)/?/init.lua;$(TEST_BUILD_DIR)/?.lua;$(TEST_BUILD_DIR)/?/init.lua;$(LUAROCKS_LUA)/?.lua;$(LUAROCKS_LUA)/?/init.lua;" \
	LUA_CPATH="$(LUAROCKS_CLIB)/?.so;" \
	LUA=$(LUA_CMD) $(BUSTED_CMD) --coverage $(TEST_BUILD_DIR) || true
	# Move coverage stats to build/ (busted always writes to current dir)
	@if [ -f luacov.stats.out ]; then \
		mv luacov.stats.out build/luacov.stats.out; \
	fi
	@echo "Coverage stats written to build/luacov.stats.out"

# Generate human-readable text coverage report
coverage-report: coverage
	@echo "Generating text coverage report..."
	# Run reporter from build/ dir to keep paths relative
	@cd build && LUA_PATH=$(COVERAGE_LUA_PATH) LUA_CPATH=$(COVERAGE_LUA_CPATH) \
	luajit -e "require('luacov.runner').init('../.luacov'); require('luacov.reporter').report()" 2>/dev/null || true
	# Move report file if generated in root (some luacov versions do this)
	@if [ -f luacov.report.out ]; then \
		mv luacov.report.out build/luacov.report.out 2>/dev/null || true; \
	fi
	# Display summary if report was generated
	@if [ -f build/luacov.report.out ]; then \
		echo ""; \
		echo "=== Code Coverage Summary ==="; \
		echo ""; \
		tail -20 build/luacov.report.out; \
		echo ""; \
		echo "Full report available in build/luacov.report.out"; \
	else \
		echo "No coverage report generated. Check luacov installation."; \
	fi

# Generate LCOV format for HTML generation via genhtml
coverage-lcov: coverage
	@echo "Generating LCOV coverage report..."
	# Run LCOV reporter from project root (stats file is in build/)
	@LUA_PATH="$(LUA_DIR)/?.lua;$(LUA_DIR)/?/init.lua;$(LUAROCKS_LUA)/?.lua;$(LUAROCKS_LUA)/?/init.lua;" \
	LUA_CPATH="$(LUAROCKS_CLIB)/?.so;" \
	luajit -e "require('luacov.runner').init({statsfile='build/luacov.stats.out', reportfile='build/coverage.info'}); require('luacov.reporter.lcov').report()"
	@echo "LCOV report written to build/coverage.info"

# Generate HTML coverage report using genhtml
coverage-html: coverage-lcov
	@if command -v genhtml >/dev/null 2>&1; then \
		if [ -s build/coverage.info ]; then \
			echo "Generating HTML coverage report..."; \
			genhtml build/coverage.info -o build/coverage-html --quiet; \
			echo "HTML coverage report written to build/coverage-html/"; \
			echo "Open with: open build/coverage-html/index.html"; \
		else \
			echo "LCOV file not found or empty. Check 'make coverage-lcov' output."; \
		fi \
	else \
		echo "genhtml not found. Install lcov to generate HTML reports:"; \
		echo "  brew install lcov"; \
	fi

# ================= LuaRocks =================
newrock:
	@if [ -z "$(ROCK)" ] || [ -z "$(NEW_VERSION)" ]; then \
		echo "Usage: make newrock ROCK=<rockspec> NEW_VERSION=<version>"; \
		echo "Example: make newrock ROCK=tecs NEW_VERSION=0.3.0"; \
		exit 1; \
	fi
	@if [ ! -f "$(ROCK)-dev-1.rockspec" ]; then \
		echo "Error: $(ROCK)-dev-1.rockspec not found"; \
		exit 1; \
	fi
	luarocks new_version --dir build --tag=v$(NEW_VERSION) $(ROCK)-dev-1.rockspec $(NEW_VERSION)

# Test local rockspec installation
test-rockspec: build
	@echo "Testing rockspec syntax validation..."
	@echo "Validating tecs..."
	@luarocks lint tecs-dev-1.rockspec
	@echo "Validating tecs2d..."
	@luarocks lint tecs2d-dev-1.rockspec
	@echo "Rockspecs validated successfully!"
	@echo ""
	@echo "Note: For full installation testing, update the source.url field in rockspecs"
	@echo "to point to your actual git repository, then run luarocks install locally."

# ================= Examples =================

# Example directories (explicit list for autocomplete)
EXAMPLE_DIRS := examples/text-bench examples/sprite-collision examples/assets examples/audio \
                examples/ball-bench examples/controller examples/lighting \
                examples/orbiting-shapes examples/particles examples/physics \
                examples/physics-bench examples/shape-bench examples/sprite-bench \
                examples/camera-target examples/camera-multi examples/tiled examples/transform-demo examples/ui

# Type check all examples
check-examples: build
	@echo "Type checking examples..."
	@for dir in $(EXAMPLE_DIRS); do \
		name=$$(basename "$$dir"); \
		echo "=== Checking $$name ==="; \
		(cd "$$dir" && $(TEAL_ENV) tl check -I src $$(find src -name "*.tl")) || exit 1; \
	done
	@echo "All examples type-check successfully!"

# Build all examples
build-examples: build
	@echo "Building examples..."
	@for dir in $(EXAMPLE_DIRS); do \
		echo "  Building $$(basename $$dir)..."; \
		(cd "$$dir" && $(TEAL_ENV) tl run shared/run.tl -- --build-only) || exit 1; \
	done
	@echo "All examples built successfully!"

# Individual example targets (explicit for autocomplete)
example-text-bench: build $(LOVE12_BIN)
	@cd examples/text-bench && TECS_BENCHMARK=1 $(TEAL_ENV) tl run shared/run.tl $(ENTITIES)

example-sprite-collision: build $(LOVE12_BIN)
	@cd examples/sprite-collision && $(TEAL_ENV) tl run shared/run.tl

example-assets: build $(LOVE12_BIN)
	@cd examples/assets && $(TEAL_ENV) tl run shared/run.tl

example-audio: build $(LOVE12_BIN)
	@cd examples/audio && $(TEAL_ENV) tl run shared/run.tl

example-ball-bench: build $(LOVE12_BIN)
	@cd examples/ball-bench && TECS_BENCHMARK=1 $(TEAL_ENV) tl run shared/run.tl $(ENTITIES)

example-circles: build $(LOVE12_BIN)
	@cd examples/circles && $(TEAL_ENV) tl run shared/run.tl $(ENTITIES)

example-controller: build $(LOVE12_BIN)
	@cd examples/controller && $(TEAL_ENV) tl run shared/run.tl

example-lighting: build $(LOVE12_BIN)
	@cd examples/lighting && $(TEAL_ENV) tl run shared/run.tl $(ENTITIES)

example-love-interop: build $(LOVE12_BIN)
	@cd examples/love-interop && $(TEAL_ENV) tl run shared/run.tl

example-orbiting-shapes: build $(LOVE12_BIN)
	@cd examples/orbiting-shapes && $(TEAL_ENV) tl run shared/run.tl

example-particles: build $(LOVE12_BIN)
	@cd examples/particles && $(TEAL_ENV) tl run shared/run.tl

example-physics: build $(LOVE12_BIN)
	@cd examples/physics && $(TEAL_ENV) tl run shared/run.tl

example-physics-bench: build $(LOVE12_BIN)
	@cd examples/physics-bench && TECS_BENCHMARK=1 $(TEAL_ENV) tl run shared/run.tl $(ENTITIES)

example-shape-bench: build $(LOVE12_BIN)
	@cd examples/shape-bench && TECS_BENCHMARK=1 SHAPE=$(SHAPE) $(TEAL_ENV) tl run shared/run.tl $(ENTITIES)

example-sprite-bench: build $(LOVE12_BIN)
	@cd examples/sprite-bench && TECS_BENCHMARK=1 $(TEAL_ENV) tl run shared/run.tl $(ENTITIES)

example-sprite-throughput: build $(LOVE12_BIN)
	@cd examples/sprite-throughput && TECS_BENCHMARK=1 $(TEAL_ENV) tl run shared/run.tl $(ENTITIES)

example-sprite-onloop: build $(LOVE12_BIN)
	@cd examples/sprite-onloop && $(TEAL_ENV) tl run shared/run.tl

example-tiled: build $(LOVE12_BIN)
	@cd examples/tiled && $(TEAL_ENV) tl run shared/run.tl

example-transform-demo: build $(LOVE12_BIN)
	@cd examples/transform-demo && $(TEAL_ENV) tl run shared/run.tl

example-ui: build $(LOVE12_BIN)
	@cd examples/ui && $(TEAL_ENV) tl run shared/run.tl

example-mesh-demo: build $(LOVE12_BIN)
	@cd examples/mesh-demo && $(TEAL_ENV) tl run shared/run.tl

example-layer-fx: build $(LOVE12_BIN)
	@cd examples/layer-fx && $(TEAL_ENV) tl run shared/run.tl

example-material-demo: build $(LOVE12_BIN)
	@cd examples/material-demo && $(TEAL_ENV) tl run shared/run.tl

example-camera-multi: build $(LOVE12_BIN)
	@cd examples/camera-multi && $(TEAL_ENV) tl run shared/run.tl

example-msdf-text: build $(LOVE12_BIN)
	@cd examples/msdf-text && $(TEAL_ENV) tl run shared/run.tl

example-camera-target: build $(LOVE12_BIN)
	@cd examples/camera-target && $(TEAL_ENV) tl run shared/run.tl

example-tween-demo: build $(LOVE12_BIN)
	@cd examples/tween-demo && $(TEAL_ENV) tl run shared/run.tl

example-save-game: build $(LOVE12_BIN)
	@cd examples/save-game && $(TEAL_ENV) tl run shared/run.tl

# Create a new example from template
new-example:
	@if [ -z "$(NAME)" ]; then \
		echo "Usage: make new-example NAME=my-example"; \
		exit 1; \
	fi
	@if [ -d "examples/$(NAME)" ]; then \
		echo "Error: examples/$(NAME) already exists"; \
		exit 1; \
	fi
	@echo "Creating example: $(NAME)"
	@mkdir -p examples/$(NAME)/src
	@ln -s ../shared examples/$(NAME)/shared
	@ln -s shared/tlconfig.lua examples/$(NAME)/tlconfig.lua
	@cp examples/_template/src/conf.tl examples/$(NAME)/src/
	@cp examples/_template/src/main.tl examples/$(NAME)/src/
	@echo "Created examples/$(NAME)/"
	@echo "  - Edit src/main.tl to implement your example"
	@echo "  - Run with: make example-$(NAME)"

typecheck:
	@echo "Type checking source files..."
	@$(TEAL_ENV) tl check $(SOURCE_TL)


# Generate documentation using tealdoc (TODO: Doesn't really work for Tecs at the moment)
docs: build
	@echo "Generating tealdoc documentation..."
	@mkdir -p build/docs
	@$(TEAL_ENV) tealdoc html src/tecs/init.tl src/tecs/types.tl -o build/docs/tecs.html
	@echo "Documentation generated in build/docs/"

# Regenerate the debugger command reference and the MCP tools page from the
# kernel tool definitions and the live command registry. A spec compares the
# committed pages against a fresh render, so run this after adding or
# changing a kernel tool or a debugger command.
docs-debug: compile
	@LUA_PATH="$(LUA_DIR)/?.lua;$(LUA_DIR)/?/init.lua;$(TEST_BUILD_DIR)/?.lua;$(TEST_BUILD_DIR)/?/init.lua;$(VENDOR_LUA)/?.lua;$(VENDOR_LUA)/?/init.lua;;" \
		luajit scripts/gen_debug_docs.lua

# Regenerate the API-signature reference pages under docs/tecs2d/api/, one page
# per public module, from the Teal type API (scripts/gen_api_docs.lua). A spec
# (spec/tecs2d/api/docgen_spec.tl) compares the committed pages against a fresh
# render, so run this after changing a public signature or doc comment.
docs-api:
	@$(TEAL_ENV) luajit scripts/gen_api_docs.lua

# Run Vite documentation dev server with hot reload
docs-dev:
	@cd docs && [ -d node_modules ] || npm install
	@cd docs && npm run docs:dev

# Fail if any docs page is missing a `description:` frontmatter key. Also run
# in CI so a new page can't land without one.
docs-descriptions:
	@bash scripts/check-docs-descriptions.sh


# ================= Benchmarks =================
# All bench targets accept three optional filters (handy for targeted profiling):
#   CASE=<n>                run only the case at 1-based index n (see "Running N/M" in output)
#   VARIANTS=a,b            run only the named variants (CSV, defaults to all)
#   PARAMS='k=v,k=v'        run only expansions whose parameters match all given values
#                           (values are coerced: "true"/"false" → boolean, numbers → number)
# Examples:
#   make ecs-bench CASE=3 VARIANTS=tecs
#   make ecs-bench PARAMS='count=1000,defer=true'
#   make ecs-bench CASE=12 PARAMS='count=1000,defer=true' VARIANTS=tecs
json-bench: build
	@cd benches/json-bench && BENCH_CASE="$(CASE)" BENCH_VARIANTS="$(VARIANTS)" BENCH_PARAMS="$(PARAMS)" luajit main.lua

# Set EVOLVED_PATH to point at a checkout of https://github.com/BlackMATov/evolved.lua
# (defaults to ~/projects/evolved.lua).
ecs-bench: build
	@cd benches/ecs-bench && BENCH_CASE="$(CASE)" BENCH_VARIANTS="$(VARIANTS)" BENCH_PARAMS="$(PARAMS)" luajit main.lua

snapshot-bench: build
	@cd benches/snapshot-bench && BENCH_CASE="$(CASE)" BENCH_VARIANTS="$(VARIANTS)" BENCH_PARAMS="$(PARAMS)" luajit main.lua

bitset-bench: build
	@cd benches/bitset && BENCH_CASE="$(CASE)" BENCH_VARIANTS="$(VARIANTS)" BENCH_PARAMS="$(PARAMS)" luajit main.lua

# ================= Love2D 12 (GPU Features) =================

# Auto-download Love2D 12 if missing
$(LOVE12_BIN):
	@$(MAKE) --no-print-directory download-love12

# Download Love2D 12 nightly (nightly.link wraps artifacts in a double-zip)
download-love12:
	@rm -rf $(LOVE12_DIR)
	@mkdir -p $(LOVE12_DIR)
ifeq ($(UNAME_S),Darwin)
	@echo "Downloading Love2D 12 for macOS..."
	@curl -sL -o $(LOVE12_DIR)/outer.zip $(NIGHTLY_BASE)/love-macos.zip
	@cd $(LOVE12_DIR) && unzip -q outer.zip && unzip -q love-macos.zip && rm -f outer.zip love-macos.zip
else ifeq ($(UNAME_S),Linux)
	@echo "Downloading Love2D 12 for Linux..."
	@curl -sL -o $(LOVE12_DIR)/outer.zip $(NIGHTLY_BASE)/love-linux-X64.AppImage.zip
	@cd $(LOVE12_DIR) && unzip -q outer.zip && rm -f outer.zip && mv love-* love && chmod +x love
else
	@echo "Downloading Love2D 12 for Windows..."
	@curl -sL -o $(LOVE12_DIR)/outer.zip $(NIGHTLY_BASE)/love-windows-x64.zip
	@cd $(LOVE12_DIR) && unzip -q outer.zip && rm -f outer.zip
endif
	@echo "Love2D 12 installed to $(LOVE12_DIR)/"

# Check if Love2D 12 is installed
check-love12:
	@if [ ! -f "$(LOVE12_BIN)" ]; then \
		echo "Love2D 12 not found. Run 'make download-love12' to install."; \
		exit 1; \
	fi
	@echo "Love2D 12 found at $(LOVE12_BIN)"
	@$(LOVE12_BIN) --version

system-info: $(LOVE12_BIN)
	@$(LOVE) scripts/dump_system_info.lua

help:
	@echo "Available Makefile targets:"
	@echo "  build          - Incremental build (tl gen)"
	@echo "  rebuild        - Force full rebuild (clean + compile)"
	@echo "  dev            - Install development dependencies"
	@echo "  test           - Run tests"
	@echo "  test-love      - Run Love2D integration tests (real LÖVE + MCP)"
	@echo "                   Filter with MATCH='<Lua pattern>' or FILE_MATCH='<Lua pattern>'"
	@echo "  test-no-ffi    - Run tests with FFI disabled"
	@echo "  typecheck      - Type check source files only"
	@echo "  check-examples - Type check all examples"
	@echo "  build-examples - Build all examples"
	@echo "  docs-debug     - Regenerate docs/tecs2d/debug-reference.md and docs/tecs2d/mcp/tools.md"
	@echo "  clean          - Remove build directory"
	@echo ""
	@echo "Love2D 12 (GPU features):"
	@echo "  download-love12 - Download Love2D 12 nightly (auto-runs when needed)"
	@echo "  check-love12    - Verify Love2D 12 installation"
	@echo "  system-info     - Dump system info for bug reports (copies to clipboard)"
	@echo ""
	@echo "Examples (run with 'make example-<name>'):"
	@echo "  example-text-bench   - Text rendering benchmark"
	@echo "  example-sprite-collision    - Slice-based collision demo"
	@echo "  example-assets              - Asset loading demo"
	@echo "  example-audio               - Spatial audio demo"
	@echo "  example-ball-bench          - Ball physics benchmark"
	@echo "  example-controller          - Gamepad input demo"
	@echo "  example-lighting            - Lighting & shadows stress test"
	@echo "  example-love-interop        - GPU/CPU draw interleaving demo"
	@echo "  example-orbiting-shapes     - Hierarchical transform demo"
	@echo "  example-particles           - Particle effects demo"
	@echo "  example-physics             - Physics collision demo"
	@echo "  example-physics-bench       - Physics benchmark"
	@echo "  example-shape-bench         - Shape rendering benchmark (SHAPE=rectangle|circle|ellipse|arc|line)"
	@echo "  example-sprite-bench        - Sprite rendering benchmark"
	@echo "  example-tiled     			 - Tiled map + physics collision"
	@echo "  example-transform-demo      - Transform/pivot/shader showcase"
	@echo "  example-ui                  - UI layout system demo"
	@echo "  example-layer-fx            - Per-layer shader effects demo"
	@echo "  example-material-demo       - GPU material system demo"
	@echo "  example-camera-multi           - Multi-camera demo (minimap + splitscreen)"
