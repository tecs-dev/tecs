# Tools

The MCP server provides the following tools for AI assistants to interact with your game.

## ping

Check if the game is running.

**Input:** None

**Response:** `Game is running (time: 123.45s)`

## screenshot

Capture a screenshot of the game window.

| Parameter   | Type     | Required   | Description                        |
| ----------- | -------- | ---------- | ---------------------------------- |
| `x`         | number   | No         | X coordinate for region capture    |
| `y`         | number   | No         | Y coordinate for region capture    |
| `width`     | number   | No         | Width for region capture           |
| `height`    | number   | No         | Height for region capture          |

**Response:** Base64-encoded PNG image

## get_window_size

Get the game window dimensions.

**Input:** None

**Response:** `800x600`

## get_fps

Get the current frames per second.

**Input:** None

**Response:** `FPS: 60`

## get_stats

Get ECS world statistics.

**Input:** None

**Response:**
```
Entities: 150
Archetypes: 12
Components: 25
Systems: 18
```

## get_components

List all component types registered in the game.

**Input:** None

**Response:**
```
Health (id=5, entities=42)
Position (id=1, entities=150)
Velocity (id=2, entities=75)
```

## get_systems

List all systems and their phases.

**Input:** None

**Response:**
```
[Update] MovementSystem
[Update] CollisionSystem
[Render] SpriteRenderer
```

## get_resources

List all world resources.

**Input:** None

**Response:**
```
AssetManager: AssetManager
Camera: Camera
Pipeline: Pipeline
```

## get_archetypes

List all archetypes with their component composition and entity counts.

**Input:** None

**Response:**
```json
{
  "count": 5,
  "archetypes": [
    {"id": 1, "entities": 50, "components": ["Position", "Velocity"]},
    {"id": 2, "entities": 25, "components": ["Position", "Sprite"]}
  ]
}
```

## get_entity

Get a single entity by ID with all its components. Unlike `query`, this does not require knowing the entity's
component composition upfront.

| Parameter   | Type     | Required   | Description            |
| ----------- | -------- | ---------- | ---------------------- |
| `id`        | number   | Yes        | Entity ID to look up   |

**Response:**
```json
{
  "id": 42,
  "archetypeId": 1,
  "archetypeComponents": "Position, Sprite, Velocity",
  "components": {
    "Position": {"x": 100, "y": 200},
    "Velocity": {"x": 5, "y": 0},
    "Sprite": {"texture": "player.png", "width": 32, "height": 32}
  }
}
```

Returns an error if the entity does not exist.

## query

Query entities by component composition.

| Parameter   | Type       | Required   | Description                            |
| ----------- | ---------- | ---------- | -------------------------------------- |
| `include`   | string[]   | Yes        | Component names to include             |
| `exclude`   | string[]   | No         | Component names to exclude             |
| `limit`     | number     | No         | Max entities to return (default: 100)  |

**Response:**
```json
{
  "count": 2,
  "entities": [
    {
      "id": 42,
      "archetypeId": 1,
      "archetypeComponents": "Position, Velocity",
      "components": {
        "Position": {"x": 100, "y": 200},
        "Velocity": {"x": 5, "y": 0}
      }
    }
  ]
}
```

## spawn

Spawn an entity with components.

| Parameter      | Type     | Required   | Description                               |
| -------------- | -------- | ---------- | ----------------------------------------- |
| `components`   | object   | Yes        | Map of component name to component data   |

**Example:**
```json
{
  "components": {
    "Transform": {"x": 100, "y": 200, "layer": 1},
    "Velocity": {"x": 5, "y": 0}
  }
}
```

**Response:** `{"id": 42}`

## despawn

Remove entities by ID.

| Parameter   | Type       | Required   | Description                     |
| ----------- | ---------- | ---------- | ------------------------------- |
| `id`        | number     | No*        | Single entity ID to despawn     |
| `ids`       | number[]   | No*        | List of entity IDs to despawn   |

*One of `id` or `ids` is required.

**Response:** `Despawned 3 entities`

## get_bundles

Get registered bundles.

**Input:** None

**Response:**
```json
{
  "bundles": {
    "Player": {"required": ["Transform", "Health"], "defaulted": ["Velocity"]},
    "Enemy": {"required": ["Transform"], "defaulted": ["Health", "AI"]}
  }
}
```

## spawn_bundle

Spawn an entity from a registered bundle.

| Parameter      | Type     | Required   | Description           |
| -------------- | -------- | ---------- | --------------------- |
| `bundle`       | string   | Yes        | Bundle name           |
| `components`   | object   | No         | Component overrides   |

**Example:**
```json
{
  "bundle": "Enemy",
  "components": {
    "Transform": {"x": 500, "y": 300}
  }
}
```

**Response:** `{"id": 42}`

## run_lua

