#!/usr/bin/env bash
set -euo pipefail

base="${TECS_RELEASE_BASE:-https://github.com/tecs-dev/tecs-cli/releases/latest/download}"
bin_dir="${TECS_BIN_DIR:-$HOME/.local/bin}"
share_dir="${TECS_SHARE_DIR:-$HOME/.local/share/tecs}"

mkdir -p "$bin_dir" "$share_dir"
curl -fsSL "$base/tecs" -o "$bin_dir/tecs"
curl -fsSL "$base/tecs-cli.love" -o "$share_dir/tecs-cli.love"
chmod +x "$bin_dir/tecs"

echo "Installed tecs to $bin_dir/tecs"
case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "Add $bin_dir to PATH before running tecs." ;;
esac
