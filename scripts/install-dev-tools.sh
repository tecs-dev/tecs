#!/bin/sh

set -eu

: "${TL_REF:?Run this through cargo xtask dev-tools}"
: "${CERULEAN_REF:?Run this through cargo xtask dev-tools}"
: "${TEALDOC_REF:?Run this through cargo xtask dev-tools}"
: "${BUSTED_VERSION:?Run this through cargo xtask dev-tools}"
: "${LUAJIT_TYPES_VERSION:?Run this through cargo xtask dev-tools}"
: "${BUSTED_TYPES_VERSION:?Run this through cargo xtask dev-tools}"
: "${LUASSERT_TYPES_VERSION:?Run this through cargo xtask dev-tools}"
: "${SCINTILLUA_REF:?Run this through cargo xtask dev-tools}"

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
vendor="$repo/vendor"
licenses="$vendor/licenses"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tecs-dev-tools.XXXXXX")

cleanup() {
    rm -rf "$scratch"
}
trap cleanup EXIT HUP INT TERM

git clone --quiet https://github.com/teal-language/tl.git "$scratch/tl"
git -C "$scratch/tl" checkout --quiet --detach "$TL_REF"
install -d "$licenses/teal"
install -m 0644 "$scratch/tl/LICENSE" "$licenses/teal/LICENSE"
(
    cd "$scratch/tl"
    luarocks make --tree="$vendor" --lua-version=5.1 tl-dev-2.rockspec
)

git clone --quiet https://github.com/mtdowling/cerulean.git "$scratch/cerulean"
git -C "$scratch/cerulean" checkout --quiet --detach "$CERULEAN_REF"
install -d "$licenses/cerulean"
install -m 0644 "$scratch/cerulean/LICENSE" "$licenses/cerulean/LICENSE"
install -m 0644 \
    "$scratch/cerulean/LICENSES/MIT-teal.txt" \
    "$licenses/cerulean/MIT-teal.txt"
PATH="$vendor/bin:$PATH" make --directory="$scratch/cerulean" compile
(
    cd "$scratch/cerulean"
    luarocks make --tree="$vendor" --lua-version=5.1 cerulean-dev-1.rockspec
)

git clone --quiet https://github.com/teal-language/tealdoc.git "$scratch/tealdoc"
git -C "$scratch/tealdoc" checkout --quiet --detach "$TEALDOC_REF"
PATH="$vendor/bin:$PATH" make --directory="$scratch/tealdoc" build
install -d "$licenses/tealdoc"
install -m 0644 "$scratch/tealdoc/LICENSE" "$licenses/tealdoc/LICENSE"
(
    cd "$scratch/tealdoc"
    luarocks make --tree="$vendor" --lua-version=5.1 tealdoc-dev-1.rockspec
)
luarocks install \
    --tree="$vendor" \
    --lua-version=5.1 \
    busted \
    "$BUSTED_VERSION"

# LuaRocks' generated launcher prepends this tree and then loads
# `luarocks.loader`, which replaces that path from the system configuration.
# The checkout-local modules consequently disappear before Busted starts.
# Install a relocatable launcher that names the tree directly and does not
# involve the loader.
cat >"$vendor/bin/busted" <<EOF
#!/bin/sh

set -eu

vendor=\$(CDPATH= cd -- "\$(dirname -- "\$0")/.." && pwd)
LUA_PATH="\$vendor/share/lua/5.1/?.lua;\$vendor/share/lua/5.1/?/init.lua;;\${LUA_PATH:-}"
LUA_CPATH="\$vendor/lib/lua/5.1/?.so;;\${LUA_CPATH:-}"
export LUA_PATH LUA_CPATH

exec luajit "\$vendor/lib/luarocks/rocks-5.1/busted/$BUSTED_VERSION/bin/busted" "\$@"
EOF
chmod 0755 "$vendor/bin/busted"

# Teal type definitions for the modules this tree requires from outside itself.
# The compiler reads them out of `vendor/share/lua/5.1`, which is what
# `cargo xtask check` and every `tl gen` here pass as an include directory, so a
# checkout without them fails to type-check in every file that touches the FFI
# rather than failing to find a tool. They were absent from this script for long
# enough that only checkouts with an earlier manual install could be checked at
# all, so nothing here is allowed to depend on them arriving another way.
for rock in \
    "luajit-tl-type $LUAJIT_TYPES_VERSION" \
    "busted-tl-type $BUSTED_TYPES_VERSION" \
    "luassert-tl-type $LUASSERT_TYPES_VERSION"; do
    # Word splitting is what pairs the name with its version here.
    # shellcheck disable=SC2086
    luarocks install --tree="$vendor" --lua-version=5.1 $rock
done

# The documentation site's lexers for every language that is not Teal. Pure
# Lua, so this is a checkout and a copy rather than a build: tealdoc reads them
# through `tealdoc.site.lexers` and highlights nothing extra when they are
# absent.
git clone --quiet https://github.com/orbitalquark/scintillua.git \
    "$scratch/scintillua"
git -C "$scratch/scintillua" checkout --quiet --detach "$SCINTILLUA_REF"
rm -rf "$vendor/scintillua"
install -d "$vendor/scintillua/lexers"
install -m 0644 "$scratch"/scintillua/lexers/*.lua "$vendor/scintillua/lexers/"
install -d "$licenses/scintillua"
install -m 0644 "$scratch/scintillua/LICENSE" "$licenses/scintillua/LICENSE"
