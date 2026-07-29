---
description: "Archetype storage, column access, relationship lookups, dirty tracking, and lifecycle observers"
outline: deep
---

# Archetypes

An archetype stores entities with one component signature. Adding or removing
a component moves an entity to another archetype. Most game code reaches these
storage groups through a [query](/ecs/queries/).

## Rows and columns

One row index selects an entity ID and every component value for that entity:

```teal
for archetype, length, entities in movers:iter() do
    local transforms <const> = archetype:getMut(tecs.Transform)
    local velocities <const> = archetype:get(Velocity)

    for row = 1, length do
        local transform <const> = transforms[row]
        local velocity <const> = velocities[row]

        transform.x = transform.x + velocity.x * dt
        transform.y = transform.y + velocity.y * dt
        print(entities[row])
    end
end
```

Rows start at 1. `archetype.entities[0]` contains the current length. Treat the
entity column and `componentList` as read-only.

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

`archetype:set(row, value)` replaces a component already present in the
signature and marks it dirty. It cannot add a component. Use `world:set` when
the entity may need an archetype transition.

## Relationship storage

Dense relationship instances occupy archetype columns. Use
`forEachRelationship` or `getFirstRelationship` when code already has an
archetype and row.

Sparse relationships, including `ChildOf`, keep targets in a world-owned
store. Resolve them through `world:getFirstRelationship`, `world:targets`,
`world:traverse`, or `world:walkUp`. See
[Relationships](/ecs/relationships/).

## Dirty consumers

Incremental consumers can test one component, test the whole archetype, or
iterate its dirty components. The world clears dirty bits after each
`world:update`, once the pipeline has consumed them.

Spawn placement, archetype movement, swap-pop, `getMut`, and `set` maintain
dirty state automatically. Call explicit markers only after a write through a
path Tecs cannot observe, such as direct FFI cdata obtained through `get`.

[Dirty tracking](/ecs/components/dirty-tracking) covers the complete write
contract.

## Lifecycle reactions

An archetype observer can react to contiguous additions, removals, row moves,
activation, deactivation, and destruction. It remains attached for that
archetype's lifetime and cannot unsubscribe.

Prefer [query callbacks](/ecs/queries/callbacks) when the reaction belongs to
a component filter. Queries discover current and future matching archetypes
and attach the necessary observers. Use a direct archetype observer only when
the storage object itself matters.
