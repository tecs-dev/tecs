---
outline: deep
---

# Queries

Queries are used to find entities that have specific [components](/reference/components). Queries are typically
created inside [plugins](/reference/plugins) and used by [systems](/reference/systems) to update entities every
frame.

## Creating queries

Queries are created using `world:query()` and passing in a `QueryDescriptor`.

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

You can give queries a name using the `name` property. This makes it easier to identify queries in debug logs.

```lua{2}
world:query({
    name = "NameQuery",
    include = {tecs.builtins.Name}
})
```

## Iterating over queries

Queries are iterated by calling them as a function, which returns (archetype, length, entities) tuples for
maximum performance.

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

Queries are iterated by calling them like a function:

```lua:line-numbers
for archetype, len, entities in query() do
    local names = archetype[Name]
    local transforms = archetype[Transform]
    for row = 1, len do
        local name = names[row]
        local transform = transforms[row]
        love.graphics.print(name.value, transform.x, transform.y)
    end
end
```

* Line `1`: gets each non-empty archetype, the number of entities in the archetype, and an array of entity IDs.
* Line `2` and `3`: access component columns directly from the archetype using table-style indexing with the component
  type as the key. Teal is able to type `names` as `{Name}`.
* Line `4`: iterates over the entities in the archetype. Each value is the "row" of the entity. This row is used to
  index into component columns.
* Line `5` and `6`: grab components for an entity by indexing into the columns.

## Query callbacks

Query callbacks allow you to react when entities **match** or **stop matching** a query. This is particularly useful
for integrating with external systems, managing resources, or tracking entity state changes.

### onMatch callback

The `onMatch` callback of a query can be used to get notified when an entity matches the query. This can be useful for
things like integrating with another framework, like a physics engine.

```lua{3}
world:query({
    include = {tecs.builtins.Transform, MyPhysicsComponent},
    onMatch = function(id: integer, archetype: tecs.Archetype, row: integer)
        local transform = archetype:get(tecs.builtins.Transform, row)
        local myPhysicsComponent = archetype:get(MyPhysicsComponent, row)
        -- add the entity to your physics world...
    end
})
```

The `onMatch` callback accepts the entity ID that matched, the archetype the entity is contained within, and the
row of the entity in the archetype. You can access the components of the entity using `archetype:get()`, and
passing in the component type and entity row.

### onRemove callback

When an entity no longer matches a query, the `onRemove` callback is invoked. An entity stops matching a query
if a component is removed that is a requirement of the query, a component is added that is excluded from
the query, or the entity is despawned.

```lua{8}
world:query({
    include = {tecs.builtins.Transform, MyPhysicsComponent},
    onMatch = function(id: integer, archetype: tecs.Archetype, row: integer)
        local transform = archetype:get(tecs.builtins.Transform, row)
        local myPhysicsComponent = archetype:get(MyPhysicsComponent, row)
        -- add the entity to your physics world...
    end,
    onRemove = function(id: integer, archetype: Archetype, row: integer, despawned: boolean)
        local transform = archetype:get(tecs.builtins.Transform, row)
        local myPhysicsComponent = archetype:get(MyPhysicsComponent, row)
        -- remove the entity from your physics world...
    end
})
```

The `onRemove` callback accepts the entity ID that was removed, the archetype the entity belongs to, the row of the
entity in the archetype, and a boolean that specified if the entity was despawned or just moved archetypes. Like
`onMatch`, you can access the components of the entity using `archetype:get()`, and passing in the component type
and entity row. If the entity moved archetypes, then the given archetype is the new archetype of the entity. If the
entity was despawned, then the archetype is the old archetype the entity belonged to.

### Common use cases for callbacks

Query callbacks are ideal for things like:

- **Physics engine integration**: Add/remove entities from physics simulation
- **Resource management**: Initialize/cleanup entity-specific resources
- **Sound system**: Start/stop audio sources when entities enter/leave range

```lua
-- Example: Audio source management
world:query({
    include = {AudioSource, Position},
    onMatch = function(id, archetype, row)
        local audio = archetype:get(AudioSource, row)
        audio.sourceId = createAudioSource(audio.soundFile)
    end,
    onRemove = function(id, archetype, row, despawned)
        local audio = archetype:get(AudioSource, row)
        if audio.sourceId then
            destroyAudioSource(audio.sourceId)
        end
    end,
    save = true  -- Keep query alive for callbacks only
})
```

## Using queries with systems

Queries are commonly created outside of systems (in plugins) and then used within systems to process entities. This
pattern keeps queries efficient by creating them once and reusing them across multiple system updates.

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
            for arch, len, entities in movableQuery() do
                local positions = arch[Position]
                local velocities = arch[Velocity]
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

### Saving queries from garbage collection

When using queries for callbacks only, you might not have a reference to the query anywhere, which leads to the
query possibly getting garbage collected. The `save` property can be used to ensure the query isn't garbage collected.

```lua{7}
world:addPlugin(function(w: tecs.World)
    w:query({
        include = {Transform},
        onMatch = function(id: integer, archetype: tecs.Archetype, row: integer)
            print("An entitiy matched the query: " .. id)
        end,
        save = true  -- Prevents garbage collection
    })
end)
```

## Query interface

```lua
--- A query for finding entities with specific components.
interface Query
    --- Iterate over archetypes and entities.
    --- Returns (archetype, length, entities) for each matching archetype.
    --- Use archetype[Component] to retrieve component data.
    metamethod __call: function(self): function(): (Archetype, integer, {integer})
end
```

## QueryDescriptor interface

```lua
--- Query descriptor for creating queries.
interface QueryDescriptor
    --- An optional name to give the query, used in logging.
    name: string

    --- The components an archetype must contain in order to match the query.
    include: {Component}

    --- The components an archetype must not contain in order to match the query.
    exclude: {Component}

    --- Called when an entity matches the query.
    onMatch: function(entityId: integer, archetype: Archetype, row: integer)

    --- Called when an entity no longer matches the query.
    onRemove: function(entityId: integer, archetype: Archetype, row: integer)

    --- Whether to save the query in the world (strong reference).
    save: boolean
end
```