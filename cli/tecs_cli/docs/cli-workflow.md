# Tecs CLI workflow

The command loop for a Tecs project — type-check, build, run, test, package — and the MCP bridge tools. Run everything from the project root (the directory with `tlconfig.lua`).

## Core loop

- `tecs check`: type-check `src/`. Run after every source edit; it must pass before finishing a
  task. Add `--json` for machine-readable diagnostics.
- `tecs build`: compile to `build/`. A running game hot-reloads a successful build automatically,
  so prefer building over restarting the game.
- `tecs run`: build, then launch the game with the cached LÖVE runtime.
- `tecs integ`: compile and run `spec/` with the bundled busted runner. See `tecs docs testing`.
- `tecs dist [love|macos|windows]`: package the game into `dist/`. The MCP server and debugger
  disable themselves in these builds unless constructed with `{enableInDist = true}`.
- `tecs docs`: this reference. `tecs docs` lists topics; `tecs docs <topic>` prints one.

## MCP bridge

Generated projects ship `.mcp.json` (Claude Code) and `.codex/config.toml` (Codex), both running
`tecs mcp` — a stdio bridge that works even before the game exists. Prefer these MCP tools over
shell commands when connected:

- Toolchain as tools: `check`, `build`, `integ`, `dist`.
- Game lifecycle: `start_game`, `stop_game`, `restart_game`, `game_status`, `game_logs`
  (the log tool still works after a crash).
- It proxies the running game's own tools.

The game's own tools (`screenshot`, `run_lua`, `cmd_*`) become callable only **after** `start_game`.
Prefer `build` over `restart_game` for code changes, since the running game hot-reloads. The HTTP
endpoint on port 19999 is only for attaching to an already-running game (e.g. a dist build with
`enableInDist`).

## Dependencies

Vendor pure-Lua rocks with LuaRocks into the project tree, which already uses the LuaRocks layout:

```sh
luarocks install --tree src/vendor --lua-version=5.1 <rock>
```

Install the matching `<rock>-tl-type` rock too so `tecs check` keeps passing. Only pure-Lua rocks
work: the runtime is LÖVE's LuaJIT with no C toolchain. `src/vendor/` is regenerated and gitignored,
so record installed rocks somewhere repeatable and reinstall after a fresh clone.

## Facts worth knowing

- `build/tecs_buildinfo.lua` records name, timestamp, tool versions, and a `dev` flag; read it at
  runtime with `require("tecs2d.buildinfo")`.
- `TECS_MCP_PORT` picks the game's MCP port; harnesses assign a free one.
- `build/` and `src/vendor/` are generated; never edit them by hand.

See also: `tecs docs testing`, `tecs docs tecs2d-quickstart`.