Execute Lua code in the game. Code is automatically wrapped in `function(world) ... end` and
queued for execution by MCP's `Last`-phase drain system. Use `world` directly
to access the ECS world.

| Parameter   | Type     | Required   | Description                                    |
| ----------- | -------- | ---------- | ---------------------------------------------- |
| `code`      | string   | Yes        | Lua code to execute with `world` in scope      |

**Example:**
```json
{
  "code": "print('Hello from MCP!')"
}
```

**Response:** `Code queued for execution`

Errors are logged without crashing the game.

## restart

Restart the game. See [Dev-Mode Restart](./dev-mode) for rebuild configuration.

**Input:** None

**Response:** `Restarting game`

## quit

Quit the game.

**Input:** None

**Response:** `Quitting game`

## send_love_event

Send a Love2D event to the game. This allows simulating keyboard presses, mouse clicks, and other user
interactions without physical input.

| Parameter   | Type       | Required   | Description       |
| ----------- | ---------- | ---------- | ----------------- |
| `event`     | string     | Yes        | Event name        |
| `args`      | string[]   | No         | Event arguments   |

Supported events: `keypressed`, `keyreleased`, `mousepressed`, `mousereleased`, `mousemoved`, `wheelmoved`,
`resize`, `focus`

**Example:**
```json
{
  "event": "keypressed",
  "args": ["space"]
}
```

**Response:** `OK`

## patch_entities

Update components on existing entities. Can add, update, or remove components.

| Parameter   | Type       | Required   | Description                                           |
| ----------- | ---------- | ---------- | ----------------------------------------------------- |
| `id`        | number     | No*        | Single entity ID to patch                             |
| `ids`       | number[]   | No*        | List of entity IDs to patch (all get same changes)    |
| `set`       | object     | No         | Components to add or update (map of name to data)     |
| `remove`    | string[]   | No         | Component names to remove                             |

*One of `id` or `ids` is required.

**Example:**
```json
{
  "ids": [42, 43, 44],
  "set": {
    "Health": {"current": 100, "max": 100}
  },
  "remove": ["Poison"]
}
```

**Response:** `Patched 3 entities`

## screen_to_world

Convert screen coordinates to world coordinates using the active camera.

| Parameter   | Type     | Required   | Description          |
| ----------- | -------- | ---------- | -------------------- |
| `x`         | number   | Yes        | Screen X coordinate  |
| `y`         | number   | Yes        | Screen Y coordinate  |

**Response:**
```json
{
  "x": 512.5,
  "y": 384.0
}
```

## query_in_bounds

Query entities within a world-space bounding box. Returns entities that have a Position component within bounds.

| Parameter   | Type       | Required   | Description                                                       |
| ----------- | ---------- | ---------- | ----------------------------------------------------------------- |
| `x`         | number     | Yes        | Left X coordinate of bounds                                       |
| `y`         | number     | Yes        | Top Y coordinate of bounds                                        |
| `width`     | number     | Yes        | Width of bounds                                                   |
| `height`    | number     | Yes        | Height of bounds                                                  |
| `include`   | string[]   | No         | Additional components to include (Position is always included)    |
| `limit`     | number     | No         | Max entities to return (default: 100)                             |

**Example:**
```json
{
  "x": 0,
  "y": 0,
  "width": 800,
  "height": 600,
  "include": ["Enemy", "Health"]
}
```

**Response:** Same format as `query`

## toggle_system

Enable or disable a system by name. Disabled systems are skipped during update.

| Parameter   | Type      | Required   | Description                        |
| ----------- | --------- | ---------- | ---------------------------------- |
| `name`      | string    | Yes        | System name to toggle              |
| `enabled`   | boolean   | Yes        | True to enable, false to disable   |

**Example:**
```json
{
  "name": "AISystem",
  "enabled": false
}
```

**Response:** `System 'AISystem' disabled`

## set_time_scale

Set the time scale for the game. Affects delta time passed to systems.

| Parameter   | Type     | Required   | Description                           |
| ----------- | -------- | ---------- | ------------------------------------- |
| `scale`     | number   | Yes        | Time scale multiplier (0.1 to 10.0)   |

**Example:**
```json
{
  "scale": 0.5
}
```

**Response:** `Time scale set to 0.5`

## pause

Hard pause that disables all gameplay and physics systems while rendering continues. The game window stays
responsive and MCP tools remain available. Different from `set_time_scale(0)` which still ticks every system
with zero dt.

The previous time scale is saved and restored on `resume`.

**Input:** None

**Response:** `Game paused`

## resume

Resume gameplay after a pause, restoring the previous time scale and re-enabling all gameplay systems.

**Input:** None

**Response:** `Game resumed`

## step

Advance N frames while paused, then pause again. The game must be paused first. Gameplay systems run
for the specified number of frames with the original (pre-pause) time scale, then are automatically
disabled again.

