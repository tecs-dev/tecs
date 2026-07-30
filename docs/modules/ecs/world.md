---
description: "World entities, spawning, batches, deferred scopes, resources, plugins, phases, and stats"
outline: deep
---

# World

A world owns the complete ECS runtime: entities, archetypes, queries, systems,
resources, bundles, event observers, snapshot handlers, and state.

```teal
local world <const> = tecs.ecs.newWorld({
    timestep = 1 / 60,
})
```

The default world supports about one million concurrent entity slots. A
configuration may raise `maxEntities` to the packed-ID limit of `2^22 - 1`.
Tests and specialized hosts may also supply a pipeline factory.

## Lifecycle

`Application` creates and drives its world. After the entry plugin finishes,
it calls `startup()` once, `update(dt)` every host iteration, and `shutdown()`
at teardown.

Tests, tools, and benchmarks may drive those calls directly:

```teal
world:startup()
world:update(1 / 60)
world:shutdown()
```

Before phase dispatch, `update` calls `unwind` to close any scope an earlier
error left open. After the pipeline returns, it clears component dirty bits.
Render extraction runs inside that pipeline and consumes the bits first.

`getFixedTiming()` returns the timestep, residual accumulator, and clamped
interpolation alpha without allocating. `fixedStepCount()` returns the number
of fixed steps since world construction. The scheduler advances those values
even when callers disable fixed phases.

## Entity IDs

Entity IDs pack a slot and generation into an opaque number:

```teal
local old <const> = world:spawn()
world:despawn(old)

local current <const> = world:spawn()
assert(not world:isAlive(old))
assert(world:isAlive(current))
```

Slot reuse changes the generation, so stale handles fail lookups. Do not
inspect IDs with LuaJIT bit operations; packed values may exceed 32 bits.

Use `EntityKey` for the few authored entities that runtime code must
rediscover:

```teal
world:spawn(
    tecs.ecs.EntityKey("player"),
    tecs.ecs.Name("Player ship")
)

local player <const> = world:requireKey("player")
```

Callers choose keys. Tecs owns the unique index, releases entries on removal or
despawn, and rebuilds it after snapshot load.

## Spawning entities

`spawn` accepts initial components and returns an ID immediately:

```teal
local player <const> = world:spawn(
    tecs.Transform(100, 100),
    tecs.gfx.Tint(1, 1, 1, 1),
    tecs.gfx.Renderable,
    tecs.ecs.Name("Player")
)
```

Outside a scope, the entity occupies its archetype before `spawn` returns.
Inside a scope, the world reserves the ID and stages placement. Later staged
`set`, `remove`, or `despawn` calls may use that ID.

`spawnAt` and `batchSpawnAt` place caller-chosen packed IDs. Snapshot loading
uses them to preserve relationship targets and generations. The caller must
ensure that each chosen slot has no live entity.

## Batch mutation

`batchSpawn` resolves one component signature and opens one fill callback:

```teal
local signature <const> = {
    tecs.Transform,
    tecs.gfx.Tint,
    tecs.gfx.Renderable,
}

local firstId, ids = world:batchSpawn(
    1000,
    signature,
    function(archetype, firstRow, lastRow)
        local transforms <const> = archetype:getMut(tecs.Transform)
        local tints <const> = archetype:getMut(tecs.gfx.Tint)

        for row = firstRow, lastRow do
            local transform <const> = transforms[row]
            transform.x = row - firstRow
            transform.y = 0
            transform.z = 0
            transform.layer = 1
            transform.rotation = 0
            transform.scaleX = 1
            transform.scaleY = 1

            local tint <const> = tints[row]
            tint.r = 1
            tint.g = 1
            tint.b = 1
            tint.a = 1
        end
    end
)
```

The contiguous allocator returns `firstId`; the fallback returns an explicit
`ids` list. Both paths reserve IDs before placement.

Batch placement follows these rules:

- Component constructors do not run. Tecs writes only `requires` defaults
  before the callback, so the callback must initialize every field it uses.
- `EntityKey` cannot participate because each row needs a distinct index
  claim.
