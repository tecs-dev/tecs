---
outline: deep
---

# Tools

The MCP server provides tools for AI assistants to inspect and control a running game.

Except for `screenshot`, tool results are returned as MCP text content whose text is compact JSON. Successful tool
payloads use:

```json
{"ok":true,"result":{}}
```

Some tools also include metadata:

```json
{"ok":true,"result":{},"meta":{"limit":100,"truncated":false}}
```

Tool-level failures use MCP `isError: true` and a structured payload:

```json
{"ok":false,"error":{"code":"unknown_component","message":"Unknown component","details":{"component":"Health"}}}
```

JSON-RPC protocol errors, such as unknown tool names or malformed requests, still use standard JSON-RPC errors.

## Discovery

MCP clients discover tools by calling `tools/list`. The server returns the tool list from
`src/tecs2d/mcp/tools.tl`, including each tool's `name`, `description`, and `inputSchema`. The human-facing examples
below document response payloads, but response schemas are not currently advertised through `tools/list`.

## ping

Check if the game is running.

**Input:** None

**Response:**

```json
{"ok":true,"result":{"running":true,"port":19999,"time":123.45}}
```

## screenshot

Capture a screenshot of the game window.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `x` | number | No | X coordinate for region capture |
| `y` | number | No | Y coordinate for region capture |
| `width` | number | No | Width for region capture |
| `height` | number | No | Height for region capture |

**Response:** MCP image content containing a base64-encoded PNG.

## send_love_event

Send a Love2D event to the game. This allows simulating keyboard presses, mouse clicks, resize events, focus changes,
and other user interactions without physical input.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `event` | string | Yes | Event name |
| `args` | array | No | Event arguments; values keep their JSON types |

Supported events include `keypressed`, `keyreleased`, `mousepressed`, `mousereleased`, `mousemoved`, `wheelmoved`,
`resize`, and `focus`.

**Example:**

```json
{"event":"keypressed","args":["space"]}
```

**Response:**

```json
{"ok":true,"result":{"event":"keypressed","args":["space"]}}
```

## get_window_size

Get the game window dimensions.

**Input:** None

**Response:**

```json
{"ok":true,"result":{"width":800,"height":600}}
```

## get_fps

Get the current frames per second.

**Input:** None

**Response:**

```json
{"ok":true,"result":{"fps":60}}
```

## get_stats

Get ECS world statistics.

**Input:** None

**Response:**

```json
{
  "ok": true,
  "result": {
    "entities": 150,
    "archetypes": 12,
    "components": 25,
    "systems": 18,
    "memoryKB": 43100.4,
    "memoryMB": 42.1
  }
}
```

## get_components

List all component types registered in the game with component IDs and entity counts.

**Input:** None

**Response:**

```json
{
  "ok": true,
  "result": {
    "count": 3,
    "components": [
      {"name":"Health","id":5,"entities":42},
      {"name":"Position","id":1,"entities":150},
      {"name":"Velocity","id":2,"entities":75}
    ]
  }
}
```

## get_systems

List all systems and their phases.

**Input:** None

**Response:**

```json
{
  "ok": true,
  "result": {
    "count": 3,
    "systems": [
      {"name":"MovementSystem","phase":"Update"},
      {"name":"CollisionSystem","phase":"Update"},
      {"name":"SpriteRenderer","phase":"Render"}
    ]
  }
}
```

## get_resources

List all world resources.

**Input:** None

**Response:**

```json
{
  "ok": true,
  "result": {
    "count": 3,
    "resources": [
      {"key":"AssetManager","type":"AssetManager"},
      {"key":"Camera","type":"Camera"},
      {"key":"Pipeline","type":"Pipeline"}
    ]
  }
}
```

## get_archetypes

List all archetypes with their component composition and entity counts.

**Input:** None

**Response:**

```json
{
  "ok": true,
  "result": {
    "count": 2,
    "archetypes": [
      {"id":1,"entities":50,"components":["Position","Velocity"]},
      {"id":2,"entities":25,"components":["Position","Sprite"]}
    ]
  }
}
```

## get_entity

Get a single entity by ID with all serializable components. Unlike `query`, this does not require knowing the
entity's component composition upfront.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `id` | number | Yes | Entity ID to look up |

**Response:**

```json
{
  "ok": true,
  "result": {
    "id": 42,
    "archetypeId": 1,
    "archetypeComponents": "Position, Sprite, Velocity",
    "components": {
      "Position": {"x":100,"y":200},
      "Velocity": {"x":5,"y":0},
      "Sprite": {"texture":"player.png","width":32,"height":32}
    }
  }
}
```

## query

Query entities by component composition.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `include` | string[] | Yes | Component names to include |
| `exclude` | string[] | No | Component names to exclude |
| `limit` | number | No | Max entities to return (default: 100) |

Only components in `include` are serialized in each entity result. Tag components and components without serializers are
skipped in the returned `components` object.

**Response:**

