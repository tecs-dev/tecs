---
description: "Set a checkout up, run an example through the Rust host, and write a game component of your own"
order: 20
---

# Getting started

## What a checkout needs

Three things, and only one of them is installed for you:

- **The Nupp compiler on `PATH`.** Use a build that provides
  `nupp.data.binary`; the CI workflow pins a compatible revision. With sibling
  checkouts, run `export PATH="$(cd ../nupp/bin && pwd):$PATH"` from the Tecs
  root to select that compiler.
- **The Rust toolchain** `rust-toolchain.toml` pins. `rustup` fetches it on the
  first build.
- **`stylua` and `prettier`**, which format the Lua manifest and the Markdown.
  `nupp task deps` installs them on macOS. On other platforms, install both on `PATH`.

Running the Rust host also needs a Nupp embedding SDK.
`native/rust/winit-host/build.rs` stages one through the compiler's
`scripts/toolchain`, so a sibling checkout covers it; `NUPP_SDK` names a staged
one instead. The SDK is staged for a named feature set and the runtime refuses
to load a component whose declared features the library lacks, which reads as a
load failure in a host that built cleanly.

## Check, test, run

```bash
nupp check --strict           # Type-check every Nupp source, strictly
nupp test                     # Build native services; require every test to pass
nupp task ex-flatcolor           # Open a window and render the example
nupp task ex-lighting --frames 120
```

`nupp tasks` lists the configured commands. Example build and run tasks use the
`ex-` prefix: `ex-flatcolor`, `ex-sprites`, `ex-lighting`, `ex-tiled`, `ex-ui`,
`ex-uistandalone` and `ex-nativesmoke`. `ex-host` runs the blank host, and
`ex-physicssmoke` runs the bounded native-physics script.

`--frames N` stops after N frames and exits zero, which is what makes a
graphical example usable as a smoke test. It needs at least two: the first
completed frame renders, and the following turn observes the limit.

`nupp test` builds the five native services, selects their exact Cargo
artifact paths, and requires every discovered test to pass with zero skips.
The JSON report is saved to `out/validation/nupp-tests.json`. `nupp test <suite>` narrows the same gate to named suites; `--json` keeps
its structured report. Native libraries remain mandatory. `nupp task test-tools` checks the development
tools in their separate project; `nupp task verify` runs both.

`nupp task verify` requires an embedding SDK. It runs strict checking,
whole-tree formatting, the mandatory test gate, documentation checks, workspace
Rust formatting/Clippy/tests, and eight headless component smokes. Benchmarks
and relocated release-package checks remain separate commands; `verify` does
not claim performance or platform acceptance.

## The Tecs namespace

With Tecs sources in your Nupp project, `tecs` is always available for typed
qualified access. Write `tecs.ecs.newWorld()` or `tecs.gfx.images.upload(...)`
directly. You do not need to require a module, declare a global, or run a setup
function. The same paths name types, such as `tecs.ecs.World`.

Nupp checks the module and member at compile time. It emits one direct import
for each referenced module when the caller loads; dotted calls in a frame loop
do not repeatedly look up or load modules. Only referenced modules load, so an
ECS-only program does not initialize the host or native physics. Type-only
references do not load a module.

This is a compiler-resolved namespace, not a mutable Lua `_G.tecs` table.
Use the full path for type annotations. A local variable named `tecs` shadows
the namespace, so reserve that name for the engine.

## A world without a host

The ECS runs on its own. Nothing below needs a window, a device, or the host.

```nupp
const world = tecs.ecs.newWorld()
const moving = world:newQuery({include = {tecs.ecs.Transform2D}})

world:spawn(tecs.ecs.Transform2D(120, 90, 0, 1, 0, 64, 64), tecs.gfx.Tint(1, 0.4, 0.2, 1), tecs.gfx.Renderable2D)
world:addSystem({
    name = "example.drift",
    phase = tecs.ecs.phases.Update,
    run = function(dt: number): nil
        for candidate, count in moving:iter() do
            local transforms: {tecs.ecs.Transform2D} = assert(candidate:getMut(tecs.ecs.Transform2D))
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

## Squares, circles and other shapes

A drawable entity needs a transform, tint and `Renderable2D`. The transform's
last two arguments set its width and height; equal values produce a square.
Add a material to select another shape:

```nupp
const world = tecs.ecs.newWorld()
world:spawn(
    tecs.ecs.Transform2D(80, 80, 0, 1, 0, 64, 64),
    tecs.gfx.Tint(1, 0.4, 0.2, 1),
    tecs.gfx.Renderable2D
)
world:spawn(
    tecs.ecs.Transform2D(180, 80, 0, 1, 0, 64, 64),
    tecs.gfx.Tint(0.2, 0.6, 1, 1),
    tecs.gfx.Material(tecs.gpu.materials.id("circle")),
    tecs.gfx.Renderable2D
)
```

[`tecs.gpu.materials`](tecs.gpu.materials) describes the other built-in shapes
and their parameters. These are rendered shapes; attach a body through
[`tecs.physics`](tecs.physics) when they also need collision and motion.
Physics uses Rapier. Its batched native interface sends the world's changes
and reads the resulting poses once per fixed step; games need only
`tecs.physics.install`, `attach`, and the other entity-facing operations.

## Maps and interfaces

```bash
nupp task ex-tiled               # TMX map, animated tiles and collision
nupp task ex-ui                  # Compose, Flex, Overlay and Scroll over a lit gradient field
nupp task ex-uistandalone        # Centered panel with scrollable controls
```

[The Tiled guide](tiled/index.md) covers TMX/TSX files, layers, tile edits,
object factories and collision outlines. [Building interfaces](ui/index.md)
composes retained layout with the same shape, sprite and text entities.
Taffy sizes UI boxes; Rapier simulates physical bodies.

## A component of your own

A game is one compiled component exporting a session constructor. The Rust host
selects that export with `--entry`, so no game code is ever dynamically
required.

```nupp
module mygame

--[[
The smallest complete game entry.
]]

local function install(exclusive app: tecs.application.Application): nil
    local width, height = app.window:getSize()
    app.world:spawn(
        tecs.ecs.Transform2D(width * 0.5, height * 0.5, 0, 1, 0, 160, 160),
        tecs.gfx.Tint(0.15, 0.65, 1, 1),
        tecs.gfx.Renderable2D
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
): tecs.host.Session
    return tecs.host.createWithPlugin(install, title or "My game", width, height, debug, maxFrames)
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

Then `nupp task run mygame`. To give the game a short command, add a task:

```lua
tasks = {
    mygame = {
        build = "mygame",
        argv = {"nupp", "run", "tools/run.nupp", "host", "mygame"},
    },
}
```

`nupp task mygame` builds the component before starting its host. The entry defaults to `<target>.create`, so
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
nupp task presets             # The packaging presets and what each produces
nupp task package             # Install a relocatable release into out/package
nupp task check-package       # Gate what it installed
nupp task test-package        # Install, check, and run from a relocated copy
```

A development preset links against the staged SDK where it sits and ships no
shader pack, which is convenient and not shippable. A release preset links a
loader-relative run path and ships the pack, and only a release install passes
`check-package`. `test-package` copies the prefix elsewhere and runs it with an
unrelated working directory and every `TECS_*`, `DYLD_*`, `LD_LIBRARY_PATH` and
`NUPP_SDK` override removed, so it proves the package rather than the build
tree.
