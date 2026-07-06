---
outline: deep
---

# World

The `World` is the core of the Tecs entity component system. It manages entities, components, systems, and
the game loop, acting as the central hub for your Tecs application.

## Creating a World

Interact with `World` through the `tecs` module.

```teal
local tecs = require("tecs")
```

Create a World that by default updates at 60 FPS using default configuration:

```teal
local world = tecs.newWorld()
```

Create a World that updates at 30 FPS:

```teal
local world = tecs.newWorld({
    timestep = 1 / 30
})
```

**`newWorld` Fields:**

| Parameter           | Type                                                   | Required   | Default    | Description                                        |
| ------------------- | ------------------------------------------------------ | ---------- | ---------- | -------------------------------------------------- |
| `timestep`          | `number`                                               | No         | 1/60       | The fixed timestep of the game in seconds          |
| `pipelineFactory`   | `function(number, function): Pipeline`                 | No         | Built-in   | Custom factory for creating the system pipeline    |
| `maxEntities`       | `integer`                                              | No         | 2^20 (~1M) | Maximum allocated entity slots for the world. Must be positive and at most `2^22` (~4M). The allocator is preallocated, so raise it only when you need more concurrent entities. |

## World Lifecycle

::: tip
When using `tecs2d`, the game loop calls `update` and all world lifecycle methods for you automatically.
:::

### update

Runs all phases of the game loop. Call this each frame with the time elapsed since the last update.
Any pending changes are committed before the frame begins.

```teal
function World:update(dt: number)
```

**Parameters:**

- `dt`: Time since the last update in seconds.

**Example:**

```teal
-- In a custom game loop
while running do
    local dt = computeDeltaTime()
    world:update(dt)
end
```

### startup

Runs all systems in the Startup phase group. Call this once before the main game loop begins.

```teal
function World:startup()
```

### shutdown

Runs all systems in the Shutdown phase group. Call this when the game is exiting.

```teal
function World:shutdown()
```

## Entity Management

### Entity IDs

Entity IDs are numeric handles returned by `world:spawn` and accepted by entity APIs such as `world:get`,
`world:set`, `world:despawn`, and `world:observe`. Treat them as opaque values: store them, compare them, and pass
them back to the world, but don't derive gameplay meaning from the number itself.

Tecs encodes a slot and generation into each ID so it can detect stale handles after a despawned slot is reused:

```teal
local a: integer = world:spawn()
world:despawn(a)
local b: integer = world:spawn() -- may reuse storage, but gets a distinct ID

world:isAlive(a)        -- false
world:isAlive(b)        -- true
```

The packed layout reserves 22 bits for the slot and 31 bits for the generation. That means a world can be configured
for at most `2^22` allocated slots (~4M), and each slot has `2^31` generation values before wrapping. The default
`maxEntities` is lower (`2^20`, roughly one million slots) to keep the preallocated entity table smaller.

Don't inspect or unpack IDs with `bit.*`; packed IDs can exceed 32-bit range, and LuaJIT bit operations truncate to
32 bits. If tooling needs the slot or generation, use the arithmetic layout:

```teal
local slot = id % 2^22
local generation = math.floor(id / 2^22)
```

