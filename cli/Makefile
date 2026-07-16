TEAL_REF ?= main
COMPAT53_REF ?= v0.14.4
TEAL_TYPES_REF ?= master
LOVE_TYPES_REF ?= main
ARGPARSE_REF ?= 0.7.2
ANSICOLORS_REF ?= v1.0.2
BUSTED_REF ?= 2.2.0-1

.PHONY: build package lint test check docs-bundle update-vendor update-teal update-types update-lua-vendor clean

build:
	./scripts/build_love.sh

package: build
	./scripts/package_dist.sh

lint:
	luacheck tecs_cli/cli.lua tecs_cli/cliApi.lua tecs_cli/cliDocs.lua \
		tecs_cli/cliFileSystem.lua tecs_cli/cliParser.lua \
		tecs_cli/apidocs.lua loveapp spec

# Build the offline docs bundle the CLI serves via `tecs docs`, from the Tecs
# docs source (needs Node). Reuses an existing docs build; run with
# GEN_DOCS_FORCE=1 to rebuild.
docs-bundle:
	./scripts/gen-docs-bundle.sh

# Specs that exercise --json and `tecs docs` need framework sources and the docs
# bundle; default to a sibling Tecs checkout like scripts/build_love.sh does.
test: docs-bundle
	TECS_DIR="$${TECS_DIR:-$(abspath ..)/tecs}" luajit spec/run.lua

check: lint test build

update-vendor: update-teal update-types update-lua-vendor update-busted

update-teal:
	TEAL_REF="$(TEAL_REF)" COMPAT53_REF="$(COMPAT53_REF)" ./scripts/update_vendor.sh teal

update-types:
	TEAL_TYPES_REF="$(TEAL_TYPES_REF)" LOVE_TYPES_REF="$(LOVE_TYPES_REF)" ./scripts/update_vendor.sh types

update-lua-vendor:
	ARGPARSE_REF="$(ARGPARSE_REF)" ANSICOLORS_REF="$(ANSICOLORS_REF)" ./scripts/update_vendor.sh lua

update-busted:
	BUSTED_REF="$(BUSTED_REF)" ./scripts/update_vendor.sh busted

clean:
	rm -rf build dist
