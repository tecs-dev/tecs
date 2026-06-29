---
outline: deep
---

# World

The `World` is the core of the Tecs entity component system. It manages entities, components, systems, and
the game loop, acting as the central hub for your Tecs application.

## Creating a World

Interact with `World` through the `tecs` module.

```lua
local tecs = require("tecs")
```

Create a World that by default updates at 60 FPS using default configuration:

```lua
local world = tecs.newWorld()
```

Create a World that updates at 30 FPS:

```lua
local world = tecs.newWorld({
    timestep = 1 / 30
})
```

**`newWorld` Fields:**

| Parameter           | Type                                                   | Required   | Default    | Description                                        |
| ------------------- | ------------------------------------------------------ | ---------- | ---------- | -------------------------------------------------- |
| `timestep`          | `number`                                               | No         | 1/60       | The fixed timestep of the game in seconds          |
| `pipelineFactory`   | `function(number, function): Pipeline`                 | No         | Built-in   | Custom factory for creating the system pipeline    |
| `maxEntities`       | `integer`                                              | No         | 2^20 (~1M) | Allocated arena slots per world. A positive integer, at most `2^22` (~4M, the packed-id format ceiling). Slot 0 is reserved, so the maximum live entity count is `maxEntities - 1`. The entity arena is preallocated to this size: ~16 bytes/slot (~16MB at default). Raise if your world exceeds ~1M concurrent entities; lower to shrink per-world memory. |

## World Lifecycle

::: tip
When using `tecs2d`, the game loop calls `update` and all world lifecycle methods for you automatically.
:::

### update

Runs all phases of the game loop. Call this each frame with the time elapsed since the last update.
Any pending changes are committed before the frame begins.

```lua
function World:update(dt: number)
```

**Parameters:**

- `dt`: Time since the last update in seconds.

**Example:**

```lua
-- In a custom game loop
while running do
    local dt = computeDeltaTime()
    world:update(dt)
end
```

### startup

Runs all systems in the Startup phase group. Call this once before the main game loop begins.

```lua
function World:startup()
```

### shutdown

Runs all systems in the Shutdown phase group. Call this when the game is exiting.

```lua
function World:shutdown()
```

## Entity Management

### Entity IDs

Entity IDs in Tecs are packed numeric handles that encode both a **slot** (22 bits) and a **generation**
counter (31 bits). The id fits in 53 bits total (the full integer precision of a double), so LuaJIT
stores and passes it as a normal Lua number without loss.

```
id = slot + generation * 2^22
       [0..2^22-1]      [0..2^31-1]
```

The slot indexes into a preallocated per-world allocator that stores each entity's current archetype and
row. The generation counter bumps every time a slot is despawned and recycled, so a stored id becomes
stale the moment its slot is reused.

```lua
local a: integer = world:spawn()
world:despawn(a)
local b: integer = world:spawn() -- reuses the slot, but with a new generation

world:isAlive(a)        -- false: generation mismatch
world:isAlive(b)        -- true
```

Treat the id as an opaque handle. Don't inspect or unpack its bits with `bit.*`; packed ids can exceed
int32 range, and `bit.band` would silently truncate. If you need to extract slot or generation for
tooling, use plain arithmetic (`id % 2^22` for slot, `math.floor(id / 2^22)` for generation).

