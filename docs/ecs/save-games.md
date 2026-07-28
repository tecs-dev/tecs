---
description: "Snapshot save and load with saveSnapshot, loadSnapshot, transient components, snapshot handlers, filtering, and the binary format spec"
outline: deep
---

# Save games

A snapshot captures a world and puts it back. It is the mechanism behind save games, checkpoints, replay
buffers, and hot reload. Game code and engine subsystems can attach arbitrary keyed metadata alongside the ECS
data, so a snapshot stays self-contained: a player profile, an RNG seed, and a mixer setting travel in the same
file as the entities.

```teal
-- Save the world into a LuaJIT string.buffer.
local buf = world:saveSnapshot().buffer

-- Put it back.
world:loadSnapshot(buf)
```

## Save formats

Two formats ship in the box.

| Format | API                                                                 | Description                                                                                                                                                    |
| ------ | ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Binary | `world:saveSnapshot()`, `world:loadSnapshot(...)`                   | [LuaJIT `string.buffer`](https://luajit.org/ext_buffer.html#serialize) serialization with bulk FFI memcpy for dense columns. The default, and the one to ship. |
| Table  | `world:saveSnapshot({format = "table"})`, `world:loadSnapshot(...)` | A plain Lua table for programmatic inspection, in-memory round-trips, and custom tooling such as JSON through `tecs.data`.                                     |

## What is and isn't saved by default

A snapshot captures durable ECS state plus the framework's own runtime bookkeeping. It does not capture
anything living outside the world. Everything else is yours to carry through
[`customData`](#customdata) or a [snapshot handler](#snapshot-handlers).

### Saved automatically

- **Entities**, at their original ids. `batchSpawnAt` restores each entity at its saved packed id, so both slot
  and generation round-trip and handles taken before a same-world load still resolve afterwards.
- **Components.** FFI components memcpy their raw column bytes in one block per column; table components
  round-trip through a default serializer that copies every string-keyed field holding a number, string,
  boolean, or table, skipping the ECS metadata fields. A component may replace that with a
  [custom `serialize`](#per-component-serialization).
- **Relationships**, including their targets. A dense relationship instance column is recorded as
  `"<container>-><target>"` and rebuilt from the container on load.
- **The [state stack](/ecs/states)**: the active state and everything pushed beneath it. Loading a snapshot whose
  stack names a state this world has not registered raises, so call `world:createState(name)` for each state
  before loading.
- **Pipeline runtime state**: the fixed-timestep accumulator and the per-phase enable flags.
- **The [`Key`](/ecs/builtins) index**, rebuilt from the restored entities after the archetypes are in place.
- **Custom data** attached through [`customData`](#customdata) or a [snapshot handler](#snapshot-handlers).

### Not saved

- Components marked [`transient`](#transient-components), and entities removed with
  [`ev:exclude(...)`](#excluding-derived-entities).
- **Non-exclusive sparse relationships.** Their stores hold several targets per source, which does not fit the
  one-value-per-component row format; saving a world that uses one raises unless the relationship is
  `transient`.
- **`world.resources`.** Managers, RNGs, config objects, and anything else kept there is outside the ECS. See
  [World resources](#world-resources).
- **Process-local runtime objects**: GPU buffers, device handles, physics bodies, audio voices, open files, and
  worker threads.
- **Work in flight.** A [`Future`](/modules/future) holds listeners, a source and, through it, a native handle,
  so no save carries one. A sequence cursor parked on a future is saved, as a provider name, an entity and a
  key: after a load nothing is tracked, `isPending` answers false, and the parked cursor resumes on the next
  fixed step. A game that wants the wait to still mean something re-issues the work and re-tracks it under the
  same key.
- **Lua locals, closures, and callbacks.** A variable holding an entity id, and an observer registered on an
  entity address, do not survive a load. Rebind them from a [`Key`](#runtime-handles-after-load), or reinstall
  them from ECS data.

The practical rule: snapshot the data you would write into a save file, and rebuild the objects you would create
during startup. Keep the durable source of truth in components, mark process-local backing components
`transient`, and recreate derived objects during the [load lifecycle](#snapshot-handlers).

### Per-component serialization

Most components serialize with no work. A component whose fields are this process's numbering rather than
durable data opts out of the bulk path with `serialize` / `deserialize` hooks, and the engine's own components
are the worked examples of why:

- **`tecs.gfx.Sprite`** holds an image's intern index, handed out in the order images were registered.
  A number that depends on load order cannot survive a save, so `serialize` writes the image's _name_ and
  `deserialize` interns it again. What a saved sprite refers to is decided by the name on both sides.
- **`tecs.gfx.animation.Animation`** holds a sheet id and a tag id, both decided by the order sheets were built in,
  and saves the pair of names instead. The frame index is deliberately dropped to zero, so the first step after
  a load rewrites the Sprite's region rather than trusting the region it was saved holding.
- **`tecs.audio.Sound`** crosses as the clip path and the group name it interned from. The voice is not
  restored: a snapshot records that an entity has a sound, not how far through it the mixer had got, so it
  starts.
- **`tecs.text.Text`** saves the authored fields and the font by name. A font never loaded in this process
  leaves the restored text without one, which lays out nothing rather than failing the load.
- **`tecs.physics.RigidBody`** serializes to nothing at all and restores as the null handle, because a Box2D
  handle is dense and reused, so a saved one would name whichever body the loading run happened to put in that
  slot, and the sync would write a stranger's pose into this entity's `Transform` with nothing to signal it.
  The null handle is inert rather than merely wrong: the write-back reads no movement for it, and the impulse
  and velocity calls refuse it instead of indexing off the front of Box2D's body array. So an entity that
  simulated before a load does not simulate after it until something attaches a body again. The description
  does survive, in the `Body` and `Collider` components, and `physics.hasBody` is how to tell an entity whose
  body is gone from one that never had one. See [physics](/modules/physics).

The pattern behind all five: a name is durable and an index is not.

Snapshots also survive component changes across game updates. Every FFI component carries a canonical
fingerprint of the form `field1:type1,field2:type2,...|sizeBytes`. Save embeds it and load compares it against
the current registration: on a match, the column is one bulk memcpy; on a mismatch, load cdefs a struct matching
the saved layout, reads each entity's bytes into it, and copies same-named fields into a current-schema
instance. Fields added since the save get their zero default, removed fields are dropped, and type changes ride
LuaJIT's implicit numeric conversion. A rename reads as a removal plus an addition, so the old value is lost.

> See [Component serialization](/ecs/components/serialization) for the full reference.

### Transient components

Use `transient = true` when the entity is durable but one component on it is nothing but this run's bookkeeping.
The entity is still saved; the transient column is left out of the saved archetype. On load, normal spawn
behavior applies, including `requires` defaults for transient components.

```teal
local record PathCache is tecs.Component
    nodeCount: number
    cursor: number
end

tecs.ecs.newFFIComponent({
    name = "PathCache",
    container = PathCache,
    fields = {
        {"nodeCount", "int32_t"},
        {"cursor", "int32_t"},
    },
    transient = true,
})
```

`transient = true` cannot be combined with a custom `serialize`: registration raises. Declare the component
runtime-only, or give it durable serialization, not both. The engine's own non-portable components take the
second route, because each of them has something durable to say: see
[per-component serialization](#per-component-serialization) above.

### Excluding derived entities

Game code that owns _derived_ entities, a projection of smaller durable input, skips them at save time with
[`ev:exclude(component)`](#onsnapshotsave). Every entity carrying an excluded component is omitted, and the
plugin that owns them re-derives them from the saved source of truth on load. A tilemap that spawns one entity
per visible tile from a much smaller authored grid is the shape this exists for:

```teal
world:observe(0, tecs.ecs.builtins.OnSnapshotSave, function(ev: tecs.ecs.builtins.OnSnapshotSave)
    ev:exclude(TileInstance)
end)
```

The contract is symmetric: whatever a subsystem omits, that subsystem re-creates. Excludes are merged into a
cloned filter descriptor before the archetype walk, so an `opts` table reused across saves never accumulates
them.

### Handled by the engine

Three engine subsystems already carry their own state across a snapshot, so these need no work from you:

- **Seeded randomness.** `tecs.ecs.random` installs a `"tecs.random"` handler that saves the world seed and the
  state of every named stream. It is installed lazily, on the first `random.stream` or `random.seed` call for
  that world, so a world that loads a snapshot before anything has asked for a stream drops the saved seed.
  Seeding during setup, which a game that cares does anyway, is enough to avoid that.
- **Audio.** Installing the mixer adds a `"tecs.audio"` handler covering the master gain and mute, plus the
  gain, mute, and pause of every group that has one set. Loading routes through the ordinary setters, so voices
  already sounding follow. Keyed limits are deliberately not carried: a limit is a rule the build states at
  startup beside the clip it governs, and restoring one from a file would let an old save override a rule the
  build has since changed. Set your limits during setup, as you would anyway.
- **Text.** The text plugin observes `FinishSnapshotLoad` and gives up its glyph run whole, because a load
  replaces the world in place rather than despawning what was in it.

### World resources

A snapshot does not capture `world.resources`. Anything stored there is runtime state outside the ECS and is
lost on load unless you persist it yourself. Register a [snapshot handler](#snapshot-handlers) per resource that
holds durable state:

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

## World:saveSnapshot

Snapshots the world and lets subsystems inject custom data.

```teal
function world:saveSnapshot(opts?: tecs.SnapshotOptions): tecs.SnapshotOutput
```

**Parameters:**

- `opts`: [save options](#snapshotoptions), optional. Omitted, every entity is captured into a fresh buffer with
  no custom data.

**Returns:** a tagged `SnapshotOutput`.

- Binary: `{format = "binary", buffer = <string.buffer>, snapshot = nil}`
- Table: `{format = "table", buffer = nil, snapshot = <Snapshot>}`

### SnapshotOptions

All fields are optional.

| Field         | Type                               | Purpose                                                                                                                                                    |
| ------------- | ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `format`      | `"binary" \| "table"`              | Output format. Defaults to `"binary"`.                                                                                                                     |
| `buffer`      | `string.buffer`                    | Reuse an existing buffer instead of allocating one. It is `:reset()` first. Binary only; passing it with `format = "table"` raises. See [buffer](#buffer). |
| `path`        | `string`                           | Write the bytes to this path and still return the tagged result. Binary only; passing it with `format = "table"` raises.                                   |
| `filterQuery` | [`QueryDescriptor`](/ecs/queries/) | Save only entities matching this query. Composes freely with `layers`. See [filterQuery](#filterquery).                                                    |
| `layers`      | `{integer}`                        | Allow-list of `Transform.layer` values, each in 0..31. See [layers](#layers).                                                                              |
| `customData`  | `{string: any}`                    | Keyed metadata attached to the snapshot's data section. Values must be `string.buffer`-encodable. See [customData](#customdata).                           |

#### buffer

For high-frequency saves, replay buffers and autosave loops, pass `opts.buffer` to reuse one allocation:

```teal
local buffer = require("string.buffer")
local sharedBuf = buffer.new()

for _ = 1, 1000 do
    world:saveSnapshot({buffer = sharedBuf})
    -- The buffer is :reset() before each save. Compress it, send it,
    -- write it, then go around again.
end
```

#### filterQuery

Restrict the capture to a subset of entities with a `filterQuery`. Any
[query descriptor](/ecs/queries/) works, so `include`, `includeAny`, and `exclude` are all available; only
matching archetypes are walked. The descriptor you pass is cloned, never mutated.

```teal
world:saveSnapshot({
    filterQuery = {include = {Persist}},
})
```

#### layers

Games laid out by layer can serialize a subset by passing `layers`, an array of `Transform.layer` values. A
value outside 0..31 raises. Entities carrying a `Transform` whose layer is not in the allow-list are skipped;
entities without a `Transform` pass through unchanged, because there is nothing to filter on.

```teal
-- Only Transform-bearing entities on layer 2 or 3. Entities with no
-- Transform, such as singletons and config entities, still flow through.
world:saveSnapshot({layers = {2, 3}})

-- Combined: Persist entities; if one has a Transform, it must be on 2 or 3.
world:saveSnapshot({
    filterQuery = {include = {Persist}},
    layers = {2, 3},
})
```

#### customData

Attach keyed metadata such as a build version, a player profile, or a checkpoint. Each entry becomes one pair in
the snapshot's data section. Values must be `string.buffer`-encodable: numbers, strings, booleans, and plain
tables. See [Snapshot handlers](#snapshot-handlers) for reading it back.

```teal
world:saveSnapshot({
    customData = {
        build      = "v0.1.2-alpha",
        player     = "Alice",
        checkpoint = {level = "intro", elapsed = 42.5},
    },
})
```

Keys beginning `__tecs.` are reserved: the framework writes the state stack and pipeline state under them and
consumes them during load before any handler is dispatched.

### Table snapshots

Ask for table format to capture the world into a plain Lua table. Reach for it when you need to inspect, mutate,
or transform a snapshot programmatically, or feed it to another serializer:

```teal
local snap = world:saveSnapshot({format = "table"}).snapshot
-- snap is a plain Lua table: mutate it, walk it, print it.

world:loadSnapshot(snap)
```

It accepts the same [options](#snapshotoptions) as a binary save minus `buffer` and `path`. The table is
JSON-friendly, so `tecs.data` gives you a human-readable save:

```teal
tecs.filesystem.write(tecs.filesystem.writablePath("save.json"), tecs.data.encodeJSON(snap))

local payload = tecs.filesystem.read(tecs.filesystem.writablePath("save.json"))
world:loadSnapshot(tecs.data.decodeJSON(payload))
```

::: tip Table snapshots are slower
The table format decodes per entity and allocates a Lua table per component. Prefer binary for production
saves, and reach for table format when debugging, migrating, or peeking at a snapshot before applying it.
:::

## World:loadSnapshot

Restores a snapshot into `world`, replacing the current world state. See
[Snapshot handlers](#snapshot-handlers) for hooking the load lifecycle and reading custom data back.

```teal
function world:loadSnapshot(source: any): tecs.SnapshotPrelude
```

**Parameters:**

- `source`: a Lua string, a `string.buffer` produced by `saveSnapshot`, a snapshot table, or a tagged
  `SnapshotOutput`. Strings are copied once into an internal buffer; buffers are read directly, with no
  intermediate Lua string.

**Returns:** a `SnapshotPrelude` with `version`, `nextEntityId`, `entityCount`, `archetypeCount`, and
`componentTable`.

A load clears the world in place rather than despawning entity by entity, so no per-entity `OnDespawn` fan-out
fires. A snapshot whose `version` does not match this build's raises.

### Runtime handles after load

Snapshots restore durable ECS state, not the application handles pointing into it. If a runtime variable holds
an entity that must survive save and load, give that entity a [`Key`](/ecs/builtins) and rebind afterwards:

```teal
local playerId = world:spawn(
    tecs.ecs.builtins.Key("player"),
    Player()
)

-- Later:
world:loadSnapshot(saveBuffer)
playerId = world:requireKey("player")
```

The lifecycle is designed for this. `StartSnapshotLoad` lets a subsystem register per-key data callbacks, and
`FinishSnapshotLoad` is where to refresh runtime handles that need the fully restored world. For state kept in
`world.resources` rather than on an entity, see [World resources](#world-resources).

### Observers and runtime callbacks

Snapshots do not serialize Lua callbacks or closures. Global observers registered at address `0` survive a
same-world `loadSnapshot`, because the world, its systems, and its message bus stay installed. Load a save into
a fresh world in a new process and those observers have to be registered again during normal setup.
Entity-address observers survive neither case: a load replaces the entity set, and the world's entity observers
are cleared with it.

When an entity needs durable behavior, save the intent as ECS data and let a query install the runtime callback.
Rather than hand-registering a one-off `OnDespawn` callback per entity, store a component:

```teal
local record DespawnEffect is tecs.Component
    name: string
    metamethod __call: function(self, name: string): DespawnEffect
end

tecs.ecs.newComponent({
    name = "DespawnEffect",
    container = DespawnEffect,
    fields = {"name"},
})
```

Then let setup react to matching entities and install the entity observer:

```teal
local despawnEffectQuery = world:query({
    include = {DespawnEffect, tecs.ecs.builtins.Transform},
    onEntitiesAdded = function(archetype: tecs.Archetype, firstRow: integer, lastRow: integer, _count: integer)
        local entities = archetype.entities
        for row = firstRow, lastRow do
            local entity = entities[row]
            world:observe(entity, tecs.ecs.builtins.OnDespawn, function(_ev: tecs.ecs.builtins.OnDespawn)
                -- spawn the effect here
            end, "despawn-effect")
        end
    end,
})
```

The dynamic part stays dynamic: gameplay adds or removes `DespawnEffect("poof")` whenever it likes. The durable
part is no longer a closure; it is component data that snapshots cleanly. After a load, the query sees the
restored entities and installs fresh entity-address observers from the restored component state.

## Saving and loading from files

Binary saves give you a LuaJIT [`string.buffer`](https://luajit.org/ext_buffer.html), and how its bytes reach
disk is yours to choose.

### Let saveSnapshot write it

The shortest path. `opts.path` writes the bytes and still returns the tagged result:

```teal
world:saveSnapshot({path = tecs.filesystem.writablePath("save.bin")})
```

### Through the platform filesystem

`tecs.filesystem.writablePath` resolves against the only directory a build may write to, and `tecs.filesystem` reads and
writes bytes through the platform rather than stdio, which is what reaches content on targets where stdio does
not.

```teal
local path = tecs.filesystem.writablePath("save.bin")

-- Save
local buf = world:saveSnapshot().buffer
tecs.filesystem.write(path, tostring(buf))

-- Load
world:loadSnapshot(tecs.filesystem.read(path))
```

### Plain Lua files

Fine for a tool or a test, at the cost of an intermediate string on each side:

```teal
local buf = world:saveSnapshot().buffer
local f = io.open("save.bin", "wb")
f:write(tostring(buf))
f:close()

local g = io.open("save.bin", "rb")
local data = g:read("*a")
g:close()
world:loadSnapshot(data)
```

## Snapshot handlers

For state living outside components, register a named handler:

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

`save` writes one value into the data section under `name` when it returns non-nil; returning nil writes
nothing. `load` receives that value after the ECS world has been restored. `finish` runs after every data
callback has completed, which makes it the place to rebind `Key` handles and rebuild indexes that need the final
restored world. All three are optional; `name` is required and must be non-empty.

Values must be `string.buffer`-encodable. Use namespaced keys, as the engine's own `"tecs.random"` and
`"tecs.audio"` do, so two subsystems cannot collide.

## Snapshot events

`addSnapshotHandler` is built from three events emitted at address `0` during save and load. Register with
`world:observe(0, event, callback)` when you need the lower-level access; otherwise prefer the handler.

| Event                | Fires                                                                          | For                                            |
| -------------------- | ------------------------------------------------------------------------------ | ---------------------------------------------- |
| `OnSnapshotSave`     | At the start of `saveSnapshot`, before archetypes are walked.                  | Attaching data and excluding derived entities. |
| `StartSnapshotLoad`  | During `loadSnapshot`, after the world is restored, before data is dispatched. | Registering per-key data callbacks.            |
| `FinishSnapshotLoad` | During `loadSnapshot`, after every data callback has run.                      | Finalizing the loaded world.                   |

### OnSnapshotSave

| Member       | Signature                   | Purpose                                                                                                                                                   |
| ------------ | --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ev:addData` | `(key: string, value: any)` | Attach a keyed value to the data section. Values must be `string.buffer`-encodable. Calls are queued and flushed after the archetype data, in call order. |
| `ev:exclude` | `(component: Component)`    | Omit every entity carrying `component` from the save.                                                                                                     |

Both can be used from the same listener.

### StartSnapshotLoad

| Member      | Signature                                       | Purpose                                                                                                                                             |
| ----------- | ----------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ev:onData` | `(key: string, callback: function(value: any))` | Register a callback fired once per matching data entry. Keys with no callback are skipped; several callbacks on one key fire in registration order. |

### FinishSnapshotLoad

| Member       | Type              | Purpose                                                     |
| ------------ | ----------------- | ----------------------------------------------------------- |
| `ev.prelude` | `SnapshotPrelude` | Version and entity/archetype counts of the loaded snapshot. |

## Subsystem checklist

For each subsystem that takes part in saves:

- Save the durable source of truth as components, relationships, and custom data.
- Use `world:addSnapshotHandler(...)` for ordinary non-component data and for load finalization.
- Persist any durable state kept in `world.resources` through a handler; resources are not saved.
- Mark process-local backing components `transient = true` when the entity itself is durable.
- Use `ev:exclude(component)` for fully derived entities that should not appear in saves.
- Rebuild derived entities, resources, and caches in ordinary systems or in `FinishSnapshotLoad`.
- Store durable per-entity behavior as components interpreted by queries or global observers, never as
  entity-address callback registrations.
- Use `Key` only for stable anchors the application has to rediscover, such as `"player"`.
- Prefer a query or a rebuilt index over assigning a key to every entity in a group.
- Keep device handles, physics bodies, audio voices, open files, worker threads, and caches out of the snapshot
  unless they are converted into portable durable data.

## What makes the binary format fast

- **Pre-pass component table.** Every unique component in the save appears once in the prelude; archetype frames
  reference it by 1-based integer index instead of repeating name and schema strings.
- **Column-major layout.** Each eligible FFI column writes and reads as one `structSize × entityCount` memcpy.
  No per-entity loop, no intermediate Lua tables.
- **Bulk entity ids.** The id array writes with one `putcdata` per archetype and loads with one `ffi.copy` into
  a freshly allocated `double[count]`. Doubles let a packed `(slot, generation)` id survive the round trip
  without truncation; the packed format uses 22 bits of slot and 31 of generation.
- **Schema fingerprint per component**, compared once per component on load, so a matching schema is a bulk
  memcpy and only a drifted one pays the per-entity migration path.

A component with a custom `serialize` / `deserialize` opts out of the bulk path automatically and round-trips
per entity through its own codec. So does an archetype carrying a serializable sparse relationship, which is
written row-major with a presence mask instead.

`make bench-snapshot` runs the snapshot benchmarks.

## Snapshot format spec

### Binary (LuaJIT `string.buffer`)

The wire format is a sequence of LuaJIT-encoded values and raw byte runs:

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

Row-major presence masks use exact double arithmetic, which caps that path at 52 columns.

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
                {1, {x = 10, y = 20}, {hp = 100}},
                {2, {x = 30, y = 40}, {hp = 50}},
            },
        },
    },
    data = {                                      -- ordered (key, value) pairs
        {key = "build",  value = "v0.1.2-alpha"},
        {key = "player", value = "Alice"},
    },
}
```

Each entity row is a positional array, `{id, comp1Data, comp2Data, ...}`, aligned with that archetype's
`columnIndices`; each element is whatever the component's `serialize` returned. The table writer strips
fingerprints, because a table load always goes through per-component `deserialize` and handles schema drift
intrinsically.
