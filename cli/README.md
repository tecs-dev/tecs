# tecs-cli

Command-line tool for creating, building, checking, and running fixed-layout
Tecs2D projects.

## Install

Homebrew (macOS and Linux):

```sh
brew install tecs-dev/tap/tecs-cli
```

Scoop (Windows):

```powershell
scoop bucket add tecs https://github.com/tecs-dev/scoop-bucket
scoop install tecs
```

Or use the standalone installers — macOS and Linux:

```sh
curl -fsSL https://github.com/tecs-dev/tecs-cli/releases/latest/download/install.sh | sh
```

Windows PowerShell:

```powershell
irm https://github.com/tecs-dev/tecs-cli/releases/latest/download/install.ps1 | iex
```

The first `tecs` command downloads the current LÖVE 12 nightly into the user
cache. Later commands reuse it. Lua, LuaRocks, and a compiler toolchain are not
required.

For local checkout development, build the same payload used by releases:

```sh
TECS_DIR=../tecs make build
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
tecs info
tecs new hello
tecs run
tecs build
tecs check
tecs clean
tecs agent list
tecs completions zsh
```

`tecs run` builds the project and launches it with the same cached LÖVE runtime
that hosts the CLI. `tecs build` compiles Teal source into a self-contained
`build/`. `tecs check` runs the embedded Teal compiler in-process. Pass
`--quiet` (or `-q`) to suppress progress output. `tecs --version` prints only
the CLI version; `tecs info` reports the LÖVE/LuaJIT runtime and current project.

`tecs check --json` and `tecs info --json` print machine-readable JSON on
stdout for editors, CI, and coding agents. Check output has the shape
`{"ok": boolean, "diagnostics": [{"file", "line", "column", "severity",
"kind", "message"}]}` and exits non-zero when errors are reported.

`tecs agent list` shows the guides bundled for AI coding agents, and
`tecs agent path <name>` writes one to the per-user data directory and prints
its absolute path, ready to reference from agent configuration
(`CLAUDE.md`, `AGENTS.md`, and similar).

`tecs completions bash|zsh|fish` prints a shell completion script; source its
output from your shell profile.

## Dependencies

```sh
tecs add inspect          # newest version with a source rock
tecs add inspect@2.0-1    # pin a version
tecs remove inspect
tecs update               # re-resolve every added rock (or: tecs update inspect)
```

`tecs add` vendors a pure-Lua rock from luarocks.org into
`src/vendor/share/lua/5.1/`, along with its dependencies, license files, and —
when luarocks.org publishes a `<rock>-tl-type` package — the matching Teal
type declarations, so `tecs check` keeps working. The files are meant to be
committed; `src/vendor/rocks.lua` records what was installed and why.

Rocks that need a C compiler (or any non-`builtin` build) are rejected: the
game runtime is LÖVE's LuaJIT with no toolchain, and builds must stay
self-contained. The LuaRocks client is never used — the CLI talks to
luarocks.org directly over the LÖVE runtime's HTTPS support.

## Development Commands

This command copies framework sources from a local Tecs checkout:

```sh
TECS_DIR=../tecs tecs dev
```

Run it again after changing the local framework, then run `tecs check` or
`tecs build`.

To try a local Teal compiler instead of the embedded one, point
`TECS_TEAL_DIR` at a `teal-language/tl` checkout (its generated `teal/`,
`tlcli/`, and `compat53/` Lua modules are loaded in place of the bundled
copies):

```sh
TECS_TEAL_DIR=../tl tecs check
```

## Embedded Toolchain

`tecs-cli.love` contains:

- the Teal compiler
- compatible Tecs and Tecs2D sources
- project type declarations for LuaJIT, LuaSocket, and LÖVE
- the starter template

The CLI stages the required declarations and framework sources into
`src/vendor/`; it never builds rocks and has no LuaRocks dependency. Third
party pure-Lua rocks are vendored explicitly with `tecs add`. A `TECS_DIR`
checkout can replace the embedded framework sources during development.

The repository keeps private CLI libraries in `tecs_cli/vendor/`. Teal lives
under `tecs_cli/runtime/teal/` because its canonical `teal.*`, `tlcli.*`, and
`compat53.*` modules are copied to the root of the `.love` archive. Type
declarations under `tecs_cli/runtime/types/` are copied into generated projects.

Maintainers can refresh every embedded dependency, or one group at a time:

```sh
make update-vendor
make update-teal
make update-types
make update-lua-vendor
```

The refs are declared at the top of the Makefile and can be overridden, for
example `make update-teal TEAL_REF=<commit>`.

## System Requirements

- curl
- unzip on macOS/Linux, or PowerShell `Expand-Archive` on Windows

LÖVE 12 is downloaded once per user on the first command. The cached runtime
provides the same LuaJIT and LuaSocket implementation used by the game.

## License

Licensed under the [MIT license](LICENSE). Embedded third-party components
retain their upstream license notices in `tecs_cli/runtime/licenses/`.
