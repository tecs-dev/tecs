---
outline: deep
---

# Save games

Tecs provides a fast snapshot system for save games, checkpoints, and state restoration. Plugins and game code can
attach arbitrary metadata alongside ECS data so snapshots stay self-contained (e.g., player profile,
physics state, RNG seeds, etc).

```lua
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

## World:saveSnapshot

Snapshots the ECS world and allows plugins to inject custom data.

```lua
function world:saveSnapshot(opts?: tecs.SnapshotOptions): tecs.SnapshotOutput
```

**Parameters:**

- `opts`: [Snapshot save options](#saveoptions)

**Returns**

- A tagged `SnapshotOutput`
- For binary saves: `{format = "binary", buffer = string.buffer, snapshot = nil}`
- For table saves: `{format = "table", buffer = nil, snapshot = Snapshot}`

## SaveOptions

All fields are optional; the default `world:saveSnapshot()` captures every entity into a fresh buffer with no
custom data.

| Field           | Type                                    | Purpose |
| ----------------| ----------------------------------------| ------- |
| `format`        | `"binary" \| "table"`                   | Output format. Defaults to `"binary"`. |
| `buffer`        | `string.buffer`                         | Reuse an existing buffer instead of allocating a fresh one. The buffer is `:reset()` first; see [Reusing a buffer across saves](#buffer). |
| `path`          | `string`                                | Optional binary output file path. Writes the bytes to disk and still returns the tagged result. |
| `filterQuery`   | [`QueryDescriptor`](/tecs/queries/) | Only save entities matching this query (`include` / `includeAny` / `exclude`). Composes freely with `layers`. |
| `layers`        | `{integer}`                             | Allow-list of `Transform.layer` values (0..31). Filters Transform-bearing entities by layer; entities without a `Transform` pass through unchanged. |
| `customData`    | `{string: any}`                         | Keyed metadata attached to the snapshot's data section. Values must be `string.buffer`-encodable. See [Snapshot events](#snapshot-events) for how to read it back. |

### buffer

For high-frequency saves (replay buffers, autosave loops), pass `opts.buffer` to reuse one allocation:

```lua
local buffer = require("string.buffer")
local sharedBuf = buffer.new()

for round = 1, 1000 do
    world:saveSnapshot({buffer = sharedBuf})
    -- The buffer is :reset() automatically before each save.
    -- Do whatever you need with it (compress, send, write to disk, etc.)
end
```

### filterQuery

You can restrict the capture to a subset of entities by providing a `filterQuery`. Any
[`QueryDescriptor`](/tecs/queries/) works (`include`, `includeAny`, `exclude`); only matching archetypes are
walked.

```lua
-- Only entities that carry a Persist component.
world:saveSnapshot({
    filterQuery = {include = {Persist}},
})
```

### layers

Some games are logically laid out by layer. You can serialize just specific layers by providing `layers`,
an array of `Transform.layer` values (0..31). Entities carrying a `Transform` with a layer outside the allow-list
are skipped; entities that don't have a `Transform` pass through unchanged (the filter only applies when there's 
something to filter on).

```lua
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

### customData

