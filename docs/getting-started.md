---
description: "Build the engine, write an entry file that returns an application, and register a game as one plugin"
outline: deep
---

# Getting started

Tecs is a typed entity component system and the game engine built around it, written in Teal for LuaJIT. The two
are one project: the ECS knows what the GPU reads, and the engine is not a layer bolted on top of a
renderer-agnostic core.

Entities are the interface. Anything that renders or updates per frame is an entity in a world.

## Installation

The [Tecs CLI](/cli/) is a single executable carrying the engine, project
toolchain, templates, and offline reference. To work on the engine itself,
build from a checkout:

```bash
git clone https://github.com/tecs-dev/tecs.git
cd tecs
cargo xtask deps   # install development dependencies (Homebrew)
cargo xtask build  # build the host's development preset
cargo xtask run    # run the demo
```

`cargo xtask deps` is the only step that touches the machine outside this directory, and on macOS it is
Homebrew. It installs what the engine links against and the development tools the build runs: the Teal compiler,
the formatter and the documentation generator land in `vendor/`, pinned by revision in the Cargo build-support
crate, so every checkout formats and type-checks with the same versions rather than whatever a machine happens
to have.

Nothing is installed globally by these commands. `cargo xtask single` writes a
self-contained CLI to `out/single/bin/tecs`; putting that file on `PATH`
provides the project commands. A game can instead be built and run through
Cargo from this tree, which is what the rest of this page does.

## Building the engine

Cargo is the project build and `cargo xtask` owns assembly, generation, tests, packaging, and maintenance.

```bash
cargo xtask build  # build the selected preset
cargo xtask test   # run the spec suite
cargo xtask check  # type-check Teal sources
```

`--preset` selects the target and defaults to the host's development preset; `cargo xtask presets` lists the
matrix. A development preset resolves dependencies from the system, which is convenient and not shippable. A
packaged preset builds pinned revisions from source, and `cargo xtask check-package` is the gate on the
difference.

## Reaching the engine

`tecs` is ambient in a game. The module installs itself as a global as it returns, and the host has already
loaded it by the time an entry file runs, so every file in a game reaches `tecs.ecs.newWorld()` and
`tecs.gfx.Camera` with no require line. It is the same table `require` gives back, metatable included, so a
headless tool or a spec that does not go through the host writes `local tecs <const> = require("tecs")` first
and gets exactly that.

Every module but `tecs.ecs` resolves on first field access, so loading `tecs` loads no engine module and a
headless tool, a test or a server never demands a graphics stack.

A game's own modules resolve the same way. The host puts the content root on `package.path` before it loads
anything, so `require("game.enemies")` finds `game/enemies.lua` beside the entry chunk with no path setup in the
entry file. A development run overrides the root with `TECS_LUA`, which is how it reads out of a build tree
rather than out of an installed one.

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

`tl check` then reports `tecs.ecs.newWorldd()` as an invalid key at the line that wrote it.

## Entry file

SDL owns the loop. An entry file does not run until done; it returns an application, and a Rust host drives it
through `SDL_AppInit`, `SDL_AppEvent`, `SDL_AppIterate` and `SDL_AppQuit`. A platform that never hands control
back has no loop to block in, which is why the shape is this and not a `run()`.

```teal
return tecs.newApplication({
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
local Transform <const> = tecs.Transform

return tecs.newApplication({
    plugin = function(world: tecs.World, app: tecs.Application)
        local movers = world:query({ include = { Transform } })

        world:addSystem({
            name = "game.Spin",
            phase = tecs.ecs.phases.Update,
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
- [The module reference](/modules/): one page per module a game can reach.
