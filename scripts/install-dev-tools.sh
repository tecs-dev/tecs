#!/bin/sh

set -eu

: "${TL_REF:?Run this through make dev-tools}"
: "${CERULEAN_REF:?Run this through make dev-tools}"
: "${TEALDOC_REF:?Run this through make dev-tools}"

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
