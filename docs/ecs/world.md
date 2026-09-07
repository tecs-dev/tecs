---
description: "World entities, structural transactions, resources, phases, and stats"
outline: deep
---

# World

A world owns the complete ECS runtime: entities, archetypes, queries, systems,
resources, bundles, event observers, snapshot handlers, and state.

```nupp
local world = tecs.ecs.newWorld({
    timestep = 1 / 60,
})
```

The default world supports about one million concurrent entity slots. A
configuration may raise `maxEntities` to the packed-ID limit of `2^22 - 1`.
The maximum is 4,194,303 live entities; slot zero is reserved.

## Lifecycle

`Application` creates and drives its world. After the entry plugin finishes,
it calls `startup()` once, `update(dt)` every host iteration, and `shutdown()`
at teardown.

Tests, tools, and benchmarks may drive those calls directly:

```nupp
world:startup()
world:update(1 / 60)
world:shutdown()
```

Before phase dispatch, `update` publishes pending structural work. The pipeline
then publishes after each non-empty phase, and `update` clears component dirty
bits only after the pipeline returns. The host then extracts and encodes the
completed world into a render packet.

`getFixedTiming()` returns the timestep, residual accumulator, and clamped
interpolation alpha without allocating. `fixedStepCount()` returns the number
of fixed steps since world construction. The scheduler advances those values
even when callers disable fixed phases.

## Entity IDs

Entity IDs pack a slot and generation into an opaque number:

```nupp
local old = world:spawn()
-- `old` becomes live at the next pipeline barrier.
```

Slot reuse changes the generation, so stale handles fail lookups. Do not
inspect IDs with LuaJIT bit operations; packed values may exceed 32 bits.

Use `EntityKey` for the few authored entities that runtime code must
rediscover:

```nupp
world:spawn(
    tecs.ecs.EntityKey("player"),
    tecs.ecs.Name("Player ship")
)

world:commit()
local player = world:requireKey("player")
```

Callers choose keys. Tecs owns the unique index, releases entries on removal or
despawn, and rebuilds it after snapshot load.

## Spawning entities

`spawn` accepts initial components and returns an ID immediately:

```nupp
local player = world:spawn(
    tecs.ecs.Transform2D(100, 100),
    tecs.gfx.Tint(1, 1, 1, 1),
    tecs.gfx.Renderable2D,
    tecs.ecs.Name("Player")
)
```

The ID is reserved immediately, but the entity occupies no archetype until the
next pipeline barrier. Later `set`, `remove`, or `despawn` calls in the same
transaction may use that ID and edit its final staged result.

`spawnAt` places caller-chosen packed IDs. Snapshot loading
uses them to preserve relationship targets and generations. The caller must
ensure that each chosen slot has no live entity.

## Entity clearing and storage maintenance

`clearEntities()` removes entity data, pending transactions, keys, and
entity-address observers. It preserves registered systems, queries, global
observers, bundles, and component definitions.

Use a new world when systems and queries must also disappear.
`getStats()` returns entity, archetype, component, and system counts, together
with fixed-step overload statistics.

## Structural transactions {#structural-transactions}

Structural mutations always stage. The scheduler publishes at lifecycle and
phase boundaries, so systems in one phase normally share a transaction and see
the same committed archetype membership.

A system that needs an extra boundary declares it in its configuration:

```nupp
world:addSystem({
    name = "game.ResolveDamage",
    phase = tecs.ecs.phases.Update,
    commitBefore = true,
    run = resolveDamage,
})
```

`commitBefore` publishes work from earlier systems in the same phase before
this system runs. `commitAfter` publishes this system's work before the next
system. Prefer normal phase ordering when it expresses the dependency.

`world:commit()` publishes synchronously. Finish query traversal before calling
it, because publication can change archetype storage. In systems, prefer phase
boundaries or `commitBefore` / `commitAfter` to make dependencies explicit.

`world:set` stages replacements as well as additions. Writes through `getMut`
change the committed value immediately and mark its column dirty. Query
iteration owns no transaction scope, so an early `break` is safe. The
[queries guide](/ecs/queries/index.md) covers traversal.

## Plugins and resources

A plugin configures one world. Games, engine features, and reusable mechanics
use ordinary functions for composition:

```nupp
local RATE = nupp.data.newKey<number>("game.spinRate")

local function spinPlugin(exclusive world: tecs.ecs.World): nil
    world.resources[RATE] = 1.5
    -- Build queries and register systems here.
end

spinPlugin(world)
```

Callers own resource values and may replace them. Key identity and typed stores
come directly from `nupp.data`. Snapshots omit `world.resources`; register a
[snapshot handler](save-games.md#snapshot-handlers) for durable resource state.

## World subsystems

The world exposes the shared entry points for:

- [Components](/ecs/components/index.md) and [relationships](/ecs/relationships/index.md).
- [Bundles](/ecs/components/bundles.md).
- [Queries](/ecs/queries/index.md) and hierarchy traversal.
- [Systems and phases](/ecs/systems.md), and
  [plugins](/ecs/plugins.md).
- [States](/ecs/states.md).
- [Events](/ecs/events.md).
- [Snapshots](/ecs/save-games.md).

Those pages own their interaction rules; generated Nupp reference owns
individual method signatures and records.
