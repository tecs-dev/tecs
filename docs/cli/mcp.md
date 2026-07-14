---
description: "The tecs mcp stdio bridge exposing check, build, integ, dist, and game control tools to agents"
outline: deep
---

# MCP Bridge

`tecs mcp` runs an MCP server on stdio for agent clients. Projects created by
`tecs new` configure Claude Code (`.mcp.json`) and Codex (`.codex/config.toml`)
to use it:

```json
{
  "mcpServers": {
    "tecs": {
      "command": "tecs",
      "args": ["mcp"]
    }
  }
}
```

The bridge runs on macOS and Linux, like `tecs integ`.

## Bridge or built-in server?

There are two ways to connect an agent to a Tecs project, and they
complement each other:

- Every running game embeds its own
  [MCP server over HTTP](/tecs2d/mcp/) (`http://127.0.0.1:19999/mcp` by
  default). Connect to it directly to attach to a game that is already
  running: a play session you started yourself, or a distributed build that
  kept the server with `enableInDist`.
- `tecs mcp` wraps that server in a stdio session that exists independently
  of the game. Use it when the agent should drive the whole loop itself. It
  works from a cold checkout with nothing running, starts and restarts the
  game on demand, keeps one session alive across game restarts and crashes,
  and reports a crashed game's log tail instead of a dead connection.

## Tools

The bridge serves three groups through one session:

| Tool | Description |
| ---- | ----------- |
| `check` | Type-check `src/`; returns structured diagnostics |
| `build` | Compile to `build/`; notes that a running game hot-reloads |
| `integ` | Run `spec/` with the bundled busted runner |
| `dist` | Package the game (`love`, `macos`, or `windows` target) |
| `start_game` | Build, then launch the game with its MCP server on a free port |
| `stop_game` | Graceful quit over MCP, then signals |
| `restart_game` | Stop, rebuild, start; prefer `build` for code changes |
| `game_status` | Running state, port, pid, build metadata, log tail |
| `game_logs` | Captured game output; survives crashes |

Every tool of the running game is proxied through the same session:
`screenshot`, `sample_pixels`, `send_love_event`, `run_lua`, `get_logs`, and
the [`cmd_*` debugger commands](/tecs2d/mcp/tools). The game's kernel tools
are listed before the first launch, and the bridge announces the full list
with a `tools/list_changed` notification once the game is up.

Each launch gets a free port through `TECS_MCP_PORT`, so several projects can
run bridges at once without conflicts.
