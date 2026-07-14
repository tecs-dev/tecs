---
name: tecs-cli
description: Drive this Tecs2D project with the tecs CLI — type-check, build, run, test, package — and the MCP bridge tools. Use for any build/test/run/package workflow.
---

# Tecs CLI workflow

Run everything from the project root (the directory with `tlconfig.lua`).

## Core loop

- `tecs check`: type-check `src/`. Run after every source edit; it must pass before finishing a
  task. Add `--json` for machine-readable diagnostics.
- `tecs build`: compile to `build/`. A running game hot-reloads a successful build automatically,
  so prefer building over restarting the game.
- `tecs run`: build, then launch the game with the cached LÖVE runtime.
- `tecs integ`: compile and run `spec/` with the bundled busted runner. See the
  integration-testing skill.
- `tecs dist [love|macos|windows]`: package the game into `dist/`. The MCP server and debugger
  disable themselves in these builds unless constructed with `{enableInDist = true}`.
- `tecs docs`: the offline mirror of the framework documentation. `tecs docs` lists the doc tree;
  `tecs docs <page>` prints a page (e.g. `tecs docs tecs2d/rendering/shapes`). Look the API up
  here instead of reading vendored sources under `src/vendor/`.

## MCP bridge

`.mcp.json` (Claude Code) and `.codex/config.toml` (Codex) run `tecs mcp`, a stdio bridge that
works even before the game exists. Prefer these MCP tools over shell commands when connected:

- Toolchain as tools: `check`, `build`, `integ`, `dist`.
- Game lifecycle: `start_game`, `stop_game`, `restart_game`, `game_status`, `game_logs`
  (the log tool still works after a crash).
- It proxies the running game's own tools.

The game's own tools (`screenshot`, `run_lua`, `cmd_*`) become callable only **after** `start_game`.
Prefer `build` over `restart_game` for code changes, since the running game hot-reloads.

Using the game tools:

- **`send_love_event`** takes a single LÖVE event plus its args: `{event = "keypressed",
  args = ["space", "space", false]}` — not an `events: [...]` array.
- **`run_lua`** runs `function(world) ... end` and **stringifies** return values, so a returned table
  becomes `"table: 0x..."`. Return a scalar or a delimited/JSON string you build yourself (e.g.
  `return table.concat({count, score}, ",")`) for structured reads.
- **Iterate entities** with `world:query({include = {Component}}):iter()` (there is no
  `world:each`); see `tecs docs tecs/queries`.
- **If the `tecs` MCP tools disconnect after `start_game`** (a client mis-reconciling the tool
  list), attach to the running game's HTTP MCP directly: `game_status` reports the port, then POST
  JSON-RPC to `http://127.0.0.1:<port>/mcp`. The `:19999` endpoint is also how you attach to a
  dist build launched with `enableInDist`.

## Dependencies

Vendor pure-Lua rocks with LuaRocks into the project tree:

```sh
luarocks install --tree src/vendor --lua-version=5.1 <rock>
```

Install the matching `<rock>-tl-type` rock too so `tecs check` keeps passing. Only pure-Lua rocks
work — the runtime is LÖVE's LuaJIT with no C toolchain. `src/vendor/` is regenerated and
gitignored, so record installed rocks somewhere repeatable.

## Facts worth knowing

- `build/tecs_buildinfo.lua` records name, timestamp, tool versions, and a `dev` flag; read it at
  runtime with `require("tecs2d.buildinfo")`.
- `TECS_MCP_PORT` picks the game's MCP port; harnesses assign a free one.
- `build/` and `src/vendor/` are generated; never edit them by hand.
