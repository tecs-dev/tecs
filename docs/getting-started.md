---
description: "Build Tecs, return an application from an entry file, and register a first game plugin"
outline: deep
---

# Getting started

Tecs combines a typed entity component system with a game engine for Teal and
LuaJIT. Game state, rendering, audio, physics, and tools share the same world.

## Install the CLI

The [Tecs CLI](/cli/) carries the engine, project toolchain, template, and
offline reference:

```bash
tecs new my-game
cd my-game
tecs run
```

The generated `tecs.lua` marks the project root and names its entry file.
Project commands work from any directory below it.

## Build this repository

Contributors build the engine through Cargo:

```bash
git clone https://github.com/tecs-dev/tecs.git
cd tecs
cargo xtask deps
cargo xtask build
cargo xtask test
cargo xtask run
```

`cargo xtask deps` installs system development dependencies. The repository
pins Teal, the formatter, and tealdoc revisions for every checkout.

`--preset` selects a target. Development presets use system libraries. Package
presets build pinned dependencies from source:

```bash
cargo xtask presets
cargo xtask test   # run Rust, ABI, and Lua/Teal tests
cargo xtask package --preset macos-arm64
cargo xtask check-package out/package
```

## Entry file

The host owns the loop. The entry file returns an application:

```teal
return tecs.newApplication({
    window = {
        title = "Hello",
        width = 1280,
        height = 960,
    },
    plugin = function(world: tecs.World, app: tecs.Application)
        -- Register the game here.
    end,
})
```

The host loads `tecs` before the entry file, so game code uses it as a global.
A headless script or spec loads the same table explicitly:

```teal
local tecs <const> = require("tecs")
```

See [`tecs.Application`](/modules/Application) for lifecycle and configuration.

## First plugin

The entry plugin registers systems, observers, resources, and entities:

```teal
local Transform <const> = tecs.Transform

return tecs.newApplication({
    plugin = function(world: tecs.World, app: tecs.Application)
        local movers <const> = world:query({
            include = {Transform},
        })

        world:addSystem({
            name = "game.Spin",
            phase = tecs.ecs.phases.Update,
            run = function(dt: number)
                for archetype, length in movers:iter() do
                    local transforms <const> = archetype:getMut(Transform)
                    for row = 1, length do
                        transforms[row].rotation =
                            transforms[row].rotation + dt
                    end
                end
            end,
        })

        world:spawn(Transform(100, 100))
    end,
})
```

Keep three rules visible when writing systems:

- Create persistent queries during plugin setup.
- Read columns with `get` and mark written columns with `getMut`.
- Run `query:iter()` to exhaustion. Use `query:cursor()` and close it when a
  loop may stop early.

The [mutation model](/ecs/mutation-model) covers deferred changes and dirty
tracking.

## Game modules

Split a game into plugins and install them from the entry plugin:

```teal
local movement <const> = require("game.movement")
local enemies <const> = require("game.enemies")

return tecs.newApplication({
    plugin = function(world: tecs.World, app: tecs.Application)
        world:addPlugin(movement.plugin)
        world:addPlugin(enemies.plugin)
    end,
})
```

The host adds the project content root to `package.path`, so
`require("game.enemies")` loads `game/enemies.lua`.

## Next pages

- [tecs.ecs](/ecs/) introduces worlds, components, queries, and systems.
- [Modules](/modules/) lists every public engine module.
- [Tecs CLI](/cli/) covers project commands and the offline reference.
