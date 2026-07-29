---
url: /ecs/queries.md
description: >-
  Creating and iterating queries with include, exclude, includeAny, temp,
  cursors, and deferred mutations
---

# Queries

Use queries to find entities with specific [components](/ecs/components/). Most game logic creates queries inside
[plugins](/ecs/plugins), then reuses them from [systems](/ecs/systems).

Queries are how the engine reaches the world too. `tecs.SyncRenderState` extracts a frame from
`{Transform, Tint, Renderable}` and `{Transform, PointLight}`; the physics, animation and text plugins each hold
their own. The examples below use those same engine components, from `tecs.ecs` and
[`tecs.gfx`](/modules/gfx/).

## World methods

These methods are available on every `World`.

| Method                                           | Description                                               |
| ------------------------------------------------ | --------------------------------------------------------- |
| [`world:query`](#world-query)                    | Create a persistent or temporary query from a descriptor. |
| [`world:findArchetypes`](#world-find-archetypes) | Iterate archetypes that contain one component.            |

### world:query {#world-query}

Creates a query to find entities with specific components.

```teal
function World:query(descriptor: QueryDescriptor): Query
```

**Parameters:**

* `descriptor`: Description of the components to query for.

**Returns:** a query object you can iterate to access matching entities.

## Creating queries

Create queries with `world:query()`, passing a `QueryDescriptor`.

The `include` property is a list of components an entity must have to match the query.

```teal{3}
-- Find all entities that have the `tecs.ecs.Name` component:
world:query({
    include = {tecs.ecs.Name}
})
```

The `exclude` property is a list of components an entity must not have to match the query.

```teal{5}
-- Find all entities that have the `tecs.ecs.Name` component and
-- don't have the `tecs.ecs.TTL` component.
world:query({
    include = {tecs.ecs.Name},
    exclude = {tecs.ecs.TTL}
})
```

The `includeAny` property is a list of components where an entity must have at least one to match the query. This
acts as an OR condition combined with the AND condition of `include`.

```teal{4}
-- Renderables that are textured or materialled: Transform AND Renderable,
-- plus at least one of Sprite or Material.
world:query({
    include = {tecs.Transform, tecs.gfx.Renderable},
    includeAny = {tecs.gfx.Sprite, tecs.gfx.Material}
})
```

You can give queries a name using the `name` property. The name is what `tostring(query)` prints, which makes
queries easier to identify in debug output.

```teal{2}
world:query({
    name = "NameQuery",
    include = {tecs.ecs.Name}
})
```

### Descriptor reference

The full set of fields accepted by `world:query()`:

| Field               | Type                           | Description                                                                                                                                                                                                                  |
| ------------------- | ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `include`           | `{Component}`                  | Archetype must contain **all** of these components.                                                                                                                                                                          |
| `exclude`           | `{Component}`                  | Archetype must contain **none** of these components.                                                                                                                                                                         |
| `includeAny`        | `{Component}`                  | Archetype must contain **at least one** of these components. Combined with `include` as AND (`include`) + OR (`includeAny`).                                                                                                 |
| `name`              | `string`                       | Human-readable name used when the query is stringified. Optional.                                                                                                                                                            |
| `type`              | `"logic" \| "render"`          | Declares whether the query drives simulation or presentation. `"logic"` excludes [`Paused`](#paused-entities) entities. Any other value raises an error. Optional.                                                           |
| `temp`              | `boolean`                      | If `true`, the query is a one-shot snapshot of the currently-matching archetypes. Skips observer registration. Cannot be combined with `onEntitiesAdded` / `onEntitiesRemoved`. See [Temporary queries](#temporary-queries). |
| `groupBy`           | `function(Archetype): integer` | Groups matching archetypes by an integer key for sorted iteration. See [Grouping](/ecs/queries/grouping).                                                                                                                    |
| `onEntitiesAdded`   | `function`                     | Fires once per contiguous range of entities when they first match the query. See [Callbacks](/ecs/queries/callbacks#onentitiesadded-callback).                                                                               |
| `onEntitiesRemoved` | `function`                     | Fires once per contiguous range of entities when they stop matching. See [Callbacks](/ecs/queries/callbacks#onentitiesremoved-callback).                                                                                     |

The descriptor is kept on the query as `query.descriptor` for inspection. Mutating it after construction does not
rebuild component masks, subscriptions, or grouping state.

## Iterating over queries

Iterate a query by calling `query:iter()` in a generic `for` loop. Each step returns
`(archetype, length, entities)` for the next non-empty archetype; empty archetypes are skipped entirely.
Inside the loop, bind component columns once per archetype and index them by row.

::: warning `iter()` runs to exhaustion; `cursor()` may stop early
`query:iter()` opens a deferred scope on its first step and closes it when the iterator is exhausted. An
archetype-level loop that may `break` or return early must use `query:cursor()` and call `cursor:close()` after
the loop, or immediately before returning from inside it. Leaving an `iter()` loop early leaves the world
deferred, and a deferred world silently queues every later spawn instead of applying it. See
[Breaking out early](#breaking-out-early).
:::

This is the query the renderer's extractor holds, verbatim:

```teal
local Transform <const> = tecs.Transform
local Tint <const> = tecs.gfx.Tint
local Renderable <const> = tecs.gfx.Renderable

local renderables = world:query({
    include = {Transform, Tint, Renderable}
})
```

Iterate it:

```teal:line-numbers
for archetype, len, entities in renderables:iter() do
    local transforms = archetype:get(Transform)
    local tints = archetype:get(Tint)
    for row = 1, len do
        local transform = transforms[row]
        local tint = tints[row]
        print(entities[row], transform.x, transform.y, tint.a)
    end
end
```

* Line `1`: gets each non-empty archetype, the number of entities in the archetype, and an array of entity IDs.
* Line `2` and `3`: bind component columns with `archetype:get(Component)`. Teal types `transforms` as `{Transform}`.
* Line `4`: iterates over the entities in the archetype. Each value is the entity's "row", which you use to
  index into component columns.
* Line `5` and `6`: grab components for an entity by indexing into the columns.

`Transform` and `Tint` are FFI components, so those columns are contiguous C memory and `transforms[row]` is a
cdata struct rather than a table. That is what lets extraction write rows straight into mapped GPU staging.

Entity IDs and component columns are both 1-based; `entities[1]` is the first entity in the archetype.

### Counting matches

`query:count()` returns the total number of entities the query currently matches. It walks the matching
archetypes, not the entities, so it does not scale with entity count.

```teal
function Query:count(): integer
```

### Nested iteration

Iteration is re-entrant: each `for … in query:iter()` loop derives its resume position from the archetype it was
handed, so the same query can be iterated from inside its own loop. This makes pairwise patterns direct:

```teal
for archA, lenA, entitiesA in colliders:iter() do
    for archB, lenB, entitiesB in colliders:iter() do
        -- compare every archetype pair, including archA against itself
    end
end
```

The same holds for `query:groups()` and `query:group(id)`. Deferred scopes nest with the loops; staged
mutations drain when the outermost loop finishes.

### Mutating component columns

Use `archetype:get(Component)` when you only read a column. Use `archetype:getMut(Component)` when you will mutate
values through the returned column. `getMut` returns the same row-indexed column and marks that component dirty on
the archetype, so dirty-tracked consumers such as rendering and snapshots can resync.

`tecs.SnapshotTransforms`, the engine system that records where an entity stood before the current fixed step, is
exactly this shape:

```teal
local interpolated = world:query({
    include = {Transform, PreviousTransform}
})

for archetype, len in interpolated:iter() do
    local transforms = archetype:get(Transform)          -- read-only
    local before = archetype:getMut(PreviousTransform)   -- written below

    for row = 1, len do
        local transform = transforms[row]
        local target = before[row]
        target.x = transform.x
        target.y = transform.y
        target.rotation = transform.rotation
    end
end
```

`getMut` is correct here because the loop writes every row it visits. A loop that only sometimes writes should
bind the column with `get` and call `archetype:markComponentDirty(Component)` at the write site instead.

`get` does not protect the column from writes; it simply does not mark the component dirty. Treat `getMut` as the
write-intent API for direct field changes, and do not call it in a loop that might not write, because that defeats
every dirty-gated consumer. Use `world:set` when you need to replace a component value or add a component to an
entity.

Iteration itself marks nothing dirty. Mutation intent lives at the access site.

### Mutations during iteration

Structural changes while iterating a query need special handling. `world:set`, `world:remove`, `world:spawn`,
`world:despawn`, and the `batch*` APIs can move entities between archetypes or resize columns, which would otherwise
invalidate the loop.

To make this safe, Tecs defers mutations issued inside a query loop. When `for … in query:iter()`
takes its first step, the world enters a **deferred scope**; `world:set`, `world:remove`, `world:spawn`,
`world:despawn`, and the `batch*` APIs all stage during iteration and apply in a drain phase when the loop exits.
You can therefore stage structural changes inside the loop body:

The builtin `ttl` system does exactly that: it counts `tecs.ecs.TTL` down on the fixed clock and despawns
from inside the loop.

```teal
local ttlQuery = world:query({include = {TTL}, type = "logic"})

for archetype, len, entities in ttlQuery:iter() do
    local ttls = archetype:getMut(TTL)
    for row = 1, len do
        local ttl = ttls[row]
        ttl.remaining = ttl.remaining - dt
        if ttl.remaining <= 0 then
            world:despawn(entities[row])  -- staged; applies after the loop
        end
    end
end
```

The same scope can be opened by hand with `world:defer()` and closed with `world:commit()`.

#### Breaking out early

The allocation-free iterators close their deferred scope only when exhausted. If an archetype-level loop may stop
early, create a cursor and close it after leaving the loop:

```teal
local cursor = query:cursor()
for archetype, len, entities in cursor:iter() do
    if shouldSelect(archetype) then
        selected = entities[1]  -- entities are 1-indexed
        break
    end
end
cursor:close()
```

`cursor:close()` is idempotent, so call it whether the loop breaks or runs to exhaustion; natural exhaustion closes
the cursor for you. It closes only that cursor's scope and drains staged mutations when no outer scope remains.
Call it immediately before returning from inside the loop.

Cursors also mirror grouped traversal through `cursor:groups()` and `cursor:group(id)`. A cursor owns exactly one
traversal: asking a cursor for a second one raises an error, as does iterating a closed cursor, so use separate
cursors for nested loops. Normal `query:iter()`, `query:groups()`, and `query:group(id)` remain the
allocation-free path for loops that always run to exhaustion.

Only the archetype-level query loop holds the deferred scope. Breaking out of an inner `for row = 1, len` row
loop has no effect on it.

If something throws part way through a frame and leaves a scope open, `world:unwind()` closes every open scope and
applies what they staged. `world:update` calls it at the top of each frame for exactly that reason, and at depth
zero it is the same drain `commit` already does.

See [Deferred scope](/ecs/queries/callbacks#deferred-scope) on the callbacks page for the full drain and
wave model that applies to any deferred region.

## Using queries with systems

Create queries outside of systems (usually in plugins), then use them within systems to process entities.

### Creating queries in plugins

Create the query once in a plugin and close over it from systems:

`Velocity` below is a component the game declares; `Transform` is the ECS builtin the whole engine already moves,
so writing into it is what makes physics interpolation, the hierarchy and extraction all see the result.

```teal
local Transform <const> = tecs.Transform

-- Create a movement plugin
local function movementPlugin(world: tecs.World)
    -- Create the query once in the plugin
    local movableQuery = world:query({
        name = "MovableEntities",
        include = {Transform, Velocity},
        type = "logic",
    })

    -- Add a system that uses the query
    world:addSystem({
        name = "game.Movement",
        phase = tecs.ecs.phases.FixedUpdate,
        run = function(dt: number)
            -- Use the query created in the plugin
            for arch, len in movableQuery:iter() do
                local transforms = arch:getMut(Transform)
                local velocities = arch:get(Velocity)
                for row = 1, len do
                    local transform = transforms[row]
                    local vel = velocities[row]
                    transform.x = transform.x + vel.vx * dt
                    transform.y = transform.y + vel.vy * dt
                end
            end
        end
    })
end

-- Add the plugin to the world
world:addPlugin(movementPlugin)
```

`type = "logic"` and `phase = tecs.ecs.phases.FixedUpdate` are a pair: the phase makes the system advance on the
simulation clock, and the query type makes it stop for paused entities.

### Temporary queries

By default, queries are persistent: they register as archetype observers and subscribe to new
archetypes. For one-shot iteration where you don't need live updates, use `temp = true` to skip
observer registration. Temp queries cannot use `onEntitiesAdded` or `onEntitiesRemoved` callbacks; combining them
raises an error at query construction.

```teal
for archetype, len in world:query({include = {tecs.gfx.PointLight}, temp = true}):iter() do
    -- iterate once and discard query
end
```

## Disabled entities

By default, all queries automatically exclude entities that have the `tecs.ecs.Disabled` component. This
behavior makes it easy to temporarily hide entities without despawning them.

```teal
-- This entity draws nothing: extraction's query excludes Disabled too.
world:spawn(Transform(100, 100), Tint(1, 1, 1, 1), Renderable(), tecs.ecs.Disabled)
```

To find disabled entities in your queries, explicitly include the `Disabled` component:

```teal
-- Every renderable, including the disabled ones
local everything = world:query({
    include = {Transform, Renderable, tecs.ecs.Disabled}
})
```

## Paused entities

`tecs.ecs.Paused` marks an entity whose simulation should stop while its rendering continues, so it is not
excluded from every query the way `Disabled` is. Declare which side of that line a query sits on with `type`:

```teal
-- Simulation: paused entities are skipped
local movement = world:query({
    include = {Transform, Velocity},
    type = "logic",
})

-- Presentation: paused entities keep drawing
local sprites = world:query({
    include = {Transform, tecs.gfx.Sprite, tecs.gfx.Renderable},
    type = "render",
})
```

The engine follows the same split. `tecs.AdvanceAnimation` holds a `type = "logic"` query over
`{Animation, Sprite}`, so a paused entity stops advancing its frames; extraction's renderable query is unfiltered,
so the entity keeps being drawn on whichever frame it stopped on.

`type = "logic"` is what makes a [state stack](/ecs/states) pause actually pause. A state declared with
`onBlur = "pause"` adds `Paused` to its entities, but a movement system only stops moving them if its query opts out.

Omitting `type` leaves the query unfiltered. Prefer setting it on every query: `"render"` is not merely the default
spelled out, it records that paused entities are meant to appear, which is the fact a later reader needs.

`exclude = {Paused}` does the same filtering as `type = "logic"`, and a query that includes `Paused` explicitly keeps
it regardless of `type`.

## Ad-hoc archetype lookup

Use `world:findArchetypes(component)` for simple one-component scans when you do not need a persistent query object.
It uses the world's component-to-archetype index and returns an iterator over matching archetypes.

Unlike a query, this iterator opens no deferred scope, so mutations issued inside the loop are not staged for you.

### world:findArchetypes {#world-find-archetypes}

Finds all archetypes that have a specific component.

```teal
function World:findArchetypes(component: Component): function(): (Archetype, integer, DoubleArray)
```

**Parameters:**

* `component`: Component to find.

**Returns:** an iterator over matching archetypes, yielding `(archetype, length, entities)`.

```teal
local PointLight <const> = tecs.gfx.PointLight

for archetype, len, entities in world:findArchetypes(PointLight) do
    local lights = archetype:get(PointLight)
    for row = 1, len do
        print(entities[row], lights[row].radius, lights[row].intensity)
    end
end
```
