# Tecs project guide for coding agents

Working guide for AI coding agents contributing to a Tecs2D game project created by `tecs new`.

## If the CLI is missing

Install it with Homebrew on macOS/Linux (`brew install tecs-dev/tap/tecs-cli`) or Scoop on
Windows (`scoop bucket add tecs https://github.com/tecs-dev/scoop-bucket`, then
`scoop install tecs`). Standalone installer scripts live on the
[tecs-cli releases page](https://github.com/tecs-dev/tecs-cli/releases/latest). No Lua,
LuaRocks, or compiler toolchain is required; the CLI downloads its LÖVE runtime on first use.

## Commands

Run these from the project root (the directory containing `tlconfig.lua`):

- `tecs check`: type-check every Teal source under `src/`. Add `--json` for machine-readable diagnostics: `{"ok": boolean, "diagnostics": [{"file", "line", "column", "severity", "kind", "message"}]}`. A diagnostic may carry a remediation `hint` — for unknown fields and signature mismatches it names the exact `tecs api` lookup; follow it instead of guessing.
- `tecs build`: compile Teal to `build/`, copy assets, and stage the runtime vendor tree. Incremental; safe to rerun.
- `tecs run`: build, then launch the game with the cached LÖVE 12 runtime.
- `tecs integ`: compile `spec/**/*.tl` and run it with the bundled busted runner.
  `*_lovespec.tl` specs use `tecs2d.testing.fixture` to launch the built game under real
  LÖVE and drive it over MCP (`fixture.runLua`, `fixture.probePixels`, `fixture.eventually`).
  Not headless; macOS and Linux only.
- `tecs dist [love|macos|windows]`: package the built game into `dist/` as a `.love`
  file, a macOS app bundle, and a fused Windows executable. The macOS bundle needs a
  POSIX host; Windows packages build anywhere.
- `tecs docs`: an offline mirror of the framework documentation, versioned with the installed
  CLI. Run `tecs docs` for the page index (a titled, described tree), then `tecs docs <page>`
  for the page you need — e.g. `tecs docs tecs2d/rendering/shapes`. `tecs docs --full` prints
  every page. Prefer this over reading vendored sources under `src/vendor/`; the CLI/testing
  workflow and conventions live in the bundled Claude Code skills.
- `tecs api <symbol>`: look up exact API signatures — the framework surface plus your own
  components/systems (type-checked on demand from `src/`). `tecs api` lists modules,
  `tecs api <module>` its symbols, `tecs api <module>.<Type>` a Teal `record` block,
  `tecs api <Type>:<method>` one method; a bare name resolves in your project. Pass several
  symbols to fan out; `--json` for structured records, `--fields <keys>` to return only the
  keys you need. **Reach for `tecs api` first for any signature, field, or constructor
  question** — it answers in tens of tokens what a full `tecs docs` page answers in thousands;
  open docs pages for concepts and how-tos, not symbol lookups. Prefer both over grepping
  `src/vendor/`.
- `tecs info --json`: CLI, LÖVE, and LuaJIT versions plus project status as JSON.
- Dependencies: vendor pure-Lua rocks with LuaRocks into the project tree
  (`luarocks install --tree src/vendor --lua-version=5.1 <rock>`, plus the matching
  `<rock>-tl-type` rock for Teal declarations). `src/vendor/` is gitignored; record
  installed rocks somewhere repeatable. C rocks do not work: the runtime has no toolchain.
- `tecs clean`: remove `build/`.

Always run `tecs check` after editing Teal sources, and make sure it passes before finishing a task.

## Project layout

- `src/`: Teal sources; `src/main.tl` is the entry point.
- `src/vendor/share/lua/5.1/`: vendored Tecs/Tecs2D framework sources and type declarations (`love2d.d.tl`, `ffi.d.tl`, `socket.d.tl`, LuaJIT types). Never edit these by hand.
- `assets/`: game assets copied into the build (`.ase`/`.aseprite` source files are excluded).
- `build/`: generated output. Never edit; regenerate with `tecs build`.
- `tlconfig.lua`: Teal configuration; marks the project root.
- `.github/workflows/ci.yml`: generated CI that installs the published CLI and runs
  `tecs check` and `tecs build` on Linux, macOS, and Windows.

## Hot reload

While the game is running, rerun `tecs build` after editing sources. A successful build refreshes `build/.tecs-reload-stamp`, and the running game snapshots, restarts, and restores its state automatically. You do not need to relaunch the game to see changes.

## MCP server

The default project wires the Tecs2D MCP plugin into the game world (`world:addPlugin(mcp.new())` in `src/main.tl`). While the game runs it serves MCP over local HTTP at `http://127.0.0.1:19999/mcp` (Streamable HTTP) with tools to screenshot the game, sample pixels, send input events, run Lua inside the game, read logs, and invoke `cmd_*` debug commands. Prefer observing the live game through MCP over guessing at runtime behavior: `tecs build`, launch with `tecs run`, then connect.

Generated projects ship ready-made client configuration: `.mcp.json` for Claude Code and `.codex/config.toml` for Codex, both running `tecs mcp` — a stdio bridge that works even before the game exists. It serves the toolchain as tools (`check`, `build`, `api`, `integ`, `dist`), manages the game process (`start_game`, `stop_game`, `restart_game`, `game_status`, `game_logs` — the log tool works after a crash), and proxies every tool of the running game. Prefer these MCP tools over shell commands when connected: call `start_game` before any game tool, and prefer `build` over `restart_game` for code changes since the running game hot-reloads. To attach to an already-running game directly (for example a dist build with `enableInDist`), use its HTTP endpoint `http://127.0.0.1:19999/mcp` instead.

`tecs docs` and `tecs api` (CLI) — and the `api` MCP tool — are available anytime, before the game is built and before `start_game`. Only in-game tools (`run_lua`, `screenshot`, `cmd_*`) require `start_game`.

**Load the `tecs-cli` skill before driving or verifying the running game.** It is the canonical playbook, and none of it should be rediscovered live: deferred-tool discovery and the `tecs call` fallback, build-identity checks, the freeze→stage→step→assert loop, `cmd_step`'s one-call events/lua form, input taping, rewind/replay, verify-by-name reads, and the screenshot budget all live there.

Two process rules apply even before the skill is loaded: **never kill the game process by hand** — `restart_game` (bridge), `tecs call cmd_restart`, or hot reload via `build` keep the prepared state, and a broad `pkill love` also kills the stdio bridge — and **check for deferred `mcp__tecs__*` tools via your tool-search mechanism** before assuming the bridge is absent.

**Always create context keys with a name** (`tecs.newKey("game.state")`): unnamed keys log a warning and are invisible to the state-reading tools the whole verification story depends on.

The MCP server and debugger disable themselves in `tecs dist` builds: `tecs build` writes a `build/tecs_buildinfo.lua` manifest (name, timestamp, tool versions, `dev` flag) that `tecs dist` packages with `dev = false`. Pass `{enableInDist = true}` to `mcp.new()` or `debug.new()` to keep them in distributed builds; read the manifest at runtime via `require("tecs2d.buildinfo")`.

## Environment variables

- `TECS_DIR`: path to a local Tecs framework checkout; `tecs dev` copies its sources into `src/vendor/`.
- `TECS_TEAL_DIR`: path to a local Teal compiler checkout (`teal-language/tl`) used instead of the embedded compiler.
- `TECS_CACHE_DIR`: override the LÖVE runtime cache directory.