```json
{
  "ok": true,
  "result": {
    "count": 1,
    "entities": [
      {
        "id": 42,
        "archetypeId": 1,
        "archetypeComponents": "Position, Velocity",
        "components": {
          "Position": {"x":100,"y":200},
          "Velocity": {"x":5,"y":0}
        }
      }
    ]
  },
  "meta": {"limit":100,"truncated":false}
}
```

## spawn

Spawn an entity with components.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `components` | object | Yes | Map of component name to component data |

**Example:**

```json
{"components":{"Transform":{"x":100,"y":200,"layer":1},"Velocity":{"x":5,"y":0}}}
```

**Response:**

```json
{"ok":true,"result":{"id":42}}
```

## despawn

Remove entities by ID.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `id` | number | No* | Single entity ID to despawn |
| `ids` | number[] | No* | List of entity IDs to despawn |

*One of `id` or `ids` is required.

**Response:**

```json
{"ok":true,"result":{"despawned":3,"failed":0,"ids":[42,43,44],"errors":[]}}
```

## get_bundles

Get registered bundles.

**Input:** None

**Response:**

```json
{
  "ok": true,
  "result": {
    "bundles": {
      "Player": {"required":["Transform","Health"],"defaulted":["Velocity"]},
      "Enemy": {"required":["Transform"],"defaulted":["Health","AI"]}
    }
  }
}
```

## spawn_bundle

Spawn an entity from a registered bundle.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `bundle` | string | Yes | Bundle name |
| `components` | object | No | Component overrides |

**Example:**

```json
{"bundle":"Enemy","components":{"Transform":{"x":500,"y":300}}}
```

**Response:**

```json
{"ok":true,"result":{"id":42}}
```

## restart

Request a Love2D restart. If the game uses `tecs2d.run` with `hotReload` enabled, the run loop handles snapshot
save/restore around the restart.

**Input:** None

**Response:**

```json
{"ok":true,"result":{"restarting":true}}
```

## quit

Quit the game.

**Input:** None

**Response:**

```json
{"ok":true,"result":{"quitting":true}}
```

## run_lua

Execute Lua code in the game. Code is automatically wrapped in `function(world) ... end` and queued for execution by
MCP's `Last`-phase drain system. Use `world` directly to access the ECS world.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `code` | string | Yes | Lua code to execute with `world` in scope |

**Example:**

```json
{"code":"return world:getStats().entities"}
```

**Response:**

```json
{"ok":true,"result":{"returned":1,"values":["150"]}}
```

Errors are returned as structured tool errors and logged without crashing the game.

## patch_entities

Update components on existing entities. Can add, update, or remove components. The mutation is queued for the MCP
world-op drain.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `id` | number | No* | Single entity ID to patch |
| `ids` | number[] | No* | List of entity IDs to patch; all get the same changes |
| `set` | object | No | Components to add or update, keyed by component name |
| `remove` | string[] | No | Component names to remove |

*One of `id` or `ids` is required.

**Example:**

```json
{"ids":[42,43,44],"set":{"Health":{"current":100,"max":100}},"remove":["Poison"]}
```

**Response:**

```json
{"ok":true,"result":{"queued":true,"entities":3,"ids":[42,43,44]}}
```

## screen_to_world

Convert screen coordinates to world coordinates using the active camera.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `x` | number | Yes | Screen X coordinate |
| `y` | number | Yes | Screen Y coordinate |

**Response:**

```json
{"ok":true,"result":{"screen":{"x":400,"y":300},"world":{"x":512.5,"y":384}}}
```

## query_in_bounds

Query entities within a world-space bounding box. Uses `Position` when registered, otherwise falls back to built-in
`Transform`. The spatial component is always included in the query.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `x` | number | Yes | Left X coordinate of bounds |
| `y` | number | Yes | Top Y coordinate of bounds |
| `width` | number | Yes | Width of bounds |
| `height` | number | Yes | Height of bounds |
| `include` | string[] | No | Additional components to include |
| `limit` | number | No | Max entities to return (default: 100) |

**Response:** Same entity format as `query`, plus the queried `bounds`.

## toggle_system

Enable or disable a system by name. Disabled systems are skipped during update.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `name` | string | Yes | System name to toggle |
| `enabled` | boolean | Yes | True to enable, false to disable |

**Response:**

```json
{"ok":true,"result":{"system":"AISystem","enabled":false}}
```

## set_time_scale

Set the time scale for the game. Affects render pipeline time.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `scale` | number | Yes | Time scale multiplier, clamped to 0.0 through 10.0 |

**Response:**

```json
{"ok":true,"result":{"scale":0.5,"gameTime":12.34}}
```

## pause

Hard pause that disables all gameplay and physics systems while rendering continues. The game window stays responsive
and MCP tools remain available. Different from `set_time_scale(0)` which still ticks every system with zero dt.

The previous time scale is saved and restored on `resume`.

**Input:** None

**Response:**

```json
{"ok":true,"result":{"paused":true,"savedTimeScale":1}}
```

## resume

Resume gameplay after a pause, restoring the previous time scale and re-enabling all gameplay systems.

**Input:** None

**Response:**

```json
{"ok":true,"result":{"paused":false,"restoredTimeScale":1}}
```

## step

