---
outline: deep
---

# Query callbacks

Query callbacks let you react when entities **match** or **stop matching** a query. `onEntitiesAdded`
and `onEntitiesRemoved` provide batch-friendly hooks that enable use cases like registering and deregistering entities
from external systems (e.g., physics, GPU, etc).

## onEntitiesAdded callback

The `onEntitiesAdded` callback fires once per contiguous range of entities when they _first_ match the query. For
example, a newly-spawned batch of entities, a single spawn, an entity that gained a required component, or lost an
excluded component. This callback _does not_ fire when an entity moves between archetypes that both match the query.

```teal{3}
world:query({
    include = {tecs.builtins.Transform, MyPhysicsComponent},
    onEntitiesAdded = function(
        archetype: tecs.Archetype,
        firstRow: integer,
        lastRow: integer,
        count: integer
    )
        local transforms = archetype:get(tecs.builtins.Transform)
        local comps = archetype:get(MyPhysicsComponent)
        for row = firstRow, lastRow do
            local transform = transforms[row]
            local comp = comps[row]
            -- add to your physics world...
        end
    end
})
```

The callback receives the archetype and 1-based `firstRow` / `lastRow` (inclusive) bounds plus the `count`.

## onEntitiesRemoved callback

`onEntitiesRemoved` fires once per contiguous range of entities that no longer match the query. It's triggered by
removing a required component, adding an excluded component, or a despawn. This callback is fired _before_ entities are
removed from archetypes.

```teal{9}
world:query({
    include = {tecs.builtins.Transform, MyPhysicsComponent},
    onEntitiesRemoved = function(
        archetype: tecs.Archetype,
        firstRow: integer,
        lastRow: integer,
        count: integer
    )
        local transforms = archetype:get(tecs.builtins.Transform)
        local comps = archetype:get(MyPhysicsComponent)
        for row = firstRow, lastRow do
            local transform = transforms[row]
            local comp = comps[row]
            -- remove comps[row] from external system...
        end
    end,
})
```

## Callback signature

Callbacks receive a range of rows as 1-based inclusive bounds: `firstRow`, `lastRow`, and a `count`. Count is `1`
for single spawns and archetype transitions, `N` for batch spawns (`world:batchSpawn`) and batch despawns. This
lets you amortize per-entity work (slot allocation, buffer sizing, dirty marking) across a whole batch in one call.
Iterate the range directly with `for row = firstRow, lastRow do`.

For auto-attaching companion components (e.g. `Velocity` should imply `Position`), use
[`requires`](/tecs/components/#auto-dependencies-with-requires) on the component declaration rather
than query callbacks.

## Reacting to a single component

To run code when a specific component appears on or leaves an entity, build a query whose `include` contains
just that component. `onEntitiesAdded` fires when the entity first gains the component (via spawn, `world:set`,
or an archetype transition that pulls it in); `onEntitiesRemoved` fires when the entity loses it (via
`world:remove`, despawn, or an exclusion flipping).

```teal
-- React when Health appears or goes away, regardless of whatever
-- other components the entity carries.
world:query({
    include = {Health},
    onEntitiesAdded = function(
        arch: tecs.Archetype,
        firstRow: integer,
        lastRow: integer,
        count: integer
    )
        local healths = arch:get(Health)
        local entities = arch.entities
        for row = firstRow, lastRow do
            print("gained Health:", entities[row], healths[row].current)
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
            print("lost Health:", entities[row])
        end
    end,
})
```

Combine `include` with `exclude` to react to more specific transitions. For example, to fire exactly when
an entity enters a "stunned" state and again when it leaves:

```teal
world:query({
    include = {Enemy, Stunned},
    onEntitiesAdded = function(
        arch: tecs.Archetype,
        firstRow: integer,
        lastRow: integer,
        count: integer
    )
        -- Entity acquired Stunned (and was already Enemy).
    end,
    onEntitiesRemoved = function(
        arch: tecs.Archetype,
        firstRow: integer,
        lastRow: integer,
        count: integer
    )
        -- Entity lost Stunned or Enemy (or was despawned).
    end,
})
```

## Deferred scope

Query callbacks run inside the world's **drain**, the phase that commits staged mutations after a system or
batch finishes. The drain proceeds in **waves**: a wave walks the currently-dirty archetype list and applies
despawns, then spawns, then moves, firing matching callbacks along the way. If a callback stages more
mutations, the newly-dirtied archetypes form the next wave; batch mutations and sparse relationship writes
apply between waves. The full ordering contract lives in the
[Mutation model](/tecs/mutation-model#the-commit-drain).

Inside a callback:

- `world:set`, `world:remove`, `world:spawn`, `world:despawn`, and the `batch*` APIs all stage structural
  changes; they apply in the next wave, not immediately.
- `world:get`, `world:has`, and queries see committed **structure** only: staged adds, removes, spawns, and
  despawns stay invisible until the drain applies them. Value-only `world:set` calls on entities with no
  staged structural change write through immediately. See
  [Visibility inside a scope](/tecs/mutation-model#visibility-inside-a-scope).
- Reading the passed `archetype`'s columns is safe and reflects the current state of the entities in the range.
  Don't add or remove components on entities you're iterating within the callback; if you must, read all the
  data you need out of the archetype first, then stage the mutations.

Finite cascades settle automatically. Unbounded cascades (hook A adds a component that fires hook B which
re-adds what hook A removed, etc.) stop with an error after 64 waves.
