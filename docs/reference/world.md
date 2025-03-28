# World

The `World` is the core of the Tecs entity component system. It manages entities, components, systems, and
the game loop, acting as the central hub for your Tecs application.

## Overview

`World` stores the game state and provides methods for:

- Creating and managing entities
- Attaching and removing components
- Adding systems to process entities
- Organizing systems into phases
- Handling global game events
- Managing resources that are shared across the game

## Creating a World

Interact with `World` through the `tecs` module.

```lua
local tecs = require("tecs")
```

Create a World that by default updates at 60 FPS:

```lua
local world = tecs.newWorld()
```

Create a World that updates at 30 FPS:

```lua
local world = tecs.newWorld({
    timestep = 1 / 30
})
```

## Entity Management

### spawn

Creates a new entity in the World.

```lua
function World:spawn(...: Component): Id
```

**Parameters:**

- `...`: Variable number of components to add to the entity.

**Returns:**

- The entity ID of the spawned entity

**Notes:**

- Entity creation is deferred until the end of the current system if called from within a system.
- You may despawn entities that haven't yet been committed to the World, cancelling the spawn.
- You _may not_ add or remove components of a pending spawn.
- For spawn notifications, add an `Emitter` component and observe the `OnSpawn` event.

**Example:**

```lua
local entityId = world:spawn(tecs.builtins.Emitter())

-- Spawn with multiple components:
local playerId = world:spawn(
    tecs.builtins.Transform(100, 100),
    tecs.builtins.Name("Player")
)

-- Get notified when the spawn is committed to the World.
local enemyId = world:spawn(
    tecs.builtins.Transform({x = 100, y = 100}),
    tecs.builtins.Emitter(function(emitter)
        emitter:observe(tecs.builtins.OnSpawn, function(event: tecs.builtins.OnSpawn)
            print("Enemy created with ID: " .. event.entity)
        end)
    end)
)
```

### despawn

Removes an entity from the World.

```lua
function World:despawn(entity: Id)
```

**Parameters:**

- `entity`: The entity ID to remove.

