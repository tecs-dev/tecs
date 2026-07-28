---
description: "Core World API for entities, spawn and despawn, batch operations, deferred scopes, resources, plugins, phases, and stats"
outline: deep
---

# World

The `World` is the core of the Tecs entity component system. It owns entities, components, systems, plugins,
resources, queries and the state stack, and it is what a frame is run against.

## Requiring it

```teal
local tecs <const> = require("tecs")
```

The whole surface is `require("tecs")`, and `tecs` is also set as a global, so the require line is optional.
Engine modules on the surface resolve lazily on first field access, which keeps a world buildable with no
window and no device.

## Creating a world

Create a world that runs its fixed phases at 60 Hz using the default configuration:

```teal
local world = tecs.newWorld()
```

Create one that runs them at 30 Hz:

```teal
local world = tecs.newWorld({
    timestep = 1 / 30
})
```

**`newWorld` fields:**

| Field             | Type                         | Required | Default    | Description                                                                        |
| ----------------- | ---------------------------- | -------- | ---------- | ---------------------------------------------------------------------------------- |
| `timestep`        | `number`                     | No       | 1/60       | The fixed timestep in seconds                                                      |
| `pipelineFactory` | `function(number): Pipeline` | No       | Built-in   | Custom factory for creating the system pipeline                                    |
| `maxEntities`     | `integer`                    | No       | 2^20 (~1M) | Maximum concurrent entity slots. Must be a positive integer and at most `2^22 - 1` |

## World lifecycle

An [`Application`](/modules/Application) owns a world and drives it: it calls `world:startup` at the end of
initialisation, once the entry plugin has run, so everything the plugin spawned is resident before the first
frame; `world:update(dt)` once per host iteration; and `world:shutdown` before anything is destroyed. A game
does not call these itself. It reaches the world through the entry plugin `tecs.application` takes; see
[Getting started](/getting-started). Call them yourself only when you drive a world with no application, as
tests, tools and benchmarks do.

### update

Runs all phases of the game loop. Call this each frame with the time elapsed since the last update.

```teal
function World:update(dt: number)
```

**Parameters:**

- `dt`: Time since the last update in seconds.

