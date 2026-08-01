---
description: "Batch onEntitiesAdded and onEntitiesRemoved query hooks with row ranges and deferred-drain semantics"
outline: deep
---

# Query callbacks

`onEntitiesAdded` and `onEntitiesRemoved` react to changes in a query's match
set. Each callback receives one contiguous row range:

```teal
local physicsBodies <const> = world:newQuery({
    include = {tecs.Transform2D, tecs.physics.RigidBody},

    onEntitiesAdded = function(
        archetype: tecs.ecs.Archetype,
        firstRow: integer,
        lastRow: integer,
        count: integer
    )
        local transforms <const> = archetype:get(tecs.Transform2D)
        local bodies <const> = archetype:get(tecs.physics.RigidBody)

        reservePhysicsBodies(count)
        for row = firstRow, lastRow do
            attachBody(bodies[row], transforms[row])
        end
    end,

    onEntitiesRemoved = function(
        archetype: tecs.ecs.Archetype,
        firstRow: integer,
        lastRow: integer,
        _count: integer
    )
        local bodies <const> = archetype:get(tecs.physics.RigidBody)

        for row = firstRow, lastRow do
            detachBody(bodies[row])
        end
    end,
})
```

The inclusive bounds use one-based rows. `count` equals the range length, so a
batch path can reserve external storage once.

A temporary query cannot define either callback.

## Entities entering the query {#onentitiesadded-callback}

`onEntitiesAdded` runs when entities first match the descriptor:

- A spawn places matching components.
- A component addition satisfies `include`.
- A component removal satisfies `exclude`.

Moving between two archetypes that both match does not run the callback. The
entity never left the query.

Use [`requires`](/modules/ecs/components/#auto-dependencies-with-requires) when one
component always implies another. Use a callback when matching should trigger
work in an external system or allocate a resource.

## Entities leaving the query {#onentitiesremoved-callback}

`onEntitiesRemoved` runs before rows leave their archetype, so the callback can
still read every included column. These changes remove a match:

- Despawn.
- Removal of an included component.
- Addition of an excluded component.

A one-component query reacts to that component alone. A wider descriptor can
express a lifecycle boundary such as `{Enemy, Stunned}` or
`{Transform2D, RigidBody}` without coordinating separate hooks.

## Commit drain {#deferred-scope}

Query callbacks run inside the commit drain. A drain applies changes in waves:
despawns first, then spawns, then archetype moves. It applies batch mutations
and sparse relationship writes between waves.

A callback may stage more work. The next wave applies that work:

- Structural calls through `set`, `remove`, `spawn`, `despawn`, and the
  `batch*` APIs do not change committed structure immediately.
- `get`, `has`, and queries see committed structure. They do not see staged
  additions, removals, spawns, or despawns.
- A value-only `set` on a committed entity writes immediately when no staged
  structural change blocks it, and it marks the component dirty.
- The callback may read the supplied archetype and row range until it returns.
  Read needed values before staging changes to those entities.

A finite callback cascade settles through later waves. Tecs stops an unbounded
cascade with an error after 64 waves.

The [mutation model](/modules/ecs/mutation-model#commit-drain) defines the complete
ordering and visibility contract.

## Archetype-local observers

`archetype:addEntityObserver` attaches lower-level hooks to one archetype,
including activation, deactivation, moves, and destruction. It does not find
other archetypes with the same signature. Query callbacks follow the query as
new archetypes begin to match, so game and subsystem code should normally use
them.
