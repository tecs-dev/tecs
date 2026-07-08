# tecs-cli

Command-line tool for creating, building, checking, and running fixed-layout
Tecs2D projects.

## Install

Tecs targets LuaJIT, so install with a LuaRocks tree configured for LuaJIT
(Lua 5.1):

```sh
luarocks --lua-version=5.1 install tecs-cli
```

If your shell cannot find `tecs` after installing with LuaRocks, add your
LuaRocks user bin directory to `PATH`. On Unix-like shells this is usually:

```sh
eval "$(luarocks path --bin)"
```

For local checkout development:

```sh
luarocks --lua-version=5.1 make tecs-cli-0.1.0-1.rockspec
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

`tecs run` builds the project and launches Love2D. `tecs build` compiles Teal
source into `build/` and stages vendored runtime files. `tecs check` runs the
Teal type checker. Pass `--quiet` (or `-q`) to any command to suppress
progress output.

## Development Commands

These commands work against a local Tecs checkout, found via `TECS_DIR` or a
sibling `../tecs` directory:

```sh
tecs dev        # copy local Tecs/Tecs2D sources into src/vendor/ for iteration
tecs sync-tecs  # reinstall Tecs/Tecs2D into src/vendor/ from local rockspecs
```

## Project Dependencies

The CLI installs project-local dependencies under `src/vendor/`:

- pinned Teal compiler
- `tecs`
- `tecs2d`

If `TECS_DIR` is set, or if `../tecs` exists, the CLI can use that local checkout
for development commands. Otherwise it installs `tecs` and `tecs2d` with
LuaRocks.

## System Requirements

- LuaJIT and LuaRocks
- Git
- curl
- unzip on macOS/Linux, or PowerShell `Expand-Archive` on Windows
- a C compiler toolchain for LuaRocks native dependencies

Love2D 12 is downloaded per project with `tecs love12` or on first `tecs run`.

## License

Licensed under either of:

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))
