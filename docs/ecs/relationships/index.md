---
description: "Directed entity relationships, storage, deletion, and traversal"
outline: deep
---

# Relationships

A relationship connects one entity to another. Tecs ships
[`ChildOf`](tecs.ecs.ChildOf), an exclusive relationship with a
reverse index and cascade delete:

```nupp
local ChildOf = tecs.ecs.ChildOf

local parent = world:spawn(tecs.ecs.Transform2D(100, 100))
local child = world:spawn(
    ChildOf(parent),
    tecs.ecs.RelativeTransform2D(16, 0)
)

world:commit()
local link = world:get(child, ChildOf)
print(assert(link).target) -- parent

world:despawn(parent) -- also despawns child
```

Relationships use the component API. Pass an instance to `world:set`, pass the
relationship definition to `world:remove`, include it in a query, and read it from an entity
or archetype.

## Defining a relationship

A relationship connects a source to one target. Setting it again replaces that
edge. Tecs currently exposes target-only, exclusive relationships:

```nupp
local Targets = tecs.ecs.newRelationship({
    name = "Targets",
    exclusive = true,
    reverseIndex = true,
})
world:set(enemy, Targets(player))
world:set(enemy, Targets(decoy))
```

Tecs owns `target`; treat it as read-only and replace an edge through
`world:set` instead of changing the field. Read the edge with
`world:get(entity, Targets)` and test presence with `world:has(entity, Targets)`.

## Reverse lookup and traversal

Set `reverseIndex = true` when code needs to find the sources that point at a
target. `world:relationshipSources(Relationship, target)` returns those IDs.

```nupp
for _, child in ipairs(world:relationshipSources(tecs.ecs.ChildOf, parent)) do
    print(child)
end
```

A forward walk reads successive target values with `world:get`. Keep a visited
set or depth bound when a game permits cycles.

## Removal and target lifetime

`world:remove(entity, Relationship)` removes the edge. Removing an edge never
triggers cascade delete, so reparenting can remove or replace `ChildOf` without
despawning the child.

`cascadeDelete = true` makes target despawn recursively despawn every source.
It requires both `exclusive = true` and `reverseIndex = true`.

Snapshots preserve target identities. Set `transient = true` for an edge that
must not survive a snapshot.