You can attach keyed metadata (build version, player profile, checkpoint, etc.) by providing `customData`. Each entry
becomes a data pair in the snapshot. Values must be `string.buffer`-encodable (numbers, strings, booleans, plain
tables). See [Snapshot events](#snapshot-events) for how to read the data back on load.

```lua
world:saveSnapshot({
    customData = {
        build     = "v0.1.2-alpha",
        player    = "Alice",
        checkpoint = {level = "intro", elapsed = 42.5},
    },
})
```

## World:loadSnapshot

Restores a previously saved snapshot into `world`, replacing the current world state. See
[Snapshot events](#snapshot-events) for how to hook into the load lifecycle and read back custom data.

```lua
function world:loadSnapshot(source: any): tecs.SnapshotPrelude
```

**Parameters:**

- `source`: Either a Lua string (e.g. from `love.filesystem.read`) or a `string.buffer` produced by `saveSnapshot`.
  Strings are copied once into an internal buffer; buffers are read directly without first converting to a Lua string.
  You may also pass a snapshot table or a tagged `SnapshotOutput`.

**Returns**

- `SnapshotPrelude` with `version`, `nextEntityId`, `entityCount`, `archetypeCount`, and `componentTable`.

## Table snapshots

Capture the world into a plain Lua snapshot table by requesting table format:

```lua
local out = world:saveSnapshot({format = "table"})
local snap = out.snapshot
```

This is useful for programmatic inspection, migration, or feeding through another serializer (e.g. `tecs.json`).
It is slower than the binary path; prefer binary for production save games.

## Per-component serialization

Most components serialize automatically. Table components round-trip every field, and FFI components memcpy through
their schema. Components holding non-portable state (Love2D handles, GPU slab pointers, derived fields) can opt out of
the bulk path with custom `serialize` / `deserialize` hooks, and any component whose `serialize` returns `nil` is
omitted from the snapshot entirely.

> See [Component serialization](/tecs/components/serialization) for the full reference, covering when to
override, schema fingerprinting and migration, performance implications, and examples.

## Saving and loading from files

`saveSnapshot` returns a LuaJIT [string.buffer](https://luajit.org/ext_buffer.html); you decide how to
get its bytes onto disk.

### Plain files

You can use plain Lua files (though this allocates unnecessary intermediate strings):

```lua
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

```lua
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

```lua
local ffi = require("ffi")

local buf = world:saveSnapshot().buffer
local ptr, len = buf:ref()
local byteData = love.data.newByteData(len)
ffi.copy(byteData:getPointer(), ptr, len)
love.filesystem.write("save.bin", byteData, len)
```

To load from disk with no string allocations:

```lua
local buffer = require("string.buffer")

local fileData = love.filesystem.newFileData("save.bin")
local loadBuf = buffer.new(fileData:getSize())
loadBuf:putcdata(fileData:getPointer(), fileData:getSize())
world:loadSnapshot(loadBuf)
```

## Snapshot events

Three events fire on entity 0 during save/load so plugins and game systems can participate in the snapshot lifecycle:

| Event                | When                                                                            | Purpose |
| -------------------- | ------------------------------------------------------------------------------- | ------- |
| `OnSnapshotSave`     | At the start of `saveSnapshot`, before archetypes are walked.                   | Attach keyed data via `ev:addData(key, value)` and/or omit plugin-derived components via `ev:exclude(component)`. |
| `StartSnapshotLoad`  | During `loadSnapshot`, after the world is restored, before data is dispatched.  | Register per-key callbacks via `ev:onData(key, callback)`. |
| `FinishSnapshotLoad` | During `loadSnapshot`, after every data callback has run.                       | "Load is complete" hook; `ev.prelude` carries the version/counts. |

### Attaching data during save

Plugins (or any system) can attach data by listening for `OnSnapshotSave` and calling `ev:addData(key, value)`.
The framework queues these calls during the event and flushes them into the snapshot's data section after the
archetype data is written, so the ordering is deterministic (per-listener, in call order).

```lua
world:observe(0, tecs.builtins.OnSnapshotSave, function(ev: tecs.builtins.OnSnapshotSave)
    ev:addData("physics.world", physicsSystem:serialize())
    ev:addData("rng.state", rng:getState())
end)
```

Keys are strings; values are `string.buffer`-encodable. Use namespaced keys (`"tecs2d.physics"`, `"mygame.scoreboard"`)
to avoid collisions. The framework never inspects keys or values; they're round-tripped verbatim.

### Excluding plugin-derived components

Plugins that own *derived* state (state that's a projection of some smaller, durable input) can mark their derived
components for omission via `ev:exclude(component)`. Entities carrying any excluded component are skipped entirely
at save time. On load the plugin re-derives them from the source-of-truth components that _are_ saved.

```lua
-- Inside the tiled plugin:
world:observe(0, tecs.builtins.OnSnapshotSave, function(ev: tecs.builtins.OnSnapshotSave)
    ev:exclude(gfx.TileChunk)         -- GPU instances; re-spawned from Tilemap
    ev:exclude(gfx.DirtyTileChunk)    -- transient dirty marker
    ev:exclude(tecs2d.tiled.TileSource) -- per-tile metadata; re-derived
end)
```

Consider the Tiled plugin as a case study. Only the Tilemap entity + non-tile entities get serialized; the AssetLoader
system re-spawns the chunks from `Tilemap.path` on load). The same pattern fits anything with a runtime-bound
projection: physics bodies derived from a `RigidBody` marker, audio voices derived from an `AudioSource`, particle
systems derived from an emitter component, etc.

The contract is symmetric: whatever the plugin omits, the plugin re-creates. The framework only handles the
omission; re-derivation is plugin code that runs in normal systems (typically watching for the source-of-truth
component to appear, just like during initial spawn).

`exclude` and `addData` can be combined freely; both happen during the same `OnSnapshotSave` listener.

### Reading data back during load

`StartSnapshotLoad` fires once the world is fully restored, before the data section is dispatched. Listeners register
per-key callbacks via `ev:onData(key, callback)`; each callback fires exactly once per matching data entry. Keys with
no registered callback are silently skipped. Multiple listeners may register the same key; all fire in registration
order.

```lua
world:observe(0, tecs.builtins.StartSnapshotLoad, function(ev: tecs.builtins.StartSnapshotLoad)
    ev:onData("physics.world", function(value: any)
        physicsSystem:deserialize(value)
    end)
    ev:onData("rng.state", function(value: any)
        rng:setState(value)
    end)
end)

world:loadSnapshot(buf)
```

### Reactively finalizing loading logic

Once every data callback has run, `FinishSnapshotLoad` fires as a natural "load is complete" hook:

```lua
world:observe(0, tecs.builtins.FinishSnapshotLoad, function(ev: tecs.builtins.FinishSnapshotLoad)
    print("restored to version", ev.prelude.version)
end)
```

## In-memory tables (table format)

When you need to inspect or transform the snapshot programmatically, use the table format:

```lua
local snap = world:saveSnapshot({format = "table"}).snapshot
-- snap is a plain Lua table: mutate, inspect, walk by hand.

world:loadSnapshot(snap)
```

It accepts the same `opts` shape as `saveSnapshot` (minus `buffer`). The table is JSON-friendly, so you can feed it
through `tecs.json.serialize` for human-readable saves:

```lua
local snap = world:saveSnapshot({format = "table"}).snapshot
love.filesystem.write("save.json", tecs.json.serialize(snap))

local payload = love.filesystem.read("save.json")
world:loadSnapshot(tecs.json.parse(payload))
```

The table format is substantially slower than binary but useful for debugging or any case where you need to peek at
the snapshot before applying it.

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

then use the MCP integration to call `snapshot_save` against the running world.

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

    mode == 1 (row-major, sparse-bearing archetype):
        per entity:
            encode(id)
            per component j: serializeRaw OR encode(serialize(value)) OR encode(nil)

data section (sentinel-terminated):
    repeat: encode(true); encode(key); encode(value)
    encode(false)                    -- terminator
```

### Table (Lua / JSON)

`world:saveSnapshot({format = "table"}).snapshot` returns:

```lua
{
    version = 1,
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

## See also

- [`examples/save-game/`](https://github.com/tecs-dev/tecs/tree/main/examples/save-game): runnable paint demo using table snapshots
- [World reference](/tecs/world): `spawnAt` (restore entity at a specific packed id)
- [Components](/tecs/components/serialization): custom `serialize` / `deserialize`
- [JSON module](/tecs/utils/json): fast JSON for persistence