**Capacity.** The allocator defaults to `2^20` slots (~1M), with slot `0` reserved as a null sentinel, so
the default world can hold up to `2^20 - 1` live entities at once. Raise or lower this via
[`WorldConfig.maxEntities`](#newworld); it must be a positive integer and at most `2^22`
(~4M, the packed-id format ceiling). The allocator is preallocated at world creation, so this sets both
the ceiling and the per-world memory footprint (~16 bytes per allocated slot).

**Generation limits.** The packed id has 31 generation bits (~2.1B values). The FFI slot struct also
stores 31 bits; the counter wraps at `2^31` on recycle, but at one despawn per nanosecond that's about 68
years before a single slot wraps, not a practical concern. To react to an entity disappearing, listen
for [`OnDespawn`](/tecs/builtins#ondespawn-event) rather than polling `isAlive`.

### spawn

Creates a new entity in the World.

```lua
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
  `world:spawn` call.

**Example:**

```lua
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

Bulk-creates `count` entities sharing the same component signature. Instead of
calling the constructor for each component per entity, `batchSpawn` resolves
the target archetype once at call time, allocates a contiguous ID range, and
hands you a callback with direct column access to fill in the data. The
callback itself (placement and observer notifications) are deferred until the
next commit.

```lua
function World:batchSpawn(
    count: integer,
    componentTypes: {Component},
    callback: function(Archetype, integer, integer, integer)
): integer
```

**Parameters:**

- `count`: Number of entities to spawn.
- `componentTypes`: Array of component types defining the target archetype. All entities end up in the same archetype.
- `callback`: Called once with `(archetype, firstRow, lastRow, count)`. Write your per-entity data by indexing into
  the archetype's columns. Iterate with `for i = firstRow, lastRow do ... end`.

**Returns:**

- The first entity ID. Entity IDs are contiguous: `firstId`, `firstId + 1`, ..., `firstId + count - 1`.

::: info Deferred placement
`batchSpawn` is deferred: the ID range is reserved synchronously so the returned `firstId` is usable right away,
but row placement, the user `callback`, and query-observer notifications all run at the next commit. You can
safely call `world:set`, `world:remove`, or `world:despawn` on any of the returned IDs between `batchSpawn`
and `commit`. Those mutations stage against the target archetype and commit in the right order.
:::

::: info Sparse relationships
You can pass sparse relationship components in `componentTypes`. The archetype edge walk adds their wildcard container
so queries match. You can't write per-entity target values through the `callback` (sparse columns are row-indexed
proxies that error on direct writes), so attach them instead via `world:set(firstId + i, SparseRel(target))`
either inside the callback or any time before commit. The staged sparse sets drain alongside the batchSpawn placement.
:::

**Notes:**

- The `callback` fires at commit time with `(archetype, firstRow, lastRow, count)`. You fill in per-entity data
  there by writing directly to the columns.
- Query observers are notified via `onActivated` (on the first entity in an empty archetype) and a single
  `onEntitiesAdded(archetype, firstRow, lastRow, count)` for the whole range. Spawn marks every component on
  the destination archetype dirty, so renderer shadow buffers and reactive systems see the new rows.

**Example:**

```lua
-- Reserve 1000 particles. The callback runs at commit.
local firstId = world:batchSpawn(1000, {Position, Velocity},
    function(arch, firstRow, lastRow, _count)
        local positions = arch:getMut(Position)
        local velocities = arch:getMut(Velocity)
        for i = firstRow, lastRow do
            positions[i] = Position(math.random(0, 800), math.random(0, 600))
            velocities[i] = Velocity(math.random(-50, 50), math.random(-50, 50))
        end
    end)

-- After commit, all 1000 entities are placed and queryable.
world:commit()
assert(world:isAlive(firstId))
assert(world:isAlive(firstId + 999))
```

### batchSpawnBestEffort

Lenient counterpart to `batchSpawn`. Allocates as many contiguous fresh slots
as possible, then tops up the remainder from the LIFO free stack. Errors only
when the allocator is fully exhausted. Returns the list of spawned ids in
allocation order (fresh first, then free); iterate it explicitly since
the contiguous-id guarantee no longer holds.

```lua
function World:batchSpawnBestEffort(
    count: integer,
    componentTypes: {Component},
    callback: function(Archetype, integer, integer, integer)
): {integer}
```

Use this when you want the bulk-placement speedup but can tolerate
non-contiguous ids (e.g. after heavy despawn churn has fragmented the
allocator).

### batchSpawnAt

Like `batchSpawn`, but uses the supplied entity IDs instead of allocating a new
contiguous range. Intended for snapshot loads where each restored entity keeps
its original ID.

```lua
function World:batchSpawnAt(
    ids: {integer},
    componentTypes: {Component},
    callback: function(Archetype, integer, integer, integer)
)
```

The archetype resolution, capacity check, and notification fan-out happen once
per call regardless of how the ids are ordered.

### spawnAt

Spawn an entity at a specific packed id rather than auto-allocating. The
id carries both the arena slot and the generation counter, so relationship
targets resolve to the same entity across a save/load cycle. The caller is
responsible for ensuring the id's slot is not already live.

```lua
function World:spawnAt(id: integer, ...: Component)
```

See [Save games](/tecs/save-games) for a complete walkthrough.

### forEachArchetype

Iterate every archetype in the world. Intended for debugging and save-game
tools; use `query` for gameplay-level iteration.

```lua
function World:forEachArchetype(callback: function(Archetype))
```

### despawn

Removes an entity from the World.

```lua
function World:despawn(entity: integer)
```

**Parameters:**

- `entity`: The entity ID to remove.

::: info Despawn lifecycle
When you call `world:despawn(entity)`, the following happens inline:

1. Cleans up relationships targeting this entity (cascade-delete, reverse-index unlink)
2. Emits an [`OnDespawn` event](/tecs/builtins#ondespawn-event) to the entity's and world's address
3. Clears all observers registered on the entity's address
4. Notifies query observers via `onEntitiesRemoved` on the entity's current archetype

The physical removal of the entity from its archetype (the swap-pop and column
writes) is deferred until the next commit.

To react to a component leaving an entity, attach
[`onEntitiesRemoved`](/tecs/queries/callbacks) to a query that includes that component.
:::

**Example:**

```lua
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

```lua
function World:batchDespawn(query: Query)
```

**Parameters:**

- `query`: A `Query` object built via `world:query(...)`. Both persistent and
  `temp = true` queries are accepted. `batchDespawn` does not accept raw
  component arrays or descriptors; build the query once outside your hot
  loop and reuse it.

::: info Deferred teardown
`batchDespawn` is deferred: the matched archetypes are enqueued at call
time and the actual removal, `OnDespawn` events, and observer callbacks
all run at the next commit. This matches `world:despawn` and makes
`batchDespawn` safe to call mid-iteration; no bulk clear happens until
the batch queues drain at commit time.
:::

**Notes:**

- `OnDespawn` events fire for every despawned entity (global and per-entity
  observers) at commit time.
- Per-entity observer subscriptions are cleared after the event fans out.
- Query observers receive a single `onEntitiesRemoved(archetype, 1, count,
  count)` for the whole range, followed by `onDeactivated` once the
  archetype empties.
- Archetypes with dense relationships or target-of-relationship entities
  fall back transparently to per-entity `despawn` so cascade-delete and
  reverse-index unlink still run correctly.

**Example:**

```lua
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
  ```lua
  world:batchSet(query, Stunned)
  world:batchSet(query, Position(0, 0))
  ```
  If an archetype in the query lacks the component, entities are bulk-moved
  to the archetype reached by adding it, then the new column is filled.

- **Callback form**: ensure the component is present, then let the caller
  write the column directly:
  ```lua
  world:batchSet(query, Position, function(arch, firstRow, lastRow, count)
      local positions = arch:getMut(Position)
      for row = firstRow, lastRow do
          positions[row] = Position(math.random(), math.random())
      end
  end)
  ```

```lua
function World:batchSet(
    query: Query,
    componentOrInstance: Component,
    callback?: function(Archetype, integer, integer, integer)
)
```

The fast path runs when the target component is "plain": no wildcard
container (not a dense-relationship instance) and not a sparse
relationship. Sparse relationships always route through the per-entity
path since they live in per-world stores rather than archetype columns.

### batchRemove

Bulk-remove a component from every entity matching `query` whose archetype
currently carries it. Archetypes in the query that lack the component are
skipped silently (no-op).

```lua
function World:batchRemove(query: Query, componentType: Component)
```

Fast path runs when the target component is plain (no wildcard container,
not sparse). Relationship-bearing components fall back to per-entity
`world:remove` so reverse-index unlink and cascade delete still fire
correctly. Other components in the source archetype don't affect path
selection.

### compact

Prune unreachable empty archetypes (those whose relationship targets have
been despawned) and shrink overallocated archetype storage. Must be called
on a quiet world (no pending mutations); call `world:commit()` first if
unsure.

```lua
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

```lua
function World:clearEntities()
```

**Clears:**

- All entities (entity index + archetype rows).
- Pending transaction state (queued spawns, mutations, despawns, sparse
  relationship writes).
- Queued messages.

**Preserves:**

- Registered systems and the pipeline they run in.
- Queries and their observer callbacks.
- Archetype columns (chunks stay allocated, the next batch doesn't pay
  the re-grow-from-zero cost).
- Bundle registrations.
- Global component registrations.

**Example:**

```lua
-- In a test or bench, reset the state between iterations without
-- rebuilding the pipeline or re-registering queries.
for _ = 1, iterations do
    world:clearEntities()
    world:spawn(Position(10, 10))
    world:commit()
    assert(world:query({include = {Position}}):count() == 1)
end
```

::: tip When you want a fully-fresh world
If you need to drop systems and queries too (the "post-construction"
state), just call `tecs.newWorld()`; it's the same code path and makes
the intent obvious at the call site.
:::

### isAlive

Checks if an entity is alive.

```lua
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

```lua
if world:isAlive(entity) then
    world:despawn(entity)
end
```

## Component Management

### get

Retrieves a component from an entity.

```lua
function World:get<T is Component>(entity: integer, component: T): T
```

**Parameters:**

- `entity`: Entity ID.
- `component`: The component type to retrieve.

**Returns:**

- The component instance, or `nil` if not found.

**Example:**

```lua
-- Get the Position component from an entity.
local position = world:get(entity, Position)

if position then
    print("Entity position:", position.x, position.y)
end
```

:::tip Get components from archetypes
Whenever possible, prefer getting entity components from [queries](/tecs/queries/) and
[archetypes](/tecs/archetype) rather than directly from the World.
:::

### getMut

Mutable counterpart to `get`. Returns the component **and** marks it
dirty on the entity's archetype so dirty-gated consumers (shadow pipeline,
change observers, snapshots) re-process the row after subsequent cdata
writes.

```lua
function World:getMut<T is Component>(entity: integer, component: T): T
```

**Parameters:**

- `entity`: Entity ID.
- `component`: The component type to get-and-mark-dirty.

**Returns:**

- The component instance, or `nil` if not found.

**When to use:**

Use `:getMut` whenever you intend to mutate the component through the
returned reference. `:get` followed by cdata writes silently bypasses
dirty tracking and leaves stale state downstream. The two have the same
return value; pay the small cost of marking dirty at write call sites,
not at read call sites.

**Example:**

```lua
-- Move an entity in-place: getMut so the renderer flushes Transform.
local t = world:getMut(entity, tecs.builtins.Transform)
if t then
    t.x = t.x + dx
    t.y = t.y + dy
end
```

### has

Checks whether an entity currently has a component.

```lua
function World:has(entity: integer, component: Component): boolean
```

For sparse relationships, passing the relationship container checks whether
the entity has **any** target for that relationship; passing a relationship
instance checks for that specific target.

```lua
world:has(entity, Health)                -- any component
world:has(entity, ChildOf)               -- any parent (sparse relationship)
world:has(entity, ChildOf(specificParent))  -- that specific parent
```

### set

Attaches a component to an entity.

```lua
function World:set(entity: integer, component: Component)
```

**Parameters:**

- `entity`: Entity ID.
- `component`: The component **instance** to attach.

**Notes:**

- Outside any deferred scope, `set` applies immediately. If the entity already has this component type,
  the value is replaced in place; otherwise the entity moves to the archetype with the component added.
  `world:get` sees the new value right away.
- Inside a deferred scope the call stages; the archetype transition and value write happen at the next
  scope close. See [Deferred Operations](#deferred-operations).

**Example:**

```lua
-- Add a transform component to an entity
world:set(entity, tecs.builtins.Transform(100, 200))
```

### remove

Removes a component from an entity.

```lua
function World:remove(entity: integer, component: Component)
```

**Parameters:**

- `entity`: Entity ID.
- `component`: The component **type** to remove.

**Example:**
```lua
-- Remove the Velocity component from an entity
world:remove(entity, Velocity)
```

### markComponentDirty

Marks a component dirty on the entity's archetype so that incremental
sync systems (renderer shadow buffers, snapshots) re-upload it next frame. In
most cases prefer `world:getMut(entity, component)`, which combines the
read and the dirty mark. Reach for `markComponentDirty` only when you
already have a column reference from another path (e.g. iterated via a
query) and need to flag the row dirty without re-fetching.

```lua
function World:markComponentDirty(entity: integer, component: Component)
```

**Parameters:**

- `entity`: Entity ID.
- `component`: The component type whose column was mutated.

> See [Dirty tracking](/tecs/components/dirty-tracking) and the
> [Components](/tecs/components/) reference for more information.

## Bundles

Bundles are reusable templates for spawning entities with predefined components. See
[Component bundles](/tecs/components/bundles) for full documentation.

### newBundle

Creates and registers a bundle for spawning entities with a predefined set of components.

```lua
function World:newBundle(name: string, def?: BundleDef): Bundle
```

**Parameters:**

- `name`: Unique name for the bundle.
- `def`: Optional bundle definition with `required` and `with` fields.

**Returns:**

- The registered bundle.

**Example:**

```lua
local playerBundle = world:newBundle("Player", {
    required = { Transform, Health },
    with = {
        [Velocity] = function() return Velocity(0, 0) end,
        [PlayerTag] = true,
    },
})
```

### spawnBundle

Spawns an entity from a registered bundle by name. Required components
are passed positionally in the order they were declared via `:require`.
Optional components always use their registered factory; they can't be
overridden at spawn time.

```lua
function World:spawnBundle(name: string, ...: Component): integer
```

**Parameters:**

- `name`: The bundle name.
- `...`: Required components, in declaration order.

**Returns:**

- The entity ID.

**Example:**

```lua
local entityId = world:spawnBundle("Player",
    Transform(100, 200),
    Health(100)
)
```

### getBundle

Returns a registered bundle by name.

```lua
function World:getBundle(name: string): Bundle
```

**Parameters:**

- `name`: The bundle name.

**Returns:**

- The bundle, or `nil` if not found.

**Example:**

```lua
local playerBundle = world:getBundle("Player")

-- Spawn 1000 entities from the bundle.
for i = 1, 1000 do
    playerBundle:spawn(Transform(i * 10, 0), Health(100))
end
```

### getBundles

Returns all registered bundles as a map.

```lua
function World:getBundles(): {string: Bundle}
```

**Returns:**

- Map of bundle name to bundle.

**Example:**

```lua
local bundles = world:getBundles()
for name, bundle in pairs(bundles) do
    print(name, bundle.required, bundle.defaulted)
end
```

## Queries

### query

Creates a query to find entities with specific components.

```lua
function World:query(descriptor: queries.QueryDescriptor): Query
```

**Parameters:**

- `descriptor`: Description of the components to query for

**Returns:**

- A query object you can iterate to access matching entities

**Example:**

```lua
-- Query for entities with both Transform and Name components
local query = world:query({
    include = {
        tecs.builtins.Transform,
        tecs.builtins.Name
    }
})

-- Iterate over the matching archetypes.
for archetype, len, entities in query:iter() do
    -- Grab component columns.
    local names = archetype:get(tecs.builtins.Name)
    local transforms = archetype:get(tecs.builtins.Transform)
    -- Iterate over the entities in the archetype.
    for row = 1, len do
        local xf = transforms[row]
        local name = names[row]
        love.graphics.print(name.value, xf.x, xf.y)
    end
end
```

> See the [Queries](/tecs/queries/) reference for more information.

### findArchetypes

Finds all archetypes that have a specific component, returning an iterator over the matching archetypes.
This O(1), garbage-free operation works well for ad-hoc queries targeting a single component.

```lua
function World:findArchetypes(component: Component): function(): (Archetype, integer, {integer})
```

**Parameters:**

- `component`: The component to find.

**Returns:**

- An iterator over the archetypes that have the component

**Example:**

```lua
-- Iterate over all archetypes containing the Name component
for archetype, len, entities in world:findArchetypes(tecs.builtins.Name) do
    -- Grab component columns.
    local names = archetype:get(tecs.builtins.Name)
    -- Iterate over the entities in the archetype.
    for i = 1, len do
        print(entities[i] .. " has name " .. names[i].value)
    end
end
```

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
- `batchSpawn` / `batchSpawnBestEffort` / `batchSpawnAt` / `batchDespawn` / `batchSet` / `batchRemove`
  internally open a scope, stage their work, and drain before returning.

When the depth is greater than zero, every one of those calls stages into a pending transaction and applies
only after the scope closes. From the caller's perspective, the rule is simply: *outside a scope a mutation
is visible as soon as the call returns; inside a scope it isn't*.

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

```lua
function World:defer()
```

Use `defer` when you want a block of mutations to appear atomically; for example, if a helper wants to
avoid partial archetype transitions being visible to observers mid-block.

```lua
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
mutations, the transaction drains: spawns are placed, component moves execute, query observers fire, and
sparse relationship writes apply.

```lua
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

```lua
-- Force pending changes to be applied.
local id: integer = world:spawn(Transform(10, 20))
world:commit()
```

## Systems Management

### addSystem

Adds a system to the World.

```lua
function World:addSystem(config: SystemConfig)
```

**Parameters:**

- `config`: Configuration for the system.

**SystemConfig Fields:**

| Field            | Required   | Type                                   | Description                                                     |
| ---------------- | ---------- | -------------------------------------- | --------------------------------------------------------------- |
| `phase`          | **Yes**    | `Phase`                                | The [phase](/tecs/phases) when the system should run       |
| `run`            | **Yes**    | `function(dt, world)`                  | The system function to call on each update                      |
| `name`           | No         | `string`                               | Name of the system (useful for debugging and ordering)          |
| `runIf`          | No         | `function(dt, world, name): boolean`   | Optional function that determines if the system should run      |
| `before`         | No         | `{string}`                             | Optional list of system names this should run before            |
| `after`          | No         | `{string}`                             | Optional list of system names this should run after             |

**Example:**

Add a system that processes a query to move entities.

```lua
local movableQuery = world:query({
    include = {
        tecs.builtins.Transform,
        Velocity
    }
})

-- Add a simple movement system
world:addSystem({
    name = "MovementSystem",
    phase = tecs.phases.FixedUpdate,
    run = function(dt: number, w: tecs.World)
        for archetype, len in movableQuery:iter() do
            local transforms = archetype:getMut(tecs.builtins.Transform)
            local velocities = archetype:get(Velocity)
            for row = 1, len do
                local xf = transforms[row]
                local vel = velocities[row]
                xf.x = xf.x + (vel.x * dt)
                xf.y = xf.y + (vel.y * dt)
            end
        end
    end
})
```

Add a system with conditional execution.

```lua
world:addSystem({
    name = "AmbientSoundSystem",
    phase = tecs.phases.FixedUpdate,
    runIf = function(dt: number, world: tecs.World, systemName: string): boolean
        -- Only run this system occasionally
        return math.random() < 0.01
    end,
    run = function(dt: number, world: tecs.World)
        playAmbientSound()
    end
})
```

Add a system with ordering constraints.

```lua
world:addSystem({
    name = "CollisionSystem",
    phase = tecs.phases.FixedUpdate,
    after = { "MovementSystem" }, -- Run after movement
    before = { "EnemyAI" }, -- Run before enemy AI
    run = function(dt: number, world: tecs.World)
        -- Check for collisions
    end
})
```

> See the [Systems](/tecs/systems) reference for more information.

### removeSystem

Removes a system from the world by name.

```lua
function World:removeSystem(systemName: string)
```

**Parameters:**

- `systemName`: The name of the system to remove.

**Example:**

```lua
world:removeSystem("StartupSystem")
```

::: warning
Systems need a name to be removable. You cannot remove unnamed systems after adding them.
:::

> See the [Systems](/tecs/systems) reference for more information.

## Plugins

Use plugins to add systems, components, states, and more to a `World`. Tecs builds everything around plugins.

### addPlugin

Adds a plugin to the world.

```lua
function World:addPlugin(plugin: function(world: World))
```

**Parameters:**

- `plugin`: Function that configures the world.

**Example:**

```lua
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

```lua
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

```lua
local GAME_UUID: tecs.Key<string> = tecs.newKey()
world.resources[GAME_UUID] = "abc"
```

## Phase Management

### enablePhase / disablePhase

Enable or disable specific phases of the game loop.

```lua
function World:enablePhase(phase: Phase)
function World:disablePhase(phase: Phase)
```

**Parameters:**

- `phase`: The phase to enable or disable.

**Example:**

```lua
-- Disable all rendering.
world:disablePhase(tecs.phases.RenderGroup)

-- Enable rendering.
world:enablePhase(tecs.phases.RenderGroup)
```

### registerPhase

Registers a custom phase with the world's pipeline. This allows external modules to define their own phases.

```lua
function World:registerPhase(phase: Phase)
```

**Parameters:**

- `phase`: The phase to register.

> See the [Phases](/tecs/phases) reference for more information.

## State Management

The state stack manages game states with automatic entity lifecycle. See [States](/tecs/states) for full
documentation.

### createState

Creates a named state with an optional lifecycle policy. Returns a tag component
that is auto-added to entities spawned while this state is on top of the stack.

```lua
function World:createState(name: string, policy?: StatePolicy): Component
```

**Parameters:**

- `name`: The name of the state.
- `policy`: Optional lifecycle policy for state transitions.

**Returns:**

- The tag component for this state.

**Example:**

```lua
local GameState = world:createState("game", {
    onBlur = "pause",
    onFocus = "resume",
})
```

### pushState

Pushes a state onto the state stack. Fires the previous top state's `onBlur`
policy and the new state's `onEnter` policy. Entities spawned after this call
automatically receive the state's tag component.

```lua
function World:pushState(name: string)
```

**Parameters:**

- `name`: The state name (must have been created with `createState`).

### popState

Pops the current state from the state stack. Fires the current state's `onExit`
policy and the new top state's `onFocus` policy.

```lua
function World:popState()
```

### peekState

Returns the name of the current top state, or `nil` if the stack is empty.

```lua
function World:peekState(): string
```

**Example:**

```lua
local current = world:peekState()
if current == "game" then
    -- in game state
end
```

## Events

The World provides a centralized event system with address-based routing. Events can be sent to:
- **World-level** (address `0`): Global events for cross-system communication
- **Entity-level** (entity ID): Events specific to a single entity

### observe

Registers an observer for an event at a specific address.

```lua
function World:observe<E is Event>(
    address: integer,
    eventType: E,
    observer: function(E),
    id?: string
)
```

**Parameters:**

- `address`: The address to observe (`0` for world-level, entity ID for entity events)
- `eventType`: The event type to observe
- `observer`: Callback function called when the event is emitted
- `id`: Optional string ID for later removal

**Example:**

```lua
-- World-level event
world:observe(0, MyCustomEvent, function(e: MyCustomEvent)
    print("Got MyCustomEvent")
end)

-- Entity-level event
world:observe(entityId, tecs.builtins.OnDespawn, function(e: tecs.builtins.OnDespawn)
    print("Entity despawned: " .. e.entity)
end)
```

### emit

Emits an event to all observers at a specific address.

```lua
function World:emit(address: integer, eventOrType: Event, ...: any)
```

**Parameters:**

- `address`: The address to emit to (`0` for world-level, entity ID for entity events)
- `eventOrType`: An event instance to emit, or an event type followed by constructor args
- `...`: Constructor args, when `eventOrType` is an event type

**Example:**

```lua
-- World-level event (no payload)
world:emit(0, MyCustomEvent)

-- Entity-level event, passing the type plus constructor args: the world
-- checks for observers before constructing, so this allocates nothing
-- when no one is listening.
world:emit(entityId, DamageReceived, 15)
```

### hasObservers

Checks if any observers exist for an event at an address. This is still useful when upstream work is expensive, but you
usually do not need it just to avoid event construction if you use `world:emit(address, EventType, ...)`.

```lua
function World:hasObservers<E is Event>(address: integer, eventType: E): boolean
```

**Example:**

```lua
if world:hasObservers(entityId, DamageReceived) then
    -- Only useful if computing the payload itself is expensive.
    world:emit(entityId, DamageReceived, 15)
end
```

### stopObserving

Stops observing an event at an address.

```lua
function World:stopObserving<E is Event>(
    address: integer,
    eventType: E,
    observer: function(E) | string
)
```

**Parameters:**

- `address`: The address to stop observing
- `eventType`: The event type
- `observer`: The callback function or the string ID provided when observing

**Example:**

```lua
-- By callback reference
world:stopObserving(0, MyEvent, myCallback)

-- By ID
world:stopObserving(entityId, OnDespawn, "cleanup-handler")
```

### clearObservers

Clears all observers for an address. This is called automatically when an entity is despawned.

```lua
function World:clearObservers(address: integer)
```

> See the [Events](/tecs/events) reference for more information.

## Stats

### getStats

Get statistics about the World.

```lua
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

```lua
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
