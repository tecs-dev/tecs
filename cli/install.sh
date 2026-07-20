#!/usr/bin/env bash
# Install the released launcher and CLI payload into user-owned directories.
set -euo pipefail

base="${TECS_RELEASE_BASE:-https://github.com/tecs-dev/tecs-cli/releases/latest/download}"
bin_dir="${TECS_BIN_DIR:-$HOME/.local/bin}"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/tecs-install.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "$base/tecs" -o "$tmp/tecs"
curl -fsSL "$base/tecs-cli.love" -o "$tmp/tecs-cli.love"
mkdir -p "$bin_dir"
install -m 755 "$tmp/tecs" "$bin_dir/tecs"
install -m 644 "$tmp/tecs-cli.love" "$bin_dir/tecs-cli.love"

echo "Installed tecs to $bin_dir/tecs"
case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "Add $bin_dir to PATH before running tecs." ;;
esac