Before dispatching the pipeline, `update` calls [`unwind`](#unwind), which closes every open scope and applies
what it staged. After the pipeline finishes, the component dirty bits set during the frame are cleared. Render
extraction is a system in the `RenderFirst` phase, so it reads those bits inside this call, before they clear.

**Example:**

```teal
-- Driving a world without an application: a test, a tool, a benchmark.
while running do
    local dt = computeDeltaTime()
    world:update(dt)
end
```

### getFixedTiming

Returns the fixed timestep, the residual time not consumed by fixed updates, and a clamped interpolation
fraction. The method returns three numbers directly and does not allocate.

```teal
function World:getFixedTiming(): number, number, number
```

```teal
local timestep, accumulator, alpha = world:getFixedTiming()
```

`alpha` is `accumulator / timestep` clamped to `[0, 1]`. The accessor returns the scheduler's stored
accumulator unchanged, so extrapolation consumers can use the residual directly; the scheduler caps that
residual during catch-up limiting. Disabling fixed phases does not pause the fixed-step clock, so the returned
values keep describing scheduler timing.

### fixedStepCount

Fixed steps run since the world was made.

```teal
function World:fixedStepCount(): integer
```

The clock for anything that advances on the simulation rather than on frame time. It counts steps rather than
summing seconds, so two runs fed the same steps read the same number however many frames either of them drew.
Steps are counted whether or not any system is registered in a fixed phase.

### startup

Runs all systems in the Startup phase group. Call this once before the main loop begins.

```teal
function World:startup()
```

### shutdown

Runs all systems in the Shutdown phase group. Call this when the game is exiting.

```teal
function World:shutdown()
```

## Entity management

### Entity ids

Entity ids are numeric handles returned by `world:spawn` and accepted by entity APIs such as `world:get`,
`world:set`, `world:despawn`, and `world:observe`. Treat them as opaque values: store them, compare them, and
pass them back to the world, but do not derive gameplay meaning from the number itself.

Tecs encodes a slot and a generation into each id so it can detect stale handles after a despawned slot is
reused:

```teal
local a: integer = world:spawn()
world:despawn(a)
local b: integer = world:spawn() -- may reuse storage, but gets a distinct id

world:isAlive(a)        -- false
world:isAlive(b)        -- true
```

The packed layout reserves 22 bits for the slot and 31 bits for the generation. Slot 0 is reserved, so a world
can be configured for at most `2^22 - 1` concurrent entities (~4M), and each slot has `2^31` generation values
before wrapping. The default `maxEntities` is lower (`2^20`, roughly one million slots) to keep the
preallocated slot arena smaller. Both limits are exported as `tecs.MAX_ENTITIES` and
`tecs.DEFAULT_MAX_ENTITIES`, so sizing code never hard-codes the numbers.

::: warning Treat entity ids as opaque
Do not inspect or unpack entity ids with `bit.*`. Packed ids can exceed 32 bits, so LuaJIT bit operations
truncate them.
:::

Configure [`maxEntities`](#creating-a-world) if you need a different ceiling. To react when an entity
disappears, observe [`OnDespawn`](/ecs/builtins) rather than polling `isAlive`.

### Entity keys

Entity ids are the real ECS identity and snapshots preserve them so relationships and component data can
round-trip. For singleton or authored entities that runtime code needs to rediscover, add the builtin `Key`:

```teal
world:spawn(
    tecs.builtins.Key("player"),
    tecs.builtins.Name("Player ship")
)

local player = world:requireKey("player")
```

Keys are unique among live entities: claiming a key already held by another live entity raises. `world:byKey(key)`
returns the entity or `nil`; `world:requireKey(key)` returns the entity or errors. Despawning the entity removes
the key from the index, and `loadSnapshot` rebuilds the index from the restored rows. `Name` remains a
non-unique human or debug label.

After `loadSnapshot` or a hot reload, rebuild runtime-held entity ids from `Key` or from saved components. See
[Save games](/ecs/save-games).

### spawn

Creates a new entity in the world.

```teal
function World:spawn(...: Component): integer
```

**Parameters:**

- `...`: Variable number of components to add to the entity.

**Returns:** the entity id of the spawned entity.

**Notes:**

- The returned id is usable immediately regardless of whether the spawn applies instantly or stages; see
  [Deferred operations](#deferred-operations) for when each happens.
- You can follow up with `world:set`, `world:remove`, or `world:despawn` on the returned id. Inside a scope
  those calls stage in order and apply at scope close; a staged `despawn` cancels a staged spawn entirely.
- For spawn notifications, observe the `OnSpawn` event at address 0 (world-level). `OnSpawn` fires inline
  during the `world:spawn` call, while the entity is still staged; see the
  [Mutation model](/ecs/mutation-model#event-timing) for exact timing.

**Example:**

```teal
local components <const> = tecs.components

-- Spawn an entity with no components:
local id = world:spawn()

-- A renderable entity: a transform, a colour, and the marker that says it
-- contributes geometry.
local playerId = world:spawn(
    components.Transform(100, 100),
    components.Tint(1, 1, 1, 1),
    components.Renderable,
    tecs.builtins.Name("Player")
)

-- A light is an entity too.
local lightId = world:spawn(
    components.Transform(640, 360),
    components.PointLight(120, 512, 1, 0.9, 0.8, 3)
)

-- Get notified when any entity spawns (world-level observer).
world:observe(0, tecs.builtins.OnSpawn, function(event: tecs.builtins.OnSpawn)
    print("Entity created with id: " .. event.entity)
end)
```

`components.Transform` is the ECS builtin re-exported by the engine's component module: the hierarchy, the
authoring systems and the renderer all move the same one.

### spawnAt

Spawn an entity at a specific packed id rather than auto-allocating one. This is mainly for snapshot loading,
where relationship targets need to resolve to the same restored entity ids. The caller is responsible for
ensuring the id's slot is not already live.

```teal
function World:spawnAt(id: integer, ...: Component)
```

See [Save games](/ecs/save-games) for a complete walkthrough.

### batchSpawn

Bulk-creates `count` entities sharing the same component signature. Instead of calling the constructor for each
component per entity, `batchSpawn` resolves the target archetype once at call time and hands you a callback
with direct column access to fill in the data.

When possible, `batchSpawn` returns a contiguous packed-id range as `(firstId, nil)`. If a contiguous range is
unavailable, it falls back and returns `(nil, ids)` where `ids` is the explicit spawned packed-id list.

```teal
function World:batchSpawn(
    count: integer,
    componentTypes: {Component},
    callback: function(Archetype, integer, integer, integer)
): integer | nil, {integer} | nil
```

**Parameters:**

- `count`: Number of entities to spawn.
- `componentTypes`: Array of component types defining the target archetype. All entities end up in the same
  archetype.
- `callback`: Called once with `(archetype, firstRow, lastRow, count)`. Write your per-entity data by indexing
  into the archetype's columns. Iterate with `for i = firstRow, lastRow do ... end`.

**Returns:**

- `firstId, nil` when ids are contiguous: `firstId`, `firstId + 1`, ..., `firstId + count - 1`.
- `nil, ids` when the fallback uses non-contiguous packed ids. Iterate `ids` directly.

**Example:**

```teal
local components <const> = tecs.components
local signature <const> = { components.Transform, components.Tint, components.Renderable }

-- Seed a field of renderable quads in one batch.
local firstId, ids = world:batchSpawn(1000, signature, function(arch, firstRow, lastRow)
    -- getMut marks the written columns dirty, which is what extraction reads.
    local transforms = arch:getMut(components.Transform)
    local tints = arch:getMut(components.Tint)
    -- No constructors run for these rows: write every field the frame reads.
    for row = firstRow, lastRow do
        local transform = transforms[row]
        transform.x = math.random(0, 1280)
        transform.y = math.random(0, 720)
        transform.z = 0
        transform.layer = 1
        transform.rotation = 0
        transform.scaleX = 8
        transform.scaleY = 8

        local tint = tints[row]
        tint.r, tint.g, tint.b, tint.a = math.random(), math.random(), math.random(), 1
    end
end)

-- Outside an open deferred scope, all 1000 entities are placed and queryable.
if firstId then
    -- Contiguous path: ids are firstId, firstId + 1, ...
    assert(world:isAlive(firstId))
    assert(world:isAlive(firstId + 999))
else
    -- Fallback path: ids are returned explicitly.
    local list = ids as {integer}
    assert(world:isAlive(list[1]))
    assert(world:isAlive(list[1000]))
end
```

**Notes:**

- This is a [deferred operation](#deferred-operations). The callback runs when the transaction drains: inside
  the call itself at scope depth 0, at scope close otherwise.
- Ids are reserved immediately and can be passed to `world:set`, `world:remove`, or `world:despawn` before the
  operation drains.
- Component constructors do not run for the placed rows. Only `requires`-supplied defaults are written before
  the callback, so set every field you depend on inside it.
- `batchSpawn` does not support `tecs.builtins.Key`; keys must be claimed per entity before the entity becomes
  visible. Spawn keyed entities individually or add `Key` with `world:set` per entity.
- `batchSpawn` does not emit `OnSpawn` per entity; write initial data in the `callback` or react with a query's
  [`onEntitiesAdded`](/ecs/queries/callbacks).

**Sparse relationships**

You can pass sparse relationship components in `componentTypes`. The archetype walk adds their wildcard
container so queries match. You cannot write per-entity target values through the `callback`, because sparse
columns are row-indexed read proxies that raise on write. Attach targets with
`world:set(spawnedId, SparseRel(target))`; inside a deferred scope, those sets drain alongside the batch spawn
placement.

```teal
local Transform <const> = tecs.components.Transform
local ChildOf <const> = tecs.builtins.ChildOf

local firstId, ids = world:batchSpawn(5, {Transform, ChildOf},
    function(arch, firstRow, lastRow, _count)
        -- Sparse relationship targets are attached below with world:set.
        local transforms = arch:getMut(Transform)
        for row = firstRow, lastRow do
            local index = row - firstRow + 1
            local transform = transforms[row]
            transform.x = index * 16
            transform.y = 0
            transform.z = 0
            transform.layer = 1
            transform.rotation = 0
            transform.scaleX = 1
            transform.scaleY = 1
        end
    end)

local function spawnedId(index: integer): integer
    if firstId then
        -- Contiguous path: reconstruct the id arithmetically.
        return firstId + index - 1
    end
    -- Fallback path: use the explicit packed id list.
    local list = ids as {integer}
    return list[index]
end

for i = 1, 5 do
    -- Attach relationship targets to the reserved ids.
    world:set(spawnedId(i), ChildOf(parentId))
end
```

### batchSpawnAt

Like `batchSpawn`, but uses the supplied entity ids instead of allocating a new contiguous range. Intended for
snapshot loads where each restored entity keeps its original id.

```teal
function World:batchSpawnAt(
    ids: {integer},
    componentTypes: {Component},
    callback: function(Archetype, integer, integer, integer)
)
```

The archetype resolution, capacity check, and required-component expansion happen once per call regardless of
how the ids are ordered.

**Notes:**

- This is a [deferred operation](#deferred-operations).
- `batchSpawnAt` does not support `tecs.builtins.Key`; keys must be claimed per entity before the entity
  becomes visible. Spawn keyed entities individually or add `Key` with `world:set` per entity.
- Like `batchSpawn`, `batchSpawnAt` does not emit `OnSpawn` per entity.

### despawn

Removes an entity from the world.

```teal
function World:despawn(entity: integer)
```

**Parameters:**

- `entity`: The entity id to remove.

::: info Despawn lifecycle
`world:despawn(entity)` runs, in order:

1. Per-component despawn cleanup, while the row is still readable.
2. Relationship cleanup for relationships targeting this entity: cascade delete, and reverse-index unlink.
3. An [`OnDespawn` event](/ecs/builtins) to the entity's address and then to the world address.
4. Clearing of every observer registered on the entity's address, so none survives into a recycled slot.

The physical removal (the swap-pop and column writes) happens inline when the despawn takes the instant path,
and in the drain when it stages; query observers receive `onEntitiesRemoved` when the row is removed. See the
[Mutation model](/ecs/mutation-model#event-timing).

To react to a component leaving an entity, attach [`onEntitiesRemoved`](/ecs/queries/callbacks) to a query that
includes that component.
:::

**Example:**

```teal
-- Listen for despawn events
world:observe(entity, tecs.builtins.OnDespawn, function(e: tecs.builtins.OnDespawn)
    print("Entity " .. e.entity .. " is being despawned")
end)

-- Remove an entity from the world
world:despawn(entity)
```

### batchDespawn

Bulk-removes every entity matching a query. Much faster than looping `world:despawn` when clearing out a whole
archetype: when a matched archetype needs no per-entity cleanup, its entire entity range is wiped in one pass
instead of processing each entity individually.

```teal
function World:batchDespawn(query: Query)
```

**Parameters:**

- `query`: A `Query` object built via `world:query(...)`. Both persistent and `temp = true` queries are
  accepted. `batchDespawn` does not accept raw component arrays or descriptors; build the query once outside
  your hot loop and reuse it.

**Notes:**

- This is a [deferred operation](#deferred-operations).
- `OnDespawn` events fire for every despawned entity (global and per-entity observers).
- Per-entity observer subscriptions are cleared after the event fans out.
- Query observers receive a single `onEntitiesRemoved` for the whole range, followed by `onDeactivated` once
  the archetype empties.
- Archetypes whose components carry despawn cleanup (dense relationships), and archetypes holding entities that
  other entities target through a reverse index, fall back transparently to per-entity `despawn` so cascade
  delete and reverse-index unlink still run correctly.

**Example:**

```teal
local components <const> = tecs.components

-- Build a persistent query once, reuse it for repeated bulk passes.
local lights = world:query({ include = { components.PointLight } })
world:batchDespawn(lights)

-- Or use a temp query for a one-shot teardown.
local drawn = world:query({ include = { components.Renderable }, temp = true })
world:batchDespawn(drawn)
```

### batchSet

Bulk-set a component on every entity matching a query. Two forms:

- **Constant form**: write a shared value to every matched row:

  ```teal
  world:batchSet(query, tecs.components.Renderable)
  world:batchSet(query, tecs.components.Tint(1, 0, 0, 1))
  ```

  If an archetype in the query lacks the component, entities are bulk-moved to the archetype reached by adding
  it, then the new column is filled.

- **Callback form**: ensure the component is present, then let the caller write the column directly:
  ```teal
  local Tint <const> = tecs.components.Tint

  world:batchSet(query, Tint, function(arch, firstRow, lastRow, count)
      local tints = arch:getMut(Tint)
      for row = firstRow, lastRow do
          local tint = tints[row]
          tint.r, tint.g, tint.b, tint.a = math.random(), math.random(), math.random(), 1
      end
  end)
  ```

```teal
function World:batchSet(
    query: Query,
    componentOrInstance: Component,
    callback?: function(Archetype, integer, integer, integer)
)
```

**Notes:**

- This is a [deferred operation](#deferred-operations).
- The callback form requires the component **type** (the container), not an instance, and the component must be
  bulk-safe. Relationship components must use the constant form; sparse relationships always route through the
  per-entity path because they live in per-world stores rather than archetype columns.

### batchRemove

Bulk-remove a component from every entity matching `query` whose archetype currently carries it. Archetypes in
the query that lack the component are skipped silently.

```teal
function World:batchRemove(query: Query, componentType: Component)
```

**Notes:**

- This is a [deferred operation](#deferred-operations).
- Relationship-bearing components fall back to per-entity `world:remove` so reverse-index unlink and cascade
  delete run correctly.

### isAlive

Checks whether an entity is committed and alive.

```teal
function World:isAlive(entity: integer): boolean
```

**Parameters:**

- `entity`: The entity id to check.

**Returns:** `true` if the entity is live and the handle is not stale.

::: info Despawning entities
An entity whose despawn has been staged but not yet drained is still `true`; an entity whose spawn has been
staged but not yet placed is still `false`. See
[Entity lifecycle states](/ecs/mutation-model#entity-lifecycle-states).
:::

**Example:**

```teal
if world:isAlive(entity) then
    world:despawn(entity)
end
```

### forEachArchetype

Iterate every archetype in the world. Intended for debugging and save-game tools; use `query` for
gameplay-level iteration.

```teal
function World:forEachArchetype(callback: function(Archetype))
```

### dirtyArchetypes

Iterate the archetypes whose rows changed since the last `world:update`. The set is cleared automatically at
the end of each `update`, after the pipeline finishes.

```teal
function World:dirtyArchetypes(): function(): Archetype
```

This is the archetype-level view, for a consumer that wants to sweep what moved. A consumer that cares which
component moved gates per column instead, with `archetype:isComponentDirty(Component)`, which is what render
extraction does.

Same iteration constraint as queries: do not mutate the world while iterating.

### compact

Prune unreachable empty archetypes (those whose relationship targets have been despawned) and shrink
overallocated archetype storage. Must be called on a quiet world: it asserts that no mutations are pending, so
call `world:commit()` first if unsure.

```teal
function World:compact(): integer, integer
```

**Returns:**

- `archetypesPruned`: Number of dead archetypes removed.
- `archetypesCompacted`: Number of surviving archetypes whose column storage was shrunk.

Call `compact` on level transitions or other natural quiet points; it is cheap to skip and expensive to call
every frame while entities churn.

### clearEntities

Wipes all entity data from the world while preserving structural state: the pipeline, registered systems,
queries (and their observers), bundles, and archetype column capacity all survive. Useful for per-test reuse,
benchmark setup, and save/load "clear before load" flows.

```teal
function World:clearEntities()
```

**Clears:**

- All entities (the slot arena and every archetype's rows).
- Pending transaction state (queued spawns, mutations, despawns, staged sparse relationship writes) and the
  scope depth.
- Sparse relationship stores and the key index.
- Queued events and per-entity event observers, i.e. those registered on an entity's address via
  `world:observe(entityId, ...)`. Their entities are gone.

**Preserves:**

- Registered systems and the pipeline they run in.
- Queries, including the global subscription each one uses to track archetypes. A query keeps matching entities
  spawned after the clear, even into archetypes that did not exist before it, with no rebuild.
- Global (address `0`) event observers registered via `world:observe(0, ...)`.
- Archetype column capacity, so the next batch does not pay the re-grow-from-zero cost.
- Bundle registrations.
- Global component registrations.

**Example:**

```teal
-- In a test or bench, reset the state between iterations without
-- rebuilding the pipeline or re-registering queries.
local Transform <const> = tecs.components.Transform
local q = world:query({ include = { Transform } })
for _ = 1, iterations do
    world:clearEntities()
    world:spawn(Transform(10, 10))
    world:commit()
    local n = 0
    for _arch, len in q:iter() do n = n + len end
    assert(n == 1)
end
```

::: tip When you want a fully fresh world
If you need to drop systems and queries too, call `tecs.newWorld()`; it is the same code path and makes the
intent obvious at the call site.
:::

## Component management

World component methods read, write, and remove components on individual entities. See
[Components](/ecs/components/) for component kinds and access patterns, and
[Dirty tracking](/ecs/components/dirty-tracking) for `getMut` and explicit dirty marking.

| Method                                             | Description                                                          |
| -------------------------------------------------- | -------------------------------------------------------------------- |
| `world:get(entity, Component)`                     | Return one component from an entity, or `nil`.                       |
| `world:getMut(entity, Component)`                  | Return a component for in-place mutation and mark its column dirty.  |
| `world:getFirstRelationship(entity, Relationship)` | Return the first relationship instance for a relationship container. |
| `world:has(entity, Component)`                     | Check whether an entity has a component or relationship target.      |
| `world:set(entity, component)`                     | Attach or replace a component on an entity.                          |
| `world:remove(entity, Component)`                  | Remove a component from an entity.                                   |
| `world:markComponentDirty(entity, Component)`      | Mark a component column dirty on the entity's archetype.             |

## Bundles

Bundles are reusable templates for spawning entities with predefined components. See
[Component bundles](/ecs/components/bundles) for full documentation.

| Method                         | Description                                       |
| ------------------------------ | ------------------------------------------------- |
| `world:newBundle(name, def?)`  | Create and register a bundle.                     |
| `world:spawnBundle(name, ...)` | Spawn an entity from a registered bundle by name. |
| `world:getBundle(name)`        | Return one registered bundle by name, or `nil`.   |
| `world:getBundles()`           | Return a fresh map of bundle name to bundle.      |

## Queries

World query methods find matching archetypes and entities. See [Queries](/ecs/queries/) for descriptors,
iteration, grouping, callbacks, and mutation rules.

| Method                            | Description                                               |
| --------------------------------- | --------------------------------------------------------- |
| `world:query(descriptor)`         | Create a persistent or temporary query from a descriptor. |
| `world:findArchetypes(Component)` | Iterate archetypes that contain one component.            |

Every query excludes entities carrying the builtin `Disabled` component unless the descriptor includes it
explicitly. A descriptor with `type = "logic"` additionally excludes `Paused` entities, so pausing a state
stops the systems that move, damage, or think; `type = "render"` records the opposite intent and keeps them
drawing.

## Hierarchy traversal

Relationships created with `reverseIndex = true` (such as the builtin `ChildOf`) maintain an inverse index for
efficient reverse lookups. This works for both sparse and dense relationships. See
[Relationships](/ecs/relationships/) for full signatures, semantics, and the context-passing performance
pattern.

- **`world:targets(entity, relationship, callback, context?)`**: invokes `callback(sourceId, context)` for each
  direct source entity targeting the given entity. Use this to iterate a parent's direct children, an entity's
  followers, and so on.
- **`world:traverse(root, relationship)`**: depth-first iterator yielding `(depth, entityId)` for the full
  subtree under `root`.
- **`world:walkUp(entity, relationship, callback, context?, maxDepth?)`**: invokes
  `callback(ancestorId, depth, context)` for each ancestor up the chain, following the first target per level.
  Depth starts at 1 for the direct parent. Return `false` from the callback to stop early. `maxDepth` defaults
  to 100 and errors if exceeded, so accidental cycles surface immediately.

## Deferred operations

Tecs uses a **scope depth** counter to decide whether mutations apply instantly or stage.

When the depth is zero and you call a mutating API, the change applies before the call returns:

- `set` / `remove` / `spawn` / `despawn` go through a fast instant path.
- `batchSpawn` / `batchSpawnAt` / `batchDespawn` / `batchSet` / `batchRemove` internally open a scope, stage
  their work, and drain before returning.

When the depth is greater than zero, structural changes from those calls stage into a pending transaction and
apply only after the scope closes. From the caller's perspective the rule is: outside a scope a mutation is
visible as soon as the call returns; inside a scope, structural changes (spawns, despawns, component adds and
removes) stay invisible until the scope closes. Value updates to a component an entity already carries write
through immediately at any depth, unless the entity already has staged structural changes. The full contract,
including drain ordering and visibility guarantees, is specified in the [Mutation model](/ecs/mutation-model).

Scopes are opened automatically by:

- Iterating a [query](/ecs/queries/): the iterator pushes a scope on its first step and pops it on exhaustion.
  A loop that may `break` or return early needs a [query cursor](/ecs/queries/) closed with `cursor:close()`,
  or the world is left deferred.
- Query callbacks (`onEntitiesAdded` / `onEntitiesRemoved`), for the duration of the drain that triggered them.
- Each batch call, for the duration of the call (including `batchSpawn`'s user `callback`).

You can also open and close scopes explicitly with `world:defer()` and `world:commit()`.

::: info Systems do not auto-commit between each other
`world:update` calls [`unwind`](#unwind) once at the start of the frame to flush anything still pending, then
dispatches the pipeline. Phases do **not** insert a commit between individual systems: iterating a query inside
a system opens and closes a scope inline, but two consecutive plain `world:set(id, …)` statements in different
systems each apply instantly on their own. If one system needs to see changes another system staged earlier in
the same phase, it has to call `world:commit()` itself.
:::

### defer

Opens a deferred scope. All subsequent mutations stage instead of applying instantly, until a matching
[`commit`](#commit) closes it. Calls nest: each `defer` increments a depth counter; mutations stage while the
counter is above zero.

```teal
function World:defer()
```

Use `defer` when you want a block of mutations to appear atomically; for example, when a helper wants to avoid
partial archetype transitions being visible to observers mid-block.

```teal
local components <const> = tecs.components

-- One archetype transition rather than three, and nothing observes the
-- intermediate shapes.
local function extinguish(world: tecs.World, entity: integer)
    world:defer()
    world:set(entity, components.Tint(0.2, 0.2, 0.2, 1))
    world:remove(entity, components.PointLight)
    world:remove(entity, components.Renderable)
    world:commit()  -- drain is issued here
end
```

### commit

Closes one deferred scope level. When the counter reaches zero and the world has pending staged mutations, the
transaction drains: staged despawns apply first, then spawns are placed, then component moves execute, with
query observers firing along the way; batch mutations and sparse relationship writes apply after the structural
passes. See the [Mutation model](/ecs/mutation-model#the-commit-drain) for the full ordering contract.

```teal
function World:commit()
```

**Notes:**

- `commit` is the matching counterpart to `defer`; calls nest symmetrically.
- Outside any scope, `world:commit()` is harmless; the depth is already zero and there is nothing to drain.
- `commit` never discards staged work. Closing the outermost scope always applies the pending mutations.

**Example:**

```teal
-- Force pending changes to be applied.
local id: integer = world:spawn(tecs.components.Transform(10, 20))
world:commit()
```

### unwind

Closes every open scope and applies what they staged.

```teal
function World:unwind()
```

This is the recovery path after something threw part way through a frame. A throw inside `query:iter()` skips
the pop that ends the loop's scope, and a world left deferred stages every later mutation rather than applying
it, silently. `unwind` puts it back, and it is safe on a healthy world: at depth zero it is the drain `commit`
already does. `world:update` calls it rather than committing one level, so a frame that failed cannot make the
frames after it lie.

## Systems management

World system methods add and remove work from the pipeline. See [Systems](/ecs/systems) for system
configuration, ordering, conditional execution, and removal rules.

| Method                     | Description                                      |
| -------------------------- | ------------------------------------------------ |
| `world:addSystem(config)`  | Add a system to the world's pipeline.            |
| `world:removeSystem(name)` | Remove a named system from the world's pipeline. |

## Plugins

Use plugins to add systems, components, states, and more to a `World`. Tecs builds everything around plugins:
a game itself is one, the `function(world, app)` an [`Application`](/modules/Application) is configured with,
and a game with several modules calls `world:addPlugin` from inside it rather than growing a second composition
mechanism. Engine features arrive the same way, for example `tecs.text.plugin({ renderer = app.renderer })`.

### addPlugin

Adds a plugin to the world.

```teal
function World:addPlugin(plugin: function(world: World))
```

**Parameters:**

- `plugin`: Function that configures the world.

**Example:**

```teal
local Transform <const> = tecs.components.Transform
local Renderable <const> = tecs.components.Renderable

local SPIN: tecs.Key<number> = tecs.newKey("game.spinRate")

local function spinPlugin(world: tecs.World)
    -- Build the query once, here, and never inside `run`.
    local spinning = world:query({ include = { Transform, Renderable } })

    world:addSystem({
        name = "game.Spin",
        phase = tecs.phases.Update,
        run = function(dt: number)
            local rate = world.resources[SPIN]
            for archetype, length in spinning:iter() do
                -- A write, so the column is taken with getMut.
                local transforms = archetype:getMut(Transform)
                for row = 1, length do
                    transforms[row].rotation = transforms[row].rotation + dt * rate
                end
            end
        end,
    })

    world.resources[SPIN] = 1.5
end

-- Add the plugin to the world
world:addPlugin(spinPlugin)
```

## Resources

Resources store globally shared data that systems and plugins can access.

```teal
-- Define a resource type
local record GameSettings
    difficulty: string
    volume: number
end

-- Define a resource
local gameSettings: GameSettings = {
    difficulty = "normal",
    volume = 0.8
}

-- Define a key for the resource.
local GAME_SETTINGS: tecs.Key<GameSettings> = tecs.newKey("game.settings")

-- Add a resource to the world
world.resources[GAME_SETTINGS] = gameSettings

-- Get a resource
local settings = world.resources[GAME_SETTINGS]
print("Difficulty:", settings.difficulty)
```

You can define resource keys for numbers, strings, and any other type too.

```teal
local GAME_UUID: tecs.Key<string> = tecs.newKey("game.uuid")
world.resources[GAME_UUID] = "abc"
```

Always name your keys. A named key is discoverable at runtime: `tecs.findKey(name)` returns it,
`tecs.listKeys()` enumerates every named key, and tooling such as the [debug server](/modules/mcp) reads
resources by name through them. A named key is also a stable identity: calling `newKey` again with the same
name returns the same key, so resources keyed by it survive a hot reload. Creating a key without a name logs a
warning and leaves the resource invisible to name-based tools.

## Phase management

World phase methods control the pipeline's phase tree. See [Phases](/ecs/phases) for phase groups, fixed versus
variable timing, custom phases, and examples.

| Method                       | Description                                                                                                        |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `world:enablePhase(phase)`   | Enable a phase or phase group.                                                                                     |
| `world:disablePhase(phase)`  | Disable a phase or phase group.                                                                                    |
| `world:registerPhase(phase)` | Register a custom phase with the world's pipeline.                                                                 |
| `world:runPhase(phase, dt?)` | Run one phase and its enabled descendants. Unlike `update` it does not unwind first and does not clear dirty bits. |

## State management

The state stack manages game states with automatic entity lifecycle. See [States](/ecs/states) for full
documentation.

| Method                             | Description                                        |
| ---------------------------------- | -------------------------------------------------- |
| `world:createState(name, policy?)` | Create a named state and return its tag component. |
| `world:pushState(name)`            | Push a state onto the stack.                       |
| `world:popState()`                 | Pop the current state from the stack.              |
| `world:peekState()`                | Return the current top state name, or `nil`.       |

## Events

World event methods use the address-based event system. See [Events](/ecs/events) for event types, addresses,
constructor behavior, and MessageBus details.

| Method                                              | Description                                                      |
| --------------------------------------------------- | ---------------------------------------------------------------- |
| `world:observe(address, Event, callback, id?)`      | Subscribe to an event at a world or entity address.              |
| `world:emit(address, eventOrType, ...)`             | Emit an event instance, or construct and emit an event type.     |
| `world:hasObservers(address, Event)`                | Check whether any observer exists for an address and event type. |
| `world:stopObserving(address, Event, observerOrId)` | Remove a callback or named observer.                             |
| `world:clearObservers(address)`                     | Remove all observers at one address.                             |

## Snapshots

Snapshots save and restore the entity data of a world. See [Save games](/ecs/save-games) for the full
walkthrough.

| Method                              | Description                                                                            |
| ----------------------------------- | -------------------------------------------------------------------------------------- |
| `world:saveSnapshot(opts?)`         | Save the world to binary (default) or to a plain snapshot table.                       |
| `world:loadSnapshot(source)`        | Restore from a string, a `string.buffer`, or a snapshot table, and return the prelude. |
| `world:addSnapshotHandler(handler)` | Register named save/load callbacks for custom non-component data.                      |

## Stats

### getStats

Get statistics about the world.

```teal
function World:getStats(fill?: World.Stats): World.Stats
```

**Parameters:**

- `fill`: Optional stats table to fill instead of allocating a new one, for reducing collector pressure.

**Returns:** a stats table with the following fields.

| Field        | Type      | Description                                               |
| ------------ | --------- | --------------------------------------------------------- |
| `entities`   | `integer` | The number of live entities in the world                  |
| `archetypes` | `integer` | The number of archetypes                                  |
| `components` | `integer` | The number of distinct component types held by archetypes |
| `systems`    | `integer` | The number of registered systems                          |

**Example:**

```teal
-- Create a new stats table
local stats = world:getStats()
print("Entities:", stats.entities)
print("Archetypes:", stats.archetypes)
print("Components:", stats.components)
print("Systems:", stats.systems)

-- Reuse an existing stats table (reduces allocations)
local myStats = {}
world:getStats(myStats)
print("Entities:", myStats.entities)
```

## Design record

- [One plugin, and what it is handed](https://github.com/tecs-dev/tecs/blob/main/README.md#one-plugin-and-what-it-is-handed)
- [A frame that throws puts back what it was holding](https://github.com/tecs-dev/tecs/blob/main/README.md#a-frame-that-throws-puts-back-what-it-was-holding)
