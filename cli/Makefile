TEAL_REF ?= main
COMPAT53_REF ?= v0.14.4
TEAL_TYPES_REF ?= master
LOVE_TYPES_REF ?= main
ARGPARSE_REF ?= 0.7.2
ANSICOLORS_REF ?= v1.0.2

.PHONY: build test check update-vendor update-teal update-types update-lua-vendor clean

build:
	./scripts/build_love.sh

test:
	luajit spec/run.lua

check: test build

update-vendor: update-teal update-types update-lua-vendor

update-teal:
	TEAL_REF="$(TEAL_REF)" COMPAT53_REF="$(COMPAT53_REF)" ./scripts/update_vendor.sh teal

update-types:
	TEAL_TYPES_REF="$(TEAL_TYPES_REF)" LOVE_TYPES_REF="$(LOVE_TYPES_REF)" ./scripts/update_vendor.sh types

update-lua-vendor:
	ARGPARSE_REF="$(ARGPARSE_REF)" ANSICOLORS_REF="$(ANSICOLORS_REF)" ./scripts/update_vendor.sh lua

clean:
	rm -rf build dist
