---
description: "Plugin functions that configure a world with components, systems, and resources, plus configuration, dependency, and composition patterns"
outline: deep
---

# Plugins

Plugins in Tecs provide a modular way to extend your World with reusable functionality. They can add components,
systems, resources, states, and any other game logic in a self-contained package.

## What are plugins?

A plugin is simply a function that takes a World as its parameter and configures it with additional functionality:

```teal
type Plugin = function(world: World)
```

## Using plugins

Add plugins to your world using the `addPlugin` method:

```teal
local world = tecs.newWorld()

-- Add a plugin
world:addPlugin(myPlugin)
```

## Creating plugins

Here's a simple example of a plugin that adds a health system:

```teal
local function healthPlugin(world: tecs.World)
    -- Define a Health component
    local Health = tecs.newComponent({
        name = "Health",
        container = {
            current: number,
            max: number
        },
        fields = {"max"},
        init = function(instance: Health, max: number)
            instance.current = max
            instance.max = max
        end
    })

    -- Create the query once in the plugin
    local healthQuery = world:query({include = {Health}})

    -- Add a damage system
    world:addSystem({
        name = "damageOverTime",
        phase = tecs.phases.Update,
        run = function(dt: number)
            for arch, len in healthQuery:iter() do
                local healths = arch:getMut(Health)
                for row = 1, len do
                    local health = healths[row]
                    -- Apply damage over time
                    health.current = math.max(0, health.current - dt)
                end
            end
        end
    })

    -- Set up an event listener
    world:observe(0, DamageEvent, function(event: DamageEvent)
        local health = world:get(event.entity, Health)
        if health then
            health.current = math.max(0, health.current - event.amount)
        end
    end)
end

-- Use the plugin
world:addPlugin(healthPlugin)
```

## Plugin patterns

### Configuration via closures

Create configurable plugins by returning a plugin function from a configuration function:

```teal
local function createMovementPlugin(speed: number): Plugin
    return function(world: tecs.World)
        world:addSystem({
            name = "movement",
            phase = tecs.phases.Update,
            run = function(dt: number)
                -- Use the configured speed value
                local distance = speed * dt
                -- ... movement logic
            end
        })
    end
end

-- Use with different configurations
world:addPlugin(createMovementPlugin(100))  -- Normal speed
world:addPlugin(createMovementPlugin(200))  -- Fast speed
```

### Plugin dependencies

Plugins can depend on other plugins using assertions.

```teal
-- This plugin requires you to add the Physics plugin first
local function collisionPlugin(world: tecs.World)
    local rigidBody = world.resources[RIGID_BODY]
    assert(rigidBody, "CollisionPlugin requires PhysicsPlugin")

    -- Add collision detection systems...
end
```

### Organizing plugin modules

Structure larger plugins as modules:

```teal
-- myproject/plugins/inventory.tl
local record inventory
    -- Export the plugin function
    plugin: function(world: tecs.World)

    -- Export types for use outside the plugin
    record Item
        id: string
        count: number
    end
end

function inventory.plugin(world: tecs.World)
    -- Plugin implementation
end

return inventory
```

## Built-in plugin

Tecs includes a built-in plugin that's automatically added to every World. This plugin provides:

- **ChildOf relationship**: Automatically despawns children when you despawn parents
- **TTL system**: Despawns entities when their time-to-live expires
- **RelativeTransform system**: Composes each child's world-space `Transform` from its parent's transform plus its `RelativeTransform` offset (following `ChildOf`)

Tecs adds the built-in plugin automatically when you create a World, so you don't need to add it manually.

## Best practices

1. **Keep plugins focused**: Each plugin should have a single purpose
2. **Document dependencies**: State what other plugins or components you require
3. **Export types**: If your plugin defines components or events that other code needs to use, export them
4. **Use descriptive names**: Name your systems and components clearly within plugins
5. **Make plugins configurable**: Use factory functions to create parameterized plugins
6. **Test independently**: Plugins should be testable in isolation

## Example: Input plugin

Here's a more complete example of an input handling plugin:

```teal
local function inputPlugin(world: tecs.World)
    -- Define input components
    local KeyPressed = tecs.newTagComponent("KeyPressed")
    local MousePosition = tecs.newComponent({
        name = "MousePosition",
        container = {x: number, y: number},
        fields = {"x", "y"},
        init = function(instance: MousePosition, x: number, y: number)
            instance.x = x
            instance.y = y
        end
    })

    -- Track input state
    local inputEntity = world:spawn(
        MousePosition(0, 0)
    )

    -- Add input polling system
    world:addSystem({
        name = "inputPoll",
        phase = tecs.phases.First,
        run = function()
            local mouse = world:get(inputEntity, MousePosition)
            -- Update mouse position (framework specific)
            mouse.x, mouse.y = love.mouse.getPosition()

            -- Check for key presses
            if love.keyboard.isDown("space") then
                world:set(inputEntity, KeyPressed)
            else
                world:remove(inputEntity, KeyPressed)
            end
        end
    })

    -- Export for other systems to query
    local INPUT_ENTITY: tecs.Key<integer> = tecs.newKey()
    world.resources[INPUT_ENTITY] = inputEntity
end
```

## Advanced: Plugin composition

Combine multiple plugins into plugin groups:

```teal
local function gameplayPlugins(world: tecs.World)
    world:addPlugin(physicsPlugin)
    world:addPlugin(inputPlugin)
    world:addPlugin(aiPlugin)
    world:addPlugin(audioPlugin)
end

world:addPlugin(gameplayPlugins)
```

This pattern helps organize large projects with many plugins.
