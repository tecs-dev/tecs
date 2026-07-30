---
description: "Snapshot saving, loading, transient components, handlers, filtering, and binary format"
outline: deep
---

# Save games

Snapshots carry durable world state between processes. Use them for save
games, checkpoints, replay buffers, and hot reload.

```teal
local save = world:saveSnapshot().buffer
world:loadSnapshot(save)
```

## Binary and table formats

`saveSnapshot` writes binary data by default. The binary format uses a LuaJIT
[`string.buffer`](https://luajit.org/ext_buffer.html#serialize) and copies dense
FFI columns in bulk. Use it for shipped saves.

The table format returns plain Lua data. Use it for inspection, migrations, and
tools:

```teal
local snapshot = world:saveSnapshot({format = "table"}).snapshot
snapshot.data[#snapshot.data + 1] = {
    key = "mygame.migrated",
    value = true,
}
world:loadSnapshot(snapshot)
```

Table saves accept the same selection options as binary saves. They reject
`buffer` and `path`. Encoding a table as JSON through `tecs.data` costs more
allocations and per-component work than the binary format.

## Snapshot contents

### Durable world state

A snapshot records:

- entity IDs, including their slot and generation
- components and relationship targets
- the complete [state stack](/modules/ecs/states)
- the fixed-step accumulator and per-phase enable flags
- custom data

Load rebuilds the [`EntityKey`](/modules/ecs/builtins#entitykey) index after it restores
the entities. A same-world load therefore preserves entity handles whose saved
IDs still exist.

Create every named state before loading a snapshot that uses it:

```teal
world:createState("menu")
world:createState("playing")
world:loadSnapshot(save)
```

Load raises when the snapshot names an unregistered state. Save also raises
when the world contains a non-exclusive sparse relationship unless its
component declares `transient = true`. A non-exclusive sparse store can hold
several targets for one source, while a snapshot component row holds one
value.

### Runtime state

Snapshots omit:

- `world.resources`
- GPU buffers and device handles
- audio voices and playback positions
- open files and worker threads
- futures and native work in flight
- Lua locals, closures, and entity-address observers

A [`Future`](/modules/Future) is never a component field, and the omission above is
what that rule buys. A future holds listeners and the source that settles them,
so the binary encoder walks a cyclic graph of runtime state rather than refusing
the component: the save fails with `too deep to serialize` and names nothing.
Keep the future in a table beside the world and give the entity a transient
marker, which is what [`tecs.net.http`](/modules/net/http) does with `Pending`.

A sequence cursor waiting on a future saves the provider name, entity, and key.
Load restores the cursor without restoring the future. `isPending` then returns
false, and the cursor resumes on the next fixed step. Reissue and retrack the
work when the wait must continue.

Load replaces the world in place and despawns nothing, so a subsystem holding
work for an entity never hears that the entity is gone. Cancel or reissue from
[`FinishSnapshotLoad`](/modules/ecs/builtins#snapshot-events) rather than from
`OnDespawn`.

Keep durable input in components. Recreate process-local objects from that
input after load.

## Component durability

Dense FFI components normally cross the binary format as raw columns. Table
components use their default serializer. A component can instead provide
`serialize` and `deserialize` callbacks. See
[Component serialization](/modules/ecs/components/serialization) for the registration
API.

Custom codecs must turn process-local numbers into durable names:

- `tecs.gfx.Sprite` saves the image name instead of its intern index.
- `tecs.gfx.animation.Animation` saves sheet and tag names. Load resets the
  frame index so the next update writes the sprite region.
- `tecs.audio.Sound` saves the clip path and group name. Load starts a new
  voice instead of restoring playback progress.
- `tecs.gfx.Text` saves authored fields and the font name. A missing font
  produces no layout.
- `tecs.physics.RigidBody` saves no component value. The physics snapshot
  handler stores Rapier's complete versioned state under `"tecs.physics"` and
  reconnects body and collider handles by entity.

An FFI component also stores a schema fingerprint. When the saved and current
fingerprints match, load copies the column in bulk. Otherwise load maps fields
by name into the current schema. New fields start at zero, removed fields
disappear, and LuaJIT converts numeric types. Renaming a field loses its old
value.

### Transient components

Declare process-local backing data as transient when the entity itself belongs
in the save:

```teal
local record PathCache is tecs.ecs.Component
    nodeCount: integer
    cursor: integer
end

local PathCacheComponent = tecs.ecs.newFFIComponent({
    name = "PathCache",
    container = PathCache,
    fields = {
        {"nodeCount", "int32_t"},
        {"cursor", "int32_t"},
    },
    transient = true,
})
```

Save omits the transient column. Load applies normal spawn behavior, including
`requires` defaults. Component registration rejects the combination of
`transient = true` and a custom serializer.

### Derived entities

A subsystem can exclude fully derived entities during
[`OnSnapshotSave`](/modules/ecs/builtins#snapshot-events):

```teal
world:observe(0, tecs.ecs.OnSnapshotSave,
    function(ev: tecs.ecs.OnSnapshotSave)
        ev:exclude(TileInstance)
    end
)
```

The snapshot omits every entity that carries `TileInstance`. The owning
subsystem must recreate those entities from durable input after load.

## Save selection and custom data

`saveSnapshot` accepts a reusable binary buffer, a destination path, a query,
layer selection, and custom data:

```teal
local buffer = require("string.buffer")
local replayBuffer = buffer.new()

local result = world:saveSnapshot({
    buffer = replayBuffer,
    path = tecs.filesystem.writablePath("checkpoint.bin"),
    filterQuery = {include = {Persist}},
    layers = {2, 3},
    customData = {
        build = "v12",
        checkpoint = {level = "intro", elapsed = 42.5},
    },
})

local bytes = result.buffer
```

The world resets a supplied buffer before writing. A path writes the same
binary bytes and still returns the tagged result. The world clones
`filterQuery`, so repeated saves never mutate the caller's descriptor.

`layers` accepts values from 0 through 31. It rejects an entity with
`Transform` when the component's `layer` falls outside the allowlist. It keeps
an entity without `Transform`.

Custom-data values must support `string.buffer` encoding. Prefix your keys with
the game or subsystem name. Tecs reserves keys that begin with `__tecs.` for
the state stack and pipeline state.

## Load lifecycle

`loadSnapshot` accepts a Lua string, `string.buffer`, snapshot table, or tagged
save result. It clears and repopulates the world in place. It does not emit
`OnDespawn` for the replaced entities. A format-version mismatch raises.

Use `EntityKey` to rediscover important entities:

```teal
local player = world:spawn(
    tecs.ecs.EntityKey("player"),
    Player()
)

local save = world:saveSnapshot().buffer
world:loadSnapshot(save)
player = world:requireKey("player")
```

Global observers registered at address `0` survive a same-world load because
the world keeps its systems and event bus. A fresh process must register those
observers during setup. Load clears entity-address observers with the old
entity set.

Store durable per-entity behavior as component data. Let a query or global
observer interpret that data and install any runtime callbacks.

## Snapshot handlers

Register a named handler for durable state that lives outside components:

```teal
local player: tecs.ecs.Entity = 0

world:addSnapshotHandler({
    name = "mygame.session",
    save = function(_world: tecs.World): any
        return {
            difficulty = session.difficulty,
            rng = rng:save(),
        }
    end,
    load = function(_world: tecs.World, value: any)
        session.difficulty = value.difficulty
        rng:load(value.rng)
    end,
    finish = function(loadedWorld: tecs.World,
        _prelude: tecs.ecs.SnapshotPrelude)
        player = loadedWorld:requireKey("player")
    end,
})
```

The caller supplies any combination of `save`, `load`, and `finish`, plus a
nonempty `name`. `save` returns one encodable value for that name. A nil result
writes no value. Load restores the ECS first, then calls matching `load`
callbacks, then calls every `finish` callback.

`addSnapshotHandler` builds on three global events:

- `OnSnapshotSave` fires before the archetype walk. Tecs owns `addData` and
  `exclude`; an observer may call these functions but must not replace them.
- `StartSnapshotLoad` fires after ECS restoration and before data dispatch.
  Tecs owns `onData`; an observer may call it to register callbacks by key.
- `FinishSnapshotLoad` fires after every data callback. Tecs owns its
  `prelude`; observers may read it but must not replace it.

The prelude reports the format version and entity, archetype, and component
table information. Use handlers unless a subsystem needs the lower-level event
ordering.

## Engine subsystem state

Engine plugins register their own snapshot behavior:

- `tecs.ecs.random` stores the world seed and every named stream under
  `"tecs.random"`. The first `random.stream` or `random.seed` call installs the
  handler. Seed during world setup so a load cannot encounter the saved value
  before the handler exists.
- Audio stores master and group gain, mute, and pause settings under
  `"tecs.audio"`. It does not store keyed limits or voice progress. Configure
  limits during setup.
- The sequence plugin stores its runtime under `"tecs.sequence"`.
- The text plugin discards cached glyph runs after load and derives them again.
- The HTTP plugin saves the `Request` and not the transient `Pending` marker, so
  a request that was in flight is sent again after load. It stops the transfers
  the load replaced, because the entities waiting on them are gone.
- Physics stores Rapier's complete state under `"tecs.physics"` and reconnects
  transient handles. `physics.hasBody` reports whether an entity has a live
  body after reconnection.

## Saving files

`path` provides the shortest binary save:

```teal
local path = tecs.filesystem.writablePath("save.bin")
world:saveSnapshot({path = path})
world:loadSnapshot(tecs.filesystem.read(path))
```

To transform the bytes first, write the returned buffer:

```teal
local path = tecs.filesystem.writablePath("save.bin")
local bytes = tostring(world:saveSnapshot().buffer)
tecs.filesystem.write(path, bytes)
```

`tecs.filesystem.writablePath` resolves a path inside the application's
writable directory and works on targets where stdio cannot reach platform
storage.

## Binary snapshot layout

The binary format uses one component table and column-major storage:

- Archetypes refer to component names and schemas by table index.
- Dense FFI columns use one raw copy per column.
- Entity IDs use raw doubles, which retain the packed 22-bit slot and 31-bit
  generation.
- Custom codecs encode one value per row.
- Archetypes with a serializable sparse relationship use row-major data and a
  presence mask.

The wire format follows this sequence:

```text
prelude:
    encode(version)
    encode(nextEntityId)
    encode(entityCount)
    encode(archetypeCount)
    encode(componentCount)
    per component:
        encode(name)
        encode(fingerprint)       # empty for non-FFI components

per archetype:
    encode(columnCount)
    encode(entityCount)
    per column: encode(componentTableIndex)
    encode(mode)                  # 0 column-major, 1 row-major

    mode 0:
        putcdata(entityIds, entityCount * 8)
        per column:
            putcdata(column, structSize * entityCount)
            OR per row: encode(serializedValue)

    mode 1:
        per row:
            encode(entityId)
            encode(presenceMask)
            per present column: encode(serializedValue)

data:
    repeat: encode(true); encode(key); encode(value)
    encode(false)
```

Row-major presence masks use exact double arithmetic and support at most 52
columns.

## Table snapshot layout

The table writer produces this general shape:

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
            columnIndices = {1, 2},
            entities = {
                {1, {x = 10, y = 20}, {hp = 100}},
                {2, {x = 30, y = 40}, {hp = 50}},
            },
        },
    },
    data = {
        {key = "build", value = "v12"},
    },
}
```

Each entity row aligns its component values with the archetype's
`columnIndices`. Table load always calls each component's deserializer, so the
table writer omits schema fingerprints.
