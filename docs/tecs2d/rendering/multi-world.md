---
description: "Advanced guide to isolated render worlds, shared GPU resources, independent clocks, and ordered canvas compositing"
outline: deep
---

# Multiple render worlds and compositing

::: warning Advanced topic
Most games should use one world and one render pipeline. Use additional
[cameras](./camera) when you need another view of the same simulation, such as
a minimap or split screen. Add another world only when the entities, systems,
clock, or lifecycle must be isolated.
:::

A useful rule is:

```text
Camera = another view of one reality
World  = another independently updated reality
Canvas = how those realities are presented together
```

The debugger is the built-in example. Its UI, shapes, Text, and Sprite previews
live in a small tool world, while its completed image is composited over the
game. Freezing or mutating the tool world cannot change game entities.

## Ownership model

A renderable world owns exactly one pipeline for its lifetime.
`gfx.newPipeline` rejects a second pipeline for the same world. Pipelines are
not attached, detached, or moved between worlds.

This invariant provides two useful guarantees:

- A render component always has one unambiguous world and pipeline.
- Normal entity iteration never performs a per-entity pipeline lookup.

The pipeline created by `tecs2d.run` is the **primary pipeline**. It renders
automatically during the world's `Render` phase. A pipeline configured with
`composite = true` is a **composite pipeline**. Its owner updates and renders
it explicitly at the desired composition point.

All pipelines automatically use the same process-owned GPU device resources.
No pipeline is the resource parent of another pipeline. `composite` controls
presentation only: it does not change world ownership or GPU resource sharing.

Every pipeline exposes a stable generational identity through
`pipeline:getWorldId()`. Entity IDs remain local to their world: two worlds may
contain the same numeric entity ID without referring to the same entity.

## Choosing a camera or a world

| Requirement | Prefer |
| --- | --- |
| Minimap of current gameplay | Another camera |
| Split-screen view of current gameplay | Another camera |
| Security camera or mirror showing current gameplay | Another camera |
| Debugger/editor entities that must not enter gameplay | Another world |
| Character or asset preview with a separate lifecycle | Another world |
| Replay showing a different point in time | Another world |
| Pause UI that advances while gameplay is frozen | Another world |
| Prediction, rollback, testing, or AI planning | Another non-rendered or rendered world |

If two sets of entities must continuously share physics, relationships,
queries, lighting, or depth ordering, they normally belong in one world.

## Creating a secondary render world

The following plugin creates a small unlit tool world after `tecs2d.run` has
already created the game pipeline:

```teal
local tecs <const> = require("tecs")
local gfx <const> = require("tecs2d.gfx")
local ui <const> = require("tecs2d.ui")

local function game(world: tecs.World)
    local tools = tecs.newWorld({maxEntities = 4096})

    local toolsPipeline = gfx.newPipeline({
        world = tools,
        composite = true,
        lightingMode = "none",
        lerpingEnabled = false,
        layers = {
            [1] = {name = "tools", space = "screen", unlit = true},
        },
        sizeHints = {
            sprites = 8,
            circles = 32,
            lines = 128,
            rects = 256,
            textEntities = 256,
            textGlyphs = 8192,
        },
    })

    tools:addPlugin(ui.plugin)
    tools:startup()

    world:addSystem({
        name = "game.CompositeTools",
        phase = tecs.phases.RenderLast,
        before = {"love.Present"},
        run = function(dt)
            tools:update(dt)
            toolsPipeline:render()
        end,
    })

    world:addSystem({
        name = "game.ShutdownTools",
        phase = tecs.phases.PreShutdown,
        run = function()
            tools:shutdown()
        end,
    })
end
```

The secondary world is otherwise a normal Tecs world. It can install plugins,
define components, run systems, use UI layout, and render all standard Tecs2D
drawable components.

## Loading screens

A loading world is useful when the alternative is adding loading-state predicates to gameplay systems. Suspend the
gameplay world instead:

```teal
local suspension <const> = require("tecs2d.suspension")

suspension.suspend(gameWorld, "assets.loading")
-- Create and explicitly update a small secondary UI world.
-- After its LoadBatch completes and its final frame is composited:
suspension.resume(gameWorld, "assets.loading")
```

See [World suspension](/tecs2d/suspension) for suspension ownership and phase semantics.

Suspension disables gameplay phases from `First` through `Last`, but leaves render phases active. Each feature owns an
independent suspension claim, so the loading screen cannot resume a world that the debugger or MCP also suspended.
`tecs2d.run` updates the process-global worker queue outside world phases, so asset loading continues while the gameplay
world is suspended.

Do not pass the suspended world's scaled `dt` to the loading world—it is zero. Measure real time for the secondary world,
clamp large deltas, and update it explicitly in `RenderLast` before calling its pipeline's `render()`. Share the runtime
services through the global `tecs2d.assets` and `tecs2d.workers` facades. Neither world owns those services, and a
secondary world must not replace or shut down the runtime manager or queue.

