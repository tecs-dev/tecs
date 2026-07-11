---
outline: deep
---

# Debug plugin

The `tecs2d.debug` plugin adds an in-game debugging surface to a running game: a
modal debugger overlay for inspecting and manipulating the world, and a stats
HUD for performance metrics. When the [MCP plugin](./mcp/) is also present, an
AI agent reads and drives the same debugger through MCP tools.

## Getting started

Add the plugin to your world. Debug mode is enabled automatically; there is no
separate flag to set.

```teal
local tecs = require("tecs")
local tecs2d = require("tecs2d")
local debug = require("tecs2d.debug")

local function gamePlugin(world: tecs.World)
    world:addPlugin(debug.new())

    -- Your game systems...
end

love.run = tecs2d.run({ fps = 60, game = gamePlugin })
```

With the plugin installed:

- **Ctrl+/** opens the modal debugger and freezes the game.
- **Ctrl+.** toggles the stats HUD.

## Modal debugger

Press **Ctrl+/** to open the debugger. Opening it freezes the game: every
gameplay phase is disabled and the render time scale is set to zero, so
animation and simulation stop while input and the overlay keep running. Pressing
Ctrl+/ again, pressing Escape on an empty prompt, or running `exit` closes it
and resumes the game.

The overlay draws two rows across the top of the screen. The upper row is a
status line showing the cursor position (screen and world), the camera, the
frame rate, and the entity count. The
lower row is a command line.

### Bindings and controls

The leader key is **Ctrl** by default. `leaderKey`, `debugToggleKey`, and
`statsToggleKey` can be changed in the plugin configuration.

| Keyboard | Action |
| --- | --- |
| Ctrl+/ | Open or close the debugger; opening freezes the game |
| Ctrl+. | Toggle the stats HUD, whether the debugger is open or closed |
| Ctrl+C | Clear the command, completion cycle, and popup without closing the debugger |
| Ctrl+Y | Yank the last executed command's popup or message to the clipboard |
| Escape | Close the context menu; otherwise clear prompt state, or close the debugger when the prompt is empty |
| Enter / keypad Enter | Execute a non-empty command; activate the highlighted context-menu item |
| Tab / Shift+Tab | Cycle completions forward or backward; hold to repeat |
| Up / Down | Browse command history; move through an open context menu |
| Left / Right | Page through a multi-page popup |
| Backspace | Delete the last command-line character |
| Delete | Despawn every selected entity |

| Pointer | Action |
| --- | --- |
| Left-click | Toggle the entity under the cursor in or out of the selection |
| Left-drag and release | Add every entity inside the box to the selection |
| Shift+left-drag | Move the selection with the cursor; right-click cancels and restores the original positions |
| Right-click | Open the context menu for the entity or empty world position under the cursor |
| Context-menu hover/click | Highlight and activate an item; clicking outside or right-clicking closes the menu |
| Middle-drag | Pan the camera |
| Wheel | Zoom toward the cursor |

The entity context menu includes info, selection, marks, notes, copy ID, set,
remove, and despawn actions. The empty-space menu includes copy position, spawn,
draw marker, physics query, and tile inspection actions.

Selected entities are highlighted in the world. The selection is a set: Left
Clicks and drags add to it, and Left Clicking a selected entity removes it.

### Commands

Type a command and press Enter. As you type, its usage appears to the right. On
an empty line, the completion cycle starts at the last used command, so
Tab-Enter quickly repeats recent work. Command history persists across sessions
in the save directory (`history` lists it, `history clear` forgets it). Long
commands wrap onto additional rows instead of running off screen.

The bar shows a short one-line hint as you type. Commands with richer usage
(`snapshot`, `screenshot`, `profile`, `query`) keep that hint terse and carry a
full usage block that pops up automatically once you have typed the bare command
name, and is also available any time with `help <command>`.

Commands are grouped into sections, mirrored by `help` and the Tab-completion
strip (which separates sections with colored `| Section |` markers).

**Select**

| Command | Description |
| --- | --- |
| `select <id\|name> [replace]` | Select an entity by id, or every entity with the mark `name`; `replace` swaps the selection instead of adding |
| `clear` | Clear the selection, message, and drag area |
| `mark [name\|list\|clear]` | Name all selected entities; `list` shows marks, `clear` removes all, an empty name unmarks the selected |
| `goto <id\|name>` | Move the camera to the entity `id`, or the first entity marked `name` |
| `note [msg]` | Annotate the selected entities for the agent; an empty message clears the note |
| `info [id\|name]` | Show an entity's components as pretty-printed JSON; Left/Right page long output |
| `despawn [id\|name]` | Despawn `id`, every entity marked `name`, or every selected entity |
| `query <expr> [invert]` | Select entities matching a component query; `invert=true` de-selects the matches instead |
| `ids [on\|off]` | Toggle entity id labels over on-screen entities (up to 200) |

**Edit**

| Command | Description |
| --- | --- |
| `set <id\|name\|@selection> Comp {lua}` | Set one component from a Lua table value; adds it when missing and resets omitted fields to defaults |
| `modify <id\|name\|@selection> Comp {lua}` | Change only the given fields of a component the target already has; targets without it are skipped |
| `remove <id\|name\|@selection> Comp ...` | Remove components from the target entities |
| `spawn [bundle] Comp {lua} ...` | Spawn an entity from a bundle and/or components |
| `draw rect\|circle\|line\|text\|clear ...` | Draw world-space annotations over the game (see below) |

**Render**

| Command | Description |
| --- | --- |
| `light info\|color\|toggle\|shadows\|bloom` | Lighting state; `color r g b` sets ambient, `toggle`/`shadows` flip lighting and shadows, `bloom` configures bloom |
| `camera info\|move\|timescale\|toggle` | Inspect the camera, move it, set the time scale, toggle named cameras |
| `layers list\|info\|all\|toggle\|solo\|unlit` | List render layers; `info` shows one layer's flags and entity count, `toggle` hides, `solo` isolates (bare `solo` restores), `all` shows everything again, `unlit` toggles lighting |
| `grid [on\|off] [size=N] [offsetX=N] [offsetY=N]` | Toggle a world-space grid; matches the tile-chunk grid by default, with optional size and origin overrides |
| `bounds [on\|off]` | Outline entities with known sizes (sprites, rectangles, circles, ellipses) |
| `map [id]` | Tilemap info (first map or by entity id): size, tile size, origin, layers, tilesets; `map info x y [id]` shows the tile at a world point with per-layer gids, falling back to grid coordinates without maps |
| `materials list\|info <name\|id>` | List registered materials; `info` shows a material's fragment and vertex GLSL |
| `sprites info` | Sprite renderer stats: buckets, instance counts, texture memory |

**Engine**

| Command | Description |
| --- | --- |
| `systems list\|stop\|start\|toggle\|info` | List systems and stop or restart them by name |
| `states info\|push\|pop` | Show the state stack; push a created state or pop the top |
| `archetypes list\|info <id>\|select <id>` | List archetypes by entity count; show one, or select its entities |
| `components list\|info <name>` | List component types; `info` shows a schema and defaults by name or id |
| `physics info\|debug\|raycast\|query` | Physics state or one body's properties; `debug` toggles collision-shape drawing (installing the drawer on first use); `raycast`/`query` probe with a drawn ray/box that selects the hits |
| `controllers list\|info <id>\|rumble <id>` | List controllers; `info` shows bindings, `rumble` test-vibrates |
| `assets list\|info <path>\|reload <path>` | List every loaded asset with its status (even after the game drops its handle), show one, or re-read one from disk in place |
| `audio info\|stop\|mute` | Audio status; stop every source or mute the master group |

**Capture**

| Command | Description |
| --- | --- |
| `profile [seconds\|info\|open\|path\|list\|clear]` | Sample the running game (see below); `info` re-shows a summary, `open` hands a capture to speedscope, `path` copies its absolute path |
| `snapshot save\|load\|open\|path\|info\|list\|clear [ref]` | Save/load/open the whole world (`save` reports a number you can pass to the other verbs); `path` copies the file's absolute path |
| `screenshot [name\|open\|path\|info\|list\|clear]` | Capture the screen (or the drag area) to a PNG; `panel=true` keeps the debugger visible, `delay=n` defers the capture; `info` shows details with a thumbnail, `path` copies the file's absolute path |
| `rewind start\|stop\|pause\|resume\|list\|info\|load\|keep\|clear` | Time travel: a rolling snapshot ring captured on wall-clock intervals; `load` rewinds the world, `keep` promotes an entry into the snapshot history |
| `diff <from> [to] [filters]` | Structural diff between snapshots, rewind entries, and the live world; `diff get <pointer>` drills into the result |
| `record start\|stop\|status\|info\|list\|open\|path\|cancel` | Record the window by capturing frames, then assemble with ffmpeg; `path` copies the file's absolute path |

**Session**

| Command | Description |
| --- | --- |
| `help [command]` | List everything in a paged popup, or one command's detailed usage |
| `history [clear]` | Show the persisted command history |
| `capabilities` | Installed plugins, command sections, capture support, and host features |
| `agent info\|connect` | MCP session info; `connect` copies the client config JSON |
| `step [n]` | Tick the game `n` frames while otherwise frozen (default 1) |
| `exit` | Close the debugger (same as Ctrl+/ or Escape) |
| `quit` | Quit the game |

### Marks and notes

Marks name a group of entities and notes attach a message to them. Both survive
until the entities are despawned.

```
select 42        # add entity 42 to the selection
mark boss        # name the whole selection "boss"
goto boss        # move the camera to the first entity marked "boss"
note flickers when hit
```

`mark list` (or `mark ls`) pops up the list of marks, each with its entity
count and first id, so you can see what is available. Running `mark` or `note`
with no argument clears the mark or note on the current selection. Mark names
cannot be purely numeric, since numbers resolve to entity ids everywhere a
target is accepted.

Marked and noted entities carry a small label in the world (the mark name, plus
`*` when a note is present) so it is visible which entities are annotated.

### Queries

`query` selects every entity matching a component expression. Each token names a
component:

| Token | Meaning |
| --- | --- |
| `Foo` | Must have `Foo` |
| `-Foo` | Must not have `Foo` |

For example:

```text
query Position Velocity -Dead
```

selects entities that have `Position` and `Velocity` and not `Dead`. The matches
are added to the current selection. `invert=true` refines instead of adding: it
de-selects the currently selected entities that match the expression, so
`query Dead invert=true` drops the dead ones from your selection.

### Editing entities

`set`, `remove`, and `spawn` edit the world directly. Their target is an entity
id, a mark name, or the literal `@selection`; component values are Lua table
expressions (easier to type than JSON), evaluated with the same trust as
`run_lua`:

```text
set 42 Transform {x = 100, y = 50}
set @selection Color {r = 1, g = 0, b = 0}
remove @selection Burning Stunned
spawn Transform {x = 160, y = 120} Sprite {sheet = "player"}
spawn enemy Transform {x = 0, y = 0}
```

`spawn` accepts an optional leading bundle name, then component name / value
pairs (a bare component name uses its defaults); the new entity is added to the
selection. Agents call the same actions as `debug_set`, `debug_remove`, and
`debug_spawn`, passing the value expression as a string.

### Annotations and id labels

`draw` places world-space shapes and text over the game, drawn every frame
whether the panel is open or not:

```text
draw rect 10 10 64 48 tag=zone
draw circle 0 0 20 entity=42 r=0 b=1
draw text 5 -30 spawn point here seconds=10
draw clear zone
```

Every verb takes color channels (`r= g= b= a=`), a `tag` for grouped clearing,
`seconds` for a wall-clock expiry (0 = one frame), `stroke` for outline width, and
`entity` to pin the annotation to an entity: positions become offsets from its
Transform and the annotation is removed when the entity dies. Durations use
wall-clock time, so annotations appear and expire even while the game is
frozen. Agents draw through the `debug_draw_*` tools.

`ids` toggles small entity-id labels over every on-screen entity (capped at
200 labels), so ids can be read off the screen and used in commands.

### Cameras, systems, and time

`camera` shows the camera position, zoom, rotation, and time scale plus every
registered camera; `camera move [x y] [r] [z]` repositions it, with omitted
parameters keeping their current values (`camera move z=0.3` zooms in place;
a named camera via `name=`), `camera timescale 0.5` sets the game speed (applied on unfreeze
when set while frozen), and `camera toggle <name>` flips a named camera's
active flag.

`systems` lists every system with its phase and state; `systems stop <name>` /
`systems start <name>` / `systems toggle <name>` gate one by name (useful for
bisecting a rendering or gameplay bug live), and `systems info <name>` shows
its phase, order, and state.

### Profiling

`profile` samples the running game with the LuaJIT sampler. Because the game
must run to be sampled, `profile` closes the debugger (unfreezing the game) and
starts a session:

- `profile <seconds>` samples for that long, then reopens the debugger with the
  results: the saved file, the top 10 hot spots by self-samples (each labeled
  with the zone it ran in), and the top 10 systems by inclusive samples
  (every system runs in its own sampler zone, so per-system CPU share falls
  out of the same capture).
- `profile` with no duration samples until you reopen the debugger yourself
  (Ctrl+/), which stops the session and shows the results.

The collapsed-stack file (loadable in speedscope) is written to the game's
working directory, and its path plus the top frames are published to the debug
context for the agent. `profile info [name|index]` re-generates the summary
for any past capture (the latest if omitted), and `profile open [name|index]`
opens [speedscope](https://www.speedscope.app/) in the browser with the
capture's absolute path copied to the clipboard, ready to paste into the
file picker.

### Snapshots

`snapshot save [name]` writes the whole world to the game's save directory and
reports a save number; `snapshot load [name|number]` restores it (loading clears
the selection, marks, and notes since entity ids change). `snapshot open
[name|number]` opens the file with the OS default handler. With no name, `save`
auto-names by number and `load`/`open` use the most recent save. `snapshot list`
shows every save with its size and timestamp, `snapshot info [name|number]`
shows one save's details (number, paths, size, time, the entity count captured
at save time, and whether the file is still on disk), and `snapshot clear` deletes the files and wipes the history.
Every save is recorded in the debug context with its number, path, size, and
timestamp. `profile list` and `profile clear` work the same way for captures.

### Time travel

`rewind start [interval=5] [cap=10]` keeps a rolling ring of world snapshots
under `debug-rewind/` in the save directory, captured on wall-clock intervals.
Capture never runs while the freeze controller is held (the debugger is open,
an agent paused the game, or a recording countdown froze it), so freezing to
investigate cannot churn the ring and evict the history you came for.

When something goes wrong: freeze, `rewind list` to see the ring newest first
(age, timestamp, size, entity count), then `rewind load 3`, `rewind load
latest`, or `rewind load ago=10` (shorthand: `rewind load 10s`) to restore
the closest capture at or before that age. Loading clears the selection, marks, and notes, and pauses capture
(reason `loaded`) so the ring stops overwriting the timeline; `rewind resume`
continues it. `rewind keep <ref> [name]` copies an entry into the normal
snapshot history with a snapshot number, preserving its capture time. `rewind
stop` ends the session but keeps the ring; `start` refuses to overwrite a
stopped ring (`keep` what you need, then `rewind clear`). `rewind info` shows
the session state, window, total bytes, and the last capture's cost in
milliseconds: captures serialize the whole world on the main thread, so heavy
worlds should prefer longer intervals.

A typical flow:

```text
rewind start 2 30        60-second window, capturing quietly
...bug happens...
Ctrl+/                   freeze; captures hold automatically
diff rewind:10s ignore=Transform    what changed in the last 10 seconds?
rewind load ago=10       jump to just before it went wrong
step 30                  replay toward the bug frame by frame
rewind keep latest before-bug
```

### Diffing timelines

`diff <from> [to]` compares any two moments structurally: `from`/`to` are a
snapshot number, filename, or `latest`; `rewind:<idx|latest|Ns|ago=N>`; or
`current` (the default for `to`). Binary refs decode through a throwaway
scratch world, so a diff never mutates the live world, the selection, or the
rewind state, and decoded snapshots are cached for the session so refiltering
the same pair is cheap.

Results are normalized by entity id and component name (archetype order can
never produce false differences) and reported as add/remove/replace changes
with JSON Pointer paths. The summary always covers the complete diff, per
component, even when the detailed list is truncated by `limit=` (0 = summary
only). Filters narrow both: `entity=<id|mark|@selection>`,
`component=Health`, `ignore=Transform,Velocity` (the usual first move on a
live game, where positions drift constantly), and `epsilon=0.001` for numeric
tolerance. Custom snapshot-handler data is skipped symmetrically and noted in
the result.

Every run writes the full result to `debug-diff-N.json` in the save dir
(`diff ls`/`open`/`path`/`clear` manage them), and `diff get <pointer> [ref]`
dereferences an RFC 6901 pointer into the last diff or a saved one:
`diff get /summary/byComponent`, `diff get /changes/0/after`. Filters select;
pointers dereference.


### Screenshots

`screenshot [name]` captures the frozen screen to a PNG in the game's save
directory (the debugger chrome is hidden for that one frame, so the shot is the
game only; pass `panel=true` to keep it visible). `delay=n` waits `n` seconds
before capturing, which pairs well with `panel=true` for shots of the debugger
itself. If a drag area is active, only that region is captured. `screenshot
list` shows every capture with its size and timestamp, `screenshot open [name]`
opens one (the most recent with no name) in the OS image viewer, and `screenshot
info [name]` shows a capture's details along with a scaled thumbnail rendered
in the game view for as long as the popup is up. `screenshot clear` deletes
them. Each capture is recorded in the debug context.

### Recordings

`record start [seconds] [name] [fps=30] [scale=1] [countdown=N] [debug]` arms a
recording. The
debugger shows a countdown, then closes and unfreezes gameplay so the debug
overlay is not in the capture. Untimed recordings stop when the debugger is
reopened or when `record stop` is run. Timed recordings keep running if the
debugger is reopened, so you can capture the debug panel; they stop when the
duration expires or when `record stop` is run. `stopOnDebugOpen=true|false`
overrides that default explicitly. `record cancel` cancels an armed countdown.
`record status`, `record list`, `record info [name|latest]` (path, size,
duration, stop reason, log location), and `record open [name|latest]` inspect
and open recordings.

`fps` sets the capture rate and `scale` sets the output resolution multiplier
(for example `scale=0.5` records at half resolution). Both fall back to the
plugin defaults (`recordingFps`, `recordingScale`).

Pass `debug` (or `debug=1`) to record the debugger itself, for instructional
videos: the debugger stays open and interactive during the recording, and,
unlike opening it normally, the game keeps running instead of freezing. So you
can pan and zoom the camera, show live lighting and animation, and select
entities or run commands with the overlay on camera. The captured frames include
the debug overlay. When the recording ends, an open panel re-freezes the game as
usual.

Recording captures the game's own framebuffer with `love.graphics.captureScreenshot`
each frame and hands it to a worker thread that writes numbered images to disk;
on stop, a single `ffmpeg` pass assembles them into the video and the intermediate
images are deleted. This needs no macOS Screen Recording permission, works headless,
and captures exactly the window. `ffmpeg` must be on `PATH` (only for the offline
assembly), and the capture pipeline shells out POSIX-style, so host recording is
supported on macOS and Linux only. Its stdout/stderr is written next to the recording as `<name>.ffmpeg.log`;
use `record status` to see the log path.

Frames beyond the in-flight ring (`recordingRingSize`, default 8) are dropped
rather than stalling the game loop, so a slow encoder lowers the effective frame
rate instead of hitching gameplay. The video is always assembled at the rate
actually achieved (frames written divided by the recorded duration), so playback
stays at real-time speed even when frames are dropped; heavy dropping shows up as
choppiness, not as a fast-forwarded clip.

Image encoding is the usual bottleneck, and `captureScreenshot` returns the full
pixel framebuffer, so on a high-DPI (Retina) display the frames are several times
larger and drops are more likely. If a recording comes out choppy, lower the
capture rate (`fps=15`) or use a faster image format (`recordingFrameFormat =
"tga"`, larger on disk but much faster to encode).

## Stats HUD

Press **Ctrl+.** to toggle the stats HUD. It samples once per second and shows:

- **FPS**: current frames per second
- **Lua**: Lua heap memory in MB
- **Tex** / **Buf**: GPU texture and buffer memory (with buffer count)
- **Draws** / **Batched**: draw calls this frame and how many batched
- **Canvas** / **Shader** switches: render-target and shader-program changes
- **E / C / S / A**: entities, component types, systems, and archetypes

<img src="/images/debug-overlay.jpeg" alt="Stats HUD"/>

## Configuration

```teal
local debug = require("tecs2d.debug")

world:addPlugin(debug.new({
    -- Modifier held with a toggle key: "ctrl" (default), "alt", "shift",
    -- or "gui"/"cmd"/"super".
    leaderKey = "ctrl",

    -- Key that, with the leader, toggles the modal debugger (default "/").
    debugToggleKey = "/",

    -- Key that, with the leader, toggles the stats HUD (default ".").
    statsToggleKey = ".",

    -- Seconds between graphics/world stat samples (default 1).
    sampleFrequency = 1,

    -- Seconds between Lua heap-size samples (default 8).
    gcFrequency = 8,

    -- ffmpeg executable path/name, used to assemble frames (default "ffmpeg").
    recordingFfmpegPath = "ffmpeg",

    -- Save-directory subfolder for recording outputs (default recordings).
    recordingOutputDir = "recordings",

    -- Countdown before recording starts (default 3).
    recordingCountdown = 3,

    -- Default capture frame rate (default 30).
    recordingFps = 30,

    -- Default output scale multiplier (default 1).
    recordingScale = 1,

    -- Captured image format: "png" (default), "tga", or "jpg".
    recordingFrameFormat = "png",

    -- Max frames in flight before dropping (default 8).
    recordingRingSize = 8,
}))
```

## Agent integration

The [Runtime introspection](./introspection) guide explains the complete
human-agent workflow. To expose this debugger to an AI agent, add the
[MCP plugin](./mcp/) alongside it:

```teal
world:addPlugin(require("tecs2d.mcp").new())
world:addPlugin(require("tecs2d.debug").new())
```

The debug plugin publishes a `DebugContext` resource, and the MCP server reads
and drives it:

- **`get_debug_context`** returns the open and frozen state, the current
  command, the last message, the selection, the entity count, the stats HUD
  visibility, any drag area, and the marks and notes.
- The debugger's commands are projected as **`debug_*` tools**. Every command
  is declared once (schema, help, subcommands, action) in a shared registry;
  the overlay dispatches typed command lines through it, and the MCP server
  exposes the same registry with JSON schemas generated from the command
  schemas: `debug_select` (its `replace` flag swaps the selection),
  `debug_clear`, `debug_mark` (plus `_list` / `_clear`), `debug_goto`,
  `debug_note`, `debug_despawn`, `debug_query`, `debug_light` / `debug_light_bloom`,
  `debug_screenshot` (plus `_list` / `_clear` / `_open`), the
  `debug_snapshot_*` verbs, `debug_profile_list` / `debug_profile_clear`, and
  the `debug_record_*` verbs.

Anything the operator can type, the agent can call with the same validation and
the same effects, including the on-screen highlights. Commands that already
have a purpose-built MCP tool are not duplicated: use `step`, `pause`/`resume`,
`profiler_start`/`profiler_stop`, `get_entity`, and `quit` instead of debugger
`step`, `profile`, `info`, and `quit`.

Pausing is shared: the debugger's freeze and the MCP `pause` tool go through
one freeze controller, so an agent pause survives the operator opening and
closing the debugger, and `step` works no matter which side froze the game.

Agents follow what the operator does through the log feed: every action
(selection changes, marks, notes, edits, spawns, artifact writes, panel
open/close) logs a `kind key=value ...` line under `tecs2d.debug.events`, and
**`get_logs`** reads it back with a seq cursor
(`{after = <last seq>, contains = "debug.events"}`). Pair it with
**`get_component_schema`** (field names, C types, and defaults for building
`debug_set` / `patch_entities` payloads); both are documented with the
[MCP tools](./mcp/tools).

`get_debug_context` also carries the session's `snapshots`, `profiles`,
`screenshots`, current `recording` state, and completed `recordings`. These
lists are capped to the five most recent entries so a long session does not
ship an unbounded history each call.
Snapshots, profiles, screenshots, and recordings include `path`, `size`, and
`time`; snapshots also carry a `number`. Writing snapshots, profiles, or screenshots
emits an `OnDebugContext` event (to address 0, with `kind`, `path`, and
`number`) that game systems can observe.

Marks and notes are returned keyed by name or message, with the entity ids
encoded as a compact range string. A group of contiguous ids becomes `"8-12"`
and a single entity becomes `"5"`, so large named groups stay cheap to ship to
the agent:

```json
{
  "marks": { "boss": "8-12,20" },
  "notes": { "flickers when hit": "8" }
}
```

A typical workflow is to run the game in a window, connect an agent to the MCP
server, click or drag to select entities in-game, and let the agent read the
selection and the notes to reason about what is on screen.
