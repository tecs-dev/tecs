#!/usr/bin/env bash
#
# Build the offline docs bundle the CLI serves via `tecs docs`, from the Tecs
# docs source. Writes tecs_cli/docs/{llms.txt,llms-full.txt} (gitignored), which
# build_love.sh vendors into the .love payload.
#
# Node is required to BUILD the CLI, never to use it. Set GEN_DOCS_FORCE=1 to
# always rebuild the docs (build_love.sh does, so releases are fresh); otherwise
# an existing docs build is reused.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tecs_dir="${TECS_DIR:-$root/../tecs}"
dist="$tecs_dir/docs/.vitepress/dist"

if [ ! -f "$tecs_dir/docs/package.json" ]; then
    echo "Tecs docs not found at $tecs_dir/docs (set TECS_DIR to a Tecs checkout)" >&2
    exit 1
fi

if [ -n "${GEN_DOCS_FORCE:-}" ] || [ ! -f "$dist/llms.txt" ]; then
    if ! command -v npm >/dev/null 2>&1; then
        echo "npm/Node is required to build the docs bundle" >&2
        exit 1
    fi
    ( cd "$tecs_dir/docs" && { [ -d node_modules ] || npm ci; } && npm run docs:build >/dev/null )
fi

mkdir -p "$root/tecs_cli/docs"
cp "$dist/llms.txt"      "$root/tecs_cli/docs/llms.txt"
cp "$dist/llms-full.txt" "$root/tecs_cli/docs/llms-full.txt"
echo "Wrote tecs_cli/docs/{llms.txt,llms-full.txt}"