::: info Despawn lifecycle
When an entity is despawned:
1. The entity is immediately marked as not alive (`isAlive` returns false)
2. If the entity has an `Emitter` component, an [`OnDespawn` event](/reference/builtins#ondespawn-event) is emitted
3. Relationships pointing to this entity are automatically removed (triggering any `onRemove` hooks)
4. The entity and its components are removed from the world
:::

**Example:**

```lua
-- Remove an entity from the world
world:despawn(entity)

-- Listen for despawn events (requires Emitter component)
world:getEntityEmitter(entity)
    :observe(tecs.builtins.OnDespawn, function(e: tecs.builtins.OnDespawn)
        print("Entity " .. e.entity .. " is being despawned")
    end)
```

### isAlive

Checks if an entity is alive and not being despawned.

```lua
function World:isAlive(entity: integer): boolean
```

**Parameters:**

- `entity`: The entity ID to check.

**Returns:**

- `true` if the entity exists and is not being despawned, `false` otherwise

::: info Despawning entities
When an entity begins the despawn process, `isAlive` immediately returns `false` even though the entity's components
may still be accessible briefly during cleanup operations. This allows relationship hooks and other systems to detect
when an entity is being removed versus manually modified.
:::

**Example:**

```lua
if world:isAlive(entity) then
    world:despawn(entity)
end
```

### getEntityEmitter

Gets or creates an event emitter for an entity, allowing for events specific to a single entity.

```lua
function World:getEntityEmitter(entity: integer): events.Emitter
```

**Parameters:**

- `entity`: Entity ID to get the emitter for.

**Returns:**

- The entity's [event emitter](/reference/events#entity-emitter)

**Notes:**

- Creates an emitter if one doesn't exist.
- The addition of the emitter component is deferred until after the current system completes.
- However, the created emitter is available to use immediately even if an entity has not yet been comitted.

**Example:**

```lua
-- Get the emitter for an entity
local emitter = world:getEntityEmitter(entity)

-- Listen for events on the entity
emitter:observe(tecs.builtins.OnDespawn, function(e: tecs.builtins.OnDespawn)
    print("Entity despawned: " .. e.entity)
end)

-- Despawn the entity, eventually triggering the OnDespawn
-- event when the despawn is committed.
world:despawn(entity)
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
Whenever possible, prefer getting entity components from queries and archetypes rather than directly from the World.
:::

### set

Attaches a component to an entity.

```lua
function World:set(entity: integer, component: Component)
```

**Parameters:**

- `entity`: Entity ID.
- `component`: The component **instance** to attach.

**Notes:**

- If the entity already has this component type, it will be replaced
- Changes are deferred if called from within a system. The change will not be observable with `get` until
  after the current system completes. Use `world:command(function() end)` in the system if you need to act
  on an entity after the change takes effect.

**Example:**

```lua
-- Add a transform component to an entity
world:set(entity, tecs.builtins.Transform(100, 200)
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

> See the [Components](/reference/components) reference for more information.

## Queries

### query

Creates a query to find entities with specific components.

```lua
function World:query(descriptor: queries.QueryDescriptor): Query
```

**Parameters:**

- `descriptor`: Description of the components to query for

**Returns:**

- A query object that can be used to iterate over matching entities

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
for archetype, len, entities in query() do
    -- Grab component columns.
    local names = archetype[tecs.builtins.Name]
    local transforms = archetype[tecs.builtins.Transform]
    -- Iterate over the entities in the archetype.
    for row = 1, len do
        local xf = transforms[row]
        local name = names[row]
        love.graphics.print(name.value, xf.x, xf.y)
    end
end
```

> See the [Queries](/reference/queries) reference for more information.

### findArchetypes

Finds all archetypes that have a specific component, returning an iterator over the matching archetypes.
This is a very fast O(1), garbage-free operation. This method could be used for ad-hoc queries when looking for
a single component.

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
    local names = archetype[tecs.builtins.Name]
    -- Iterate over the entities in the archetype.
    for i = 1, len do
        print(entities[i] .. " has name " .. names[i].value)
    end
end
```

## Deferred Operations

### command

Adds a command to be executed when the World is not frozen, typically after the current system completes.
If called when the World is not frozen, the command is executed immediately.

```lua
function World:command(command: function())
```

**Parameters:**

- `command`: Function that mutates the World.

**Notes:**

- Commands are deferred until after the current system completes.
- Useful for processing entities after changes made in the current system are completed.

**Example:**

```lua
-- Queue a command to be executed later.
world:command(function()
    -- process entities after current system completes
    -- (world is accessible through closure)
end)
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

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `phase` | **Yes** | `Phase` | The phase when the system should run |
| `run` | **Yes** | `function` | The system function to call on each update |
| `name` | No | `string` | Name of the system (useful for debugging and dependencies) |
| `runIf` | No | `function` | Optional function that determines if the system should run |
| `before` | No | `{string}` | Optional list of system names this should run before |
| `after` | No | `{string}` | Optional list of system names this should run after |

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
        for archetype, len in movableQuery() do
            local transforms = archetype[tecs.builtins.Transform]
            local velocities = archetype[Velocity]
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
    runIf = function(dt: number, world: tecs.World)
        -- Only run this system occasionally
        return math.random() < 0.01
    end,
    run = function(dt: number, world: tecs.World)
        playAmbientSound()
    end
})
```

Add a system with dependencies.

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

### removeSystem

Removes a system from the world.

```lua
function World:removeSystem(phase: Phase, system: System | string)
```

**Parameters:**

- `phase`: The phase the system is in.
- `system`: The system function to remove or the name of the system to remove.

**Example:**

```lua
-- Add the system.
world:addSystem({
    name = "StartupSystem",
    phase = tecs.phases.Startup,
    run = function startupSystem(dt: number, world: tecs.World)
        -- Initialize game state
    end
})

-- Later, remove the system.
world:removeSystem(tecs.phases.Startup, "StartupSystem")
```

> See the [Systems](/reference/systems) reference for more information.

## Plugins

Plugins are used to add systems, components, states, and more to a `World`. Everything in Tecs is built
around plugins.

### addPlugin

Adds a plugin to the world.

```lua
function World:addPlugin(plugin: function(world: World))
```

**Parameters:**

- `plugin`: Function that configures the world.

**Example:**

```lua
-- Define a plugin
local function physicsPlugin(world: tecs.World)
    -- Physics components would be registered globally when created
    -- with tecs.newComponent

    -- Add physics systems
    world:addSystem({
        name = "PhysicsSystem",
        phase = tecs.phases.FixedUpdate,
        run = function(dt: number, world: tecs.World)
            -- Physics simulation logic
        end
    })

    -- Add physics resources
    world.resources:set(PhysicsWorld{ gravity = 9.8 })
end

-- Add the plugin to the world
world:addPlugin(physicsPlugin)
```

## Resources

Resources are globally shared data that can be accessed by systems and plugins.

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

> See the [Phases](/reference/phases) reference for more information.

## Events

The World implements the Emitter interface, allowing it to broadcast and receive events
globally across all systems and plugins.

```lua
-- Observer a global event.
world:observe(MyCustomEvent, function(e: MyCustomEvent)
    print("Got MyCustomEvent")
end)

-- Emit a global event
world:emit(MyCustomEvent())
```

> See the [Events](/reference/events) reference for more information.

## Stats

### getStats

Get statistics about the World.

```lua
function World:getStats(fill?: world.Stats): world.Stats
```

**Parameters:**

- `fill`: Optional stats table to fill instead of allocating a new one (for reducing garbage collection pressure)

**Returns:**

- Stats object with entity count, archetype count, etc.

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
