---
outline: deep
---

# Tecs ECS Quickstart

This document provides a quick overview of the core ECS libraries of Tecs.

## What is Tecs?

Tecs is a modular entity component system for Lua and [Teal](https://teal-language.org). It provides:

* **ECS**: An entity component system for managing entities and game logic.
* [**Tecs2D**](/tecs2d): Optional [Love2D](https://love2d.org) bindings that manages the game loop, Love2D events, input
  handling, and game phases.
* [**Tecs_Render**](/plugins/tecs_render): An optional render pipeline and pixel-perfect camera for Tecs2D that provides
  deferred rendering based on layers and z-index, and lighting.
* [**Tecs_Controller**](/plugins/tecs_controller): Rebindable controls for Tecs2D games.
* [**Tecs_Assets**](/plugins/tecs_assets): A non-blocking asset loading and management system for Tecs2D.

## Installing and requiring Tecs

Install Tecs into your game:

```bash
luarocks install --tree=src/vendor tecs.tl
luarocks install --tree=src/vendor tecs2d.tl
```

> For more on installing Tecs, see [installing Tecs](/guide/install).

Next, require it:

```lua
local tecs = require("tecs")
```

## Tecs in a nutshell

### World

A `World` contains all the entities, components, systems, plugins, and resources of a game.

```lua
local world = tecs.newWorld()
```

> See the [World reference](/reference/world) for more information

### Entity

A unique ID that represents an object in the game world. Entities themselves have no data or behavior; only the
components attached to them define what they are.

```lua
-- Create an entity with two components and get the entity ID
local entityId = world:spawn(
    tecs.builtins.Name("Hello Tecs"),
    tecs.builtins.Transform(100, 100)
)
```

### Component

Components describe traits like position, velocity, or health, and are the building blocks of game state.

```lua
-- Get the Name component of the entity
local name = world:get(entityId, tecs.builtins.Name)
print(name.value)
```

::: tip Tecs is strongly typed
By passing in the **type** of the component to `get`, the Teal type system knows you are getting back a component
of the same type.
:::

#### Creating a component

You can create a new component by defining a Teal record:

```lua
local record Sprite is tecs.Component
    texture: love.graphics.Texture
    metamethod __call: function(self, love.graphics.Texture): self
end
```

Next, pass a configuration table to `tecs.newComponent` to wire up the necessary metatables to make it a component.

```lua
tecs.newComponent({
    name = "Sprite",
    container = Sprite,
    constructor = function(texture: love.graphics.Texture): Sprite
        return {texture = texture}
    end
})

-- Set the Sprite component on the entity
local image = love.graphics.newImage("cactus.png")
world:set(entityId, Sprite(image))
```

> See the [Components reference](/reference/components) for more information

### System

A system is a function that runs game logic by operating on entities with specific components. Systems are how
behavior is added to the game. Systems are added to [phases](/reference/phases) so they run at specific parts of
the game loop.

```lua
world:addSystem({
    phase = tecs.phases.Update,
    run = function()
        print("Time since last frame: " .. world.dt)
    end
})
```

> See the [Systems reference](/reference/systems) for more information

### Plugin

A plugin is used to configure the world by adding systems, registering components, setting up resources, and hooking
up event observers. Plugins are a kind of module boundary that bundle up parts of a game.

```lua
world:addPlugin(function(world: tecs.World)
    -- register components, systems, spawn entities, add resources, ...
end)
```

:::tip Plugins power everything
You'll use plugins extensively to write your game logic, include plugins from other libraries like
[Tecs2D](/tecs2d/), and install systems.
:::

### Queries

Systems are created inside plugins. For systems to be useful they typically use a **query** to find entities in the
world they care about. Systems can use zero or more queries. Queries are typically created in plugins outside
the scope of a system, and systems then reuse the query over their lifetime.

```lua
local Transform = tecs.builtins.Transform

local spritePlugin = function(world: tecs.World)
    -- Find entities with Transform and Sprite components
    local spriteQuery = world:query({
        include = {Transform, Sprite}
    })

    -- Draw the sprites in the render phase
    world:addSystem({
        phase = tecs.phases.Render,
        run = function()
            -- Iterate over entities with both Transform and Sprite.
            for archetype, len, entities in spriteQuery() do
                local transforms = archetype[Transform]
                local sprites = archetype[Sprite]
                for row = 1, len do
                    local id = entities[row]
                    local tx = transforms[row]
                    local sprite = sprites[row]
                    love.graphics.draw(sprite.texture, tx.x, tx.y)
                end
            end
        end
    })
end

-- Register the plugin with the world
world:addPlugin(spritePlugin)
```

> See the [Query reference](/reference/queries) for more information

### Archetypes

Every unique combination of components applied to entities forms an _archetype_. An entity belongs to exactly
one archetype. Archetypes give you fast access to entity IDs and components of the entities stored in the archetype.
You'll interact with archetypes primarily through queries.

```lua
-- Grab "columns" by indexing into the archetype with the component type
local transforms = archetype[Transform]
local sprites = archetype[Sprite]

for row = 1, len do
    -- Index into the archetype columns by row
    local tx = transforms[row]
    local sprite = sprites[row]
end
```

> See the [Archetype reference](/reference/archetype) for more information

::: tip Archetypes make Tecs fast!
Archetypes organize entities into groups based on their components. This means that to find entities that match a
query, you just need to find the archetypes that match. This is a dramatic optimization over iterating over every
entity to see if matches a query, and also allows for techniques like SoA storage and FFI storage.
:::

### Phases

To progress the game, you need to call `world:update(dt)`, passing in the time since the last update. This will
invoke every phase of the Tecs game loop, and call each system in those phases. When a system is added to a world,
it's added to a phase. Phases are accessed using `tecs.phases.<X>`:

```lua
world:addSystem({
    phase = tecs.phases.Startup,
    run = function()
        print("The game is starting up!")
    end
})
```

> See the [Phases reference](/reference/phases) for a list of phases

::: tip
Executing the right phases at the right time is handled for you automatically when using Love2D and [Tecs2d](/tecs2d).
:::

### Resources

_Resources_ in Tecs are the built-in way to share variables globally across your game, but **without globals**.

To add resources to a world, you first need to create a strongly typed key.

```lua
local FONT: tecs.Key<love.graphics.Font> = tecs.newKey()
```

This tells the Teal type system that `FONT` contains a `love.graphics.Font`.
Now you can assign a value to the resource:

```lua
world.resources[FONT] = love.graphics.newFont(filename, glyphs)
```

You can access the resource using the key too:

```lua
local font = world.resources[FONT]
```

::: tip Store keys in modules
Store your keys in a module because you need to refer to the exact same key when
trying to access the resource.

```lua
local record MyModule
    FONT: tecs.Key<love.graphics.Font>
end

MyModule.FONT = tecs.newKey()
```
:::