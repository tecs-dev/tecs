# Tecs CLI Project Guide

## Overview

This repository builds the cross-platform `tecs` command for creating,
checking, building, and running Tecs2D projects. The distributed CLI is a
headless LÖVE 12 application, not a LuaRocks package. Its launcher downloads a
LÖVE 12 nightly into the user cache and executes `tecs-cli.love` with the
same LuaJIT used by games.

## Key Commands

```sh
make build              # Assemble dist/tecs-cli.love and launcher/install files
make package            # Build, then bundle dist/ into versioned release archives
make lint               # Check authored Lua files with Luacheck
make test               # Run the Lua CLI unit tests
make check              # Test and build the release payload
make update-vendor      # Refresh every embedded third-party dependency
make update-teal        # Refresh Teal and compat53
make update-types       # Refresh LuaJIT, LuaSocket, and LÖVE type declarations
make update-lua-vendor  # Refresh argparse and ansicolors
make clean              # Remove build/ and dist/
```

## Repository Layout

- `tecs_cli/cli.lua`: command parsing and implementation.
- `tecs_cli/templates/default/`: source copied by `tecs new`.
- `tecs_cli/agents/`: agent guides served by `tecs agent`.
- `tecs_cli/vendor/`: private CLI Lua modules.
- `tecs_cli/runtime/teal/`: canonical `teal.*`, `tlcli.*`, and `compat53.*` modules.
- `tecs_cli/runtime/types/`: declarations copied into generated projects.
- `loveapp/`: headless LÖVE entry point and configuration.
- `launcher/`: macOS/Linux shell and Windows PowerShell/cmd launchers.
- `scripts/`: payload assembly and dependency refresh scripts.
- `spec/`: CLI unit tests.

## Distribution Model

- Do not add a CLI rockspec or runtime dependency on Lua, LuaRocks, or a C
  compiler. The release consists of `tecs-cli.love`, launchers, installers,
  and versioned archives for package managers (Homebrew tarball, Scoop zip).
- Keep the LÖVE application headless. CLI launchers set dummy SDL video/audio
  drivers; `tecs run` clears them before starting the user's game.
- Preserve macOS, Linux, and Windows behavior. CI must prove a cold-cache
  `--version`, `info`, `new`, `check`, and `build` flow on all three platforms.
- Post-publication smoke CI must repeat that flow using the exact assets from
  the tagged GitHub Release.
- The final game build is self-contained. Framework runtime modules and built-in
  assets belong under `build/`; compiler inputs and metadata do not.

## Development Guidelines

- Add or update tests for command behavior and path handling.
- Run `make check` before committing.
- Use four-space indentation in Lua and keep functions focused.
- Every file in `launcher/` and `scripts/`, plus `loveapp/main.lua`, needs a
  concise top-level comment describing its role.
- Keep vendored dependency licenses under `tecs_cli/runtime/licenses/`.
- Update `README.md` and this guide when commands or distribution behavior change.
- Keep `CHANGELOG.md` versioned and verify a release tag matches `VERSION`.