- Batch spawn emits no `OnSpawn`; use the fill callback or
  `onEntitiesAdded`.
- Sparse relationship proxies reject writes. Attach each target through
  `world:set(reservedId, Relationship(target))`.
- The callback runs during drain, either inside the call at depth zero or when
  the outer scope closes.

`batchSet` adds or replaces one component across a query. Its constant form
accepts an instance. Its callback form accepts a bulk-safe component type and
opens the destination column for caller writes. Relationships use the constant
form; sparse relationships route through their world stores.

`batchRemove` removes one component across matching archetypes.
`batchDespawn` removes every matched entity. Relationship cleanup, cascade
delete, entity observers, and component cleanup force per-entity work where
needed; otherwise the batch path clears whole ranges. Every despawn still
emits `OnDespawn`.

## Entity clearing and storage maintenance

`clearEntities()` removes entity data, pending transactions, sparse stores,
keys, queued events, and entity-address observers. It preserves systems,
queries, global observers, bundles, component registrations, archetypes, and
column capacity.

Use a new world when systems and queries must also disappear.

`compact()` prunes unreachable empty relationship archetypes and shrinks excess
column capacity. Call it only at a quiet boundary after `commit`; level
transitions suit it better than frame loops.

`forEachArchetype` and `dirtyArchetypes` expose engine-owned archetype handles
for read-only inspection. Do not mutate the world during those iterations.
Dirty-archetype iteration resets after each update.

`getStats(fill?)` writes current counts into a caller-owned table. Callers may
reuse and read that table; Tecs writes its fields on each call.

## Deferred operations {#deferred-operations}

Scope depth chooses immediate or staged structural mutation. Query iteration,
query callbacks, and batch calls open scopes automatically. Callers may open
one explicitly:

```teal
local function extinguish(world: tecs.World, entity: integer)
    world:defer()
    world:set(entity, tecs.gfx.Tint(0.2, 0.2, 0.2, 1))
    world:remove(entity, tecs.gfx.PointLight)
    world:remove(entity, tecs.gfx.Renderable)
    world:commit()
end
```

`defer` increments depth. `commit` decrements it and drains when the outermost
scope closes. Calls may nest. A `commit` at depth zero remains harmless and
never discards work.

Inside a scope, spawns, despawns, component additions, and component removals
remain invisible until drain. A value update to an existing component may
write through immediately while that entity has no staged structural change.
The [mutation model](/modules/ecs/mutation-model) defines the complete contract.

An archetype query loop must run to exhaustion. A loop that may stop early
uses `query:cursor()` and calls `cursor:close()`, or it leaves the world
deferred.

`unwind()` closes every scope and drains pending work. It supplies the recovery
path after a system throws inside iteration.

## Plugins and resources

A plugin configures one world. Games, engine features, and reusable mechanics
all use the same function shape:

```teal
local RATE <const>: tecs.data.Key<number> =
    tecs.data.newKey("game.spinRate")

local function spinPlugin(world: tecs.World)
    world.resources[RATE] = 1.5
    -- Build queries and register systems here.
end

world:addPlugin(spinPlugin)
```

Callers own resource values and may replace them. Tecs owns resource-key
identity. Always name keys so hot reload, tooling, `findKey`, and `listKeys`
on `tecs.data` can find the same key. Snapshots omit `world.resources`; register a
[snapshot handler](/modules/ecs/save-games#snapshot-handlers) for durable resource
state.

## World subsystems

The world exposes the shared entry points for:

- [Components](/modules/ecs/components/) and [relationships](/modules/ecs/relationships/).
- [Bundles](/modules/ecs/components/bundles).
- [Queries](/modules/ecs/queries/) and hierarchy traversal.
- [Systems](/modules/ecs/systems), [phases](/modules/ecs/phases), and
  [plugins](/modules/ecs/plugins).
- [States](/modules/ecs/states).
- [Events](/modules/ecs/events).
- [Snapshots](/modules/ecs/save-games).

Those pages own their interaction rules; generated Teal reference owns
individual method signatures and records.
