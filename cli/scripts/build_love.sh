#!/usr/bin/env bash
# Assemble the cross-platform tecs-cli.love payload and its launch/install files.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tecs_dir="${TECS_DIR:-$root/../tecs}"
stage="$root/build/loveapp"
output="$root/dist/tecs-cli.love"

if [ ! -f "$tecs_dir/src/tecs/init.tl" ] || [ ! -f "$tecs_dir/src/tecs2d/init.tl" ] \
    || [ ! -f "$tecs_dir/examples/shared/assets/tiny-font.fnt" ] \
    || [ ! -f "$tecs_dir/examples/shared/assets/tiny-font.png" ]; then
    echo "Complete Tecs checkout not found: $tecs_dir" >&2
    exit 1
fi

rm -rf "$stage"
mkdir -p "$stage/tecs_cli" "$stage/payload/framework" "$root/dist"
cp "$root/loveapp/main.lua" "$stage/main.lua"
cp "$root/loveapp/conf.lua" "$stage/conf.lua"
cp "$root/tecs_cli/cli.lua" "$stage/tecs_cli/cli.lua"
cp -R "$root/tecs_cli/templates" "$stage/tecs_cli/templates"
cp -R "$root/tecs_cli/agents" "$stage/tecs_cli/agents"
cp -R "$root/tecs_cli/vendor" "$stage/tecs_cli/vendor"
cp -R "$root/tecs_cli/runtime/teal/"* "$stage/"
mkdir -p "$stage/payload/types"
cp -R "$root/tecs_cli/runtime/types/"* "$stage/payload/types/"
cp -R "$root/tecs_cli/runtime/licenses" "$stage/payload/licenses"
cp "$root/LICENSE" "$stage/payload/licenses/tecs-cli-LICENSE"
cp -R "$tecs_dir/src/tecs" "$stage/payload/framework/tecs"
cp -R "$tecs_dir/src/tecs2d" "$stage/payload/framework/tecs2d"
mkdir -p "$stage/payload/framework/tecs2d/assets/fonts"
cp "$tecs_dir/examples/shared/assets/tiny-font.fnt" \
    "$tecs_dir/examples/shared/assets/tiny-font.png" \
    "$stage/payload/framework/tecs2d/assets/fonts/"
cp "$tecs_dir/LICENSE-MIT" "$stage/payload/licenses/tecs-LICENSE-MIT"

rm -f "$output"
if command -v zip >/dev/null 2>&1; then
    (cd "$stage" && zip -q -r "$output" .)
else
    # Stock windows-latest runners lack Info-ZIP. bsdtar ships with Windows
    # and writes standard forward-slash zip entries (Compress-Archive emits
    # entries that break directory listing inside the payload).
    output_windows="$(cygpath -w "$output")"
    (cd "$stage" && shopt -s dotglob && tar --format zip -cf "$output_windows" -- *)
fi
cp "$root/launcher/tecs" "$root/dist/tecs"
cp "$root/launcher/tecs.ps1" "$root/dist/tecs.ps1"
cp "$root/launcher/tecs.cmd" "$root/dist/tecs.cmd"
cp "$root/install.sh" "$root/dist/install.sh"
cp "$root/install.ps1" "$root/dist/install.ps1"
cp "$root/LICENSE" "$root/dist/LICENSE"
cp "$root/CHANGELOG.md" "$root/dist/CHANGELOG.md"
chmod +x "$root/dist/tecs"
chmod +x "$root/dist/install.sh"
echo "$output"
