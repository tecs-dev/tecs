---
description: "Setting up the tecs2d.mcp server, kernel versus cmd_* tool layers, shared cmd_context state, and the agent investigation workflow"
outline: deep
---

# Tecs MCP server

Tecs MCP connects an AI agent to the running game. With the debug plugin
installed, the agent and developer share the same selection, marks, notes,
freeze state, debugger commands, isolated debugger-world ID, and capture history.

Read [Runtime introspection](../introspection) for the complete human-agent
debugging model. This page covers setup and the MCP workflow.

## Setup

Install MCP together with the debug plugin for the full introspection surface:

```teal
local mcp = require("tecs2d.mcp")

world:addPlugin(mcp.new())
world:addPlugin(require("tecs2d.debug").new())
```

MCP listens on port `19999` by default. Pass `mcp.new({port = 12345})` to use a
different port. Without an explicit port, the `TECS_MCP_PORT` environment
variable is honored, which is how test and agent harnesses assign free ports.

::: tip Connecting through the CLI
Agent clients usually reach this server through the
[Tecs CLI's MCP bridge](/cli/mcp) (`tecs mcp`): a stdio session that starts
and restarts the game itself, adds toolchain tools, and proxies everything
documented here. Connect to the HTTP endpoint directly when attaching to a
game that is already running.
::: The MCP plugin ensures the headless debugger core, so the
registry-derived `cmd_*` tools work in every session; the debug plugin adds the
shared in-game overlay on top of the same state.

## Choose the right tool layer

Tecs exposes two MCP tool layers:

| Surface | Use it for |
| --- | --- |
| Kernel tools | Transport-level operations: `ping`, `screenshot`, `sample_pixels`, `send_love_event`, `run_lua`, and `get_logs` |
| `cmd_*` tools | Everything else, projected from the debugger command registry: queries and edits, shared selection and notes, overlays, systems, rendering, physics probes, snapshots, rewind, diffs, recordings, and game-defined commands |

Prefer a structured `cmd_*` tool when one covers the operation. Use `cmd_set`
and `cmd_modify` for component edits, `cmd_info` for entity inspection, and
`cmd_query` when selecting entities by component expression; fall back to
`run_lua` only when no command fits. MCP clients discover the exact live
surface through the standard `tools/list` request.

## Investigation workflow

Start by asking for context rather than immediately mutating the game:

1. Use `screenshot` and `cmd_context` to establish visual and operator context.
2. Locate candidates with `cmd_query`, then inspect the selection with `cmd_info`.
3. Use `cmd_components_info` before constructing edits.
4. Read `get_logs` with `contains = "debug.events"` to follow operator actions.
5. Open the debugger to suspend gameplay, then advance deliberately with `cmd_step`.
6. Use `cmd_rewind_*`, `cmd_diff`, and `cmd_snapshot_*` to investigate a timeline.
7. Apply the smallest structured change with `cmd_set`, `cmd_modify`, or a game-defined `cmd_*` command.
8. Replay and verify with a screenshot, recording, profile, or diff artifact.

Examples of useful prompts:

- "The player disappeared a few seconds ago. Compare the rewind history with now and find out why."
- "Inspect the entity I selected and explain which render state could make it invisible."
- "Rewind to before the boss attack, step toward the failure, and identify the first bad state change."
- "Fix the alignment bug and take a screenshot to verify it."
- "Profile the game for ten seconds and relate the hot systems to the entities on screen."
- "Show collision bounds, raycast through the cursor, and annotate every hit."

## Shared debugger state

`cmd_context` is the handoff point between the developer and agent. It
includes selection, marks, notes, mouse and camera coordinates, frozen state,
visible overlays, rewind status, and recent artifacts. Debugger commands called
through MCP update that same state and produce the same on-screen effects as
typed commands.

Every operator action is also logged under `tecs2d.debug.events`. Poll
`get_logs` with a sequence cursor to follow changes without repeatedly shipping
the whole history:

```json
{"after":213,"contains":"debug.events"}
```

## Connecting with Claude Code

Add this to your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "tecs": {
      "type": "http",
      "url": "http://localhost:19999/mcp"
    }
  }
}
```

If you used a custom port, update the URL to match. The game must be running before Claude Code can connect.
If you restart the game, use `/mcp` in Claude Code to reconnect.

MCP clients discover the exact live tool set through `tools/list`. It combines
the kernel tools with every command currently registered in the debugger
registry; game-defined commands appear as `cmd_<name>` tools with generated
argument schemas.

## Component serialization

For `cmd_spawn` and the entity inspection/edit commands to work, components
need serialization support. Most components work automatically:

- **Table components**: Serialize all fields by default
- **FFI components**: Serialize based on field schema

Components with Love2D objects (textures, fonts) need custom `serialize`/`deserialize` functions.

See [Component serialization](/tecs/components/serialization) for details.

## Reference

- [Runtime introspection](../introspection)
- [In-game debugger](../debug)
- [MCP tools and wire responses](./tools)
- [Custom debugger commands](../custom-debug-commands)
