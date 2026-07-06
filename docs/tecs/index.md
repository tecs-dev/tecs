---
outline: deep
---

# Tecs Getting Started

Tecs is a typed, archetype-based ECS for [LuaJIT](https://luajit.org) and [Teal](https://teal-language.org).
Tecs is the core of [Tecs2D](/tecs2d/), a Love2D engine.

::: warning Tecs is in preview
Tecs is not yet stable and may change as development progresses.
:::

## Installation

First, install LuaJIT and LuaRocks if you haven't already:

::: code-group

```bash [macOS]
brew install luajit luarocks
```

```bash [Debian/Ubuntu]
sudo apt install luajit libluajit-5.1-dev luarocks
```

```bash [Arch]
sudo pacman -S luajit luarocks
```

```powershell [Windows]
scoop install luajit luarocks
```

```bash [Source]
# LuaJIT build guide: https://luajit.org/install.html
git clone https://github.com/LuaJIT/LuaJIT.git
cd LuaJIT && make && sudo make install

# Then install LuaRocks:
# https://github.com/luarocks/luarocks/blob/main/docs/download.md
```

:::

Install Tecs via [LuaRocks](https://luarocks.org). For typical gamedev, you'll want a self-contained build:

```bash
luarocks install --dev --tree=vendor --lua-version=5.1 tecs
```

*While Tecs is in preview, `--dev` is required. There are no tagged releases yet.*

Require Tecs in your code:

```teal
local tecs = require("tecs")
```

::: tip Building a game?
If you are building a Love2D game and want the engine layer as well, install `tecs2d` instead. It depends on `tecs`
automatically and provides rendering, audio, input, physics, UI, and the Love2D loop integration.
See [Tecs2D Getting Started](/tecs2d/) for the starter template and build commands.
:::

## Tecs in a nutshell

### World

A `World` contains all the entities, components, systems, plugins, and resources of a game.

```teal
local world = tecs.newWorld()
```

> See the [World reference](/tecs/world) for more information

### Entity

A unique ID that represents an object in the game world. Entities themselves have no data or behavior; only the
components attached to them define what they are.

```teal
-- Create an entity with two components and get the entity ID
local entityId = world:spawn(
    tecs.builtins.Name("Hello Tecs"),
    tecs.builtins.Transform(100, 100)
)
```

### Component

Components describe traits like position, velocity, or health, and are the building blocks of game state.

```teal
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

```teal
local record Sprite is tecs.Component
    texture: love.graphics.Texture
    metamethod __call: function(self, love.graphics.Texture): self
end
```

Next, pass a configuration table to `tecs.newComponent` to wire up the necessary metatables to make it a component.

```teal
tecs.newComponent({
    name = "Sprite",
    container = Sprite,
    fields = {"texture"},
    init = function(instance: Sprite, texture: love.graphics.Texture)
        instance.texture = texture
    end
})

-- Set the Sprite component on the entity
local image = love.graphics.newImage("cactus.png")
world:set(entityId, Sprite(image))
```

> See the [Components reference](/tecs/components/) for more information

### System

A system is a function that runs game logic by operating on entities with specific components. Add behavior
through systems. Add systems to [phases](/tecs/phases) to run at specific parts of the game loop.

```teal
world:addSystem({
    phase = tecs.phases.Update,
    run = function(dt: number)
        print("Time since last frame: " .. dt)
    end
})
```

> See the [Systems reference](/tecs/systems) for more information

### Plugin

Use plugins to configure the world: add systems, register components, set up resources, and hook
up event observers. Plugins bundle parts of a game into modular units.

```teal
world:addPlugin(function(world: tecs.World)
    -- register components, systems, spawn entities, add resources, ...
end)
```

:::tip Plugins power everything
You'll use plugins extensively to write your game logic, include plugins from other libraries like
[tecs2d](/tecs2d/), and install systems.
:::

### Queries

Create systems inside plugins. For systems to be useful, they typically use a **query** to find entities in the
world. Systems can use zero or more queries. Create queries in plugins outside the system scope, then reuse
them over the system's lifetime.

```teal
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
            for archetype, len, entities in spriteQuery:iter() do
                local transforms = archetype:get(Transform)
                local sprites = archetype:get(Sprite)
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

> See the [Query reference](/tecs/queries/) for more information

### Archetypes

Every unique combination of components applied to entities forms an _archetype_. An entity belongs to exactly
one archetype. Archetypes give you fast access to entity IDs and components of the entities stored in the archetype.
You'll interact with archetypes primarily through queries.

```teal
-- Grab "columns" using archetype:get (read) or archetype:getMut (mark dirty)
local transforms = archetype:get(Transform)
local sprites = archetype:get(Sprite)

for row = 1, len do
    -- Index into the archetype columns by row
    local tx = transforms[row]
    local sprite = sprites[row]
end
```

> See the [Archetype reference](/tecs/archetype) for more information

::: tip Archetypes and queries
Archetypes organize entities into groups based on their components. Queries find matching archetypes, then iterate
their component columns by row. This is why query examples bind columns once per archetype instead of fetching
components one entity at a time.
:::

### Phases

To progress the game, call `world:update(dt)` with the time since last update. This invokes every phase
of the Tecs game loop and runs each system in those phases. When you add a system to a world, you specify
its phase. Access phases with `tecs.phases.<X>`:

```teal
world:addSystem({
    phase = tecs.phases.Startup,
    run = function()
        print("The game is starting up!")
    end
})
```

> See the [Phases reference](/tecs/phases) for a list of phases

::: tip
tecs2d handles phase execution timing automatically when using Love2D. See [Love2D integration](/tecs2d/love2d).
:::

### Resources

_Resources_ in Tecs are the built-in way to share variables globally across your game, but **without globals**.

To add resources to a world, you first need to create a strongly typed key.

```teal
local FONT: tecs.Key<love.graphics.Font> = tecs.newKey()
```

This tells the Teal type system that `FONT` contains a `love.graphics.Font`.
Now you can assign a value to the resource:

```teal
world.resources[FONT] = love.graphics.newFont(filename, glyphs)
```

You can access the resource using the key too:

```teal
local font = world.resources[FONT]
```

::: tip Store keys in modules
Store your keys in a module because you need to refer to the exact same key when
trying to access the resource.

```teal
local record MyModule
    FONT: tecs.Key<love.graphics.Font>
end

MyModule.FONT = tecs.newKey()
```
:::