On completion, render the loading world's final frame, shut that world down to release its pipeline, then release the
loading suspension. On application shutdown, shut down the secondary world before the primary world finishes shutdown.
The [assets example](https://github.com/tecs-dev/tecs/tree/main/examples/assets) implements this complete pattern with
normal Tecs UI components and a `LoadBatch`.

## How compositing works

Each composite pipeline renders a complete image independently before blending
that image over the caller's current render target:

```text
game world ────────────── render ───────────┐
                                            ├─ window or parent canvas ─ Present
tool world ─ render to transparent canvas ─┘
```

Calling a composite pipeline's `render()` performs these operations:

1. Clear the composite pipeline's persistent output canvas to transparent.
2. Upload and render that world's entities using its cameras and effects.
3. Restore the render target that was active before the call.
4. Draw the completed canvas with premultiplied-alpha blending.

The active target may be the window or another canvas. Tecs2D manages the
internal blend mode; callers do not need to change it.

Transparent pixels preserve previously rendered content. Worlds do not share
depth, lighting, camera state, or post-processing. Consequently, an entity in
one world cannot be inserted between entities in another world by changing its
`z` value. Cross-world ordering happens only at the completed-canvas level.

### Composition order

Composite pipelines are blended in call order, back to front:

```teal
-- The game pipeline has already rendered automatically.
replayPipeline:render()
debugPipeline:render()
modalPipeline:render()
```

This produces:

```text
game → replay → debugger → modal
```

Use `RenderLast` with `before = {"love.Present"}` for overlays that should
appear over the primary world. Other scheduling is valid when a different
composition order is required.

## Independent clocks and cadence

Pipeline time belongs to the pipeline's world. It advances from the `dt` passed
to that world's `update(dt)`:

```teal
game:update(0)                 -- frozen
menu:update(realDt)            -- continues normally
replay:update(realDt * 2)      -- fast-forward
preview:update(1 / 60)         -- deterministic fixed step
```

A composite pipeline is never rendered automatically. The owner may render it
every frame, at a reduced frequency, or only after its contents change. Updating
and rendering are separate decisions.

## Resource sharing and isolation

GPU ownership is split explicitly at the device and pipeline boundary:

- Process/device resources contain compiled shaders, fallback textures,
  sprite texture arrays, the material registry and compiled variants, shared
  animation timing data, GPU retirement state, and compatible transient
  targets that sequential pipelines can reuse.
- Each pipeline owns the mutable state derived from its world, including
  archetype shadows, instance and cull-output buffers, cameras, and persistent
  output canvases.

This split is automatic. A pipeline never needs a reference to another
pipeline merely to reuse GPU resources.

| State | Owner | Behavior |
| --- | --- | --- |
| Entities, systems, queries, resources, state stack | World | Isolated |
| Clock | World/pipeline | Advances only from that world's update |
| Camera, layers, lights, effects, and depth | Pipeline | Isolated |
| Sprite callbacks and Text slabs/metadata | World | Isolated even when entity IDs collide |
| Runtime system enable/disable state | World | Same system name can differ by world |
| Entity GPU buffers and output canvas | Pipeline | Independently mutable |
| Shaders, texture arrays, material registry and variants, timing data | Process/device | Shared |
| Compatible G-buffers and transient GPU targets | Process/device scratch pool | Reused by sequential renders |
| Input layer stack and OS input binding | Process | One explicit gameplay owner |
| MCP transport and command registry | Process/session | One operator session |

Do not render pipelines concurrently. Transient targets are designed for
ordered, sequential composition on Love's render thread.

## Capacity and performance

Each world controls several independent costs:

- `tecs.newWorld({maxEntities = ...})` sets its hard entity capacity.
- Pipeline `sizeHints` set initial GPU capacities; buffers may grow beyond them.
- Lighting, shadows, bloom, effects, and resolution determine render cost.
- The owner controls update and render frequency.

Core ECS cost is proportional to the contents and systems of that world.
Renderable worlds additionally own mutable GPU buffers and a persistent output
canvas, so they are not free. Sharing avoids recompiling common shaders and
duplicating compatible transient targets.

Adding a secondary world does not add work to every entity in the primary
world. Sprite remains 24 bytes, retains approximately four million available
entity slots, and carries no per-frame pipeline-selection branch. The compact
owner token supports 63 simultaneously live render worlds and detects stale
references across generational slot reuse.

For small tools, prefer small `maxEntities` and `sizeHints`, disable lighting,
and skip `render()` when the output is not visible or has not changed.

## Boundaries and limitations

- Entity IDs are meaningful only with their owning world.
- Queries, relationships, physics, lighting, and depth never cross worlds.
- Cross-world communication must be explicit through copied data, events, or
  an application-owned bridge.
- Process services may be shared by reference, but must have exactly one update and shutdown owner.
- A composite pipeline must be shut down by shutting down its world.
- `composite` is fixed at pipeline creation; there is no attach/detach API.
- `sizeHints` are initial capacities, not enforced GPU-memory budgets.
- Tecs2D does not currently enforce frame-time or GPU-memory quotas per world.

These boundaries are intentional. If a design needs constant cross-world
synchronization, use one world with cameras, layers, states, or tags instead.

## Debugger architecture

The [debug plugin](/tecs2d/debug) uses this design directly:

- a dedicated world capped at 4096 entities;
- the normal UI plugin and `LayoutBox` positioning;
- Rectangle, Line, Circle, Text, and Sprite components;
- an unlit composite pipeline using the process GPU device;
- a raw independent clock;
- composition in `RenderLast`, immediately before presentation.

This makes the debugger a consumer of the same public rendering and UI
facilities used by games while keeping all of its mutable state outside the
game world.
