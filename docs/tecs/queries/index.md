---
outline: deep
---

# Queries

Use queries to find entities with specific [components](/tecs/components/). Create queries inside
[plugins](/tecs/plugins) and use them in [systems](/tecs/systems) to update entities every frame.

## Creating queries

Create queries with `world:query()`, passing a `QueryDescriptor`.

The `include` property is a list of components an entity must have to match the query.

```lua{3}
-- Find all entities that have the `tecs.builtins.Name` component:
world:query({
    include = {tecs.builtins.Name}
})
```

The `exclude` property is a list of components an entity must not have to match the query.

```lua{5}
-- Find all entities that have the `tecs.builtins.Name` component and
-- don't have the `tecs.builtins.Ttl` component.
world:query({
    include = {tecs.builtins.Name},
    exclude = {tecs.builtins.Ttl}
})
```

The `includeAny` property is a list of components where an entity must have at least one to match the query. This
acts as an OR condition combined with the AND condition of `include`.

```lua{4}
-- Find all entities that have Position AND either Sprite OR Circle
world:query({
    include = {Position},
    includeAny = {Sprite, Circle}
})
```

You can give queries a name using the `name` property. This makes it easier to identify queries in debug logs.

```lua{2}
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
| `temp`              | `boolean`                                                                 | If `true`, the query is a one-shot snapshot of the currently-matching archetypes. Skips observer registration. Cannot be combined with `onEntitiesAdded` / `onEntitiesRemoved`. See [Temporary queries](#temporary-queries). |
| `groupBy`           | `function`                                                                | Groups matching archetypes by an integer key for sorted iteration. See [Grouping](/tecs/queries/grouping).                                                                |
| `onEntitiesAdded`   | `function`                                                                | Fires once per contiguous range of entities when they first match the query. See [Callbacks](/tecs/queries/callbacks#onentitiesadded-callback).                            |
| `onEntitiesRemoved` | `function`                                                                | Fires once per contiguous range of entities when they stop matching. See [Callbacks](/tecs/queries/callbacks#onentitiesremoved-callback).                                  |

## Iterating over queries

Iterate a query by calling `query:iter()` in a generic `for` loop. Each step returns
`(archetype, length, entities)` for the next non-empty archetype (empty archetypes are skipped).
`query:iter()` returns a plain iterator function, so the loop runs as a tight call in LuaJIT with no
metamethod indirection.

Consider the following query:

```lua
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

```lua:line-numbers
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
* Line `2` and `3`: bind component columns with `archetype:get(Component)` (read-only) or
  `archetype:getMut(Component)` (mark the column dirty so renderer shadow buffers and other consumers re-sync).
  Teal types `names` as `{Name}`.
* Line `4`: iterates over the entities in the archetype. Each value is the entity's "row", which you use to
  index into component columns.
* Line `5` and `6`: grab components for an entity by indexing into the columns.

### Mutations during iteration

Mutating an entity while iterating a query is unsafe. `world:set`, `world:remove`, and other mutating methods
can move an entity to a different archetype, or cause an archetype column to resize, which changes memory and
shuffles the entities out from under the loop.

To make this safe, Tecs defers mutations issued inside a query loop. When `for … in query:iter()`
takes its first step, the world enters a **deferred scope**; `world:set`, `world:remove`, `world:spawn`,
`world:despawn`, and the `batch*` APIs all stage during iteration and apply in a drain phase when the loop exits.
You can therefore mutate matching entities freely inside the loop body:

```lua
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

Normal exhaustion of `for … in query:iter()` drains staged mutations automatically. An early `break` does not; the
deferred scope stays open, and your staged writes stay invisible until the next flush point. Call
`world:commit()` after the break to drain right away:

```lua
for archetype, len, entities in query:iter() do
    if shouldStop then
        world:set(entities[1], SomeFlag)  -- entities are 1-indexed
        break
    end
end
world:commit()  -- drains the leaked scope
```

`world:commit()` is safe to call unconditionally: it's a no-op when no scope was leaked and nothing was
dirtied. If you don't need same-frame visibility, you can skip it; the mutations flush at the next
`world:update()`.

Only the archetype-level query loop holds the deferred scope. Breaking out of an inner `for row = 1, len` row
loop has no effect on it.

See [Deferred scope](/tecs/queries/callbacks#deferred-scope) on the callbacks page for the full drain and
wave model that applies to any deferred region.

## Using queries with systems

Create queries outside of systems (in plugins), then use them within systems to process entities. This
pattern keeps queries efficient: create once, reuse across multiple system updates.

### Creating queries in plugins

The recommended approach is to create queries in a plugin and store them for use by systems:

```lua
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

```lua
for archetype, len in world:query({include = {Health}, temp = true}):iter() do
    -- iterate once and discard query
end
```

## Disabled entities

By default, all queries automatically exclude entities that have the
[`tecs.builtins.Disabled`](/tecs/builtins#disabled-component) component. This behavior makes it easy to
temporarily hide entities without despawning them.

```lua
-- This entity won't appear in queries by default
world:spawn(tecs.builtins.Disabled)
```

To find disabled entities in your queries, explicitly include the `Disabled` component:

```lua
-- Find all entities with Position, including disabled ones
local allPositionQuery = world:query({
    include = {Position, tecs.builtins.Disabled}
})
```