---
description: "Game-loop phase groups and the world methods that control them"
outline: deep
---

# Phases

A system names the phase that runs it:

```nupp
world:addSystem({
    name = "game.StepEnemies",
    phase = tecs.ecs.phases.FixedUpdate,
    run = stepEnemies,
})

world:addSystem({
    name = "game.FadeTints",
    phase = tecs.ecs.phases.Update,
    run = fadeTints,
})
```

`FixedUpdate` runs on the simulation clock. `Update` runs once per frame on the
presentation clock. The phase gives game systems an order relative to engine
systems.

[`Application`](tecs.application) calls `world:startup()` once,
`world:update(dt)` every iteration, and `world:shutdown()` at teardown. Events
do not occupy a phase; see [Observer timing](events.md#observer-timing).

## Lifecycle groups

`tecs.ecs.phases.AllGroups` selects all predefined groups:

- `startup()` runs `StartupGroup`: `PreStartup`, `Startup`, and `PostStartup`.
- `update(dt)` runs `MainGroup`: `Ingress`, `First`, `PreUpdate`, `FixedUpdateGroup`,
  `Update`, `PostUpdate`, `RenderGroup`, and `Last`.
- `shutdown()` runs `ShutdownGroup`: `PreShutdown`, `Shutdown`, and
  `PostShutdown`.

`FixedUpdateGroup` contains `FixedFirst`, `FixedPreUpdate`, `FixedUpdate`,
`FixedPostUpdate`, and `FixedLast`.

`RenderGroup` contains `RenderFirst`, `PreRender`, `Render`, `PostRender`, and
`RenderLast`.

Application startup runs after the entry plugin registers its systems and
entities. Startup work therefore finishes before the first frame and does not
inflate that frame's `dt`.

## Engine system order

The engine installs its work into the same schedule:

| Phase             | Engine work                                                                                    |
| ----------------- | ---------------------------------------------------------------------------------------------- |
| `Ingress`         | Poll gamepads                                                                                  |
| `First`           | Advance frame-clock sequences                                                                  |
| `FixedFirst`      | Latch fixed input, copy previous transforms, advance fixed-clock sequences and prepare physics |
| `FixedUpdate`     | Run TTL and physics                                                                            |
| `FixedPostUpdate` | Copy physics poses and advance animation                                                       |
| `FixedLast`       | Leave fixed-input mode                                                                         |
| `Update`          | Advance presentation-clock sequences                                                           |
| `PostUpdate`      | Compose relative transforms, play sounds and lay out text                                      |
| `Last`            | Sample relative-transform dirtiness                                                            |

Plugins install optional work such as physics, animation and text. Every world
installs the [builtin systems](builtins.md#builtin-plugin).

The Rust host asks for a render packet after the completed `world:update`,
then uploads and draws it. GPU submission is outside the phase tree.
`RenderFirst` through `RenderLast` remain available to game systems.

## Fixed and presentation clocks

Fixed phases receive the configured timestep as `dt`. `world:update` consumes
accumulated time in whole steps and caps one frame at ten steps by default. `fixedMaxSteps` changes that cap;
`fixedOverload = "drop"` discards excess whole steps, while `"accumulate"`
keeps the backlog. Both policies bound work in one update.

Variable phases receive the frame `dt`. Use them for presentation work that
should follow display rate rather than simulation rate.

`world:getFixedTiming()` returns the timestep, the unconsumed accumulator, and
an interpolation alpha clamped to `[0, 1]`:

```nupp
local timestep, accumulator, alpha = world:getFixedTiming()
```

`tecs.ecs.PreviousTransform2D` lets the renderer interpolate an entity between its last
two fixed poses. `tecs.SnapshotTransforms` copies the current pose in
`FixedFirst` before simulation changes it.

`world:fixedStepCount()` counts completed fixed steps. The fixed clock and its
count advance even when no fixed system exists or callers disable the fixed
group.

## System placement

Systems within one phase follow registration order. The engine table above
supplies the boundaries game plugins commonly order around. [Systems](systems.md)
covers explicit structural barriers and conditional execution.

Register custom leaves and trees when a separate dispatch needs them:

```nupp
world:registerPhase({name = "game.ReplayRead"})
world:registerPhase({name = "game.ReplayStep"})
world:registerPhase({
    name = "game.Replay",
    children = {"game.ReplayRead", "game.ReplayStep"},
})
world:runPhase("game.Replay", dt)
```

Children must already be registered. The optional numeric `position` controls
inspection ordering; registration does not insert work into the default frame.
The world copies child lists, and rejects registration during dispatch.

`WorldConfig.pipelineFactory` replaces scheduling before built-in systems are
installed. The returned `tecs.ecs.Pipeline` owns system ordering, phase dispatch
and publication barriers. The world forwards its scheduling controls and gives
the pipeline the existing Nupp task scope. Fixed timing and phase-enabled flags
are saved and restored through that pipeline's state.

## Disabling phases

Disabling a group also disables its descendants:

```nupp
world:disablePhase(tecs.ecs.phases.FixedUpdateGroup)
world:enablePhase(tecs.ecs.phases.FixedUpdateGroup)
```

Disabling `FixedUpdateGroup` stops its systems but not the fixed clock.

Disabling `RenderGroup` stops its systems. Packet extraction and GPU submission
still run after the update. To pause gameplay while presentation continues,
use the [state stack](states.md) and explicit `Paused` query exclusions.

## Direct phase execution

`world:runPhase(phase, dt)` dispatches one phase or group immediately:

```nupp
world:runPhase(tecs.ecs.phases.RenderGroup, dt)
```

It honors each leaf phase's disabled state. Group enable/disable calls change
every leaf in that group; a later call can enable an individual leaf again.

Like `world:update`, `runPhase` publishes pending structural work before
dispatch and after each phase it runs. It does not clear dirty bits afterwards;
that contract supports custom loops that run parts of the phase tree on
separate ticks. Calling it while `world:update` is suspended raises instead of
publishing the suspended system's half-staged transaction.
