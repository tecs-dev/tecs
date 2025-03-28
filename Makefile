.PHONY: all build test test-no-ffi clean dev compile check find-busted trim-whitespace \
	coverage coverage-report coverage-xml coverage-lcov coverage-html \
	tecs_controller-example tecs_assets-example tecs_render-example ballbench-example \
	newrock test-rockspec test-install typecheck rebuild help rockspecs docs

.SILENT: clean test test-no-ffi find-busted

VERSION=0.2.0
LUA_CMD ?= luajit

# Paths
SPEC_DIR=./spec
LUA_DIR=./build
TL_SRC_DIR=./src
LUAROCKS_BIN ?= $(HOME)/.luarocks/bin
LUAROCKS_LUA ?= $(HOME)/.luarocks/share/lua/5.1
LUAROCKS_CLIB ?= $(HOME)/.luarocks/lib/lua/5.1

# Commands - use which to find busted in PATH, fallback to LUAROCKS_BIN
BUSTED_CMD ?= $(shell which busted 2>/dev/null || echo "$(LUAROCKS_BIN)/busted")
LUACOV_COBERTURA_CMD ?= $(shell which luacov-cobertura 2>/dev/null || echo "$(LUAROCKS_BIN)/luacov-cobertura")

# Common LUA paths for coverage targets
COVERAGE_LUA_PATH="../$(LUA_DIR)/?.lua;../$(LUA_DIR)/?/init.lua;$(LUAROCKS_LUA)/?.lua;$(LUAROCKS_LUA)/?/init.lua;"
COVERAGE_LUA_CPATH="$(LUAROCKS_CLIB)/?.so;"

# Source files for dependency tracking
SOURCE_TL := $(shell find $(TL_SRC_DIR) -name "*.tl" 2>/dev/null || true)

# Test support files that need to be compiled
TEST_HELPERS=spec/tecs/test_helpers.tl
TEST_MOCKS=spec/love2d/love2d_mock.tl \
          spec/love2d/tecs2d_input_mock.tl

# Find all test spec files
TEST_SPECS := $(shell find spec -name "*_spec.tl" 2>/dev/null || true)

# Generated test files (put in separate dir to avoid cyan --prune)
TEST_BUILD_DIR=$(LUA_DIR)/test_deps
TEST_HELPER_LUA=$(TEST_BUILD_DIR)/spec/tecs/test_helpers.lua
TEST_MOCK_LUA=$(patsubst spec/%.tl,$(TEST_BUILD_DIR)/spec/%.lua,$(TEST_MOCKS))
TEST_SPEC_LUA=$(patsubst spec/%.tl,$(TEST_BUILD_DIR)/spec/%.lua,$(TEST_SPECS))

# All compiled test dependencies
TEST_DEPS_LUA=$(TEST_HELPER_LUA) $(TEST_MOCK_LUA) $(TEST_SPEC_LUA)

all: build test

build: compile

dev:
	@echo "Installing development dependencies..."
	luarocks install --local --lua-version=5.1 busted
	luarocks install --local --lua-version=5.1 cyan
	luarocks install --local --lua-version=5.1 --server=https://luarocks.org/dev busted-tl
	luarocks install --local --lua-version=5.1 luacov
	luarocks install --local --lua-version=5.1 luacov-cobertura
	luarocks install --local --lua-version=5.1 luacov-reporter-lcov
	luarocks install --local --lua-version=5.1 luafilesystem
	@echo "Development dependencies installed!"

find-busted:
	luarocks path --lr-path
	echo "Checking possible Busted locations:"
	find ~/.luarocks -name "runner.lua" | grep busted

check:
	cyan check src/**/*.tl

# Use cyan's built-in incremental compilation with auto-prune
compile: $(SOURCE_TL) tlconfig.lua
	@mkdir -p $(LUA_DIR)
	cyan build --no-script

# Force full rebuild
rebuild: clean compile

# Compile test helpers individually (in separate dir to avoid cyan --prune)
$(TEST_HELPER_LUA): $(TEST_HELPERS) | $(LUA_DIR)
	@echo "Compiling test helpers..."
	@mkdir -p $(TEST_BUILD_DIR)/spec/tecs
	@tl check $(TEST_HELPERS) >/dev/null 2>&1 || (echo "ERROR: $(TEST_HELPERS) has type errors" && tl check $(TEST_HELPERS) && exit 1)
	@tl gen $(TEST_HELPERS) -o $(TEST_HELPER_LUA)

# Compile test mocks individually (in separate dir to avoid cyan --prune)
$(TEST_BUILD_DIR)/spec/%.lua: spec/%.tl | $(LUA_DIR)
	@echo "Compiling test mock: $<"
	@mkdir -p $(dir $@)
	@tl check "$<" >/dev/null 2>&1 || (echo "ERROR: $< has type errors" && tl check "$<" && exit 1)
	@tl gen "$<" -o "$@"


# Test type checking is handled during compilation; tests run on pre-compiled Lua

test: $(TEST_DEPS_LUA)
	@echo "Running tests..."
	LUA_PATH="$(LUA_DIR)/?.lua;$(LUA_DIR)/?/init.lua;$(TEST_BUILD_DIR)/?.lua;$(TEST_BUILD_DIR)/?/init.lua;;" LUA=$(LUA_CMD) $(BUSTED_CMD) $(TEST_BUILD_DIR)

# Run tests with FFI disabled using normal Lua, not luajit
test-no-ffi:
	@echo "Running tests with FFI disabled (fallback mode)..."
	TECS_DISABLE_FFI=1 LUA_CMD=lua $(MAKE) test

