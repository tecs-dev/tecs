#!/usr/bin/env bash
# Bundle dist/ into the versioned archives consumed by package managers
# (Homebrew tarball, Scoop zip). Run scripts/build_love.sh first.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dist="$root/dist"
version="$(sed -n 's/^return "\([^"]*\)"/\1/p' "$root/tecs_cli/version.lua")"

if [ -z "$version" ]; then
    echo "package_dist: could not read VERSION from tecs_cli/version.lua" >&2
    exit 1
fi
for file in tecs tecs.cmd tecs.ps1 tecs-cli.love LICENSE; do
    if [ ! -f "$dist/$file" ]; then
        echo "package_dist: missing dist/$file; run scripts/build_love.sh first" >&2
        exit 1
    fi
done

tarball="$dist/tecs-cli-$version.tar.gz"
zipfile="$dist/tecs-cli-$version-windows.zip"
rm -f "$tarball" "$zipfile"
tar -czf "$tarball" -C "$dist" tecs tecs-cli.love LICENSE
(cd "$dist" && zip -q -X "$(basename "$zipfile")" tecs.cmd tecs.ps1 tecs-cli.love LICENSE)
echo "$tarball"
echo "$zipfile"
