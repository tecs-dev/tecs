---
description: "Set a checkout up, run an example through the Rust host, and write a game component of your own"
order: 20
---

# Getting started

## What a checkout needs

Three things, and only one of them is installed for you:

- **The Nupp compiler.** `cargo xtask` looks for `NUPP`, then a `nupp` checkout
  beside this one, then a `nupp` on `PATH`, in that order. The sibling checkout
  wins over an installed release because this tree is developed against a
  compiler newer than the published one.
- **The Rust toolchain** `rust-toolchain.toml` pins. `rustup` fetches it on the
  first build.
- **`stylua` and `prettier`**, which format the Lua manifest and the Markdown.
  `cargo xtask deps` installs them and reports where the Nupp compiler
  resolved.

Running the Rust host also needs a Nupp embedding SDK.
`native/rust/winit-host/build.rs` stages one through the compiler's
`scripts/toolchain`, so a sibling checkout covers it; `NUPP_SDK` names a staged
one instead. The SDK is staged for a named feature set and the runtime refuses
to load a component whose declared features the library lacks, which reads as a
load failure in a host that built cleanly.

## Check, test, run

```bash
cargo xtask check              # Type-check every Nupp source, strictly
cargo xtask test               # Build and run the test suites
cargo xtask run flatcolor      # Open a window and render the example
cargo xtask run lighting -- --frames 120
```

`cargo xtask targets` lists what the manifest configures. `flatcolor`,
`sprites` and `lighting` are the examples; `host` is the blank host, which
opens a window and runs an empty world.

`--frames N` stops after N frames and exits zero, which is what makes a
graphical example usable as a smoke test. It needs at least two: the first
completed frame renders, and the following turn observes the limit.

`cargo xtask verify` runs the whole gate in the order that fails cheapest
first, and is what to run before pushing.

## A world without a host

The ECS runs on its own. Nothing below needs a window, a device, or the host.

```nupp
local ecs = require("tecs.ecs")
local gfx = require("tecs.gfx")

const world = ecs.newWorld()
const moving = world:newQuery({include = {ecs.Transform2D}})

world:spawn(ecs.Transform2D(120, 90, 0, 1, 0, 64, 64), gfx.Tint(1, 0.4, 0.2, 1), gfx.Renderable2D)
world:addSystem({
    name = "example.drift",
    phase = ecs.phases.Update,
    run = function(dt: number): nil
        for candidate, count in moving:iter() do
            local transforms: {ecs.Transform2D} = assert(candidate:getMut(ecs.Transform2D))
            for index = 1, count as integer do
                transforms[index].x = transforms[index].x + dt * 30
            end
        end
    end,
})

world:update(1 / 60)
```

Two rules carry most of the weight. Reads go through `world:get` and
`archetype:get`; writes go through `getMut`, which is what marks the column
dirty for every consumer downstream, the GPU included. And a system's name is
an externally typed string: the debug server reports it and an agent selects on
it, so it does not move because a module did.

## A component of your own

A game is one compiled component exporting a session constructor. The Rust host
selects that export with `--entry`, so no game code is ever dynamically
required.

```nupp
module mygame

--[[
The smallest complete game entry.
]]

local application = require("tecs.application")
local ecs = require("tecs.ecs")
local gfx = require("tecs.gfx")
local host = require("tecs.host")

local function install(exclusive app: application.Application): nil
    local width, height = app.window:getSize()
    app.world:spawn(
        ecs.Transform2D(width * 0.5, height * 0.5, 0, 1, 0, 160, 160),
        gfx.Tint(0.15, 0.65, 1, 1),
        gfx.Renderable2D
    )
end

--- Creates the game's host session through its statically linked plugin.
--- @param title the desktop title
--- @param width the initial logical width
--- @param height the initial logical height
--- @param debug whether guarded application failures may be cleared
--- @param maxFrames an optional positive frame limit
--- @return the session retained by the Rust host
export function create(
    title: string?,
    width: integer?,
    height: integer?,
    debug: boolean?,
    maxFrames: integer?
): host.Session
    return host.createWithPlugin(install, title or "My game", width, height, debug, maxFrames)
end
```

`nupp.lua` is what turns that file into a component. Add a target naming both
`tecs.host` and the module, and export `mygame.create` alongside the host's own
exports:

```lua
mygame = {
    kind = "component",
    description = "Build my game",
    entries = {"tecs.host", "mygame"},
    exports = mygameExports,
}
```

Then `cargo xtask run mygame`. The entry defaults to `<target>.create`, so
nothing else has to be named.

::: warning
A `src/tecs/**.nupp` module that is not listed in the `headless` target's
`entries` is neither built nor checked. A new module has to be added there.
:::

## Application services

Use `host.newSession` in your component constructor when it needs settings
beyond the convenience constructor:

```nupp
return host.newSession({
    plugin = install,
    window = {title = title or "My game", width = width, height = height},
    world = {nominalFrameTime = 1 / 60},
    debug = debug == true,
    debugMaxFrames = maxFrames,
    mcpPort = debug == true and 7100 or nil,
})
```

The application provides `app.assets`. A request can suspend startup or an
update while the Rust host continues polling. Release settled asset handles in
your shutdown systems; the application stops outstanding acquisitions after
world shutdown and closes its optional MCP listener even after a game failure.

Nil `mcpPort` disables the listener. Zero chooses a free port, reported by
`app.debugServer.port` after initialization. The host keeps diagnostics available
while gameplay is suspended, parked or crashed. World-touching tools refuse a
parked operation rather than changing a world halfway through its update.

`nominalFrameTime` controls how sequence frame and presentation waits convert
seconds into ticks. It is local to the world and independent of measured frame
deltas; changing it affects future waits only. Fixed waits continue to use the
world's fixed timestep.

Physics supplies `ecs.PreviousTransform2D` for presentation interpolation. It
starts at the creation pose and is refreshed before later fixed steps, so the
first rendered movement does not interpolate from the origin. Entities without
that component render directly from their current transform.

## Packaging

```bash
cargo xtask presets            # The packaging presets and what each produces
cargo xtask package            # Install a relocatable release into out/package
cargo xtask check-package      # Gate what it installed
cargo xtask test-package       # Install, check, and run from a relocated copy
```

A development preset links against the staged SDK where it sits and ships no
shader pack, which is convenient and not shippable. A release preset links a
loader-relative run path and ships the pack, and only a release install passes
`check-package`. `test-package` copies the prefix elsewhere and runs it with an
unrelated working directory and every `TECS_*`, `DYLD_*`, `LD_LIBRARY_PATH` and
`NUPP_SDK` override removed, so it proves the package rather than the build
tree.
