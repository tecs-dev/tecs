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

Or use the standalone installers. macOS and Linux:

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
- a GitHub Actions workflow that type-checks and builds on Linux, macOS, and
  Windows with the published CLI
- agent tooling: `AGENTS.md`/`CLAUDE.md` guidance and MCP client configuration
  for Claude Code (`.mcp.json`) and Codex (`.codex/config.toml`) pointing at
  the game's built-in MCP server. Workflow, testing, and authoring guidance is
  not committed into the project; it lives in `tecs docs`, and `AGENTS.md`
  points there so it always matches the installed CLI.

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
tecs docs
tecs api gfx.Rectangle
tecs call cmd_fetch '{"expr":"Transform"}'
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

`tecs docs` is an offline mirror of the framework documentation, versioned with
the installed CLI and vendored from the Tecs checkout at build time. `tecs docs`
prints the page index (a titled, described tree); `tecs docs <page>` prints one
page by its index path (e.g. `tecs docs tecs2d/rendering/shapes`);
`tecs docs --full` prints every page; and `tecs docs --json` prints the index as
machine-readable `{id, title, description}`. Generated projects reference
`tecs docs` from `AGENTS.md` rather than committing copies, so it never drifts.

`tecs api` looks up exact API signatures — the framework surface (generated from
the vendored framework sources and cached per CLI version, so it is always
available) plus your project's own components and systems, which it type-checks
on demand from `src/` (no build or running game needed). `tecs api`
lists modules; `tecs api <module>` lists a module's symbols; `tecs api
<module>.<Type>` renders a type as a Teal `record` block; `tecs api <Type>:<method>`
prints a single method. A bare name (`tecs api Health`) prefers your project's
own symbols — a framework symbol with the same name is listed as `also matches`.
Pass several symbols to look them all up at once
(`tecs api gfx.Rectangle world:getMut`); a miss on one still returns the others
with module-qualified `did you mean` suggestions. `--json` emits the structured records, and
`--fields <keys>` (e.g. `signature,doc,methods`) returns only those keys to save
tokens. The framework tier stays fixed with the installed CLI; the project overlay
refreshes automatically when your sources change.

`tecs call` is a built-in MCP client for the running game: `tecs call --list`
names every tool the game serves and `tecs call <tool> '<json-args>'` invokes
one, printing the JSON result. It talks to the game's local HTTP endpoint
directly (handshake included), so it works even in sessions where the stdio
bridge was never connected. `tecs info --keys` lists the running game's named
context keys.
Procedural guidance (the CLI workflow, integration testing, conventions) ships
as Claude Code skills under `.claude/skills/`.

## Testing

```sh
tecs integ
```

`tecs integ` compiles `spec/**/*.tl` and runs it with the bundled
[busted](https://lunarmodules.github.io/busted/) runner; no busted or
LuaRocks installation is required. Specs named `*_lovespec.tl` are integration
tests: through `tecs2d.testing.fixture` they launch the built game under real
LÖVE on a free MCP port and drive it live (run Lua inside the game, sample
pixels, send input). New projects include a working example in
`spec/game_lovespec.tl`. Integration runs are not headless; macOS and Linux
only.

## Serve over MCP

```sh
tecs mcp
```

`tecs mcp` runs an MCP server on stdio for agent clients (generated projects
configure Claude Code and Codex to use it). It exposes `check`, `build`,
`integ`, and `dist` as tools, manages the game process (`start_game`,
`stop_game`, `restart_game`, `game_status`, and `game_logs`, which survives
crashes), and proxies every tool of the running game's built-in MCP server —
screenshots, pixel probes, input events, `run_lua`, and the `cmd_*` debug
commands. Sessions survive game restarts, and each launch gets a free port.
macOS and Linux only, like `tecs integ`.

The bridge is not the only way in: every running game embeds its own MCP
server over HTTP (`http://127.0.0.1:19999/mcp` by default). Connect to that
directly when you want to attach to a game that is already running — a play
session, or a distributed build with `enableInDist`. Use the stdio bridge
when the agent should drive the whole loop itself: it works from a cold
checkout with nothing running, restarts the game without dropping the
session, and reports crashes with the log tail instead of a dead connection.

## Distribute

```sh
tecs dist            # .love file, macOS app bundle, and Windows executable
tecs dist windows    # or one target: love, macos, windows
```

`tecs dist` zips the self-contained `build/` into `dist/<name>.love`, fuses a
Windows executable with LÖVE's DLLs and license into
`dist/<name>-windows.zip`, and assembles a macOS app bundle with the game's
name and bundle identifier into `dist/<name>-macos.zip`. The LÖVE runtime
comes from the launcher cache when present and is downloaded once otherwise.

Windows packages build on any host. The macOS bundle needs macOS or Linux
(the app's symlinks require a POSIX filesystem), and it ships unsigned: sign
and notarize it before wide distribution. Packaged games use the same pinned
LÖVE 12 nightly the CLI runs.

Every build writes a `tecs_buildinfo.lua` module into `build/` recording the
project name, build timestamp, tool versions, and a `dev` flag; `tecs dist`
packages it with `dev = false`. The MCP server and debugger disable
themselves in distributed builds unless constructed with
`{enableInDist = true}`, and games can read the metadata through
`require("tecs2d.buildinfo")`.

`tecs completions bash|zsh|fish` prints a shell completion script. Install it
per shell:

```sh
# bash (~/.bashrc)
eval "$(tecs completions bash)"

# zsh: write to a directory on your fpath, named _tecs
tecs completions zsh > "$(brew --prefix 2>/dev/null || echo /usr/local)/share/zsh/site-functions/_tecs"

# fish
tecs completions fish > ~/.config/fish/completions/tecs.fish
```

## Dependencies

Vendor pure-Lua rocks with LuaRocks; the project tree already uses the
LuaRocks layout:

```sh
luarocks install --tree src/vendor --lua-version=5.1 inspect
luarocks install --tree src/vendor --lua-version=5.1 inspect-tl-type
```

Teal declarations for popular rocks are published as `<rock>-tl-type`
packages, so `tecs check` keeps type-checking code that requires them. Only
pure-Lua rocks work: the game runtime is LÖVE's LuaJIT with no C toolchain,
and `tecs build` prunes LuaRocks bookkeeping from the shipped game.
`src/vendor/` is regenerated and gitignored, so record installed rocks
somewhere repeatable and reinstall after a fresh clone.

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
party pure-Lua rocks can be vendored into the same tree with LuaRocks. A
`TECS_DIR` checkout can replace the embedded framework sources during
development.

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
