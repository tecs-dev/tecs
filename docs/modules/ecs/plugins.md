---
description: "Plugins provide the one way into a world: entry arguments, composition, and patterns that scale"
outline: deep
---

# Plugins

A plugin configures one world. It registers components, queries, systems,
resources, states, observers, and initial entities.

The application calls its entry plugin after engine subsystem installation and
before startup phases:

```teal
return tecs.newApplication({
    window = {
        title = "My game",
        width = 1280,
        height = 720,
    },
    plugin = function(world: tecs.World, app: tecs.Application)
        world:addPlugin(spinPlugin(1.5))
        world:addPlugin(tecs.gfx.textPlugin({
            renderer = app.renderer,
        }))
    end,
})
```

Game code captures `app` here when a system needs the renderer, window, input,
or audio. Systems and observers provide the per-frame and per-event
lifecycle.

## One-time setup

Declare component types at module scope. Build queries once in the plugin,
then close over them from systems:

```teal
local function spinPlugin(speed: number): tecs.Plugin
    return function(world: tecs.World)
        local spinning <const> = world:newQuery({
            include = {tecs.Transform2D, tecs.gfx.Renderable2D},
            type = "logic",
        })

        world:addSystem({
            name = "game.Spin",
            phase = tecs.ecs.phases.Update,
            run = function(dt: number)
                for archetype, length in spinning:iter() do
                    local transforms <const> =
                        archetype:getMut(tecs.Transform2D)
                    for row = 1, length do
                        transforms[row].rotation =
                            transforms[row].rotation + speed * dt
                    end
                end
            end,
        })
    end
end
```

Never construct a persistent query inside `run`; that rebuilds its match set
every frame. Name every system that needs ordering, removal, or useful debug
output.

## Composition and dependencies

`world:addPlugin` supplies the only composition mechanism. A plugin can install
other plugins:

```teal
local function gameplay(world: tecs.World)
    world:addPlugin(healthPlugin)
    world:addPlugin(inventory.plugin)
    world:addPlugin(spinPlugin(1.5))
end
```

Pass configuration through a closure, as `spinPlugin` does. This keeps
configuration typed and immutable inside the installed systems.

A plugin that depends on another should read the required resource during
setup and fail immediately:

```teal
local SPAWNER <const>: tecs.data.Key<Spawner> =
    tecs.data.Store.newKey("game.spawner")

local function wavePlugin(world: tecs.World)
    local spawner <const> = world.resources[SPAWNER]
    if not spawner then
        error("wavePlugin requires spawnerPlugin")
    end

    world:addSystem({
        name = "game.Waves",
        phase = tecs.ecs.phases.Update,
        runIf = tecs.ecs.runif.every(5, 0.5),
        run = function()
            spawner:release()
        end,
    })
end
```

Always name resource keys. Re-registering one name returns the same key, which
supports hot reload and lets tooling discover the dependency through
`tecs.data.Store.listKeys`.

Export component and event types beside the plugin function when other modules
need them. Keep one purpose per plugin, then group related plugins with another
plugin.

World construction installs the [builtin plugin](/modules/ecs/builtins#builtin-plugin)
automatically.
