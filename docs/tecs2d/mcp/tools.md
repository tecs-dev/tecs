---
outline: deep
---

# Tools

The MCP server provides tools for AI assistants to inspect and control a running game.

Except for `screenshot`, tool calls return an MCP `result` with one text content item plus the same envelope as
`structuredContent`, so typed clients consume the object directly while text-only clients parse the JSON. Every
tool declares MCP safety annotations (readOnlyHint, destructiveHint, idempotentHint, openWorldHint); reads derive
read-only and idempotent, world loads and despawns derive destructive, and commands can override per key. Successful
tool payloads use:

```json
{"ok":true,"result":{}}
```

Some tools also include metadata:

```json
{"ok":true,"result":{},"meta":{"limit":100,"truncated":false}}
```

Tool-level failures still return a JSON-RPC `result`, not a JSON-RPC `error`. The MCP tool result has
`isError: true`, and its text content contains the structured error envelope:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"ok\":false,\"error\":{\"code\":\"unknown_component\",\"message\":\"Unknown component\",\"details\":{\"component\":\"Health\"}}}"
      }
    ],
    "isError": true
  }
}
```

Decoded from `content[0].text`, the payload is:

```json
{"ok":false,"error":{"code":"unknown_component","message":"Unknown component","details":{"component":"Health"}}}
```

JSON-RPC protocol and dispatch errors, such as unknown tool names, invalid `tools/call` params, unknown methods, or
malformed requests, use standard JSON-RPC `error` responses instead of MCP tool results.

## Discovery

MCP clients discover tools by calling `tools/list`. The response combines the
core tools with the debugger command registry currently installed in the game,
including game-defined commands. The live `tools/list` response is the exact
source of truth; the families below explain the built-in workflow and response
payloads. Response schemas are not currently advertised through `tools/list`.

Use core tools for generic structured ECS operations. Use `debug_*` tools when
an action should share the developer's selection, marks, notes, overlays,
timeline, or capture artifacts. See [Runtime introspection](../introspection)
for the complete investigation workflow.

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

## sample_pixels

Sample framebuffer pixel colors at one or more points without transferring a full screenshot. Useful for cheap
graphics assertions and agent-driven visual checks.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `points` | array | Yes | Points to sample, each an object with `x` and `y`. At most 256 per call. |
| `normalized` | boolean | No | When true, `x` and `y` are 0..1 fractions of the framebuffer size instead of pixel coordinates |

Points use pixel coordinates by default; out-of-range points are clamped to the framebuffer. Each returned pixel
carries the clamped integer coordinates that were sampled plus RGBA floats in 0..1.

**Example:**

```json
{"points":[{"x":0.5,"y":0.5},{"x":0.02,"y":0.02}],"normalized":true}
```

**Response:**

```json
{"ok":true,"result":{"width":320,"height":240,"pixels":[
  {"x":160,"y":120,"r":1,"g":0,"b":0,"a":1},
  {"x":6,"y":5,"r":0,"g":0,"b":0,"a":1}
]}}
```

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

Pausing goes through the freeze controller shared with the in-game debugger, so an MCP pause and an open debugger
panel hold independent freezes: the game runs again only when both are released. The previous time scale is saved
and restored on `resume`.

**Input:** None

**Response:**

```json
{"ok":true,"result":{"paused":true,"savedTimeScale":1}}
```

## resume

Release the MCP pause, restoring the previous time scale and re-enabling all gameplay systems. `stillFrozen` is true
when another holder (the open in-game debugger) keeps the game frozen.

**Input:** None

**Response:**

```json
{"ok":true,"result":{"paused":false,"restoredTimeScale":1,"stillFrozen":false}}
```

## step

Advance N frames while frozen, then freeze again. The game must be frozen first, by `pause` or by an open in-game
debugger. Gameplay systems run for the specified number of frames with the original pre-freeze time scale, then are
automatically disabled again.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `frames` | number | No | Number of frames to advance (default: 1) |

**Response:**

```json
{"ok":true,"result":{"stepping":true,"frames":5}}
```

## get_debug_context

Get the in-game debugger context: open/frozen state, the current command and last message, the selection, the
entity count, any drag area, mouse position (screen and world), and the camera.
Marks and notes are keyed by name or message with compact entity-id range strings (`"8-12,20"`). Also carries
`statsShown` (whether the stats HUD is visible) and the session's `snapshots`, `profiles`, `screenshots`, current
`recording` state, and completed `recordings`, each list capped to the five most recent entries. Requires the debug
plugin.

**Input:** None

**Response:**

```json
{"ok":true,"result":{"open":false,"frozen":false,"selected":[8],"marks":{"boss":"8-12"},"notes":{},"entityCount":412,
  "mouse":{"screenX":100,"screenY":80,"worldX":52,"worldY":40},"camera":{"x":160,"y":120,"zoom":1}}}
