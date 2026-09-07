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
    for row = 1, length as integer do
        local transform = transforms[row]
        local velocity = velocities[row]

        transform.x = transform.x + velocity.x * dt
        transform.y = transform.y + velocity.y * dt
        print(entities[row])
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
