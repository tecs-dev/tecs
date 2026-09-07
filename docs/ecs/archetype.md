---
description: "Archetype storage, column access, relationship lookups, dirty tracking, and lifecycle observers"
outline: deep
---

# Archetypes

An archetype stores entities with one component signature. Adding or removing
a component moves an entity to another archetype. Most game code reaches these
storage groups through a [query](/ecs/queries/index.md).

## Rows and columns

One row index selects an entity ID and every component value for that entity:

```nupp
for archetype, length in movers:iter() do
    local entities = archetype.entities
    local transforms = assert(archetype:getMut(tecs.ecs.Transform2D))
    local velocities = assert(archetype:get(Velocity))
    unsafe do
        for row = 1, length as integer do
            local transform = transforms[row]
            local velocity = velocities[row]

            transform.x = transform.x + velocity.x * dt
            transform.y = transform.y + velocity.y * dt
            print(entities[row])
        end
    end
end
```

Rows start at 1. The iterator supplies the current length. Treat the entity column and
component signature as read-only.

A row identifies a position in current storage, not an entity. Despawn and
archetype transitions use swap-pop movement, so never retain a row across
structural changes. Retain the entity ID instead.

## Read and write intent

`archetype:get(Component)` returns a column without marking it dirty.
`archetype:getMut(Component)` returns the same storage and marks the component
dirty for that archetype.

Use `getMut` only when the loop will write. A speculative call dirties every
row in the column and forces dirty-gated consumers to process unchanged data.
For conditional writes, read through `get`, perform the write only when
needed, then call `markComponentDirty`.

Use `world:set` to replace a component value or add one to the signature.

## Bulk publication

Use `batchSpawn`, `batchSet`, `batchRemove`, and `batchDespawn` for whole-query
work. These are the original ECS operation names: adding a component is
`batchSet`, and deleting entities is `batchDespawn`.

```nupp
local world = tecs.ecs.newWorld()
local movers = world:newQuery({include = {tecs.ecs.Transform2D}})
local firstId, ids = world:batchSpawn(
    10000,
    {tecs.ecs.Transform2D},
    function(archetype: tecs.ecs.Archetype, first: integer, last: integer): nil
        local transforms = assert(archetype:getMut(tecs.ecs.Transform2D))
        unsafe do
            for row = first, last do
                transforms[row].x = row * 2
            end
        end
    end
)
world:commit()
world:batchSet(movers, tecs.ecs.Paused)
world:commit()
world:batchRemove(movers, tecs.ecs.Paused)
world:batchDespawn(movers)
world:commit()
```

A contiguous reservation returns its first packed identity and no ID list.
Recycled slots or mixed generations return an explicit list instead. Neither
form is alive before publication. The initializer runs after placement and
defaults, before membership and spawn observers. Stateful default factories
still run separately for every row.

Query-based batches capture committed membership when called. They do not pick
up a queued spawn that publishes later. A batch writer and subsequent scalar
edits retain their order; cancelling a reserved spawn suppresses its initializer
and spawn events. As with scalar mutations, an exception does not roll back
already published rows, but unpublished reservations are released.

The fast path queues one descriptor per batch, keeps reservation and mutation
stamps in native slot storage, and initializes columns without allocating a
transaction record or values map per entity. Whole-archetype moves exchange
common column buffers when the destination is empty and copy contiguous native
columns when it is populated. Plain teardown truncates columns once. Native ID
snapshots preserve query membership across earlier queued work. Relationships,
durable keys, and changed selections use the ordinary mutation path where their
indexing, cascading, or per-entity semantics require it.

Restoration also has `batchSpawnAt` for an ID list and `batchSpawnAtRaw` for a
borrowed zero-based native double array. The raw path permits initializing
`EntityKey` before index registration. Do not mutate its ID prefix before the
publication barrier. Ordinary batch spawns reject `EntityKey`; set unique keys
per entity instead.

Native views and row numbers must be reacquired after any structural publication,
including a bulk column swap. Run `nupp task bench bulk` to measure stage-and-commit
throughput and allocation for these four operations.

## Relationship storage

Relationship values occupy ordinary component columns. Read `ChildOf` with
`world:get(entity, tecs.ecs.ChildOf)` or `archetype:get(tecs.ecs.ChildOf)`.
Change a target through `world:set`, so its reverse index stays current.
See [Relationships](relationships/index.md).

## Dirty consumers

Incremental consumers inspect dirty state before processing a component column. The world clears dirty bits after each
`world:update`, once the pipeline has consumed them.

Spawn placement, archetype movement, swap-pop, `getMut`, and `set` maintain
dirty state automatically. Call explicit markers only after a write through a
path Tecs cannot observe, such as a value obtained through `get`.

[Dirty tracking](/ecs/components/dirty-tracking.md) covers the complete write
contract.
