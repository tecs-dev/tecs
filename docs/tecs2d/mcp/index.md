---
outline: deep
---

# Tecs MCP server

Tecs MCP connects an AI agent directly to the running game. With the debug
plugin installed, the agent and developer share the same selection, marks,
notes, freeze state, annotations, debugger commands, and capture history. The
agent can inspect what the developer points at in-game, investigate a past
moment, patch the world, replay it, and verify the result visually.

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
different port. The debug plugin is optional for the core ECS tools, but it adds
the shared in-game debugger and all registry-derived `debug_*` tools.

## Choose the right tool layer

Tecs exposes two complementary MCP surfaces:

| Surface | Use it for |
| --- | --- |
| Core MCP tools | Generic structured ECS operations: `query`, `get_entity`, `get_component_schema`, `patch_entities`, `pause`, `step`, screenshots, logs, and profiling |
| `debug_*` tools | Operator-facing runtime workflows: shared selection and notes, overlays, systems, rendering, physics probes, snapshots, rewind, diffs, recordings, and game-defined commands |

Prefer a purpose-built core tool when one exists. Use `patch_entities` for
structured component edits and `get_entity` for entity inspection. Use
`debug_*` when the action should participate in the visible debugger workflow,
target `@selection` or a mark, create an annotation, or manage a debugger
artifact.

## Investigation workflow

Start by asking for context rather than immediately mutating the game:

1. Use `screenshot` and `get_debug_context` to establish visual and operator context.
2. Inspect selected entities with `get_entity`, or locate candidates with `query` and `query_in_bounds`.
3. Use `get_component_schema` before constructing edits.
4. Read `get_logs` with `contains = "debug.events"` to follow operator actions.
5. Freeze with `pause`, inspect safely, and advance deliberately with `step`.
6. Use `debug_rewind_*`, `debug_diff`, and `debug_snapshot_*` to investigate a timeline.
7. Apply the smallest structured change with `patch_entities` or a game-defined `debug_*` command.
8. Replay and verify with a screenshot, recording, profile, or diff artifact.

Examples of useful prompts:

- "The player disappeared a few seconds ago. Compare the rewind history with now and find out why."
- "Inspect the entity I selected and explain which render state could make it invisible."
- "Rewind to before the boss attack, step toward the failure, and identify the first bad state change."
- "Fix the alignment bug and take a screenshot to verify it."
- "Profile the game for ten seconds and relate the hot systems to the entities on screen."
- "Show collision bounds, raycast through the cursor, and annotate every hit."

## Shared debugger state

`get_debug_context` is the handoff point between the developer and agent. It
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

MCP clients discover the exact live tool set through `tools/list`. Debugger
tools appear only when the debug plugin is installed; game-defined commands
registered through the debugger registry appear as `debug_<name>` tools with
generated argument schemas.

## Component serialization

For `spawn`, `query`, and `spawn_bundle` to work, components need serialization support. Most components work
automatically:

- **Table components**: Serialize all fields by default
- **FFI components**: Serialize based on field schema

Components with Love2D objects (textures, fonts) need custom `serialize`/`deserialize` functions.

See [Component serialization](/tecs/components/serialization) for details.

## Reference

- [Runtime introspection](../introspection)
- [In-game debugger](../debug)
- [MCP tools and wire responses](./tools)
- [Custom debugger commands](../custom-debug-commands)