Advance N frames while paused, then pause again. The game must be paused first. Gameplay systems run for the specified
number of frames with the original pre-pause time scale, then are automatically disabled again.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `frames` | number | No | Number of frames to advance (default: 1) |

**Response:**

```json
{"ok":true,"result":{"stepping":true,"frames":5}}
```

## debug_draw

Draw a debug overlay shape in world space. Renders on top of the game and works while paused. Uses wall-clock time for
duration, so overlays appear and expire even during pause. Returns a command ID that can be used with
`clear_debug_draw`.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `type` | string | Yes | Shape type: `rect`, `circle`, `text`, `line` |
| `x` | number | No | X position in world coordinates |
| `y` | number | No | Y position in world coordinates |
| `w` | number | No | Width, for `rect` |
| `h` | number | No | Height, for `rect` |
| `radius` | number | No | Radius, for `circle` |
| `text` | string | No | Text to display, for `text` |
| `x2` | number | No | End X position, for `line` |
| `y2` | number | No | End Y position, for `line` |
| `color` | number[] | No | RGBA color array, e.g. `[1,0,0,0.8]`; default yellow |
| `tag` | string | No | Tag for grouped clearing |
| `duration` | number | No | Seconds before auto-removal. `0` = single frame, omitted = persistent |
| `lineWidth` | number | No | Line width in pixels (default: 4) |
| `fontSize` | number | No | Font size for text (default: 14) |

**Response:**

```json
{"ok":true,"result":{"id":1,"type":"rect","tag":"selection"}}
```

## clear_debug_draw

Clear debug draw commands. With no arguments, clears all commands. Specify `tag` or `id` to clear selectively.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `tag` | string | No | Clear all commands with this tag |
| `id` | number | No | Clear a specific command by ID |

**Response:**

```json
{"ok":true,"result":{"cleared":3,"tag":"selection"}}
```

## profiler_start

Start LuaJIT's sampling profiler. Errors if a session is already active. Auto-stops when `seconds` elapses; omit
`seconds` to record until `profiler_stop` is called. Filtering and sample interval are fixed at start time.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `seconds` | number | No | Record for this many seconds, clamped to 0.1-60 |
| `interval_ms` | number | No | Sampler interval in ms. Default 1; raise to 5 or 10 for long sessions |
| `zone` | string | No | Zone-path prefix filter, e.g. `afterFixed/Render` |

**Response:**

```json
{"ok":true,"result":{"running":true,"seconds":5,"intervalMs":1,"zone":"afterFixed/Render"}}
```

## profiler_stop

Stop the profiler and return [collapsed-stack][1] text. Drag into [speedscope.app][2] or pipe to
[`flamegraph.pl`][3].

[1]: https://www.brendangregg.com/flamegraphs.html
[2]: https://speedscope.app
[3]: https://github.com/brendangregg/FlameGraph

If `profiler_start` was called with `seconds` and the auto-stop has already fired, the captured recording is returned
by the next `profiler_stop` call.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `save_to` | string | No | File path to write output to instead of returning it inline |

**Inline response:**

```json
{"ok":true,"result":{"format":"collapsed-stack","payload":"...","bytes":12345}}
```

**Saved response:**

```json
{"ok":true,"result":{"path":"profile.folded"}}
```

## snapshot_save

Capture a snapshot of the world. Returns the snapshot inline, or writes it to a file under Love2D's save directory when
`save_to` is provided. See [Save games](/tecs/save-games) for the snapshot model.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `format` | string | No | `"json"` (default) or `"luajit"` |
| `save_to` | string | No | Filename inside Love2D's save directory |
| `pretty` | boolean | No | Pretty-print JSON when saving or measuring JSON output (default: false) |
| `layers` | number[] | No | Allow-list of `Transform.layer` values, 0..31 |

**Inline JSON response:**

```json
{"ok":true,"result":{"format":"json","snapshot":{},"entities":150,"archetypes":12,"bytes":18422,"elapsedMs":2.3}}
```

**Inline LuaJIT response:**

```json
{"ok":true,"result":{"format":"luajit","encoding":"base64","payload":"...","entities":150,"archetypes":12,"bytes":9231,"elapsedMs":1.1}}
```

**Saved response:**

```json
{"ok":true,"result":{"format":"json","path":"/.../save/snapshot.json","entities":150,"archetypes":12,"bytes":18422,"elapsedMs":2.3}}
```

## snapshot_load

Restore a world snapshot, replacing the current world state. Accepts an inline payload or a filename in Love2D's save
directory. The `format` must match how the snapshot was saved.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `format` | string | No | `"json"` (default) or `"luajit"` |
| `payload` | string | No* | Inline snapshot payload. JSON is passed as-is; `luajit` payloads must be base64-encoded |
| `load_from` | string | No* | Filename inside Love2D's save directory to read from. Ignored when `payload` is supplied |

*Provide either `payload` or `load_from`.

**Response:**

```json
{"ok":true,"result":{"format":"json","source":"inline-payload","bytes":18422,"entities":150,"archetypes":12,"elapsedMs":2.6}}
```
