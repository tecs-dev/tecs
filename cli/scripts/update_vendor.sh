#!/usr/bin/env bash
# Refresh embedded compiler, type, and private Lua dependencies from upstream.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tecs-cli-vendor.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

checkout() {
    local url="$1"
    local ref="$2"
    local target="$3"
    git init -q "$target"
    git -C "$target" remote add origin "$url"
    git -C "$target" fetch -q --depth=1 origin "$ref"
    git -C "$target" checkout -q FETCH_HEAD
}

update_teal() {
    local teal="$tmp/teal"
    local compat="$tmp/compat53"
    checkout https://github.com/teal-language/tl.git "${TEAL_REF:-main}" "$teal"
    checkout https://github.com/lunarmodules/lua-compat-5.3.git "${COMPAT53_REF:-v0.14.4}" "$compat"

    rm -rf "$root/tecs_cli/runtime/teal/teal" "$root/tecs_cli/runtime/teal/tlcli" \
        "$root/tecs_cli/runtime/teal/compat53"
    cp -R "$teal/teal" "$teal/tlcli" "$root/tecs_cli/runtime/teal/"
    cp -R "$compat/compat53" "$root/tecs_cli/runtime/teal/"
    cp "$teal/LICENSE" "$root/tecs_cli/runtime/licenses/teal-LICENSE"
    cp "$compat/LICENSE" "$root/tecs_cli/runtime/licenses/compat53-LICENSE"
}

update_types() {
    local types="$tmp/teal-types"
    local love_types="$tmp/love-types"
    checkout https://github.com/teal-language/teal-types.git "${TEAL_TYPES_REF:-master}" "$types"
    checkout https://github.com/tecs-dev/tecs-love2d-tl-type.git "${LOVE_TYPES_REF:-main}" "$love_types"

    rm -rf "$root/tecs_cli/runtime/types"
    mkdir -p "$root/tecs_cli/runtime/types"
    cp -R "$types/types/luajit/"* "$root/tecs_cli/runtime/types/"
    cp -R "$types/types/luasocket/"* "$root/tecs_cli/runtime/types/"
    cp "$love_types/love2d.d.tl" "$root/tecs_cli/runtime/types/love2d.d.tl"
    cp "$types/LICENSE" "$root/tecs_cli/runtime/licenses/luajit-tl-type-LICENSE"
    cp "$types/LICENSE" "$root/tecs_cli/runtime/licenses/luasocket-tl-type-LICENSE"
    cp "$love_types/LICENSE" "$root/tecs_cli/runtime/licenses/tecs-love2d-tl-type-LICENSE"
}

update_lua_vendor() {
    local argparse="$tmp/argparse"
    local ansicolors="$tmp/ansicolors"
    checkout https://github.com/luarocks/argparse.git "${ARGPARSE_REF:-0.7.2}" "$argparse"
    checkout https://github.com/kikito/ansicolors.lua.git "${ANSICOLORS_REF:-v1.0.2}" "$ansicolors"

    cp "$argparse/src/argparse.lua" "$root/tecs_cli/vendor/argparse.lua"
    cp "$ansicolors/ansicolors.lua" "$root/tecs_cli/vendor/ansicolors.lua"
    cp "$argparse/LICENSE" "$root/tecs_cli/runtime/licenses/argparse-LICENSE"
    cp "$ansicolors/COPYING" "$root/tecs_cli/runtime/licenses/ansicolors-COPYING"
}

case "${1:-all}" in
    all)
        update_teal
        update_types
        update_lua_vendor
        ;;
    teal) update_teal ;;
    types) update_types ;;
    lua) update_lua_vendor ;;
    *)
        echo "usage: $0 [all|teal|types|lua]" >&2
        exit 2
        ;;
esac