Configure [`maxEntities`](#creating-a-world) if you need a different entity ceiling. To react when an entity
disappears, listen for [`OnDespawn`](/tecs/builtins#ondespawn-event) rather than polling `isAlive`.

### Entity keys

Entity IDs are the real ECS identity and snapshots preserve them so relationships and component data can round-trip.
For important singleton or authored entities that runtime code needs to rediscover, add the builtin
[`Key`](/tecs/builtins#key-component):

```teal
world:spawn(
    tecs.builtins.Key("player"),
    tecs.builtins.Name("Player ship")
)

local player = world:requireKey("player")
```

Keys are unique among live entities. `world:byKey(key)` returns the entity or `nil`; `world:requireKey(key)` returns
the entity or errors. Despawning the entity removes the key from the index. `Name` remains a non-unique human/debug
label.

After `loadSnapshot` or hot reload, rebuild runtime-held entity IDs from `Key` or saved components. See
[Save games: runtime handles after load](/tecs/save-games#runtime-handles-after-load).

### spawn

Creates a new entity in the World.

```teal
function World:spawn(...: Component): integer
```

**Parameters:**

- `...`: Variable number of components to add to the entity.

**Returns:**

- The entity ID of the spawned entity

**Notes:**

- The returned ID is usable immediately regardless of whether the spawn applies instantly or stages; see
  [Deferred Operations](#deferred-operations) for when each happens.
- You can follow up with `world:set`, `world:remove`, or `world:despawn` on the returned ID. Inside a scope
  those calls stage in order and apply at scope close; a staged `despawn` cancels a staged spawn entirely.
- For spawn notifications, observe the `OnSpawn` event at address 0 (world-level). `OnSpawn` fires inline during the
  `world:spawn` call, while the entity is still staged; see the
  [Mutation model](/tecs/mutation-model#event-timing) for exact timing.

**Example:**

```teal
-- Spawn an entity with no components:
local id = world:spawn()

-- Spawn with multiple components:
local playerId = world:spawn(
    tecs.builtins.Transform(100, 100),
    tecs.builtins.Name("Player")
)

-- Get notified when any entity spawns (world-level observer).
world:observe(0, tecs.builtins.OnSpawn, function(event: tecs.builtins.OnSpawn)
    print("Entity created with ID: " .. event.entity)
end)
```

### batchSpawn

Bulk-creates `count` entities sharing the same component signature. Instead of calling the constructor for each
component per entity, `batchSpawn` resolves the target archetype once at call time and hands you a callback with
direct column access to fill in the data.

When possible, `batchSpawn` returns a contiguous packed-ID range as `(firstId, nil)`. If a contiguous range is
unavailable but recycled IDs can satisfy the request, it falls back and returns `(nil, ids)` where `ids` is the
explicit spawned packed-ID list.

```teal
function World:batchSpawn(
    count: integer,
    componentTypes: {Component},
    callback: function(Archetype, integer, integer, integer)
): integer | nil, {integer} | nil
```

**Parameters:**

- `count`: Number of entities to spawn.
- `componentTypes`: Array of component types defining the target archetype. All entities end up in the same archetype.
- `callback`: Called once with `(archetype, firstRow, lastRow, count)`. Write your per-entity data by indexing into
  the archetype's columns. Iterate with `for i = firstRow, lastRow do ... end`.

**Returns:**

- `firstId, nil` when IDs are contiguous: `firstId`, `firstId + 1`, ..., `firstId + count - 1`.
- `nil, ids` when fallback uses recycled, non-contiguous packed IDs. Iterate `ids` directly.

**Example:**

```teal
-- Reserve 1000 particles and fill their columns in one batch.
local cols = {Position, Velocity}
local firstId, ids = world:batchSpawn(1000, cols, function(arch, firstRow, lastRow)
    -- getMut marks the written columns dirty for downstream sync.
    local positions = arch:getMut(Position)
    local velocities = arch:getMut(Velocity)
    -- Iterate over the provided row range and mutate columns in place.
    for i = firstRow, lastRow do
        positions[i] = Position(math.random(0, 800), math.random(0, 600))
        velocities[i] = Velocity(math.random(-50, 50), math.random(-50, 50))
    end
end)

-- Outside an open deferred scope, all 1000 entities are placed and queryable.
if firstId then
    -- Contiguous path: IDs are firstId, firstId + 1, ...
    assert(world:isAlive(firstId))
    assert(world:isAlive(firstId + 999))
else
    -- Fallback path: IDs are returned explicitly.
    local list = ids as {integer}
    assert(world:isAlive(list[1]))
    assert(world:isAlive(list[1000]))
end
```

**Notes:**

- This is a [deferred operation](#deferred-operations).
- IDs are reserved immediately and can be passed to `world:set`, `world:remove`, or `world:despawn` before the
  operation drains.
- `batchSpawn` does not support `tecs.builtins.Key`; keys must be claimed per entity before the entity becomes
  visible. Spawn keyed entities individually or add `Key` with `world:set` per entity.
- `batchSpawn` does not emit `OnSpawn` per entity; write initial data in the `callback` or react with a
  query's [`onEntitiesAdded`](/tecs/queries/callbacks).

**Sparse relationships**

You can pass sparse relationship components in `componentTypes`. The archetype edge walk adds their wildcard container
so queries match. You can't write per-entity target values through the `callback` because sparse columns are
row-indexed read proxies. Attach targets with `world:set(spawnedId, SparseRel(target))`; inside a deferred scope, those
sets drain alongside the batch spawn placement.

```teal
local firstId, ids = world:batchSpawn(5, {Position, ChildOf},
    function(arch, firstRow, lastRow, _count)
        -- Sparse relationship targets are attached below with world:set.
        local positions = arch:getMut(Position)
        for row = firstRow, lastRow do
            local index = row - firstRow + 1
            positions[row] = Position(index * 16, 0)
        end
    end)

local function spawnedId(index: integer): integer
    if firstId then
        -- Contiguous path: reconstruct the ID arithmetically.
        return firstId + index - 1
    end
    -- Fallback path: use the explicit packed ID list.
    local list = ids as {integer}
    return list[index]
end

for i = 1, 5 do
    -- Attach relationship targets to the reserved IDs.
    world:set(spawnedId(i), ChildOf(parentId))
end
```

### batchSpawnAt

Like `batchSpawn`, but uses the supplied entity IDs instead of allocating a new
contiguous range. Intended for snapshot loads where each restored entity keeps
its original ID.

```teal
function World:batchSpawnAt(
    ids: {integer},
    componentTypes: {Component},
    callback: function(Archetype, integer, integer, integer)
)
```

The archetype resolution, capacity check, and notification fan-out happen once
per call regardless of how the ids are ordered.

**Notes:**

- This is a [deferred operation](#deferred-operations).
- `batchSpawnAt` does not support `tecs.builtins.Key`; keys must be claimed per entity before the entity becomes
  visible. Spawn keyed entities individually or add `Key` with `world:set` per entity.
- Like `batchSpawn`, `batchSpawnAt` does not emit `OnSpawn` per entity.

### spawnAt

Spawn an entity at a specific packed ID rather than auto-allocating one. This is mainly for snapshot loading, where
relationship targets need to resolve to the same restored entity IDs. The caller is responsible for ensuring the ID is
not already live.

```teal
function World:spawnAt(id: integer, ...: Component)
```

See [Save games](/tecs/save-games) for a complete walkthrough.

### forEachArchetype

Iterate every archetype in the world. Intended for debugging and save-game
tools; use `query` for gameplay-level iteration.

```teal
function World:forEachArchetype(callback: function(Archetype))
```

### despawn

Removes an entity from the World.

```teal
function World:despawn(entity: integer)
```

**Parameters:**

- `entity`: The entity ID to remove.

::: info Despawn lifecycle
When you call `world:despawn(entity)`, the following happens inline:

1. Cleans up relationships targeting this entity (cascade-delete, reverse-index unlink)
2. Emits an [`OnDespawn` event](/tecs/builtins#ondespawn-event) to the entity's and world's address
3. Clears all observers registered on the entity's address

The physical removal of the entity from its archetype (the swap-pop and column
writes) is a [deferred operation](#deferred-operations); query observers receive
`onEntitiesRemoved` when the row is removed. See the
[Mutation model](/tecs/mutation-model#event-timing).

To react to a component leaving an entity, attach
[`onEntitiesRemoved`](/tecs/queries/callbacks) to a query that includes that component.
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

Bulk-removes every entity matching a query. Much faster than looping
`world:despawn` when clearing out a whole archetype: when none of the matched
archetypes have dense relationships or entities that are targets of
reverse-indexed relationships, the entire archetype's entity data is wiped in
one pass instead of processing each entity individually.

```teal
function World:batchDespawn(query: Query)
```

**Parameters:**

- `query`: A `Query` object built via `world:query(...)`. Both persistent and
  `temp = true` queries are accepted. `batchDespawn` does not accept raw
  component arrays or descriptors; build the query once outside your hot
  loop and reuse it.

**Notes:**

- This is a [deferred operation](#deferred-operations).
- `OnDespawn` events fire for every despawned entity (global and per-entity
  observers).
- Per-entity observer subscriptions are cleared after the event fans out.
- Query observers receive a single `onEntitiesRemoved(archetype, 1, count,
  count)` for the whole range, followed by `onDeactivated` once the
  archetype empties.
- Archetypes with dense relationships or target-of-relationship entities
  fall back transparently to per-entity `despawn` so cascade-delete and
  reverse-index unlink still run correctly.

**Example:**

```teal
-- Build a persistent query once, reuse it for repeated bulk passes.
local dead = world:query({include = {Health, DeadTag}})
world:batchDespawn(dead)

-- Or use a temp query for a one-shot teardown.
local bullets = world:query({include = {Bullet}, temp = true})
world:batchDespawn(bullets)
```

### batchSet

Bulk-set a component on every entity matching a query. Two forms:

- **Constant form**: write a shared instance to every matched row:
  ```teal
  world:batchSet(query, Stunned)
  world:batchSet(query, Position(0, 0))
  ```
  If an archetype in the query lacks the component, entities are bulk-moved
  to the archetype reached by adding it, then the new column is filled.

- **Callback form**: ensure the component is present, then let the caller
  write the column directly:
  ```teal
  world:batchSet(query, Position, function(arch, firstRow, lastRow, count)
      local positions = arch:getMut(Position)
      for row = firstRow, lastRow do
          positions[row] = Position(math.random(), math.random())
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

### batchRemove

Bulk-remove a component from every entity matching `query` whose archetype
currently carries it. Archetypes in the query that lack the component are
skipped silently (no-op).

```teal
function World:batchRemove(query: Query, componentType: Component)
```

**Notes:**

- This is a [deferred operation](#deferred-operations).

### compact

Prune unreachable empty archetypes (those whose relationship targets have
been despawned) and shrink overallocated archetype storage. Must be called
on a quiet world (no pending mutations); call `world:commit()` first if
unsure.

```teal
function World:compact(): integer, integer
```

**Returns:**

- `archetypesPruned`: Number of dead archetypes removed.
- `archetypesCompacted`: Number of surviving archetypes whose column
  storage was shrunk.

Call `compact` on level transitions or other natural "quiet points"; it's
cheap to skip and expensive if called every frame while entities churn.

### clearEntities

Wipes all entity data from the world while preserving structural state:
the pipeline, registered systems, queries (and their observers), bundles,
and archetype column capacity all survive. Useful for per-test reuse,
benchmark setup, and save/load "clear before load" flows.

```teal
function World:clearEntities()
```

**Clears:**

- All entities (entity index + archetype rows).
- Pending transaction state (queued spawns, mutations, despawns, sparse
  relationship writes).
- Queued events and per-entity event observers, i.e. those registered on an
  entity's address via `world:observe(entityId, ...)`. Their entities are gone.

**Preserves:**

- Registered systems and the pipeline they run in.
- Queries, including the global subscription each one uses to track
  archetypes. A query keeps matching entities spawned after the clear, even
  into archetypes that did not exist before it, with no rebuild.
- Global (address `0`) event observers registered via `world:observe(0, ...)`.
- Archetype columns (chunks stay allocated, the next batch doesn't pay
  the re-grow-from-zero cost).
- Bundle registrations.
- Global component registrations.

**Example:**

```teal
-- In a test or bench, reset the state between iterations without
-- rebuilding the pipeline or re-registering queries.
local q = world:query({include = {Position}})
for _ = 1, iterations do
    world:clearEntities()
    world:spawn(Position(10, 10))
    world:commit()
    local n = 0
    for _arch, len in q:iter() do n = n + len end
    assert(n == 1)
end
```

::: tip When you want a fully-fresh world
If you need to drop systems and queries too (the "post-construction"
state), just call `tecs.newWorld()`; it's the same code path and makes
the intent obvious at the call site.
:::

### isAlive

Checks if an entity is alive.

```teal
function World:isAlive(entity: integer): boolean
```

**Parameters:**

- `entity`: The entity ID to check.

**Returns:**

- `true` if the entity exists

::: info Despawning entities
When an entity begins despawning, `isAlive` still returns `true` since the despawn is not yet committed.
:::

**Example:**

```teal
if world:isAlive(entity) then
    world:despawn(entity)
end
```

## Component Management

World component methods read, write, and remove components on individual entities. See [Components](/tecs/components/)
for component kinds and access patterns, and [Dirty tracking](/tecs/components/dirty-tracking) for `getMut` and
explicit dirty marking.

| Method | Description |
| ------ | ----------- |
| [`world:get`](/tecs/components/#world-get) | Return one component from an entity. |
| [`world:getMut`](/tecs/components/#world-get-mut) | Return a component for in-place mutation and mark its column dirty. |
| [`world:getFirstRelationship`](/tecs/components/#world-get-first-relationship) | Return the first relationship instance for a relationship container. |
| [`world:has`](/tecs/components/#world-has) | Check whether an entity has a component or relationship target. |
| [`world:set`](/tecs/components/#world-set) | Attach or replace a component on an entity. |
| [`world:remove`](/tecs/components/#world-remove) | Remove a component from an entity. |
| [`world:markComponentDirty`](/tecs/components/#world-mark-component-dirty) | Mark a component column dirty for one entity's archetype. |

## Bundles

Bundles are reusable templates for spawning entities with predefined components. See
[Component bundles](/tecs/components/bundles) for full documentation.

| Method | Description |
| ------ | ----------- |
| [`world:newBundle`](/tecs/components/bundles#world-new-bundle) | Create and register a bundle. |
| [`world:spawnBundle`](/tecs/components/bundles#world-spawn-bundle) | Spawn an entity from a registered bundle by name. |
| [`world:getBundle`](/tecs/components/bundles#world-get-bundle) | Return one registered bundle by name. |
| [`world:getBundles`](/tecs/components/bundles#world-get-bundles) | Return all registered bundles. |

## Queries

World query methods find matching archetypes and entities. See [Queries](/tecs/queries/) for descriptors, iteration,
grouping, callbacks, and mutation rules.

| Method | Description |
| ------ | ----------- |
| [`world:query`](/tecs/queries/#world-query) | Create a persistent or temporary query from a descriptor. |
| [`world:findArchetypes`](/tecs/queries/#world-find-archetypes) | Iterate archetypes that contain one component. |

## Hierarchy Traversal

Relationships with `reverseIndex = true` (such as the builtin `ChildOf`) maintain an inverse index for
efficient reverse lookups. Works for both sparse and dense relationships. See
[Relationships](/tecs/relationships/#sparse-relationships) for details.

For relationships with `reverseIndex = true` (e.g. the builtin `ChildOf`), the world exposes
three traversal methods. See
[Relationships → Hierarchy traversal](/tecs/relationships/#hierarchy-traversal)
for full signatures, semantics, and the context-passing performance pattern.

- **`world:targets(entity, relationship, callback, context?)`**: invokes `callback(sourceId, context)`
  for each direct source entity targeting the given entity. Use this to iterate a parent's
  direct children, an entity's followers, etc.
- **`world:traverse(root, relationship)`**: DFS iterator yielding `(depth, entityId)` for the
  full subtree under `root`.
- **`world:walkUp(entity, relationship, callback, context?, maxDepth?)`**: invokes
  `callback(ancestorId, depth, context)` for each ancestor up the parent chain. Return `false`
  from the callback to stop early. `maxDepth` defaults to 100 and errors if exceeded.

## Deferred Operations

Tecs uses a **scope depth** counter to decide whether mutations apply instantly or stage.

When the depth is zero and you call a mutating API, the change applies before the call returns:

- `set` / `remove` / `spawn` / `despawn` go through a fast instant path.
- `batchSpawn` / `batchSpawnAt` / `batchDespawn` / `batchSet` / `batchRemove`
  internally open a scope, stage their work, and drain before returning.

When the depth is greater than zero, every one of those calls stages into a pending transaction and applies
only after the scope closes. From the caller's perspective, the rule is: *outside a scope a mutation is
visible as soon as the call returns; inside a scope, structural changes (spawns, despawns, component adds and
removes) stay invisible until the scope closes*. Value updates to a component an entity already carries write
through immediately at any depth, unless the entity already has staged structural changes. The full contract,
including drain ordering and visibility guarantees, is specified in the
[Mutation model](/tecs/mutation-model).

Scopes are opened automatically by:

- Iterating a [query](/tecs/queries/) (the iterator pushes a scope on its first step and pops it on
  exhaustion or `break`).
- Query callbacks (`onEntitiesAdded` / `onEntitiesRemoved`) while the drain that triggered them is running.
- Each batch call, for the duration of the call (including `batchSpawn`'s user `callback`).

You can also open and close scopes explicitly with `world:defer()` and `world:commit()`.

::: info Systems do not auto-commit between each other
`world:update` calls `world:commit()` once at the start of the frame to flush anything still pending from the
previous tick, then dispatches the pipeline. Phases do **not** insert a commit between individual systems:
iterating a query inside a system opens and closes a scope inline, but two consecutive plain
`world:set(id, …)` statements in different systems each apply instantly on their own. If one system needs to
see changes another system staged earlier in the same phase, it has to call `world:commit()` itself.
:::

### defer

Opens a deferred scope. All subsequent mutations stage instead of applying instantly, until a matching
[`commit`](#commit) closes it. Calls nest: each `defer` increments a depth counter; mutations stage while the
counter is above zero.

```teal
function World:defer()
```

Use `defer` when you want a block of mutations to appear atomically; for example, if a helper wants to
avoid partial archetype transitions being visible to observers mid-block.

```teal
local function killEntity(world: tecs.World, entity: integer)
    world:defer()
    world:set(entity, HitPoints(0))
    world:set(entity, RagdollState())
    world:remove(entity, AIController)
    world:commit()  -- drain is issued here
end
```

### commit

Closes one deferred scope level. When the scope counter reaches zero and the world has pending staged
mutations, the transaction drains: staged despawns apply first, then spawns are placed, then component moves
execute, with query observers firing along the way; batch mutations and sparse relationship writes apply
after the structural passes. See the
[Mutation model](/tecs/mutation-model#the-commit-drain) for the full ordering contract.

```teal
function World:commit()
```

**Notes:**

- `commit` is the matching counterpart to `defer`; calls nest symmetrically.
- `world:update(dt)` calls `commit` once at the very start as a safety net for any mutations left pending
  by prior host-code paths. It does **not** call `commit` between individual systems in the pipeline.
- Outside any scope, `world:commit()` is harmless; the depth is already zero and there's nothing to drain.
- `commit` never discards staged work. If you open an explicit scope, closing it always applies the pending
  mutations once the outermost scope finishes.

**Example:**

```teal
-- Force pending changes to be applied.
local id: integer = world:spawn(Transform(10, 20))
world:commit()
```

## Systems Management

World system methods add and remove work from the pipeline. See [Systems](/tecs/systems) for system configuration,
ordering, conditional execution, and removal rules.

| Method | Description |
| ------ | ----------- |
| [`world:addSystem`](/tecs/systems#world-add-system) | Add a system to the world's pipeline. |
| [`world:removeSystem`](/tecs/systems#world-remove-system) | Remove a named system from the world's pipeline. |

## Plugins

Use plugins to add systems, components, states, and more to a `World`. Tecs builds everything around plugins.

### addPlugin

Adds a plugin to the world.

```teal
function World:addPlugin(plugin: function(world: World))
```

**Parameters:**

- `plugin`: Function that configures the world.

**Example:**

```teal
local PHYSICS: tecs.Key<PhysicsConfig> = tecs.newKey()

-- Define a plugin
local function physicsPlugin(world: tecs.World)
    -- Add physics systems
    world:addSystem({
        name = "PhysicsSystem",
        phase = tecs.phases.FixedUpdate,
        run = function(dt: number, world: tecs.World)
            -- Physics simulation logic
        end
    })

    -- Add physics resources
    world.resources[PHYSICS] = { gravity = 9.8 }
end

-- Add the plugin to the world
world:addPlugin(physicsPlugin)
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

-- Define key for the resource.
local GAME_SETTINGS: tecs.Key<GameSettings> = tecs.newKey()

-- Add a resource to the world
world.resources[GAME_SETTINGS] = gameSettings

-- Get a resource
local settings = world.resources[GAME_SETTINGS]
print("Difficulty:", settings.difficulty)
```

You can define resource keys for numbers, strings, and any other type too.

```teal
local GAME_UUID: tecs.Key<string> = tecs.newKey()
world.resources[GAME_UUID] = "abc"
```

## Phase Management

World phase methods control the pipeline's phase tree. See [Phases](/tecs/phases) for phase groups, fixed vs
variable timing, custom phases, and examples.

| Method | Description |
| ------ | ----------- |
| [`world:enablePhase`](/tecs/phases#world-enable-phase) | Enable a phase or phase group. |
| [`world:disablePhase`](/tecs/phases#world-disable-phase) | Disable a phase or phase group. |
| [`world:registerPhase`](/tecs/phases#world-register-phase) | Register a custom phase with the world's pipeline. |
| [`world:runPhase`](/tecs/phases#world-run-phase) | Run a phase or phase group explicitly. |

## State Management

The state stack manages game states with automatic entity lifecycle. See [States](/tecs/states) for full
documentation.

| Method | Description |
| ------ | ----------- |
| [`world:createState`](/tecs/states#world-create-state) | Create a named state and return its tag component. |
| [`world:pushState`](/tecs/states#world-push-state) | Push a state onto the stack. |
| [`world:popState`](/tecs/states#world-pop-state) | Pop the current state from the stack. |
| [`world:peekState`](/tecs/states#world-peek-state) | Return the current top state name. |

## Events

World event methods use the address-based event system. See [Events](/tecs/events) for event types, addresses,
constructor behavior, and MessageBus details.

| Method | Description |
| ------ | ----------- |
| [`world:observe`](/tecs/events#world-observe) | Subscribe to an event at a world or entity address. |
| [`world:emit`](/tecs/events#world-emit) | Emit an event instance or construct-and-emit an event type. |
| [`world:hasObservers`](/tecs/events#world-has-observers) | Check whether any observer exists for an address and event type. |
| [`world:stopObserving`](/tecs/events#world-stop-observing) | Remove a callback or named observer. |
| [`world:clearObservers`](/tecs/events#world-clear-observers) | Remove all observers at one address. |

## Stats

### getStats

Get statistics about the World.

```teal
function World:getStats(fill?: world.Stats): world.Stats
```

**Parameters:**

- `fill`: Optional stats table to fill instead of allocating a new one (for reducing garbage collection pressure)

**Returns:**

- Stats object with the following fields:

| Field          | Type        | Description                                    |
| -------------- | ----------- | ---------------------------------------------- |
| `entities`     | `integer`   | The number of active entities in the world     |
| `archetypes`   | `integer`   | The number of archetypes                       |
| `components`   | `integer`   | The number of unique component types in use    |
| `systems`      | `integer`   | The number of registered systems               |

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
