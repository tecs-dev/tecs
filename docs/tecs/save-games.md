---
description: "Snapshot save and load with saveSnapshot, loadSnapshot, transient components, snapshot handlers, filtering, and the binary format spec"
outline: deep
---

# Save games

Tecs provides a fast snapshot system for save games, checkpoints, and state restoration. Plugins and game code can
attach arbitrary metadata alongside ECS data so snapshots stay self-contained (e.g., player profile,
physics state, RNG seeds, etc).

```teal
-- Save the world to a string.buffer
local buf = world:saveSnapshot().buffer

-- Load the world from the buffer
world:loadSnapshot(buf)
```

## Save formats

Tecs provides two save formats out of the box:

| Format | API                                                | Description |
| ------ | -------------------------------------------------- | -------- |
| Binary | `world:saveSnapshot()`, `world:loadSnapshot(...)` | High-performance [LuaJIT-based](https://luajit.org/ext_buffer.html#serialize) binary format. This should be the default choice for production saves. |
| Table  | `world:saveSnapshot({format=\"table\"})`, `world:loadSnapshot(...)` | Programmatic inspection, in-memory round-trips, and custom tooling (e.g. JSON via `tecs.json`). |

## What is and isn't saved by default

A snapshot captures durable ECS state and the framework's own runtime bookkeeping. It does not capture anything that
lives outside the ECS world. The lists below are exhaustive for the built-in save path; everything else is your
responsibility through the [custom data](#customdata) and [snapshot handler](#snapshot-handlers) mechanisms.

### Saved automatically

- **Entities**, at their original ids. Slot and generation are preserved, so handles stay valid across a same-world load.
- **Components.** FFI components memcpy their raw column bytes; table components round-trip every number, string,
  boolean, and table field through a default serializer, or through a [custom `serialize`](#per-component-serialization).
- **Relationships**, including their targets.
- **The [state stack](/tecs/states)**: the active state and everything pushed beneath it.
- **Pipeline runtime state**: the fixed-timestep accumulator and per-phase enable flags.
- **The [`Key`](/tecs/builtins#key-component) index**, rebuilt from the restored entities.
- **Custom data** you attach through [`customData`](#customdata) or a [snapshot handler](#snapshot-handlers).

### Not saved

- Components marked [`transient`](#transient-components), and entities removed with
  [`ev:exclude(...)`](#excluding-derived-entities).
- **Non-exclusive sparse relationships.** Their stores hold multiple targets per source, which does not fit the
  snapshot's one-value-per-component row format; saving a world that uses one raises an error unless the
  relationship is marked `transient`.
- **`world.resources`.** Managers, RNGs, config objects, network sessions, and anything else stored there is outside
  the ECS. See [World resources](#world-resources) below.
- **Process-local runtime objects**: GPU buffers, renderer handles, physics bodies, audio voices, Love `userdata`,
  open file handles, and thread workers.
- **Lua locals, closures, and callbacks.** A variable that points at an entity, and an observer registered on an
  entity address, do not survive a load. Rebind them from a [`Key`](#runtime-handles-after-load) or reinstall them
  from ECS data.

The practical rule: snapshot the data you would write in a save file, and rebuild the objects you would create during
startup. Store durable source-of-truth as components, mark process-local backing components `transient`, and recreate
derived objects during the [load lifecycle](#snapshot-handlers).

### Per-component serialization

Most components serialize automatically. Table components round-trip every field, and FFI components memcpy through
their schema. Components holding non-portable durable state (Love2D handles, GPU slab pointers, derived fields) can
opt out of the bulk path with custom `serialize` / `deserialize` hooks. Runtime-only components that should never be
saved should use `transient = true`.

Snapshots also survive component changes across game updates: when a patch adds, removes, reorders, or retypes an
FFI component's fields, old saves migrate automatically on load. See [Schema fingerprinting &
migration](/tecs/components/serialization#schema-fingerprinting-migration) for exactly what carries over and how to
handle renames.

> See [Component serialization](/tecs/components/serialization) for the full reference, covering when to
override, schema fingerprinting and migration, performance implications, and examples.

### Transient components

Use `transient = true` when the entity is durable but one component on it is renderer-, physics-, audio-, or
plugin-owned runtime state. The entity is still saved; transient component columns are left out of the saved
archetype. On load, normal spawn behavior applies, including `requires` defaults for transient components.

```teal
local SpriteData = tecs.newFFIComponent({
    name = "SpriteData",
    container = SpriteData,
    fields = {
        {"width", "float"},
        {"height", "float"},
    },
    transient = true,
})
```

`transient = true` cannot be combined with a custom `serialize` function: declare the whole component runtime-only
with `transient`, or provide durable serialization, not both.

### Excluding derived entities

A plugin that owns *derived* entities (a projection of smaller durable input) can skip them at save time with
[`ev:exclude(component)`](#snapshot-events); any entity carrying an excluded component is omitted, and the plugin
re-derives it from the saved source-of-truth on load.

```teal
world:observe(0, tecs.builtins.OnSnapshotSave, function(ev: tecs.builtins.OnSnapshotSave)
    ev:exclude(gfx.TileChunk)   -- GPU tile instances; re-spawned from Tilemap on load
end)
```

The contract is symmetric: whatever the plugin omits, the plugin re-creates.

### Handled by built-in plugins

The Tecs2D plugins take care of their own runtime state, so these survive a snapshot with no work from you:

- **[Audio](/tecs2d/audio/)**: mixer settings (group volumes, mutes, pauses, and listener position) and attached
  [`AudioSource`](/tecs2d/audio/components) sounds.
- **[Cameras](/tecs2d/rendering/camera)**: each camera's view state (position, zoom, rotation, lerp, and world
  bounds) and [`CameraTarget`](/tecs2d/rendering/camera#cameratarget-component) follow behavior.
- **[Sprites](/tecs2d/rendering/sprites/) and [text](/tecs2d/rendering/text)**: on-screen content and animation state.
- **[Physics](/tecs2d/physics/)**: [colliders and rigid bodies](/tecs2d/physics/components), including their current
  velocity.
- **[Tweens](/tecs2d/tween#snapshots)**: in-progress tween playback.
- **[Tiled maps](/tecs2d/tiled/)**: the [tilemap](/tecs2d/tiled/tilemap) and its rendered tiles.

One caveat: cameras are matched by name on load, so a camera your code creates dynamically at runtime is restored only
if a camera with that name exists again after the load.

### World resources

A snapshot does not capture `world.resources`. Anything you store there is runtime state outside the ECS and is lost
on load unless you persist it yourself. Register a [snapshot handler](#snapshot-handlers) for each resource that holds
durable state:

```teal
world:addSnapshotHandler({
    name = "mygame.rng",
    save = function(_world: tecs.World): any
        return rng:save()
    end,
    load = function(_world: tecs.World, value: any)
        rng:load(value)
    end,
})
```

The built-in plugins already do this for their own resources; see [Handled by built-in
plugins](#handled-by-built-in-plugins).

## World:saveSnapshot

Snapshots the ECS world and allows plugins to inject custom data.

```teal
function world:saveSnapshot(opts?: tecs.SnapshotOptions): tecs.SnapshotOutput
```

**Parameters:**

- `opts`: [Snapshot save options](#saveoptions)

**Returns**

- A tagged `SnapshotOutput`
- For binary saves: `{format = "binary", buffer = string.buffer, snapshot = nil}`
- For table saves: `{format = "table", buffer = nil, snapshot = Snapshot}`

### SaveOptions

All fields are optional; the default `world:saveSnapshot()` captures every entity into a fresh buffer with no
custom data.

| Field           | Type                                    | Purpose |
| ----------------| ----------------------------------------| ------- |
| `format`        | `"binary" \| "table"`                   | Output format. Defaults to `"binary"`. |
| `buffer`        | `string.buffer`                         | Reuse an existing buffer instead of allocating a fresh one. The buffer is `:reset()` first; see [Reusing a buffer across saves](#buffer). |
| `path`          | `string`                                | Optional binary output file path. Writes the bytes to disk and still returns the tagged result. |
| `filterQuery`   | [`QueryDescriptor`](/tecs/queries/) | Only save entities matching this query (`include` / `includeAny` / `exclude`). Composes freely with `layers`. |
| `layers`        | `{integer}`                             | Allow-list of `Transform.layer` values (0..31). Filters Transform-bearing entities by layer; entities without a `Transform` pass through unchanged. |
| `customData`    | `{string: any}`                         | Keyed metadata attached to the snapshot's data section. Values must be `string.buffer`-encodable. See [Snapshot handlers](#snapshot-handlers) for how to read it back. |

#### buffer

For high-frequency saves (replay buffers, autosave loops), pass `opts.buffer` to reuse one allocation:

```teal
local buffer = require("string.buffer")
local sharedBuf = buffer.new()

for round = 1, 1000 do
    world:saveSnapshot({buffer = sharedBuf})
    -- The buffer is :reset() automatically before each save.
    -- Do whatever you need with it (compress, send, write to disk, etc.)
end
```

#### filterQuery

You can restrict the capture to a subset of entities by providing a `filterQuery`. Any
[`QueryDescriptor`](/tecs/queries/) works (`include`, `includeAny`, `exclude`); only matching archetypes are
walked.

```teal
-- Only entities that carry a Persist component.
world:saveSnapshot({
    filterQuery = {include = {Persist}},
})
```

#### layers

Some games are logically laid out by layer. You can serialize just specific layers by providing `layers`,
an array of `Transform.layer` values (0..31). Entities carrying a `Transform` with a layer outside the allow-list
are skipped; entities that don't have a `Transform` pass through unchanged (the filter only applies when there's
something to filter on).

```teal
-- Only Transform-bearing entities on layer 2 or 3. Non-Transform
-- entities (e.g. singletons, config entities) still flow through.
world:saveSnapshot({layers = {2, 3}})

-- Combine with a query: Persist entities; if they have a Transform,
-- it must be on layer 2 or 3.
world:saveSnapshot({
    filterQuery = {include = {Persist}},
    layers = {2, 3},
})
```

#### customData

You can attach keyed metadata (build version, player profile, checkpoint, etc.) by providing `customData`. Each entry
becomes a data pair in the snapshot. Values must be `string.buffer`-encodable (numbers, strings, booleans, plain
tables). See [Snapshot handlers](#snapshot-handlers) for how to read the data back on load.

```teal
world:saveSnapshot({
    customData = {
        build     = "v0.1.2-alpha",
        player    = "Alice",
        checkpoint = {level = "intro", elapsed = 42.5},
    },
})
```

### Table snapshots

Capture the world into a plain Lua snapshot table by requesting table format. Use it when you need to inspect, mutate,
or transform the snapshot programmatically, or feed it through another serializer:

```teal
local snap = world:saveSnapshot({format = "table"}).snapshot
-- snap is a plain Lua table: mutate, inspect, walk by hand.

world:loadSnapshot(snap)
```

It accepts the same [`opts`](#saveoptions) as `saveSnapshot` (minus `buffer`). The table is JSON-friendly, so you can
feed it through `tecs.json` for human-readable saves:

```teal
local snap = world:saveSnapshot({format = "table"}).snapshot
love.filesystem.write("save.json", tecs.json.serialize(snap))

local payload = love.filesystem.read("save.json")
world:loadSnapshot(tecs.json.parse(payload))
```

::: tip Table snapshots are slow
The table format is substantially slower than binary. Prefer binary for production save games, and reach for table
format for debugging, migration, or any case where you need to peek at the snapshot before applying it.
:::

## World:loadSnapshot

Restores a previously saved snapshot into `world`, replacing the current world state. See
[Snapshot handlers](#snapshot-handlers) for how to hook into the load lifecycle and read back custom data.

```teal
function world:loadSnapshot(source: any): tecs.SnapshotPrelude
```

**Parameters:**

- `source`: Either a Lua string (e.g. from `love.filesystem.read`) or a `string.buffer` produced by `saveSnapshot`.
  Strings are copied once into an internal buffer; buffers are read directly without first converting to a Lua string.
  You may also pass a snapshot table or a tagged `SnapshotOutput`.

**Returns**

- `SnapshotPrelude` with `version`, `nextEntityId`, `entityCount`, `archetypeCount`, and `componentTable`.

### Runtime handles after load

Snapshots restore durable ECS state, not the application handles that point into it (see [What is and isn't saved by
default](#what-is-and-isnt-saved-by-default)). If a runtime variable points at an entity that must survive save/load
or hot reload, give that entity a [`Key`](/tecs/builtins#key-component) and rebind after loading:

```teal
local playerId = world:spawn(
    tecs.builtins.Key("player"),
    Player()
)

-- Later:
world:loadSnapshot(saveBuffer)
playerId = world:requireKey("player")
```

The snapshot lifecycle is designed for this. `StartSnapshotLoad` lets plugins read custom data, and
`FinishSnapshotLoad` is the right place to refresh runtime handles that depend on the fully restored world. For state
kept in `world.resources` rather than on an entity, see [World resources](#world-resources).

### Observers and runtime callbacks

Snapshots do not serialize Lua callbacks or closures. Global observers registered at address `0` survive only a
same-world `loadSnapshot`, because the existing world, systems, and message bus remain installed. If the process
exits and a save is loaded into a new world, plugins must register their global observers again during normal setup.
Entity-address observers do not survive either case: loading a snapshot replaces the current entity set, and
despawning an entity clears observers registered on that entity's address.

When an entity needs durable behavior, save the intent as ECS data and let a query or system install the runtime
callback. For example, instead of hand-registering a one-off `OnDespawn` callback for each entity that should make
an effect, store a component:

```teal
local record DespawnEffect is tecs.Component
    name: string
    metamethod __call: function(self, name: string): DespawnEffect
end

tecs.newComponent({
    name = "DespawnEffect",
    container = DespawnEffect,
    fields = {"name"},
})
```

Then let plugin setup react to matching entities and install the runtime entity observer:

```teal
local despawnEffectQuery = world:query({
    include = {DespawnEffect, tecs.builtins.Transform},
    onEntitiesAdded = function(archetype, firstRow, lastRow)
        local entities = archetype.entities
        for row = firstRow, lastRow do
            local entity = entities[row]
            world:observe(entity, tecs.builtins.OnDespawn, function(ev: tecs.builtins.OnDespawn)
                -- spawn the effect here...
            end, "despawn-effect")
        end
    end,
})
```

The dynamic part is still dynamic: gameplay can add or remove `DespawnEffect("poof")` at any time. The durable
part is no longer the observer closure; it is component data that snapshots and loads cleanly. After loading, the
plugin's query sees the restored matching entities and installs fresh entity-address observers from the restored
component state.

## Saving and loading from files

`saveSnapshot` returns a LuaJIT [string.buffer](https://luajit.org/ext_buffer.html); you decide how to
get its bytes onto disk.

### Plain files

You can use plain Lua files (though this allocates unnecessary intermediate strings):

```teal
-- Save to a Lua file
local buf = world:saveSnapshot().buffer
local f = io.open("save.bin", "wb")
f:write(tostring(buf))
f:close()

-- Load from a Lua file
local f = io.open("save.bin", "rb")
local data = f:read("*a")
f:close()
world:loadSnapshot(data)
```

### `love.filesystem.write` string

You can use Love2D's `love.filesystem.write` with a string. This is dead simple, but does unnecessary
string allocations.

```teal
-- Save to disk
local buf = world:saveSnapshot().buffer
love.filesystem.write("save.bin", tostring(buf))

-- Load from disk
local data = love.filesystem.read("save.bin")
world:loadSnapshot(data)
```

::: info Tecs core does not require Love2D
The core of Tecs, where snapshots live, has no Love2D dependency. It does depend on LuaJIT, and Love2D and LuaJIT
have really nice interop.
:::

### `love.filesystem.write` ByteData

The ideal method for saving and loading goes through Love2D's [ByteData](https://love2d.org/wiki/ByteData) and
[FileData](https://love2d.org/wiki/FileData) types instead.

For example, to save to disk with no string allocations:

```teal
local ffi = require("ffi")

local buf = world:saveSnapshot().buffer
local ptr, len = buf:ref()
local byteData = love.data.newByteData(len)
ffi.copy(byteData:getPointer(), ptr, len)
love.filesystem.write("save.bin", byteData, len)
```

To load from disk with no string allocations:

```teal
local buffer = require("string.buffer")

local fileData = love.filesystem.newFileData("save.bin")
local loadBuf = buffer.new(fileData:getSize())
loadBuf:putcdata(fileData:getPointer(), fileData:getSize())
world:loadSnapshot(loadBuf)
```

## Snapshot handlers

For most plugin and game state that lives outside components, register a named snapshot handler:

```teal
world:addSnapshotHandler({
    name = "mygame.rng",
    save = function(_world: tecs.World): any
        return rng:save()
    end,
    load = function(_world: tecs.World, value: any)
        rng:load(value)
    end,
    finish = function(world: tecs.World, _prelude: tecs.SnapshotPrelude)
        playerId = world:requireKey("player")
    end,
})
```

`save` writes one value into the snapshot data section under `name` when it returns non-nil. `load` receives that
value after the ECS world has been restored. `finish` runs after all snapshot data callbacks have completed, so it is
the right place to rebind `Key` handles and rebuild runtime indexes or resources that need the final restored world.

Values must be `string.buffer`-encodable. Use namespaced keys (`"tecs2d.physics"`, `"mygame.rng"`) to avoid
collisions.

## Snapshot events

`addSnapshotHandler` is built from three events that fire on entity 0 during save and load. Register directly with
`world:observe(0, event, callback)` when a plugin needs lower-level access; otherwise prefer the handler.

| Event                | Fires                                                                          | For |
| -------------------- | ------------------------------------------------------------------------------ | --- |
| `OnSnapshotSave`     | At the start of `saveSnapshot`, before archetypes are walked.                  | Attaching data and excluding derived entities. |
| `StartSnapshotLoad`  | During `loadSnapshot`, after the world is restored, before data is dispatched. | Registering per-key data callbacks. |
| `FinishSnapshotLoad` | During `loadSnapshot`, after every data callback has run.                       | Finalizing the loaded world. |

### OnSnapshotSave

| Member       | Signature                   | Purpose |
| ------------ | --------------------------- | ------- |
| `ev:addData` | `(key: string, value: any)` | Attach a keyed value to the data section. Values must be `string.buffer`-encodable. Calls are queued and flushed after the archetype data, so ordering is deterministic (per-listener, in call order). |
| `ev:exclude` | `(component: Component)`     | Omit every entity carrying `component` from the save. |

`addData` and `exclude` can be used together in the same listener.

### StartSnapshotLoad

| Member      | Signature                                       | Purpose |
| ----------- | ----------------------------------------------- | ------- |
| `ev:onData` | `(key: string, callback: function(value: any))` | Register a callback fired once per matching data entry. Keys with no callback are skipped; multiple callbacks for one key fire in registration order. |

### FinishSnapshotLoad

| Member       | Type              | Purpose |
| ------------ | ----------------- | ------- |
| `ev.prelude` | `SnapshotPrelude` | Version and entity/archetype counts of the loaded snapshot. |

## Plugin snapshot checklist

For each plugin or subsystem that participates in saves:

- Save durable source-of-truth components, relationships, and custom data.
- Use `world:addSnapshotHandler(...)` for ordinary non-component custom data and load-finalization work.
- Persist any durable state a plugin keeps in `world.resources` through a snapshot handler; resources are not saved.
- Mark process-local backing components `transient = true` when the entity itself is durable.
- Use `ev:exclude(component)` for fully derived entities that should not appear in saves.
- Rebuild derived entities, resources, and caches during normal systems or `FinishSnapshotLoad`.
- Store durable per-entity behavior as components/relationships interpreted by global observers or systems, not as
  entity-address callback registrations.
- Use `Key` only for stable anchors the application needs to rediscover, such as `"player"` or `"camera.main"`.
- Prefer queries or rebuilt indexes for groups of state-owned entities instead of assigning a key to every entity.
- Keep renderer handles, physics bodies, audio voices, controller state, open files, worker threads, and caches out of
  the snapshot unless they are converted into portable durable data.

## Performance

Numbers below were measured against the shape-bench example rendering circles on an Apple-silicon M1 Mac. Each entity
carries `Transform` + `Circle` + `Color`, all FFI components, spread across a handful of archetypes: representative of
a real game's hot entity loop, not a synthetic fast path.

| Entities | Save p50 | Load p50 | Size    |
| -------- | -------- | -------- | ------- |
| 10K      | 0.52 ms  | 0.98 ms  | 587 KB  |

Scaling is linear in entity count for both save and load; per-entity overhead is roughly 60 bytes (three FFI
components, ~20 bytes each), plus negligible fixed overhead per snapshot.

To reproduce:

```bash
make example-shape-bench SHAPE=circle ENTITIES=10000
```

then use the MCP integration to call `cmd_snapshot_save` against the running world.

::: details Fast-path lower bound
The synthetic `make snapshot-bench` hits a stricter fast path (three POD FFI components, no GPU handles, no
sparse containers) and clocks **10K save in ~18 μs / load in ~556 μs**. Many real games will not reach that lower
bound: shape-bench's numbers above are closer to what you'll actually see in a game with Transforms, rendering
components, and light mixed state. If your world uses components with custom `serialize` / `deserialize` (text,
sprites holding GPU handles, sparse relationships), expect per-entity costs above the shape-bench numbers too.
:::

::: details What makes the format fast
- **LuaJIT**: The biggest reason the binary path is so fast.
- **Pre-pass component table**: all unique components used in the save appear once in the prelude; archetype frames
  reference them by 1-based integer index instead of repeating name+schema strings.
- **Column-major data layout**: each FFI column writes / reads as one `structSize × entityCount` memcpy. No per-entity
  loops, no varargs spreading, no intermediate Lua tables.
- **Schema fingerprint per component**: every FFI component carries a canonical `field1:type1,...|sizeBytes` string.
  Save embeds it; load compares against the current registration. If it matches: bulk memcpy. If it doesn't match
  (e.g., a component changed in a game update): slower per-entity load.
- **Bulk entity IDs**: the entity ID array writes via one `putcdata` per archetype; loads via one `ffi.copy` into a
  freshly-allocated `double[count]`. Doubles let packed `(slot, generation)` ids up to 2^53 survive round-trip
  without truncation; the packed id format uses 22 bits for slot and 31 bits for generation.

Components with custom `serialize` / `deserialize` (e.g. `gfx.Text`, which holds non-portable glyph slab pointers) opt
out of the bulk path automatically and round-trip per entity through their structured codec.
:::

## Snapshot format spec

### Binary (LuaJIT `string.buffer`)

The wire format is a sequence of LuaJIT-encoded values + raw byte runs:

```
prelude:
    encode(version)
    encode(nextEntityId)
    encode(entityCount)
    encode(archetypeCount)
    encode(componentCount)
    per i in 1..componentCount:
        encode(name)             -- string
        encode(fingerprint)      -- "" for non-FFI components

per archetype:
    encode(columnCount)
    encode(entityCount)
    per c: encode(columnIndex)   -- 1-based into componentTable
    encode(mode)                 -- 0 = column-major, 1 = row-major (sparse)

    mode == 0 (column-major):
        putcdata(idsArray, entityCount * 8)            -- raw double[]
        per column:
            putcdata(column, structSize * entityCount) -- FFI bulk
            OR per k: encode(serialized value)         -- non-FFI / custom

    mode == 1 (row-major, sparse-bearing archetype, <= 52 columns):
        per entity:
            encode(id)
            encode(presenceMask)         -- bit (i-1) set = column i present
            per present column i: serializeRaw OR encode(serialize(value))

data section (sentinel-terminated):
    repeat: encode(true); encode(key); encode(value)
    encode(false)                    -- terminator
```

### Table (Lua / JSON)

`world:saveSnapshot({format = "table"}).snapshot` returns:

```teal
{
    version = 2,
    nextEntityId = 42,
    componentTable = {
        {name = "Position"},
        {name = "Health"},
    },
    archetypes = {
        {
            columnIndices = {1, 2},               -- references componentTable
            entities = {
                {1, {x=10, y=20}, {hp=100}},      -- {id, comp1, comp2, ...}
                {2, {x=30, y=40}, {hp=50}},
            },
        },
    },
    data = {                                      -- ordered (key, value) pairs
        {key = "build",  value = "v0.1.2-alpha"},
        {key = "player", value = "Alice"},
    },
}
```

Each entity row is a positional array, `{id, comp1_data, comp2_data, ...}`, aligned with the archetype's
`columnIndices`. Each `comp_i_data` is whatever the component's `serialize` returned.
