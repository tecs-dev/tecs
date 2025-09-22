# Dev-Mode Restart

The `restart` tool supports automatic code reloading for development. When you call `restart`:

1. **Rebuild**: If `TECS_MCP_REBUILD_CMD` is set, runs the command first
2. **Clear modules**: Clears all non-stdlib modules from `package.loaded`
3. **Restart**: Triggers Love2D restart with fresh code

## Setup

Set the `TECS_MCP_REBUILD_CMD` environment variable to your build command:

```bash
# Run with auto-rebuild on restart
TECS_MCP_REBUILD_CMD="make build" love .

# Or for Teal projects
TECS_MCP_REBUILD_CMD="cyan build --no-script" love .
```

## How it works

Love2D's `love.event.quit("restart")` does NOT clear `package.loaded`, so modules aren't reloaded by default.
The MCP restart handler:

1. Runs your rebuild command (compiles .tl → .lua)
2. Clears all loaded modules except Lua stdlib (string, table, math, etc.)
3. Triggers the restart, which loads fresh .lua files
