# tecs-cli

Command-line tool for creating, building, checking, and running fixed-layout
Tecs2D projects.

## Install

macOS and Linux:

```sh
curl -fsSL https://github.com/tecs-dev/tecs-cli/releases/latest/download/install.sh | sh
```

Windows PowerShell:

```powershell
irm https://github.com/tecs-dev/tecs-cli/releases/latest/download/install.ps1 | iex
```

The first `tecs` command downloads the tested LÖVE 12 runtime into the user
cache. Later commands reuse it. Lua, LuaRocks, and a compiler toolchain are not
required.

For local checkout development, build the same payload used by releases:

```sh
TECS_DIR=../tecs scripts/build_love.sh
TECS_CLI_LOVE="$PWD/dist/tecs-cli.love" launcher/tecs --version
```

## Create A Project

```sh
tecs new hello
cd hello
tecs run
```

`tecs new` creates a complete starter project with:

- `src/main.tl`
- `src/conf.tl`
- `tlconfig.lua`
- bundled Love2D/Teal type definitions
- empty `assets/`

The default app renders `Hello Tecs2D!`.

## Commands

```sh
tecs help
tecs new hello
tecs run
tecs build
tecs check
tecs clean
tecs wipe-clean
tecs love12
```

`tecs run` builds the project and launches it with the same cached LÖVE runtime
that hosts the CLI. `tecs build` compiles Teal source into a self-contained
`build/`. `tecs check` runs the embedded Teal compiler in-process. Pass
`--quiet` (or `-q`) to suppress progress output.

## Development Commands

These commands work against a local Tecs checkout, found via `TECS_DIR` or a
sibling `../tecs` directory:

```sh
tecs dev        # copy local Tecs/Tecs2D sources into src/vendor/ for iteration
tecs sync-tecs  # reinstall Tecs/Tecs2D into src/vendor/ from local rockspecs
```

## Embedded Toolchain

`tecs-cli.love` contains:

- the Teal compiler
- compatible Tecs and Tecs2D sources
- LuaJIT, LuaSocket, LÖVE, and project type declarations
- the starter template

The CLI stages the required declarations and framework sources into
`src/vendor/`; it does not resolve or build rocks at runtime. A `TECS_DIR`
checkout can replace the embedded framework sources during development.

## System Requirements

- curl
- unzip on macOS/Linux, or PowerShell `Expand-Archive` on Windows

LÖVE 12 is downloaded once per user on the first command. The cached runtime
provides the same LuaJIT and LuaSocket implementation used by the game.

## License

Licensed under either of:

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))
