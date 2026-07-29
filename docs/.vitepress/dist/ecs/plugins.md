---
url: /ecs/plugins.md
description: >-
  Plugins are the one way into a world: what the entry plugin is handed, how to
  compose plugins, and the patterns that scale
---

# Plugins

A plugin is a function that takes a world and configures it: components, queries, systems, resources, states,
observers and entities. It is the unit of composition in Tecs, and it is the only entry point a game gets.

```teal
type Plugin = function(world: World)
```

## The entry plugin

`Application.Config` carries one `plugin`, a `function(world, app)`, and nothing else a game supplies is called
by the loop. Everything a game wants to happen is registered from there, because the ECS already answers the
questions a lifecycle callback would: a system's order is declared by its [phase](/ecs/phases), a system and an
observer are both registered on the world so the debug server can list them, and both run inside the crash
guard.

```teal
local tecs <const> = require("tecs")
local Transform <const> = tecs.Transform
local Tint <const> = tecs.gfx.Tint
local Renderable <const> = tecs.gfx.Renderable

return tecs.application.create({
    window = { title = "my game", width = 1280, height = 720 },

    plugin = function(world: tecs.World, app: tecs.application.Application)
        world:spawn(Transform(100, 100), Tint(1, 0.4, 0.3, 1), Renderable())
    end,
})
```

The world comes first because every plugin the world takes is `function(world)`: the entry reads as that shape
with one more thing, and a body moved between the entry and a delegated plugin cannot silently swap its
arguments. The application is passed rather than looked up, so there is no nil case for a plugin to check, and
there is no way to reach it from a world that has one: capture it here, in the closure the systems and
observers you register are written in. `app.renderer` is reached the same way.

Being handed the application is not a second lifecycle mechanism. A system that captured `app` when the plugin
registered it can do everything a per-frame callback could, and gets phase order, the fixed step, pause and
state gating and the crash guard along with it, which a callback would not have.

The entry plugin runs before the startup phases, so anything it spawns is resident before the first frame is
extracted. See [Getting started](/getting-started) for the entry file and
[`Application`](/modules/application) for the rest of the config.

## world:addPlugin

Installs a plugin into a world by calling it with the world.

```teal
function World:addPlugin(plugin: Plugin)
```

**Parameters:**

* `plugin`: the plugin function.

A game with several modules calls this from inside its entry plugin, so there is one composition mechanism
rather than two. It is also how the engine's own optional pieces are installed; the demo installs the text
plugin this way:

```teal
world:addPlugin(tecs.gfx.textPlugin({ renderer = app.renderer }))
```

## Writing a plugin

A plugin declares its own components, builds its queries once, and registers the systems that use them.

```teal
local tecs <const> = require("tecs")
local Transform <const> = tecs.Transform

--- Health, declared by the game rather than by the engine.
local record Health is tecs.Component
    current: number
    max: number

    metamethod __call: function(self, max: number): Health
end

tecs.ecs.newComponent({
    name = "Health",
    container = Health,
    fields = {"max"},
    init = function(instance: Health, max: number)
        instance.current = max
    end,
})

local function healthPlugin(world: tecs.World)
    -- Built once, during setup. Never inside a system's run function.
    local living <const> = world:query({ include = { Health }, type = "logic" })

    world:addSystem({
        name = "game.DamageOverTime",
        phase = tecs.ecs.phases.FixedUpdate,
        run = function(dt: number)
            for archetype, length in living:iter() do
                local healths = archetype:getMut(Health)
                for row = 1, length do
                    local health = healths[row]
                    health.current = math.max(0, health.current - dt)
                end
            end
        end,
    })

    world:observe(0, tecs.ecs.OnDespawn, function(e: tecs.ecs.OnDespawn)
        -- The entity is still readable until the despawn commits.
        local transform <const> = world:get(e.entity, Transform)
        if transform then
            spawnDebrisAt(world, transform.x, transform.y)
        end
    end)
end
```

Install it from the entry plugin:

```teal
plugin = function(world: tecs.World, app: tecs.application.Application)
    world:addPlugin(healthPlugin)
end,
```

The query is `type = "logic"`, so entities the [state stack](/ecs/states) has marked `Paused` stop losing
health while the game is paused, without the system knowing anything about states.

## Plugin patterns

### Configuration through a closure

Return the plugin from a function that takes the configuration. This is the shape `tecs.gfx.textPlugin` uses, and
it keeps the configuration typed rather than reaching it out of a table at run time.

```teal
local function spinPlugin(speed: number): tecs.Plugin
    return function(world: tecs.World)
        local spinning <const> = world:query({
            include = { tecs.Transform, tecs.gfx.Renderable },
        })

        world:addSystem({
            name = "game.Spin",
            phase = tecs.ecs.phases.Update,
            run = function(dt: number)
                for archetype, length in spinning:iter() do
                    local transforms = archetype:getMut(tecs.Transform)
                    for row = 1, length do
                        transforms[row].rotation = transforms[row].rotation + speed * dt
                    end
                end
            end,
        })
    end
end

world:addPlugin(spinPlugin(1.5))
```

### Declaring a dependency

A plugin that needs another plugin's resource reads it and fails loudly when it is absent, so the ordering
mistake surfaces at setup rather than as a nil three frames later.

```teal
local SPAWNER <const>: tecs.Key<Spawner> = tecs.ecs.newKey("game.spawner")

local function wavePlugin(world: tecs.World)
    local spawner <const> = world.resources[SPAWNER]
    if not spawner then
        error("wavePlugin requires spawnerPlugin to be installed first")
    end

    world:addSystem({
        name = "game.Waves",
        phase = tecs.ecs.phases.Update,
        runIf = tecs.ecs.runif.every(5.0, 0.5),
        run = function() spawner:release() end,
    })
end
```

Always name a key. A named key is discoverable at run time through `tecs.ecs.findKey` and the tooling built on it,
and calling `tecs.ecs.newKey` again with the same name returns the same key, so values keyed by it survive hot
reload.

### Organizing a plugin as a module

Export the plugin function and the types other code needs from one record:

```teal
-- mygame/plugins/inventory.tl
local tecs <const> = require("tecs")

local record inventory
    record Item
        id: string
        count: number
    end

    plugin: function(world: tecs.World)
end

function inventory.plugin(world: tecs.World)
    -- registration
end

return inventory
```

### Grouping plugins

A plugin that installs other plugins is just a plugin, so a group needs no separate concept:

```teal
local function gameplayPlugins(world: tecs.World)
    world:addPlugin(healthPlugin)
    world:addPlugin(inventory.plugin)
    world:addPlugin(spinPlugin(1.5))
end

world:addPlugin(gameplayPlugins)
```

## The builtin plugin

Constructing a world installs the builtin plugin automatically. It owns the `TTL` countdown and the
`RelativeTransform` composition systems, and the components and events they work on. Nothing has to add it, and
there is no way to opt out. See [Builtins](/ecs/builtins#the-builtin-plugin).

## Practices worth keeping

1. **One purpose per plugin.** A plugin that installs three unrelated systems is three plugins.
2. **Build queries in the plugin body, never in `run`.** A query created per frame rebuilds its archetype match
   set every frame.
3. **Name every system.** `name = "game.Spin"` gives ordering constraints and `world:removeSystem` a handle,
   and it is what the debug server shows.
4. **State your dependencies.** Read the resource you need at setup and error when it is missing.
5. **Export your types.** If a plugin defines components or events other code uses, put them on the module
   record.
