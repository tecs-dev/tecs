---
description: "Snapshot saving, loading, transient components, handlers and durable state"
outline: deep
---

# Save games

Snapshots carry durable world state between processes. Use them for save
games, checkpoints, replay buffers, and hot reload.

```nupp
local save = world:saveSnapshot()
world:loadSnapshot(save)
```

## Snapshot contents

`saveSnapshot()` returns a detached, format-neutral record. It preserves entity
IDs and generations, component names and values, relationships, the state stack,
and named custom data. Store or encode this value using Nupp's file and data APIs.
The fixed accumulator and enabled phase state are preserved too.

```nupp
local snapshot = world:saveSnapshot()
-- Later, with the same component and state definitions registered:
local prelude = world:loadSnapshot(snapshot)
print(prelude.entityCount)
```

Use binary output for checkpoints and save files with native components.
`format = "binary"` returns a snapshot whose `bytes` field holds the encoding:

```nupp
local saved = world:saveSnapshot({format = "binary"})
world:loadSnapshot(saved)
world:loadSnapshot(saved.bytes)
```

A game that checkpoints often can keep one `bytes.Buffer` and save into it.
`saveSnapshotInto` replaces the buffer's contents with the new snapshot and makes
no string per save, and `loadSnapshotFrom` reads a buffer without consuming it:

```nupp
local checkpoint = bytes.Buffer.create()
world:saveSnapshotInto(checkpoint)
world:loadSnapshotFrom(checkpoint)
```

The optional `path` writes binary output to a file as well. The version-one
framing uses native double ID arrays and column-major FFI copies. Matching raw
layouts copy directly into their final columns without constructing a value per
row. Changed scalar layouts use saved fingerprints for field-name migration.
Custom codecs always take the codec path.

Loading accepts detached tables, column-indexed tables, tagged table and binary
outputs, and their byte strings. Install the named component and state
definitions before loading. Save and load may run inside an active system
after leaving any query loop; they reject publication callbacks and attempts to
operate on another suspended dispatch.

`filterQuery` selects archetypes, and `layers` selects Transform2D layers from
zero through 31. Entities without Transform2D pass the layer filter. A snapshot
without a filter includes disabled and paused entities.

## Where a save goes

Nupp owns the writable roots and names them from one application identity. A
game names itself once with `os.setappid`, before it creates its application,
and then asks `os.appdir` for a root and joins under it.
`tecs.application.newApplication` names the identity `"tecs", "tecs"` when a game
named none.

```nupp
os.setappid("Ex Nihilo", "Starfarer")
const saves = assert(os.appdir("data")):join("saves")
assert(os.mkdir(saves))
const saved = world:saveSnapshot({format = "binary"})
assert(os.writeatomic(saves:join("slot1.bin"), assert(saved.bytes)))
```

A joined path does not refuse `..`, so check a slot name that comes from player
input before joining it, or the save can land outside the root. `os.appdir("data")`
holds what a player would miss, `os.appdir("cache")` holds what the game can
rebuild and the operating system may empty between runs, and
`tecs.files.assetPath` resolves shipped content, which is never a place to
write.

## Durable world state

Persist game meaning: entity relationships, health, inventory, animation state,
and authored identity. `EntityKey` lets setup code rediscover individual entities
after load without keeping an old row address.

## Runtime state

Systems, queries, observers, component definitions, and resource values are runtime
setup. Install them before loading. Snapshots do not serialize functions or the
world's execution machinery.

## Component durability

Record components may supply `save(value)` and `load(saved)` callbacks. Use them
when the in-memory record holds handles or a different durable representation.
Keep persisted component names stable across code and module moves.
Use `deserialize(world, saved)` instead of `load` when decoding needs destination
world resources. Both component and relationship codecs accept this form. It runs
during validation, before entity replacement. A serializer
returning nil omits that component on the decoded path and never invokes its loader.

## Transient components

Set `transient = true` for projections such as native handles or caches. The
snapshot omits that component while retaining the entity. Rebuild projections
from durable state after loading.

## Snapshot handlers

Register a handler for durable resource state outside component columns:

```nupp
local SCORE: nupp.util.Key<number> = nupp.util.newKey("game.score")
world.resources:set(SCORE, 0)
world:addSnapshotHandler({
    name = "game.score",
    save = function(exclusive world: tecs.ecs.World): number
        return world.resources:get(SCORE) or 0
    end,
    load = function(exclusive world: tecs.ecs.World, value: any): nil
        world.resources:set(SCORE, value as number)
    end,
})
```

Handler names are persisted keys. `finish(world, prelude)` runs after entity and
handler restoration, when derived state can resolve restored identities.
`tecs.random`, `__tecs.pipeline` and `__tecs.stateStack` are reserved metadata keys.

## Snapshot lifecycle observation

`OnSnapshotSave` fires at address zero before entity selection. Its `addData`
method attaches metadata; `exclude(Component)` excludes whole derived entities,
unlike a transient component, which only omits its own column.

`StartSnapshotLoad` fires after entity restoration and before metadata dispatch.
Register `onData(key, callback)` handlers on this event for this load only.
Multiple listeners receive a key in registration order. `FinishSnapshotLoad`
carries the prelude after metadata handlers finish. Mutations staged by load
callbacks publish before `loadSnapshot` returns.

## State setup

Create every state with its policy before loading. Snapshots preserve the stack
and state tags; policy functions stay in game code. See [State stack](states.md).