| Parameter   | Type     | Required   | Description                                |
| ----------- | -------- | ---------- | ------------------------------------------ |
| `frames`    | number   | No         | Number of frames to advance (default: 1)   |

**Example:**
```json
{
  "frames": 5
}
```

**Response:** `Stepping 5 frame(s)`

## debug_draw

Draw a debug overlay shape in world space. Renders on top of the game and works while paused.
Uses wall-clock time for duration, so overlays appear and expire even during pause. Returns
a command ID that can be used with `clear_debug_draw` for removal.

| Parameter     | Type       | Required   | Description                                                           |
| ------------- | ---------- | ---------- | --------------------------------------------------------------------- |
| `type`        | string     | Yes        | Shape type: `rect`, `circle`, `text`, `line`                          |
| `x`           | number     | No         | X position in world coordinates                                       |
| `y`           | number     | No         | Y position in world coordinates                                       |
| `w`           | number     | No         | Width (rect only)                                                     |
| `h`           | number     | No         | Height (rect only)                                                    |
| `radius`      | number     | No         | Radius (circle only)                                                  |
| `text`        | string     | No         | Text to display (text only)                                           |
| `x2`          | number     | No         | End X position (line only)                                            |
| `y2`          | number     | No         | End Y position (line only)                                            |
| `color`       | number[]   | No         | RGBA color array, e.g. `[1,0,0,0.8]` (default: yellow)                |
| `tag`         | string     | No         | Tag for grouped clearing                                              |
| `duration`    | number     | No         | Seconds before auto-removal. `0` = single frame, omit = persistent    |
| `lineWidth`   | number     | No         | Line width in pixels (default: 4)                                     |
| `fontSize`    | number     | No         | Font size for text (default: 14)                                      |

**Examples:**

Highlight an area:
```json
{
  "type": "rect",
  "x": 100, "y": 200,
  "w": 50, "h": 50,
  "color": [1, 0, 0, 0.8],
  "tag": "selection",
  "duration": 3
}
```

Circle an entity:
```json
{
  "type": "circle",
  "x": 150, "y": 225,
  "radius": 30,
  "color": [0, 1, 0, 0.8]
}
```

Label something:
```json
{
  "type": "text",
  "x": 100, "y": 180,
  "text": "Player spawn",
  "color": [1, 1, 1, 1],
  "fontSize": 16
}
```

**Response:** `Created debug draw 1`

## clear_debug_draw

Clear debug draw commands. With no arguments, clears all commands. Specify `tag` or `id` to
clear selectively.

| Parameter   | Type     | Required   | Description                            |
| ----------- | -------- | ---------- | -------------------------------------- |
| `tag`       | string   | No         | Clear all commands with this tag       |
| `id`        | number   | No         | Clear a specific command by ID         |

**Examples:**

Clear by tag:
```json
{
  "tag": "selection"
}
```

Clear by ID:
```json
{
  "id": 1
}
```

Clear all (no arguments):
```json
{}
```

**Response:** `Cleared 3 debug draw command(s)`

## profiler_start

Start LuaJIT's sampling profiler. Errors if a session is already active. Auto-stops when
`seconds` elapses; omit `seconds` to record until `profiler_stop` is called. Filtering
and sample interval are fixed at start time.

| Parameter      | Type     | Required   | Description                                                                                       |
| -------------- | -------- | ---------- | ------------------------------------------------------------------------------------------------- |
| `seconds`      | number   | No         | Record for this many seconds (0.1-60), then auto-stop                                             |
| `interval_ms`  | number   | No         | Sampler interval in ms. Default 1; raise to 5 or 10 for long sessions                             |
| `zone`         | string   | No         | Zone-path prefix filter; keeps only samples whose zpath starts with it (e.g. `afterFixed/Render`) |

`zone` filters by exact prefix match on the zpath. Speedscope and flamegraph.pl both
support zoom/include filters at render time, so usually you don't need this; reach for
it when you want a smaller MCP response or a filtered file on disk.

**Response:** `Profiler started: 5.0s duration`

## profiler_stop

Stop the profiler and return [collapsed-stack][1] text. Drag into [speedscope.app][2]
or pipe to [`flamegraph.pl`][3].

[1]: https://www.brendangregg.com/flamegraphs.html
[2]: https://speedscope.app
[3]: https://github.com/brendangregg/FlameGraph

If `profiler_start` was called with `seconds` and the auto-stop has already fired, the
captured recording is returned by the next `profiler_stop` call (so a missed timeout
does not lose the data).

| Parameter   | Type     | Required   | Description                                                                 |
| ----------- | -------- | ---------- | --------------------------------------------------------------------------- |
| `save_to`   | string   | No         | File path to write output to instead of returning it                        |