```

## Debugger command tools (debug_*)

Every in-game debugger command is declared once, in a schema-based registry shared by the command line and the MCP
server. The registry is projected as `debug_*` tools: each command (and each subcommand verb) becomes one tool whose
JSON input schema is generated from the command's argument schema, so `tools/list` always matches what the operator
can type and validation is identical on both surfaces. These tools appear in the listing only when the debug plugin
is installed.

The built-in projected families are summarized below. Games may add more at
runtime; inspect `tools/list` for the exact set and generated input schemas.

- Selection and annotation: `debug_select` (with a `replace` flag to swap instead of adding), `debug_clear`,
  `debug_mark` (plus `_list` / `_clear`), `debug_goto`, `debug_note`, `debug_query` (with `invert` to de-select the
  matches from the selection), `debug_ids` (entity id labels).
- Entity editing: `debug_set` (one component, Lua-table `value` string), `debug_remove` (components off a target),
  `debug_spawn` (bundle and/or components with Lua-table values), `debug_despawn`. Targets are an entity `id`, a
  mark `name`, or the literal `@selection`.
- Drawing: `debug_draw_rect` / `debug_draw_circle` / `debug_draw_line` / `debug_draw_text` (world-space, optional
  `entity` pin and wall-clock `seconds` expiry) and `debug_draw_clear` (by `id` or `tag`, or everything).
- Engine introspection: `debug_archetypes_list` / `_info` / `_select`, `debug_components_list` / `_info`,
  `debug_states_info` / `_push` / `_pop`, `debug_physics_info` / `_debug` / `_raycast` / `_query` (`_debug`
  installs the collision-shape drawer on first use; the probes draw annotations and select their hits),
  `debug_layers_list` / `_info` / `_all` / `_toggle` / `_solo` / `_unlit`, `debug_controllers_list` / `_info` / `_rumble`,
  `debug_materials_list` / `_info` (info returns the material's GLSL), `debug_sprites_info`,
  `debug_assets_list` / `_info` / `_reload` (reload re-reads a cached asset from disk in place), and
  `debug_audio_info` / `_stop` / `_mute`.
- World control: `debug_grid` (world-space grid with optional `size`, `offsetX`, and `offsetY`; tile-chunk matched by default), `debug_map` / `debug_map_info` (tilemap details and per-layer tiles at a world point, with grid-coordinate fallback), and `debug_bounds`
  (size outlines), the `debug_light_*` verbs (`info`, `color`, `toggle` for lighting, `shadows`, `bloom`),
  the `debug_camera_*` verbs (`info`, `move`, `timescale`, `toggle` for named cameras), and the
  `debug_systems_*` verbs (`list`, `stop`, `start`, `toggle`, `info`).
- Session: `debug_agent_info` (MCP URL, tool count, save dir) and `debug_agent_connect`
  (copies the MCP client config JSON to the host clipboard).
- Artifacts: every artifact family also has a `_path` verb that copies the file's absolute path to the host
  clipboard. `debug_screenshot` (plus `_list` / `_clear` / `_open` / `_path` / `_info`; `panel` keeps the debugger
  visible and `delay` defers the capture), the `debug_snapshot_*` verbs
  (`save`, `load`, `open`, `info`, `list`, `clear`), the `debug_profile_*` verbs (`list`, `clear`, `info` for a
  regenerated summary, `open` to launch speedscope with the capture path in the clipboard), `debug_history` (plus
  `_clear`), the `debug_rewind_*` verbs (`start`, `stop`, `pause`, `resume`, `list`, `info`, `load`, `keep`,
  `clear`: a rolling snapshot ring; `load` rewinds the live world and pauses capture until resumed; capture
  holds while the freeze controller is held), `debug_diff` (structural snapshot diff; refs are snapshot
  number/name/latest, `rewind:<selector>`, or current; `limit = 0` returns the complete per-component summary alone,
  the intended first call before filtering with `component`/`ignore`/`entity`) with `debug_diff_get` (RFC 6901
  pointer into the last or a saved diff) and its `_list` / `_open` / `_path` / `_clear` artifact verbs over the
  JSON file each run writes, and the `debug_record_*` verbs (`start`, `stop`, `cancel`, `status`, `info`, `list`, `open`). `debug_record_start` takes
  `seconds`, `name`, `fps`, `scale`, `countdown`, `stopOnDebugOpen`, and a `debug` flag that keeps the debugger
  visible and the game running during the capture. Host recording requires `ffmpeg` on PATH and a POSIX host
  (macOS or Linux).

Commands with a purpose-built MCP tool are not projected; use `step`, `pause`/`resume`,
`profiler_start`/`profiler_stop`, `get_entity`, and `quit` instead of the debugger's `step`, `profile`, `info`,
and `quit`.

Games can extend the surface: a command registered with `require("tecs2d.debug.commands").register(world, cmd)`
(set `mcpHelp` for an agent-facing description and `annotations` to override the derived safety hints)
appears here as `debug_<name>` with a generated schema, exactly like the builtins. See
[Custom debugger commands](../custom-debug-commands) for the complete registration API and examples.

Arguments that share one positional slot on the command line (an entity id or a mark name) become separate optional
JSON parameters with a "provide exactly one" constraint. For example `debug_select`:

```json
{"name":"debug_select","arguments":{"id":42}}
{"name":"debug_select","arguments":{"name":"boss"}}
```

Results carry the command's structured data plus its human-readable `message`:

```json
{"ok":true,"result":{"selected":3,"added":[42],"message":"selected 1"}}
```

## get_logs

Read recent engine log lines captured from `tecs.utils.logging` (a ring of the last 500). Filter by minimum level or
by substring (matched against the message and the logger name); lines return newest last. Every captured line carries
a monotonic `seq`, and `result.latest` is the newest captured seq: pass it back as `after` for cheap incremental
polling. Pass `clear: true` to empty the buffer instead of reading.

The debugger's operator-action feed rides this channel: every operator action (selection changes, marks, notes,
edits, spawns, artifact writes, panel open/close) logs one `kind key=value ...` line under the
`tecs2d.debug.events` logger, so "watch what the operator does" is
`get_logs {after = <last seq>, contains = "debug.events"}`.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `level` | string | No | Minimum severity: `DEBUG`, `INFO`, `WARN`, or `ERROR` |
| `contains` | string | No | Only lines whose message or logger contains this text |
| `after` | number | No | Only lines with `seq` greater than this (cursor; default 0) |
| `limit` | number | No | Max lines to return (default 50) |
| `clear` | boolean | No | Clear the captured buffer |

**Response:**

```json
{"ok":true,"result":{"returned":1,"matched":1,"captured":213,"dropped":0,"latest":213,
  "logs":[{"seq":213,"time":"2026-07-10 17:20:11","logger":"tecs2d.debug.events","level":"INFO","message":"selection clicked=42 selected=2"}]}}
```

## get_component_schema

Get a component's field names and types plus default values, for constructing `patch_entities`, `spawn`, and
`debug_set` payloads without guessing. FFI components report exact C types from the storage fingerprint; table
components report Lua types derived from a default-constructed instance.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `name` | string | Yes | Component name |

**Response:**

```json
{"ok":true,"result":{"name":"Transform","id":3,"kind":"ffi","serializable":true,
  "fields":[{"name":"x","type":"float"},{"name":"y","type":"float"},{"name":"layer","type":"int32_t"}],
  "defaults":{"x":0,"y":0,"z":0,"layer":1,"rotation":0,"scaleX":1,"scaleY":1}}}
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
