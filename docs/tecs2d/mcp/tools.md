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

Every built-in projected tool is listed below with a link into the
[Command Reference](../debug-reference), which documents each tool's arguments, result data,
examples, and safety annotations. The list is generated by `make docs-debug`. Games may add more
at runtime; inspect `tools/list` for the exact set and generated schemas.

<!-- BEGIN GENERATED debug-tools-index (make docs-debug) -->
| Tool | Description |
| --- | --- |
| [`debug_select`](../debug-reference#cmd-select) | Select an entity by id, or all entities with a mark name. |
| [`debug_clear`](../debug-reference#cmd-clear) | Clear the selection, message, and drag area. |
| [`debug_mark`](../debug-reference#cmd-mark) | Name the selected entities so select, goto, and despawn can recall them by name. |
| [`debug_mark_list`](../debug-reference#cmd-mark-list) | Show every mark with its count and first id. |
| [`debug_mark_clear`](../debug-reference#cmd-mark-clear) | Remove all marks. |
| [`debug_goto`](../debug-reference#cmd-goto) | Move the camera to an entity by id, or the first with a mark name. |
| [`debug_note`](../debug-reference#cmd-note) | Annotate the selected entities for the agent; empty message clears. |
| [`debug_despawn`](../debug-reference#cmd-despawn) | Despawn an entity by id or mark name, or the whole selection. |
| [`debug_remove`](../debug-reference#cmd-remove) | Remove components from an entity, marked group, or @selection. |
| [`debug_set`](../debug-reference#cmd-set) | Set one component on an entity, marked group, or @selection (Lua table value). |
| [`debug_modify`](../debug-reference#cmd-modify) | Change only the given fields of a component the target already has. |
| [`debug_spawn`](../debug-reference#cmd-spawn) | Spawn an entity from a bundle and/or components with Lua table values. |
| [`debug_query`](../debug-reference#cmd-query) | Select entities matching a component query: Foo has it, -Foo lacks it. |
| [`debug_draw_rect`](../debug-reference#cmd-draw-rect) | Outline a rectangle (x y w h in world units). |
| [`debug_draw_circle`](../debug-reference#cmd-draw-circle) | Outline a circle (x y radius in world units). |
| [`debug_draw_line`](../debug-reference#cmd-draw-line) | Draw a line (x y x2 y2 in world units). |
| [`debug_draw_text`](../debug-reference#cmd-draw-text) | Print text at a world position. |
| [`debug_draw_clear`](../debug-reference#cmd-draw-clear) | Remove annotations by id or tag; everything when omitted. |
| [`debug_ids`](../debug-reference#cmd-ids) | Toggle entity id labels over on-screen entities. |
| [`debug_history`](../debug-reference#cmd-history) | Show the command history (persisted across sessions). |
| [`debug_history_clear`](../debug-reference#cmd-history-clear) | Forget the history and delete its file. |
| [`debug_agent_info`](../debug-reference#cmd-agent-info) | Show the MCP URL, tool count, and save directory. |
| [`debug_agent_connect`](../debug-reference#cmd-agent-connect) | Copy the MCP client config JSON to the clipboard. |
| [`debug_capabilities`](../debug-reference#cmd-capabilities) | Installed plugins, command families, and host features. |
| [`debug_describe`](../debug-reference#cmd-describe) | One command's full contract as structured data. |
| [`debug_light_info`](../debug-reference#cmd-light-info) | Show ambient color, lighting, shadows, and bloom state. |
| [`debug_light_color`](../debug-reference#cmd-light-color) | Set or show the ambient light color. |
| [`debug_light_toggle`](../debug-reference#cmd-light-toggle) | Enable or disable lighting entirely. |
| [`debug_light_shadows`](../debug-reference#cmd-light-shadows) | Enable or disable shadow rendering. |
| [`debug_light_bloom`](../debug-reference#cmd-light-bloom) | Configure or show the bloom effect. |
| [`debug_camera_info`](../debug-reference#cmd-camera-info) | Show camera position, zoom, time scale, and registered cameras. |
| [`debug_camera_move`](../debug-reference#cmd-camera-move) | Set camera position (and optionally rotation and zoom). |
| [`debug_camera_timescale`](../debug-reference#cmd-camera-timescale) | Set the game time scale (0 = frozen, 1 = normal). |
| [`debug_camera_toggle`](../debug-reference#cmd-camera-toggle) | Toggle a named camera's active flag. |
| [`debug_layers_list`](../debug-reference#cmd-layers-list) | List named or modified layers with their flags. |
| [`debug_layers_info`](../debug-reference#cmd-layers-info) | Show one layer's name, flags, and entity count. |
| [`debug_layers_all`](../debug-reference#cmd-layers-all) | Show every layer (undo toggles and solo). |
| [`debug_layers_toggle`](../debug-reference#cmd-layers-toggle) | Show or hide a layer by name or number. |
| [`debug_layers_solo`](../debug-reference#cmd-layers-solo) | Hide every layer but one; bare `layers solo` restores. |
| [`debug_layers_unlit`](../debug-reference#cmd-layers-unlit) | Toggle a layer between lit and unlit. |
| [`debug_grid`](../debug-reference#cmd-grid) | Toggle a world-space grid matched to the tile grid. |
| [`debug_bounds`](../debug-reference#cmd-bounds) | Toggle size outlines around entities with known bounds. |
| [`debug_map`](../debug-reference#cmd-map) | Tilemap info; `info x y` shows the tile at a world point. |
| [`debug_map_info`](../debug-reference#cmd-map-info) | Tile coordinates and per-layer tiles at a world point. |
| [`debug_materials_list`](../debug-reference#cmd-materials-list) | List registered materials. |
| [`debug_materials_info`](../debug-reference#cmd-materials-info) | Show a material's GLSL sources by name or id. |
| [`debug_sprites_info`](../debug-reference#cmd-sprites-info) | Show bucket instance counts and texture memory. |
| [`debug_systems_info`](../debug-reference#cmd-systems-info) | Show one system's phase, order, and state. |
| [`debug_archetypes_info`](../debug-reference#cmd-archetypes-info) | Show one archetype's entity count and components. |
| [`debug_archetypes_select`](../debug-reference#cmd-archetypes-select) | Select every entity in an archetype. |
| [`debug_states_info`](../debug-reference#cmd-states-info) | Show the state stack, top last. |
| [`debug_states_push`](../debug-reference#cmd-states-push) | Push a created state onto the stack. |
| [`debug_states_pop`](../debug-reference#cmd-states-pop) | Pop the top state off the stack. |
| [`debug_physics_debug`](../debug-reference#cmd-physics-debug) | Toggle collision-shape debug drawing (installs the drawer if needed). |
| [`debug_physics_info`](../debug-reference#cmd-physics-info) | Physics state, or one entity's Box2D body properties. |
| [`debug_physics_raycast`](../debug-reference#cmd-physics-raycast) | Cast a ray, draw it, and select the hits. |
| [`debug_physics_query`](../debug-reference#cmd-physics-query) | Select bodies inside a world-space box and draw it. |
| [`debug_controllers_list`](../debug-reference#cmd-controllers-list) | List controllers and their joysticks. |
| [`debug_controllers_info`](../debug-reference#cmd-controllers-info) | Show a controller's joystick, deadzone, and bindings. |
| [`debug_controllers_rumble`](../debug-reference#cmd-controllers-rumble) | Vibrate a controller's joystick to verify it. |
| [`debug_assets_list`](../debug-reference#cmd-assets-list) | List cached asset keys, optionally filtered. |
| [`debug_assets_info`](../debug-reference#cmd-assets-info) | Show a cached asset's action, path, and load state. |
| [`debug_assets_reload`](../debug-reference#cmd-assets-reload) | Re-read matching cached assets from disk in place. |
| [`debug_audio_info`](../debug-reference#cmd-audio-info) | Show active sources per group and the master volume. |
| [`debug_audio_stop`](../debug-reference#cmd-audio-stop) | Stop every active source. |
| [`debug_audio_mute`](../debug-reference#cmd-audio-mute) | Silence the master group; `audio mute off` restores. |
| [`debug_profile_list`](../debug-reference#cmd-profile-list) | List profiles with size and timestamp. |
| [`debug_profile_clear`](../debug-reference#cmd-profile-clear) | Delete all profiles this session. |
| [`debug_profile_info`](../debug-reference#cmd-profile-info) | Re-show a capture's summary (latest if omitted). |
| [`debug_profile_path`](../debug-reference#cmd-profile-path) | Copy the file's absolute path to the clipboard (latest if omitted). |
| [`debug_profile_open`](../debug-reference#cmd-profile-open) | Open speedscope and copy the capture's path to the clipboard. |
| [`debug_snapshot_save`](../debug-reference#cmd-snapshot-save) | Save the world; reports a number for load/open. |
| [`debug_snapshot_load`](../debug-reference#cmd-snapshot-load) | Restore a save (the last if omitted). |
| [`debug_snapshot_open`](../debug-reference#cmd-snapshot-open) | Open with the OS default handler (latest if omitted). |
| [`debug_snapshot_path`](../debug-reference#cmd-snapshot-path) | Copy the file's absolute path to the clipboard (latest if omitted). |
| [`debug_snapshot_list`](../debug-reference#cmd-snapshot-list) | List snapshots with size and timestamp. |
| [`debug_snapshot_clear`](../debug-reference#cmd-snapshot-clear) | Delete all snapshots this session. |
| [`debug_snapshot_info`](../debug-reference#cmd-snapshot-info) | Show one save's details (latest if omitted). |
| [`debug_rewind_start`](../debug-reference#cmd-rewind-start) | Begin capturing; refuses over a stopped ring. |
| [`debug_rewind_stop`](../debug-reference#cmd-rewind-stop) | Stop capturing; the ring stays for list/load/keep. |
| [`debug_rewind_pause`](../debug-reference#cmd-rewind-pause) | Hold capture without ending the session. |
| [`debug_rewind_resume`](../debug-reference#cmd-rewind-resume) | Resume after a pause (including after a load). |
| [`debug_rewind_list`](../debug-reference#cmd-rewind-list) | List ring entries, newest first. |
| [`debug_rewind_info`](../debug-reference#cmd-rewind-info) | Show the session state: interval, cap, window, cost. |
| [`debug_rewind_load`](../debug-reference#cmd-rewind-load) | Restore a ring entry; capture pauses until resumed. |
| [`debug_rewind_keep`](../debug-reference#cmd-rewind-keep) | Promote a ring entry into the snapshot history. |
| [`debug_rewind_clear`](../debug-reference#cmd-rewind-clear) | Delete the ring files and reset to idle. |
| [`debug_diff`](../debug-reference#cmd-diff) | Structural diff between snapshots, rewind entries, and the live world. |
| [`debug_diff_list`](../debug-reference#cmd-diff-list) | List diffs with size and timestamp. |
| [`debug_diff_clear`](../debug-reference#cmd-diff-clear) | Delete all diffs this session. |
| [`debug_diff_open`](../debug-reference#cmd-diff-open) | Open with the OS default handler (latest if omitted). |
| [`debug_diff_path`](../debug-reference#cmd-diff-path) | Copy the file's absolute path to the clipboard (latest if omitted). |
| [`debug_diff_get`](../debug-reference#cmd-diff-get) | Dereference a JSON Pointer into a diff result. |
| [`debug_screenshot`](../debug-reference#cmd-screenshot) | Capture the screen (or drag area) to a PNG. |
| [`debug_screenshot_list`](../debug-reference#cmd-screenshot-list) | List screenshots with size and timestamp. |
| [`debug_screenshot_clear`](../debug-reference#cmd-screenshot-clear) | Delete all screenshots this session. |
| [`debug_screenshot_open`](../debug-reference#cmd-screenshot-open) | Open with the OS default handler (latest if omitted). |
| [`debug_screenshot_path`](../debug-reference#cmd-screenshot-path) | Copy the file's absolute path to the clipboard (latest if omitted). |
| [`debug_screenshot_info`](../debug-reference#cmd-screenshot-info) | Show one capture's details with a thumbnail (latest if omitted). |
| [`debug_record_start`](../debug-reference#cmd-record-start) | Start recording the window. |
| [`debug_record_stop`](../debug-reference#cmd-record-stop) | Stop the active recording. |
| [`debug_record_cancel`](../debug-reference#cmd-record-cancel) | Cancel an armed countdown. |
| [`debug_record_status`](../debug-reference#cmd-record-status) | Show the current recording state. |
| [`debug_record_list`](../debug-reference#cmd-record-list) | List recordings with size and timestamp. |
| [`debug_record_open`](../debug-reference#cmd-record-open) | Open a completed recording (latest if omitted). |
| [`debug_record_path`](../debug-reference#cmd-record-path) | Copy the file's absolute path to the clipboard (latest if omitted). |
| [`debug_record_info`](../debug-reference#cmd-record-info) | Show one completed recording's details (latest if omitted). |
<!-- END GENERATED debug-tools-index -->

Commands with a purpose-built MCP tool are not projected; use `step`, `pause`/`resume`,
`profiler_start`/`profiler_stop`, `get_entity`, and `quit` instead of the debugger's `step`, `profile`, `info`,
and `quit`.

Games can extend the surface: a command registered with `require("tecs2d.debug.commands").register(world, cmd)`
(set `mcpHelp` for an agent-facing description and `annotations` to override the derived safety hints)
appears here as `debug_<name>` with a generated schema, exactly like the builtins. See
[Custom debugger commands](../custom-debug-commands) for the complete registration API and examples.

Argument schemas project faithfully: enums, numeric minimum/maximum, arrays (comma-separated on the command
line), and objects (the `value` of `debug_set` and `debug_modify` takes a real JSON object; the Lua-expression
string also still works).
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
| `intervalMs` | number | No | Sampler interval in ms. Default 1; raise to 5 or 10 for long sessions |
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
| `saveTo` | string | No | File path to write output to instead of returning it inline |

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
`saveTo` is provided. See [Save games](/tecs/save-games) for the snapshot model.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `format` | string | No | `"json"` (default) or `"luajit"` |
| `saveTo` | string | No | Filename inside Love2D's save directory |
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
| `loadFrom` | string | No* | Filename inside Love2D's save directory to read from. Ignored when `payload` is supplied |

*Provide either `payload` or `loadFrom`.

**Response:**

```json
{"ok":true,"result":{"format":"json","source":"inline-payload","bytes":18422,"entities":150,"archetypes":12,"elapsedMs":2.6}}
```
