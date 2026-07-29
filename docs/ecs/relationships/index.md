---
description: "Directed entity relationships, storage, deletion, and traversal"
outline: deep
---

# Relationships

A relationship connects one entity to another. Tecs ships
[`ChildOf`](/ecs/builtins#childof), an exclusive sparse relationship with a
reverse index and cascade delete:

```teal
local ChildOf <const> = tecs.ecs.ChildOf

local parent <const> = world:spawn(tecs.Transform(100, 100))
local child <const> = world:spawn(
    ChildOf(parent),
    tecs.ecs.RelativeTransform(16, 0)
)

local link <const> = world:getFirstRelationship(child, ChildOf)
print(link.target) -- parent

world:despawn(parent) -- also despawns child
```

Relationships use the component API. Pass an instance to `world:set` or
`world:remove`, include the relationship in a query, and read it from an entity
or archetype.

## Defining a relationship

`newRelationship` creates either a target-only relationship or a relationship
with a Lua payload. Use [`newFFIRelationship`](/ecs/relationships/ffi) when the
payload belongs in a packed C struct.

This target-only relationship lets an entity like several targets:

```teal
local Likes: tecs.ecs.Relationship = tecs.ecs.newRelationship({
    name = "Likes",
})

world:set(alice, Likes(bob))
world:set(alice, Likes(carol))
```

A relationship with data declares the payload fields after the target:

```teal
local record Follows is tecs.ecs.Relationship
    delay: number
    maxDistance: number

    metamethod __call: function(
        self,
        target: integer,
        delay?: number,
        maxDistance?: number
    ): Follows
end

tecs.ecs.newRelationship({
    name = "Follows",
    container = Follows,
    fields = {"delay", "maxDistance"},
    defaults = {0.5, 100},
})

world:set(follower, Follows(leader, 0.25, 50))
world:set(follower, Follows.new({
    target = leader,
    delay = 0.25,
    maxDistance = 50,
}))
```

The target always comes first in the positional form and lives under `target`
in the table form. Tecs owns `target`; treat it as read-only and replace an
edge through `world:set` instead of changing the field. Do not include
`"target"` in `fields`.
[Component construction](/ecs/components/construction) covers `fields`,
`defaults`, `init`, custom `__call`, and `.new`.

## Exclusive relationships

A relationship normally allows several targets on one source. Setting the same
target again replaces that edge's value.

Set `exclusive = true` when each source may name only one target:

```teal
local Targets: tecs.ecs.Relationship = tecs.ecs.newRelationship({
    name = "Targets",
    exclusive = true,
})

world:set(enemy, Targets(player))
world:set(enemy, Targets(decoy)) -- replaces Targets(player)
```

`world:getFirstRelationship(entity, Targets)` returns the edge. For an
exclusive relationship, it returns the only edge.

## Dense and sparse storage

A dense relationship creates a component type for each target. Entities that
point at different targets occupy different archetypes. That layout supports a
target-specific query:

```teal
local followersOfLeader <const> = world:query({
    include = {Follows:targeting(leader)},
})
```

Use dense storage when systems often query one target and the target set stays
small.

`sparse = true` keeps targets in entity-indexed side storage. Every source
shares the relationship's wildcard component in its archetype, so a large
target set does not fragment the world. `ChildOf` uses this layout.

```teal
local children <const> = world:query({
    include = {ChildOf, tecs.Transform},
})

for archetype, length in children:iter() do
    local parents <const> = archetype:get(ChildOf)
    for row = 1, length do
        print(parents[row].target)
    end
end
```

The sparse column proxy supports row reads only. Tecs owns its target values;
change an edge through `world:set`. Sparse relationships do not expose
`targeting`; filter the proxy inside the loop or use a reverse index.

For either layout:

- `world:getFirstRelationship(entity, Relationship)` returns an arbitrary
  edge, and the only edge for an exclusive relationship.
- `world:get(entity, Relationship(target))` selects one target.
- `world:has(entity, Relationship)` checks for any target.
- `world:has(entity, Relationship(target))` checks one target.
- A query that includes the bare relationship matches any target.

Callers may mutate a dense payload through `getMut`. Sparse payloads belong to
the side store; replace those edges through `world:set`.

## Reverse lookup and traversal

Set `reverseIndex = true` when code needs to find the sources that point at a
target. Both dense and sparse relationships support the index.

```teal
world:targets(parent, ChildOf, function(childId: integer)
    print("child", childId)
end)

for depth, entityId in world:traverse(root, ChildOf) do
    print(depth, entityId)
end
```

`world:targets` accepts a context value and passes it as the callback's second
argument. A hoisted callback and reused context avoid a closure allocation:

```teal
local countContext = {count = 0}

local function countChild(_childId: integer, context: typeof(countContext))
    context.count = context.count + 1
end

countContext.count = 0
world:targets(parent, ChildOf, countChild, countContext)
```

`world:walkUp` follows forward edges, so it needs an exclusive relationship but
not a reverse index:

```teal
world:walkUp(entity, ChildOf, function(ancestorId: integer, depth: integer)
    print(depth, ancestorId)
end)
```

The callback may return `false` to stop. The optional `maxDepth` defaults to
100 and turns a cycle into an error instead of an infinite walk.

## Removal and target lifetime

Pass an instance to remove one target:

```teal
world:remove(alice, Likes(bob))
```

Passing a sparse relationship container removes all its targets from the
source. Removing an edge never triggers cascade delete, so reparenting can
remove or replace `ChildOf` without despawning the child.

`cascadeDelete = true` makes target despawn recursively despawn every source.
It requires both `exclusive = true` and `reverseIndex = true`.

A reverse index also lets target despawn unlink ordinary edges. Without one,
Tecs has no inverse to consult; `world:compact()` later prunes unreachable
archetypes whose targets have died.

`Relationship(target)` interns one weakly held instance per target. Dense
storage registers that instance as its target-specific component. Sparse
storage uses it as an edge value and keeps the payload in the world's side
store.

Snapshots write `target` plus every declared payload field. Set
`transient = true` for an edge that must not survive a snapshot.
