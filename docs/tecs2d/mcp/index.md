---
outline: deep
---

# Tecs MCP Server

Tecs MCP is a [Model Context Protocol](https://modelcontextprotocol.io/) server that lets AI assistants interact with
your running game. Connect Claude Code or other MCP-compatible tools to query entities, spawn objects, and debug your
game in real-time.

Here are some example prompts you can use with a coding agent when Tecs MCP is connected:

- "Take a screenshot and describe what you see"
- "Fix the alignment bug and take a screenshot to confirm it worked"
- "What entities exist in the game right now?"
- "Spawn 10 enemies in a circle around the player"
- "Query all entities with a Transform component"
- "What components and systems are registered?"
- "Double the size of all rectangles"
- "Remove all entities that have the Enemy component"
- "What bundles are available for spawning?"
- "Profile the game for 10 seconds and find out what's slow"

## Setup

Add the MCP plugin to your world:

```lua
local mcp = require("tecs2d.mcp")

world:addPlugin(mcp.new())              -- default port 19999
world:addPlugin(mcp.new({port = 12345})) -- custom port
```

The HTTP server starts when the plugin is added and listens for connections on the configured port.

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

## Component Serialization

For `spawn`, `query`, and `spawn_bundle` to work, components need serialization support. Most components work
automatically:

- **Table components**: Serialize all fields by default
- **FFI components**: Serialize based on field schema

Components with Love2D objects (textures, fonts) need custom `serialize`/`deserialize` functions.

See [Component serialization](/tecs/components/serialization) for details.
