---
name: tecs-cli
description: Drive this Tecs2D project with the tecs CLI. Use when type-checking, building, running, testing, packaging the game, or adding a Lua dependency.
---

# Tecs CLI

Every workflow in this project runs through `tecs`. Run commands from the
project root (the directory containing `tlconfig.lua`).

## Core loop

- `tecs check`: type-check `src/`. Run after every source edit; it must pass
  before finishing a task. Add `--json` for machine-readable diagnostics.
- `tecs build`: compile to `build/`. A running game hot-reloads a successful
  build automatically, so prefer build over restarting the game.
- `tecs run`: build, then launch the game with the cached LÖVE runtime.
- `tecs integ`: compile and run `spec/` with the bundled busted runner (see
  the integration-testing skill for writing specs).
- `tecs dist [love|macos|windows]`: package the game into `dist/`. The MCP
  server and debugger disable themselves in these builds unless constructed
  with `{enableInDist = true}`.

Prefer the MCP bridge tools over shell commands when connected over MCP:
`.mcp.json` runs `tecs mcp`, which exposes check/build/integ/dist plus
`start_game`, `stop_game`, `restart_game`, `game_status`, and `game_logs`,
and proxies the running game's own tools.

## Dependencies

Vendor pure-Lua rocks with LuaRocks into the project tree, which already uses
the LuaRocks layout:

```sh
luarocks install --tree src/vendor --lua-version=5.1 <rock>
```

Teal declarations for popular rocks are published as `<rock>-tl-type` rocks;
install those too so `tecs check` keeps passing. Only pure-Lua rocks work:
the game runtime is LÖVE's LuaJIT with no C toolchain. `src/vendor/` is
regenerated and gitignored, so record installed rocks somewhere repeatable
(a Makefile target or the README) and reinstall after a fresh clone.

## Facts worth knowing

- `build/tecs_buildinfo.lua` records name, timestamp, tool versions, and a
  `dev` flag; read it at runtime with `require("tecs2d.buildinfo")`.
- `TECS_MCP_PORT` picks the game's MCP port; harnesses assign it a free port.
- `build/` and `src/vendor/` are generated; never edit them by hand.
