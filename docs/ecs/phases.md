---
description: "Game-loop phase groups, what the engine runs in each, and the enablePhase, disablePhase, registerPhase, and runPhase world methods"
outline: deep
---

# Phases

Tecs divides its game loop into _phases_. Add [systems](/ecs/systems) to phases to run game logic at
specific points: when the game starts, each frame update, frame render, and shutdown.

Phases are not advice. They are how the engine composes itself: input latching, transform snapshotting, physics,
animation, text layout, audio and render extraction are all systems the engine registers into named phases, and a
game's systems interleave with them by declaring a phase rather than by being called from somewhere.

[`Application`](/modules/application) drives all three groups. It runs the game's plugin, then `world:startup()`
once, then `world:update(dt)` per iteration, then `world:shutdown()` at teardown. Nothing else calls back into a
game per frame: a phase is where per-frame work is declared, and the three groups are the whole lifecycle.

Events are the exception, and they are not in a phase at all. A platform event is delivered to its observers as
it arrives, ahead of `world:update`, so an observer runs before every system in the frame the event belongs to
and gets none of the fixed step, pause or state gating a phase carries. See
[An observer is not a system](/ecs/events#an-observer-is-not-a-system).

## Phase groups

Tecs organizes phases into hierarchical groups. The whole tree hangs off `tecs.ecs.phases.AllGroups`.

### StartupGroup

One-time initialization phases run when `world:startup()` is called.

- `PreStartup` - Critical initialization before main startup
- `Startup` - Main startup phase
- `PostStartup` - Final setup after startup

`Application` runs this group after the game's plugin has registered everything, and before the first frame, so
what startup spawned is resident before that frame is extracted and its cost lands outside the first frame's `dt`.

### MainGroup

The main game loop that runs every frame when `world:update(dt)` is called.

- `First` - Very start of each frame
- `PreUpdate` - Before main update
- **`FixedUpdateGroup`** - Fixed timestep loop (may run 0-N times per frame)
  - `FixedFirst` - Start of fixed update iteration
  - `FixedPreUpdate` - Preparation for game logic
  - `FixedUpdate` - Main game logic and physics
  - `FixedPostUpdate` - After game logic
  - `FixedLast` - End of fixed update iteration
- `Update` - Variable timestep presentation update
- `PostUpdate` - After presentation, before rendering
- **`RenderGroup`** - Rendering phases
  - `RenderFirst` - Start of rendering
  - `PreRender` - Render preparation
  - `Render` - Main rendering
  - `PostRender` - Post-processing and effects
  - `RenderLast` - End of rendering
- `Last` - Very end of each frame

### ShutdownGroup

One-time cleanup phases run when `world:shutdown()` is called.

- `PreShutdown` - Preparation for shutdown
- `Shutdown` - Main shutdown phase
- `PostShutdown` - Final cleanup

## What the engine runs, and where

Every world gets the builtin plugin. An application gets the renderer's extractor, audio and the sequencer as
well, because `Application` installs them itself. The rest arrive with the plugin that owns them.

| Phase             | System                          | Installed by                                       |
| ----------------- | ------------------------------- | -------------------------------------------------- |
| `First`           | `sequence.AdvanceFrame`         | [`sequence`](/modules/sequence), every application |
| `FixedFirst`      | `tecs.EnterFixedInput`          | [`Application`](/modules/application)              |
| `FixedFirst`      | `tecs.SnapshotTransforms`       | [`Renderer`](/modules/gfx/)                        |
| `FixedFirst`      | `sequence.Advance`              | [`sequence`](/modules/sequence), every application |
| `FixedUpdate`     | `ttl`                           | builtins, every world                              |
| `FixedUpdate`     | `tecs.StepPhysics`              | [`physics`](/modules/physics) plugin               |
| `FixedPostUpdate` | `tecs.SyncBodyTransforms`       | [`physics`](/modules/physics) plugin               |
| `FixedPostUpdate` | `tecs.AdvanceAnimation`         | [`animation`](/modules/gfx/animation) plugin       |
| `FixedLast`       | `tecs.ExitFixedInput`           | [`Application`](/modules/application)              |
| `Update`          | `sequence.AdvancePresentation`  | [`sequence`](/modules/sequence), every application |
| `PostUpdate`      | `RelativeTransform`             | builtins, every world                              |
| `PostUpdate`      | `tecs.PlaySounds`               | [`Audio`](/modules/audio)                          |
| `PostUpdate`      | `tecs.EncodeAnimation`          | [`animation`](/modules/gfx/animation) plugin       |
| `PostUpdate`      | `tecs.ReportAnimation`          | [`animation`](/modules/gfx/animation) plugin       |
| `PostUpdate`      | `tecs.TextLayout`               | [`text`](/modules/text) plugin                     |
| `PostUpdate`      | `tecs.ParticleEmitterSync`      | [`particles`](/modules/gfx/particles) plugin       |
| `RenderFirst`     | `tecs.SyncRenderState`          | [`Renderer`](/modules/gfx/)                        |
| `RenderLast`      | `RelativeTransformDirtySampler` | builtins, every world                              |

Three things follow from that table and are worth stating outright.

**Extraction is `RenderFirst`.** `tecs.SyncRenderState` walks the world's renderable and light queries and fills
the frame packet. Anything that must be visible this frame has to have run before it, which is why the engine's
own presentation work (`RelativeTransform`, text layout, animation encoding, emitter sync) sits in `PostUpdate`
rather than in a render phase: `PostUpdate` lands ahead of `RenderFirst` no matter what order the plugins were
installed in.

**GPU work is not in a phase at all.** `Application` acquires a frame, calls `Renderer:render(frame)` and submits
it _after_ `world:update` has returned. The `Render`, `PostRender` and `RenderLast` phases still run, and are
yours to use, but the engine registers nothing in `Render` or `PostRender`.

**Input is latched across the fixed group.** `tecs.EnterFixedInput` and `tecs.ExitFixedInput` bracket
`FixedUpdateGroup`, which is what lets a fixed step observe a press that began and ended between two steps.

## Fixed vs variable phases

- **Fixed timestep phases** (`FixedUpdate` and related): physics, game logic, AI, and anything affecting gameplay
  that should feel consistent regardless of the speed of the computer.
- **Variable timestep phases** (`Update` and related): visual presentation, animations, camera smoothing, UI
  effects, and anything that looks or feels better the faster the computer.

Fixed systems receive the fixed timestep as their `dt`, not the frame's. The loop consumes accumulated time in
whole steps and runs at most ten of them per `world:update`, so a long stall cannot spiral.

The sequencer shows the split in one plugin. `sequence.Advance` runs in `FixedFirst` on the fixed clock;
`sequence.AdvanceFrame` runs in `First` on the frame clock, because a frame runs the fixed phases zero times or
several and a program driving input has to advance exactly once per frame either way; and
`sequence.AdvancePresentation` runs in `Update` with the frame's real `dt`, because what it carries moves at the
display's rate rather than the simulation's.

Rendering between two fixed steps is the same problem, and the engine answers it with a component rather than a
system: an entity carrying `tecs.components.PreviousTransform` alongside `Transform` is drawn between the two.
`tecs.SnapshotTransforms` copies the current transform into it in `FixedFirst`, before anything in the step moves,
and extraction blends them.

Presentation code that wants the same blend factor for itself reads `world:getFixedTiming()`, which returns the
timestep, the residual time not yet consumed, and that residual divided by the timestep clamped to `[0, 1]`. It
does not allocate.

```teal
local timestep, accumulator, alpha = world:getFixedTiming()
```

`world:fixedStepCount()` returns the number of fixed steps run since the world was made. It counts steps rather
than summing seconds, so two runs fed the same steps read the same number however many frames either of them drew.
Both clocks advance whether or not any system is registered in a fixed phase.

## Using phases

Access phases through `tecs.ecs.phases`:

```teal
local tecs <const> = require("tecs")

-- Presentation: runs once per frame with the frame's dt.
world:addSystem({
    name = "game.FadeTints",
    phase = tecs.ecs.phases.Update,
    run = myFadeSystem
})

-- Simulation: runs on the fixed clock with the fixed timestep as dt.
world:addSystem({
    name = "game.StepEnemies",
    phase = tecs.ecs.phases.FixedUpdate,
    run = myEnemySystem
})
```

Systems are ordered within a phase by `before` and `after`, which name other systems, so the table above doubles
as a list of handles you can order against.

Concrete indexed phases expose a public `position`: their numeric slot in the pipeline. It can be used for
inspection and ordering diagnostics:

```teal
print(tecs.ecs.phases.Update.name, tecs.ecs.phases.Update.position)
```

Phase groups expose their child phase tree through `children` instead, and have no `position` of their own. A custom
leaf phase receives a position when it is registered. Systems should still select phases by object, not by
hard-coded numeric positions.

Adding a system to a phase the pipeline does not know raises an error, as does adding a phase object with no
position. Register custom phases with [`world:registerPhase`](#world-register-phase) first.

## Managing phases

These methods are available on every `World`.

| Method                                         | Description                                        |
| ---------------------------------------------- | -------------------------------------------------- |
| [`world:enablePhase`](#world-enable-phase)     | Enable a phase or phase group.                     |
| [`world:disablePhase`](#world-disable-phase)   | Disable a phase or phase group.                    |
| [`world:registerPhase`](#world-register-phase) | Register a custom phase with the world's pipeline. |
| [`world:runPhase`](#world-run-phase)           | Run a phase or phase group explicitly.             |

### Enabling and disabling phases

You can dynamically enable and disable phases to control which systems run:

```teal
-- Stop the simulation without stopping presentation: physics, TTL and
-- animation advance all live in the fixed group.
world:disablePhase(tecs.ecs.phases.FixedUpdateGroup)

-- Resume it
world:enablePhase(tecs.ecs.phases.FixedUpdateGroup)
```

::: warning Disabling parent phases
Disabling a parent phase (like `RenderGroup`) also disables all its child phases.
:::

Two consequences are worth knowing before reaching for this.

Disabling `FixedUpdateGroup` stops its systems, but the fixed-step clock keeps advancing, so `fixedStepCount` and
`getFixedTiming` continue to move.

Disabling `RenderGroup` disables `RenderFirst`, and `tecs.SyncRenderState` lives there, so the frame packet stops
being refilled. The GPU still draws, because `Renderer:render` runs outside the pipeline; it draws what the last
extraction left. To pause simulation while the screen keeps updating, prefer the
[state stack](/ecs/states) and `type = "logic"` [queries](/ecs/queries/#paused-entities).

### Running specific phases

You can explicitly run a specific phase using `world:runPhase()`:

```teal
-- Run only the Render phase
world:runPhase(tecs.ecs.phases.Render)

-- Run the entire RenderGroup
world:runPhase(tecs.ecs.phases.RenderGroup)
```

::: info Disabled phases behavior
When you disable a phase:

- It won't run during the normal game loop
- `world:runPhase()` honors the disabled state too, so it also skips the phase
- Disabling a parent phase cascades to its children, so they are disabled as well

Re-enable a phase with `world:enablePhase()` before running it directly.
:::

```teal
-- Disable all rendering (this cascades to RenderGroup's children too)
world:disablePhase(tecs.ecs.phases.RenderGroup)

-- runPhase honors the disabled state, so this runs nothing
world:runPhase(tecs.ecs.phases.RenderGroup)

-- Re-enable a phase before running it directly
world:enablePhase(tecs.ecs.phases.Render)
world:runPhase(tecs.ecs.phases.Render)
```

Unlike `world:update`, `runPhase` only dispatches systems: it does not unwind deferred scopes before running and
does not clear dirty bits afterwards. That is what makes it usable for piecewise phase execution, such as a custom
loop that splits update and render across distinct ticks.

### world:enablePhase {#world-enable-phase}

Enables a phase or phase group so it runs during normal pipeline execution.

```teal
function World:enablePhase(phase: Phase)
```

**Parameters:**

- `phase`: Phase or phase group to enable.

### world:disablePhase {#world-disable-phase}

Disables a phase or phase group during normal pipeline execution. Disabling a parent phase also disables its child
phases.

```teal
function World:disablePhase(phase: Phase)
```

**Parameters:**

- `phase`: Phase or phase group to disable.

### world:registerPhase {#world-register-phase}

Registers a custom phase with the world's pipeline, assigning it a position if it does not already have one and
enabling it. Use this when an extension or custom pipeline adds phases outside the built-in `tecs.ecs.phases` tree.

```teal
function World:registerPhase(phase: Phase)
```

**Parameters:**

- `phase`: Phase to register.

### world:runPhase {#world-run-phase}

Runs a phase or phase group immediately. Disabled phases are skipped whether you run them directly or via a parent
group; re-enable a phase with `world:enablePhase()` before running it.

```teal
function World:runPhase(phase: Phase, dt?: number)
```

**Parameters:**

- `phase`: Phase or phase group to run.
- `dt`: Optional delta time passed to systems in that phase. Defaults to `0`.
