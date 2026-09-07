---
description: "Plugins provide the one way into a world: entry arguments, composition, and patterns that scale"
outline: deep
---

# Plugins

A plugin configures one world. It registers components, queries, systems,
resources, states, observers, and initial entities.

The application calls its entry plugin after engine subsystem installation and
before startup phases:

```nupp
local function install(exclusive app: tecs.application.Application): nil
    spinPlugin(app.world, 1.5)
    tecs.gfx.text.install(app.world)
end

-- A component's exported constructor returns this session.
local session = tecs.host.newSession({
    window = {title = "My game", width = 1280, height = 720},
    plugin = install,
})
```

Capture the particular world, window, or input value a later system needs. Systems and observers provide the per-frame and per-event
lifecycle.

## One-time setup

Declare component types at module scope. Build queries once in the plugin,
then close over them from systems:

```nupp
local function spinPlugin(exclusive world: tecs.ecs.World, speed: number): nil
    local spinning = world:newQuery({
        include = {tecs.ecs.Transform2D, tecs.gfx.Renderable2D},
        exclude = {tecs.ecs.Disabled, tecs.ecs.Paused},
    })
    world:addSystem({
        name = "game.Spin",
        phase = tecs.ecs.phases.Update,
        run = function(dt: number): nil
            for archetype, count in spinning:iter() do
                local transforms = assert(archetype:getMut(tecs.ecs.Transform2D))
                for row = 1, count as integer do
                    transforms[row].rotation = transforms[row].rotation + speed * dt
                end
            end
        end,
    })
end
```

Never construct a persistent query inside `run`; that rebuilds its match set
every frame. Name every system that needs removal or useful debug output.

## Composition and dependencies

A plugin can call other installation functions:

```nupp
local function gameplay(exclusive app: tecs.application.Application): nil
    healthPlugin(app.world)
    inventoryPlugin(app.world)
    spinPlugin(app.world, 1.5)
end
```

Pass configuration through arguments or a closure. Keep configuration typed and
immutable inside the installed systems. A plugin that depends on another
should read its required resource during setup and fail immediately if absent.

Export component and event types beside the plugin function when other modules
need them. Keep one purpose per plugin, then group related plugins with another
plugin.
