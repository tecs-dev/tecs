---
description: "Build the engine, write an entry file that returns an application, and register a game as one plugin"
outline: deep
---

# Getting started

Tecs is a typed entity component system and the game engine built around it, written in Teal for LuaJIT. The two
are one project: the ECS knows what the GPU reads, and the engine is not a layer bolted on top of a
renderer-agnostic core.

Entities are the interface. Anything that renders or updates per frame is an entity in a world.

## Building the engine

CMake is canonical and Make wraps it, so there is one description of how the tree is assembled.

```bash
make deps     # install development dependencies (Homebrew)
make build    # build the selected preset
make run      # run the demo
```

`PRESET=` selects the target and defaults to `macos-arm64-dev`; `make presets` lists the matrix. A development
preset resolves dependencies from the system, which is convenient and not shippable. A packaged preset builds
pinned revisions from source, and `make check-package` is the gate on the difference.

::: info There is no CLI yet
The previous project shipped a `tecs` command that scaffolded, built and packaged games. It is planned here and
not built. See [the CLI](/cli/).
:::

## The surface

`require("tecs")` is the whole surface, ECS and engine together.

```teal
local tecs <const> = require("tecs")
```

`tecs` is also a global, set by the module itself as it returns, so a game can write `tecs.newWorld()` in any file
with no require line. It is the same table `require` gives back, metatable included. Engine modules resolve on
first field access, so `require("tecs")` alone loads no engine module and a headless tool, a test or a server
never demands a graphics stack.

Teal types the global through `src/tecs/global.d.tl`, which reads the type off the module rather than restating
it, so the two cannot drift. A game names that declaration in its own `tlconfig.lua`:

```lua
return {
    global_env_def = "tecs.global",
    include_dir = {
        "<luajit-tl-type>",          -- ffi, bit, jit, string.buffer
        "<prefix>/share/tecs/teal",  -- tecs
    },
}
```

`tl check` then reports `tecs.newWorldd()` as an invalid key at the line that wrote it.

## The entry file

SDL owns the loop. An entry file does not run until done; it returns an application, and a C host drives it
through `SDL_AppInit`, `SDL_AppEvent`, `SDL_AppIterate` and `SDL_AppQuit`. A platform that never hands control
back has no loop to block in, which is why the shape is this and not a `run()`.

```teal
local tecs <const> = require("tecs")

return tecs.application({
    plugin = function(world: tecs.World, app: tecs.Application)
        -- register systems, observers and entities here
    end,
})
```

There is one entry point rather than a list of callbacks. `Application.Config` carries `plugin`, a single
`function(world, app)`, and nothing else a game supplies is called by the loop, because the ECS already answers
every question a callback would have. See [`Application`](/modules/Application) for the rest of the config.

The four callbacks a loop-shaped engine would hand you map onto machinery that was already there:

| Would have been | Is instead                                | Run by           |
| --------------- | ----------------------------------------- | ---------------- |
| `load`          | `PreStartup`, `Startup`, `PostStartup`    | `world:startup`  |
| `update`        | `First` through `Last`, fixed or not      | `world:update`   |
| `event`         | `world:observe(0, tecs.events.on.<kind>)` | the event drain  |
| `quit`          | `PreShutdown`, `Shutdown`, `PostShutdown` | `world:shutdown` |

A system's order is declared by the phase it is registered in rather than being implicit in where the loop happens
to call it; a system and an observer are both registered on the world, so the debug server lists them; and both
run inside the crash guard, so a line that fails leaves a traceback and a live process.

## A first plugin

The entry plugin is handed the world and the application, in that order. The world comes first because every
plugin the world takes is `function(world)`, so the entry reads as that shape with one more thing.

```teal
local tecs <const> = require("tecs")
local Transform <const> = tecs.builtins.Transform

return tecs.application({
    plugin = function(world: tecs.World, app: tecs.Application)
        local movers = world:query({ include = { Transform } })

        world:addSystem({
            name = "game.Spin",
            phase = tecs.phases.Update,
            run = function(dt: number)
                for archetype, length in movers:iter() do
                    local transforms = archetype:getMut(Transform)
                    for row = 1, length do
                        transforms[row].rotation = transforms[row].rotation + dt
                    end
                end
            end,
        })

        world:spawn(Transform(100, 100))
    end,
})
```

Three rules that this snippet is following, and that prevent the most common defect class:

- Create queries once, during plugin setup. Never inside `run`.
- Reads use `archetype:get`; writes go through `archetype:getMut`, which marks the component's column dirty. Never
  take `getMut` in a loop that might not write: it defeats every dirty-gated consumer.
- Keep `query:iter()` for loops that run to exhaustion. A loop that may `break` or return early uses
  `query:cursor()` and closes it. See [the mutation model](/ecs/mutation-model).

A game with several modules calls `world:addPlugin` from inside its entry plugin, so there is one composition
mechanism rather than two.

## Where to go next

- [The ECS](/ecs/): worlds, components, queries, systems, events, states and snapshots.
- [The module reference](/modules/): one page per module on the public surface.
- [The design record](https://github.com/tecs-dev/tecs/blob/main/README.md): why the engine is shaped as it is.
