---
description: "Batch onEntitiesAdded and onEntitiesRemoved query hooks with row ranges and deferred-drain semantics"
outline: deep
---

# Query callbacks

Query callbacks let you react when entities **match** or **stop matching** a query. `onEntitiesAdded`
and `onEntitiesRemoved` provide batch-friendly hooks that enable use cases like registering and deregistering
entities from external systems such as physics or the GPU.

Both are fields on the [query descriptor](/ecs/queries/#descriptor-reference), and neither can be combined with
`temp = true`.

## onEntitiesAdded callback

The `onEntitiesAdded` callback fires once per contiguous range of entities when they _first_ match the query. For
example, a newly-spawned batch of entities, a single spawn, an entity that gained a required component, or lost an
excluded component. This callback _does not_ fire when an entity moves between archetypes that both match the query.

```teal{3}
world:query({
    include = {tecs.ecs.builtins.Transform, tecs.physics.RigidBody},
    onEntitiesAdded = function(
        archetype: tecs.Archetype,
        firstRow: integer,
        lastRow: integer,
        count: integer
    )
        local transforms = archetype:get(tecs.ecs.builtins.Transform)
        local bodies = archetype:get(tecs.physics.RigidBody)
        for row = firstRow, lastRow do
            local transform = transforms[row]
            local body = bodies[row]
            -- add to your physics world...
        end
    end
})
```

The callback receives the archetype and 1-based `firstRow` / `lastRow` (inclusive) bounds plus the `count`.

It also fires at query construction, and again whenever a new archetype starts matching, for every entity already
in a matching archetype. A query built after the entities exist still sees them.

## onEntitiesRemoved callback

`onEntitiesRemoved` fires once per contiguous range of entities that no longer match the query. It's triggered by
removing a required component, adding an excluded component, or a despawn. This callback is fired _before_ entities
are removed from archetypes, so the rows in the range are still readable.

```teal{9}
world:query({
    include = {tecs.ecs.builtins.Transform, tecs.physics.RigidBody},
    onEntitiesRemoved = function(
        archetype: tecs.Archetype,
        firstRow: integer,
        lastRow: integer,
        count: integer
    )
        local transforms = archetype:get(tecs.ecs.builtins.Transform)
        local bodies = archetype:get(tecs.physics.RigidBody)
        for row = firstRow, lastRow do
            local transform = transforms[row]
            local body = bodies[row]
            -- destroy the solver body backing this row...
        end
    end,
})
```

Like `onEntitiesAdded`, it is suppressed when the destination archetype also matches the query, because the entity
never left the match set.

## Callback signature

```teal
function(archetype: Archetype, firstRow: integer, lastRow: integer, count: integer)
```

Callbacks receive a range of rows as 1-based inclusive bounds: `firstRow`, `lastRow`, and a `count`. Count is `1`
for single spawns and archetype transitions, `N` for batch spawns (`world:batchSpawn`) and batch despawns. This
lets you amortize per-entity work (slot allocation, buffer sizing, dirty marking) across a whole batch in one call.
Iterate the range directly with `for row = firstRow, lastRow do`.

For auto-attaching companion components, use `requires` on the component declaration rather than query callbacks.
That is how `tecs.ecs.builtins.RelativeTransform` pulls in `Transform`: the dependency is declared once and applied in
the same archetype transition, so no callback has to observe the add and issue a second one. See
[Components](/ecs/components/).

## Reacting to a single component

To run code when a specific component appears on or leaves an entity, build a query whose `include` contains
just that component. `onEntitiesAdded` fires when the entity first gains the component (via spawn, `world:set`,
or an archetype transition that pulls it in); `onEntitiesRemoved` fires when the entity loses it (via
`world:remove`, despawn, or an exclusion flipping).

```teal
local PointLight <const> = tecs.gfx.PointLight

-- React when a light appears or goes away, regardless of whatever
-- other components the entity carries.
world:query({
    include = {PointLight},
    onEntitiesAdded = function(
        arch: tecs.Archetype,
        firstRow: integer,
        lastRow: integer,
        count: integer
    )
        local lights = arch:get(PointLight)
        local entities = arch.entities
        for row = firstRow, lastRow do
            print("gained PointLight:", entities[row], lights[row].radius)
        end
    end,
    onEntitiesRemoved = function(
        arch: tecs.Archetype,
        firstRow: integer,
        lastRow: integer,
        count: integer
    )
        local entities = arch.entities
        for row = firstRow, lastRow do
            print("lost PointLight:", entities[row])
        end
    end,
})
```

`arch.entities` is the archetype's 1-based entity ID array; its length is `entities[0]`.

Narrow the `include` set to react to more specific transitions. This one fires exactly when a renderable starts
being clipped and again when it stops:

```teal
world:query({
    include = {tecs.gfx.Renderable, tecs.gfx.Clip},
    onEntitiesAdded = function(
        arch: tecs.Archetype,
        firstRow: integer,
        lastRow: integer,
        count: integer
    )
        -- Entity acquired Clip (and was already Renderable).
    end,
    onEntitiesRemoved = function(
        arch: tecs.Archetype,
        firstRow: integer,
        lastRow: integer,
        count: integer
    )
        -- Entity lost Clip or Renderable (or was despawned).
    end,
})
```

`exclude` participates in the same way: an entity that gains an excluded component leaves the match set and fires
`onEntitiesRemoved`.

## Deferred scope

Query callbacks run inside the world's **drain**, the phase that commits staged mutations when the outermost
deferred scope closes. The drain proceeds in **waves**: a wave walks the currently-dirty archetype list and applies
despawns first (so spawns can reuse rows), then spawns, then moves, firing matching callbacks along the way. If a
callback stages more mutations, the newly-dirtied
archetypes form the next wave; batch mutations and sparse relationship writes apply between waves.

Inside a callback:

- `world:set`, `world:remove`, `world:spawn`, `world:despawn`, and the `batch*` APIs all stage structural
  changes; they apply in a later wave, not immediately.
- `world:get`, `world:has`, and queries see committed **structure** only: staged adds, removes, spawns, and
  despawns stay invisible until the drain applies them. A value-only `world:set` on a committed entity with no
  staged structural change writes through immediately and marks the component dirty.
- Reading the passed `archetype`'s columns is safe and reflects the current state of the entities in the range.
  Don't add or remove components on entities you're iterating within the callback; if you must, read all the
  data you need out of the archetype first, then stage the mutations.

Finite cascades settle automatically. An unbounded cascade (hook A adds a component that fires hook B which
re-adds what hook A removed, and so on) stops with an error after 64 waves.

## Related archetype observers

Query callbacks are the supported way to react to match-set changes. An archetype also accepts a lower
level `ArchetypeEntityObserver` through `archetype:addEntityObserver`, which adds `onEntityMove`, `onActivated`,
`onDeactivated`, and `onArchetypeDestroyed` on top of the two range hooks. Registration applies only to that one
archetype; it does not discover other archetypes with the same components, which is what a query does for you.
