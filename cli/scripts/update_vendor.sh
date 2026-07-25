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
    cp -R "$types/types/busted/"* "$root/tecs_cli/runtime/types/"
    cp -R "$types/types/luassert/"* "$root/tecs_cli/runtime/types/"
    cp "$love_types/love2d.d.tl" "$root/tecs_cli/runtime/types/love2d.d.tl"
    cp "$types/LICENSE" "$root/tecs_cli/runtime/licenses/luajit-tl-type-LICENSE"
    cp "$types/LICENSE" "$root/tecs_cli/runtime/licenses/luasocket-tl-type-LICENSE"
    cp "$love_types/LICENSE" "$root/tecs_cli/runtime/licenses/tecs-love2d-tl-type-LICENSE"
}

# Vendor busted and its pure-Lua dependencies for `tecs integ`. The C
# dependencies are never installed: lfs, system, and term are shimmed over
# the Love runtime inside the CLI.
update_busted() {
    local tree="$tmp/busted-tree"
    local rocks=(
        "lua_cliargs ${CLIARGS_REF:-3.0.2-1}"
        "dkjson ${DKJSON_REF:-2.8-1}"
        "say ${SAY_REF:-1.4.1-3}"
        "luassert ${LUASSERT_REF:-1.9.0-1}"
        "penlight ${PENLIGHT_REF:-1.14.0-3}"
        "mediator_lua ${MEDIATOR_REF:-1.1.2-0}"
        "busted ${BUSTED_REF:-2.2.0-1}"
    )
    for entry in "${rocks[@]}"; do
        # shellcheck disable=SC2086
        luarocks install --tree "$tree" --lua-version=5.1 --deps-mode=none $entry
    done

    rm -rf "$root/tecs_cli/runtime/busted"
    mkdir -p "$root/tecs_cli/runtime/busted"
    cp -R "$tree/share/lua/5.1/"* "$root/tecs_cli/runtime/busted/"
    # Shimmed at runtime; never vendor whatever fragments the rocks staged.
    rm -rf "$root/tecs_cli/runtime/busted/system" "$root/tecs_cli/runtime/busted/term"

    local rockdir="$tree/lib/luarocks/rocks-5.1"
    for rock in busted luassert say penlight lua_cliargs mediator_lua dkjson; do
        local license
        license="$(find "$rockdir/$rock" \( -iname 'LICENSE*' -o -iname 'COPYRIGHT*' -o -iname 'COPYING*' \) -type f 2>/dev/null | head -1)"
        if [ -n "$license" ]; then
            cp "$license" "$root/tecs_cli/runtime/licenses/$rock-$(basename "$license")"
        fi
    done
    # Rocks whose trees ship no license file; fetch from the upstream repos.
    curl -fsSL https://raw.githubusercontent.com/lunarmodules/Penlight/master/LICENSE.md \
        -o "$root/tecs_cli/runtime/licenses/penlight-LICENSE.md"
    curl -fsSL https://raw.githubusercontent.com/lunarmodules/say/master/LICENSE \
        -o "$root/tecs_cli/runtime/licenses/say-LICENSE"
    curl -fsSL https://raw.githubusercontent.com/lunarmodules/lua_cliargs/master/LICENSE \
        -o "$root/tecs_cli/runtime/licenses/lua_cliargs-LICENSE"
    # mediator_lua publishes no license file; its rockspec declares MIT and
    # dkjson embeds its MIT notice in the module header.
    printf 'mediator_lua declares the MIT license in its rockspec\n(https://luarocks.org/modules/olivine-labs/mediator_lua).\n' \
        > "$root/tecs_cli/runtime/licenses/mediator_lua-LICENSE-NOTE"
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
        update_busted
        ;;
    teal) update_teal ;;
    types) update_types ;;
    lua) update_lua_vendor ;;
    busted) update_busted ;;
    *)
        echo "usage: $0 [all|teal|types|lua|busted]" >&2
        exit 2
        ;;
esac
