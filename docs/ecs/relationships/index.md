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

A relationship has either one target per source (`exclusive = true`) or multiple
targets. Edges may be target-only or carry a record or native struct payload.
For example, this target-only relationship replaces its edge when set again:

```nupp
local Targets = tecs.ecs.newRelationship({
    name = "Targets",
    exclusive = true,
    reverseIndex = true,
})
world:set(enemy, Targets(player))
world:set(enemy, Targets(decoy))
```

Derive a payload relationship directly on its declaration:

```nupp
@derive(tecs.ecs.Relationship)
@relationship(reverseIndex = true)
local struct Spring
    target: number
    stiffness: number = 1
end

world:set(enemy, new Spring(player, 0.5))
local springsToPlayer = world:newQuery({
    include = {tecs.ecs.targeting(Spring, player)},
})
```

Native payloads use a `number` target field to store exact entity identifiers.
Managed record payloads may use `integer`. Names default to the module-qualified
declaration; `@relationship(name = "game.Spring")` pins the persisted name.
`tecs.ecs.newRelationship(Spring, options)` configures factories, requirements or
codecs, or creates another named identity for the same payload layout.
There is no untargeted default factory: the declaration supplies the layout,
and every constructed edge supplies its target.

Dense storage creates target-specific archetype columns. `targeting` returns
their typed query selectors. With `sparse = true`, edges live in entity-indexed
storage instead; use `world:forEachRelationship` to visit outgoing payloads and
`world:targets` to visit sources through the reverse index. Sparse relationships do not support
target-specific archetype selectors.

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