clean:
	rm -rf build

trim-whitespace:
	@find src spec -name "*.tl" -exec sed -i.bak 's/[[:space:]]*$$//' {} \;
	@find src spec -name "*.tl.bak" -exec rm {} \;
	@find docs -name "*.md" -exec sed -i.bak 's/[[:space:]]*$$//' {} \;
	@find docs -name "*.md.bak" -exec rm {} \;
	@echo "Trimmed trailing whitespace from .tl and .md files"

# Run tests with coverage collection
coverage: clean $(TEST_DEPS_LUA)
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

# ================= Test Installation =================
test-install: build
	@echo "Setting up test installation in build/test-install..."
	@rm -rf build/test-install
	@mkdir -p build/test-install
	@echo "Copying install-example..."
	@cp -r examples/install-example/* build/test-install/
	@echo "Setting up vendor directory structure..."
	@mkdir -p build/test-install/src/vendor/share/lua/5.1
	@echo "Copying compiled Tecs modules to vendor..."
	@cp -r build/tecs build/test-install/src/vendor/share/lua/5.1/
	@cp -r build/tecs2d build/test-install/src/vendor/share/lua/5.1/
	@cp -r build/tecs_render build/test-install/src/vendor/share/lua/5.1/
	@cp -r build/tecs_controller build/test-install/src/vendor/share/lua/5.1/
	@cp -r build/tecs_assets build/test-install/src/vendor/share/lua/5.1/
	@echo "Compiling Teal files..."
	@cd build/test-install && tl gen src/main.tl -o build/main.lua
	@cd build/test-install && tl gen src/conf.tl -o build/conf.lua
	@echo "Copying assets to build directory..."
	@cp -r build/test-install/assets build/test-install/build/ 2>/dev/null || true
	@echo "Done! Running Love2D from build directory..."
	@cd build/test-install/build && love .

# ================= LuaRocks =================
newrock:
	@if [ -z "$(ROCK)" ] || [ -z "$(NEW_VERSION)" ]; then \
		echo "Usage: make newrock ROCK=<rockspec> NEW_VERSION=<version>"; \
		echo "Example: make newrock ROCK=tecs.tl NEW_VERSION=0.3.0"; \
		exit 1; \
	fi
	@if [ ! -f "rockspec-templates/$(ROCK)-dev-1.rockspec.template" ]; then \
		echo "Error: rockspec-templates/$(ROCK)-dev-1.rockspec.template not found"; \
		exit 1; \
	fi
	luarocks new_version --dir build --tag=v$(NEW_VERSION) rockspec-templates/$(ROCK)-dev-1.rockspec.template $(NEW_VERSION)

# Test local rockspec installation
test-rockspec: build
	@echo "Testing rockspec syntax validation..."
	@echo "Validating tecs.tl..."
	@luarocks lint build/tecs.tl-dev-1.rockspec
	@echo "Validating tecs2d.tl..."
	@luarocks lint build/tecs2d.tl-dev-1.rockspec
	@echo "Validating tecs_render.tl..."
	@luarocks lint build/tecs_render.tl-dev-1.rockspec
	@echo "Validating tecs_controller.tl..."
	@luarocks lint build/tecs_controller.tl-dev-1.rockspec
	@echo "Validating tecs_assets.tl..."
	@luarocks lint build/tecs_assets.tl-dev-1.rockspec
	@echo "All rockspecs validated successfully!"
	@echo ""
	@echo "Note: For full installation testing, update the source.url field in rockspecs"
	@echo "to point to your actual git repository, then run luarocks install locally."

# ================= Examples =================
tecs-controller-example: build
	@./examples/tecs_controller/run.sh

tecs-assets-example: build
	@./examples/tecs_assets/run.sh

tecs-render-example: build
	@./examples/tecs_render/run.sh

ballbench-example: build
	@./examples/ballbench/run.sh $(ENTITIES) $(DRAW)

typecheck:
	@echo "Type checking source files..."
	@cyan check src/**/*.tl

# Generate rockspecs from current file structure into build/
rockspecs: build
	@echo "Generating rockspecs from file discovery..."
	@tl run cyan-plugins/generate_rockspecs.tl

# Generate documentation using tealdoc (TODO: Doesn't really work for Tecs at the moment)
docs: build
	@echo "Generating tealdoc documentation..."
	@mkdir -p build/docs
	@tealdoc html src/tecs/init.tl src/tecs/types.tl -o build/docs/tecs.html
	@echo "Documentation generated in build/docs/"

help:
	@echo "Available Makefile targets:"
	@echo "  build       - Incremental build (cyan only)"
	@echo "  rebuild     - Force full rebuild (clean + compile)"
	@echo "  test        - Run tests with parallel compilation"
	@echo "  test-no-ffi - Run tests with FFI disabled"
	@echo "  typecheck   - Type check source files only"
	@echo "  check       - Type check source files only"
	@echo "  rockspecs   - Generate rockspecs from file structure"
	@echo "  docs        - Generate tealdoc documentation"
	@echo "  clean       - Remove build directory"
	@echo ""
	@echo "Parallel builds:"
	@echo "  make -j4 test  - Recommended for fast testing"
	@echo "  make -j8 test  - Max parallelism"
	@echo ""
	@echo "Optimizations:"
	@echo "  ✓ Incremental compilation"
	@echo "  ✓ Parallel test dependencies"
	@echo "  ✓ Busted handles test type checking automatically"