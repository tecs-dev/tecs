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

Use binary output for checkpoints and save files with native components:

```nupp
local buffer = require("string.buffer")
local output = buffer.new()
local saved = world:saveSnapshot({format = "binary", buffer = output})
world:loadSnapshot(saved)
world:loadSnapshot(output:tostring())
```

The optional `path` writes binary output to a file and still returns the buffer.
Reusing a buffer replaces its prior snapshot; loading a buffer does not consume
it. The version-one framing uses native double ID arrays and column-major
FFI copies. Matching raw layouts copy directly into their final columns without
constructing a value per row. Changed scalar layouts use saved fingerprints for
field-name migration. Custom codecs always take the codec path.

Loading accepts detached tables, column-indexed tables, tagged
table/binary outputs, byte strings and buffers. Install the named component and
state definitions before loading. Save and load may run inside an active system
after leaving any query loop; they reject publication callbacks and attempts to
operate on another suspended dispatch.

`filterQuery` selects archetypes, and `layers` selects Transform2D layers from
zero through 31. Entities without Transform2D pass the layer filter. A snapshot
without a filter includes disabled and paused entities.

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
local SCORE = nupp.data.newKey<number>("game.score")
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
