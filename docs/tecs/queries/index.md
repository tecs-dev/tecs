---
description: "Creating and iterating queries with include, exclude, includeAny, temp, cursors, and deferred mutations"
outline: deep
---

# Queries

Use queries to find entities with specific [components](/tecs/components/). Most game logic creates queries inside
[plugins](/tecs/plugins), then reuses them from [systems](/tecs/systems).

## World methods

These methods are available on every `World`.

| Method | Description |
| ------ | ----------- |
| [`world:query`](#world-query) | Create a persistent or temporary query from a descriptor. |
| [`world:findArchetypes`](#world-find-archetypes) | Iterate archetypes that contain one component. |

### world:query {#world-query}

Creates a query to find entities with specific components.

```teal
function World:query(descriptor: QueryDescriptor): Query
```

**Parameters:**

- `descriptor`: Description of the components to query for.

**Returns:**

- A query object you can iterate to access matching entities.

## Creating queries

Create queries with `world:query()`, passing a `QueryDescriptor`.

The `include` property is a list of components an entity must have to match the query.

```teal{3}
-- Find all entities that have the `tecs.builtins.Name` component:
world:query({
    include = {tecs.builtins.Name}
})
```

The `exclude` property is a list of components an entity must not have to match the query.

```teal{5}
-- Find all entities that have the `tecs.builtins.Name` component and
-- don't have the `tecs.builtins.Ttl` component.
world:query({
    include = {tecs.builtins.Name},
    exclude = {tecs.builtins.Ttl}
})
```

The `includeAny` property is a list of components where an entity must have at least one to match the query. This
acts as an OR condition combined with the AND condition of `include`.

```teal{4}
-- Find all entities that have Position AND either Sprite OR Circle
world:query({
    include = {Position},
    includeAny = {Sprite, Circle}
})
```

You can give queries a name using the `name` property. This makes it easier to identify queries in debug logs.

```teal{2}
world:query({
    name = "NameQuery",
    include = {tecs.builtins.Name}
})
```

### Descriptor reference

The full set of fields accepted by `world:query()`:

| Field               | Type                                                                      | Description                                                                                                                                                                    |
| ------------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `include`           | `{Component}`                                                             | Archetype must contain **all** of these components.                                                                                                                            |
| `exclude`           | `{Component}`                                                             | Archetype must contain **none** of these components.                                                                                                                           |
| `includeAny`        | `{Component}`                                                             | Archetype must contain **at least one** of these components. Combined with `include` as AND (`include`) + OR (`includeAny`).                                                   |
| `name`              | `string`                                                                  | Human-readable name shown in debug logs and the MCP inspector. Optional.                                                                                                       |
| `type`              | `"logic" \| "render"`                                                     | Declares whether the query drives simulation or presentation. `"logic"` excludes [`Paused`](#paused-entities) entities. Optional.                                               |
| `temp`              | `boolean`                                                                 | If `true`, the query is a one-shot snapshot of the currently-matching archetypes. Skips observer registration. Cannot be combined with `onEntitiesAdded` / `onEntitiesRemoved`. See [Temporary queries](#temporary-queries). |
| `groupBy`           | `function`                                                                | Groups matching archetypes by an integer key for sorted iteration. See [Grouping](/tecs/queries/grouping).                                                                |
| `onEntitiesAdded`   | `function`                                                                | Fires once per contiguous range of entities when they first match the query. See [Callbacks](/tecs/queries/callbacks#onentitiesadded-callback).                            |
| `onEntitiesRemoved` | `function`                                                                | Fires once per contiguous range of entities when they stop matching. See [Callbacks](/tecs/queries/callbacks#onentitiesremoved-callback).                                  |

## Iterating over queries

Iterate a query by calling `query:iter()` in a generic `for` loop. Each step returns
`(archetype, length, entities)` for the next non-empty archetype (empty archetypes are skipped).
Inside the loop, bind component columns once per archetype and index them by row.

Consider the following query:

```teal
local Name <const> = tecs.builtins.Name
local Transform <const> = tecs.builtins.Transform

local query = world:query({
    include = {
        Name,
        Transform
    }
})
```

Iterate it:

```teal:line-numbers
for archetype, len, entities in query:iter() do
    local names = archetype:get(Name)
    local transforms = archetype:get(Transform)
    for row = 1, len do
        local name = names[row]
        local transform = transforms[row]
        love.graphics.print(name.value, transform.x, transform.y)
    end
end
```

* Line `1`: gets each non-empty archetype, the number of entities in the archetype, and an array of entity IDs.
* Line `2` and `3`: bind component columns with `archetype:get(Component)`. Teal types `names` as `{Name}`.
* Line `4`: iterates over the entities in the archetype. Each value is the entity's "row", which you use to
  index into component columns.
* Line `5` and `6`: grab components for an entity by indexing into the columns.

### Nested iteration

Iteration is re-entrant: each `for … in query:iter()` loop tracks its own position, so the same query can
be iterated from inside its own loop. This makes pairwise patterns direct:

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

```teal
local movementQuery = world:query({
    include = {Position, Velocity}
})

for archetype, len in movementQuery:iter() do
    local positions = archetype:getMut(Position) -- mutated below
    local velocities = archetype:get(Velocity)   -- read-only

    for row = 1, len do
        positions[row].x = positions[row].x + velocities[row].x * dt
        positions[row].y = positions[row].y + velocities[row].y * dt
    end
end
```

`get` does not protect the column from writes; it simply does not mark the component dirty. Treat `getMut` as the
write-intent API for direct field changes. Use `world:set` when you need to replace a component value or add a
component to an entity.

### Mutations during iteration

Structural changes while iterating a query need special handling. `world:set`, `world:remove`, `world:spawn`,
`world:despawn`, and the `batch*` APIs can move entities between archetypes or resize columns, which would otherwise
invalidate the loop.

To make this safe, Tecs defers mutations issued inside a query loop. When `for … in query:iter()`
takes its first step, the world enters a **deferred scope**; `world:set`, `world:remove`, `world:spawn`,
`world:despawn`, and the `batch*` APIs all stage during iteration and apply in a drain phase when the loop exits.
You can therefore stage structural changes inside the loop body:

```teal
for archetype, len, entities in query:iter() do
    local healths = archetype:get(Health)
    for row = 1, len do
        if healths[row].current <= 0 then
            world:despawn(entities[row])  -- staged; applies after the loop
        end
    end
end
```

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

`cursor:close()` is idempotent, so call it whether the loop breaks or runs to exhaustion. It closes only that
cursor's scope and drains staged mutations when no outer scope remains. Call it immediately before returning from
inside the loop.

Cursors also mirror grouped traversal through `cursor:groups()` and `cursor:group(id)`. A cursor owns one traversal;
use separate cursors for nested loops. Normal `query:iter()`, `query:groups()`, and `query:group(id)` remain the
allocation-free path for loops that always run to exhaustion.

Only the archetype-level query loop holds the deferred scope. Breaking out of an inner `for row = 1, len` row
loop has no effect on it.

See [Deferred scope](/tecs/queries/callbacks#deferred-scope) on the callbacks page for the full drain and
wave model that applies to any deferred region.

## Using queries with systems

Create queries outside of systems (usually in plugins), then use them within systems to process entities.

### Creating queries in plugins

Create the query once in a plugin and close over it from systems:

```teal
-- Create a movement plugin
local function movementPlugin(world: tecs.World)
    -- Create the query once in the plugin
    local movableQuery = world:query({
        name = "MovableEntities",
        include = {Position, Velocity}
    })

    -- Add a system that uses the query
    world:addSystem({
        name = "MovementSystem",
        phase = tecs.phases.FixedUpdate,
        run = function(dt: number)
            -- Use the query created in the plugin
            for arch, len, entities in movableQuery:iter() do
                local positions = arch:getMut(Position)
                local velocities = arch:get(Velocity)
                for row = 1, len do
                    local id = entities[row]
                    local pos = positions[row]
                    local vel = velocities[row]
                    pos.x = pos.x + vel.vx * dt
                    pos.y = pos.y + vel.vy * dt
                end
            end
        end
    })
end

-- Add the plugin to the world
world:addPlugin(movementPlugin)
```

### Temporary queries

By default, queries are persistent: they register as archetype observers and subscribe to new
archetypes. For one-shot iteration where you don't need live updates, use `temp = true` to skip
observer registration. Temp queries cannot use `onEntitiesAdded` or `onEntitiesRemoved` callbacks.

```teal
for archetype, len in world:query({include = {Health}, temp = true}):iter() do
    -- iterate once and discard query
end
```

## Disabled entities

By default, all queries automatically exclude entities that have the
[`tecs.builtins.Disabled`](/tecs/builtins#disabled-component) component. This behavior makes it easy to
temporarily hide entities without despawning them.

```teal
-- This entity won't appear in queries by default
world:spawn(tecs.builtins.Disabled)
```

To find disabled entities in your queries, explicitly include the `Disabled` component:

```teal
-- Find all entities with Position, including disabled ones
local allPositionQuery = world:query({
    include = {Position, tecs.builtins.Disabled}
})
```

## Paused entities

[`tecs.builtins.Paused`](/tecs/builtins#paused-component) marks an entity whose simulation should stop while its
rendering continues, so it is not excluded from every query the way `Disabled` is. Declare which side of that line a
query sits on with `type`:

```teal
-- Simulation: paused entities are skipped
local movement = world:query({
    include = {Transform, Velocity},
    type = "logic",
})

-- Presentation: paused entities keep drawing
local sprites = world:query({
    include = {Transform, Sprite},
    type = "render",
})
```

`type = "logic"` is what makes a [state stack](/tecs/states) pause actually pause. A state declared with
`onBlur = "pause"` adds `Paused` to its entities, but a movement system only stops moving them if its query opts out.

Omitting `type` leaves the query unfiltered. Prefer setting it on every query: `"render"` is not merely the default
spelled out, it records that paused entities are meant to appear, which is the fact a later reader needs.

`exclude = {Paused}` does the same filtering as `type = "logic"`, and a query that includes `Paused` explicitly keeps
it regardless of `type`.

## Ad-hoc archetype lookup

Use `world:findArchetypes(component)` for simple one-component scans when you do not need a persistent query object.
It uses the world's component-to-archetype index and returns an iterator over matching archetypes.

### world:findArchetypes {#world-find-archetypes}

Finds all archetypes that have a specific component.

```teal
function World:findArchetypes(component: Component): function(): (Archetype, integer, {integer})
```

**Parameters:**

- `component`: Component to find.

**Returns:**

- An iterator over matching archetypes.

```teal
for archetype, len, entities in world:findArchetypes(tecs.builtins.Name) do
    local names = archetype:get(tecs.builtins.Name)
    for row = 1, len do
        print(entities[row] .. " has name " .. names[row].value)
    end
end
```
