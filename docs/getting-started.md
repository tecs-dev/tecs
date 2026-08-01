---
description: "Build Tecs, return an application from an entry file, and register a first game plugin"
sidebar_order: 10
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
cargo xtask example ui-demo
cargo xtask example scene3d
cargo xtask example gltf3d
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
local Transform2D <const> = tecs.Transform2D

return tecs.newApplication({
    plugin = function(world: tecs.World, app: tecs.Application)
        local movers <const> = world:newQuery({
            include = {Transform2D},
        })

        world:addSystem({
            name = "game.Spin",
            phase = tecs.ecs.phases.Update,
            run = function(dt: number)
                for archetype, length in movers:iter() do
                    local transforms <const> = archetype:getMut(Transform2D)
                    for row = 1, length do
                        transforms[row].rotation =
                            transforms[row].rotation + dt
                    end
                end
            end,
        })

        world:spawn(Transform2D(100, 100))
    end,
})
```

Keep three rules visible when writing systems:

- Create persistent queries during plugin setup.
- Read columns with `get` and mark written columns with `getMut`.
- Run `query:iter()` to exhaustion. Use `query:newCursor()` and close it when a
  loop may stop early.

The [mutation model](/modules/ecs/mutation-model) covers deferred changes and dirty
tracking.

## Optional transparent meshes

Opaque mesh rendering keeps its original three-pass cull chain. Enable the
separate transparent resources only when a game needs glTF `BLEND` materials
or registers an `ALPHA_BLEND` material itself:

```teal
return tecs.newApplication({
    sprites = false,
    meshes = {
        transparency = true,
    },
    plugin = function(world: tecs.World, app: tecs.Application)
        tecs.assets.loadGLTF(
            tecs.io.files.assetPath("models/glass.gltf")
        ):onSettle(function(loaded: tecs.Future<tecs.assets.Model>)
            if loaded.status ~= "ready" then
                error(loaded.error, 0)
            end
            for _, primitive in ipairs(
                app.renderer.meshes:registerModel(loaded.value)
            ) do
                world:spawn(
                    primitive.transform,
                    primitive.mesh,
                    primitive.bounds,
                    primitive.material,
                    tecs.gfx.Tint(),
                    tecs.gfx.Renderable3D()
                )
            end
        end)
    end,
})
```

The mesh domain frustum-culls and depth-sorts complete indexed commands on the
GPU. It draws transparent meshes before the sprite forward lane, so sprites
retain deterministic overlay ordering in a renderer that enables both domains.

## Optional mesh shadows

Enable the mesh domain's directional light and shadow resources at renderer
creation:

```teal
return tecs.newApplication({
    ambientLight = {0.12, 0.13, 0.16},
    sprites = false,
    meshes = {
        shadows = {
            scale = 1,
            distance = 40,
            directionX = -0.45,
            directionY = -1,
            directionZ = -0.3,
            intensity = 1.4,
            strength = 0.85,
            softness = 1.5,
        },
    },
    plugin = function(_world: tecs.World, app: tecs.Application)
        -- Everything except scale remains mutable after creation.
        app.renderer.meshes.shadow.bias = 0.002
    end,
})
```

`scale` fixes the map size and is creation-only. The other fields are copied
to `app.renderer.meshes.shadow` and may change between frames. `distance` is
the half extent of a camera-centered light volume; meshes outside it are
removed by the same ordered GPU mark, scan, and compact shape used for camera
culling. Culling rejects complete mesh instances; one surviving mesh still
draws its full resident index range. Opaque and masked materials cast and
receive. Blended materials receive but do not cast.

Omitting `meshes.shadows` preserves the shadow-free mesh shaders and allocates
no map, shadow command buffer, cull pipeline, or graphics pipeline. The 2D
`shadows` application option remains a separate occluder and drop-shadow
system.

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

- [tecs.ecs](/modules/ecs/) introduces worlds, components, queries, and systems.
- [Modules](/modules/) lists every public engine module.
- [Tecs CLI](/cli/) covers project commands and the offline reference.
