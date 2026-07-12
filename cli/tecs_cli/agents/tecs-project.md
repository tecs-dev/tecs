# Tecs project guide for coding agents

Working guide for AI coding agents contributing to a Tecs2D game project created by `tecs new`.

## Commands

Run these from the project root (the directory containing `tlconfig.lua`):

- `tecs check`: type-check every Teal source under `src/`. Add `--json` for machine-readable diagnostics: `{"ok": boolean, "diagnostics": [{"file", "line", "column", "severity", "kind", "message"}]}`.
- `tecs build`: compile Teal to `build/`, copy assets, and stage the runtime vendor tree. Incremental; safe to rerun.
- `tecs run`: build, then launch the game with the cached LÖVE 12 runtime.
- `tecs integ`: compile `spec/**/*.tl` and run it with the bundled busted runner.
  `*_lovespec.tl` specs use `tecs2d.testing.fixture` to launch the built game under real
  LÖVE and drive it over MCP (`fixture.runLua`, `fixture.probePixels`, `fixture.eventually`).
  Not headless; macOS and Linux only.
- `tecs info --json`: CLI, LÖVE, and LuaJIT versions plus project status as JSON.
- `tecs add <rock>[@version]` / `tecs remove <rock>` / `tecs update`: vendor pure-Lua
  rocks from luarocks.org into `src/vendor/` (with Teal type declarations when a
  `<rock>-tl-type` package exists). `tecs-rocks.lua` at the project root records them
  and must be committed; `tecs check`/`tecs build` restore missing rocks from it at
  pinned versions. C rocks are rejected by design.
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

Generated projects ship ready-made client configuration: `.mcp.json` for Claude Code and `.codex/config.toml` for Codex, both pointing at that endpoint. The server only listens while the game is running.

## Environment variables

- `TECS_DIR`: path to a local Tecs framework checkout; `tecs dev` copies its sources into `src/vendor/`.
- `TECS_TEAL_DIR`: path to a local Teal compiler checkout (`teal-language/tl`) used instead of the embedded compiler.
- `TECS_CACHE_DIR`: override the LÖVE runtime cache directory.
