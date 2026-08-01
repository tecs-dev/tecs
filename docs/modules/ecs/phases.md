---
description: "Game-loop phase groups and the world methods that control them"
outline: deep
---

# Phases

A system names the phase that runs it:

```teal
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

[`Application`](/modules/Application) calls `world:startup()` once,
`world:update(dt)` every iteration, and `world:shutdown()` at teardown. Events
do not occupy a phase; see [Observer timing](/modules/ecs/events#observer-timing).

## Lifecycle groups

The phase tree hangs from `tecs.ecs.phases.AllGroups`:

- `startup()` runs `StartupGroup`: `PreStartup`, `Startup`, and `PostStartup`.
- `update(dt)` runs `MainGroup`: `First`, `PreUpdate`, `FixedUpdateGroup`,
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

The engine installs its work into the same tree:

| Phase             | Engine work                                                                             |
| ----------------- | --------------------------------------------------------------------------------------- |
| `First`           | Advance frame-clock sequences                                                           |
| `FixedFirst`      | Latch fixed input, snapshot transforms, advance fixed-clock sequences                   |
| `FixedUpdate`     | Run TTL and physics                                                                     |
| `FixedPostUpdate` | Copy physics poses                                                                      |
| `FixedLast`       | Leave fixed-input mode                                                                  |
| `Update`          | Advance presentation-clock sequences                                                    |
| `PostUpdate`      | Compose relative transforms, play sounds, encode animation, lay out text, sync emitters |
| `RenderFirst`     | Extract the world into a frame packet                                                   |
| `RenderLast`      | Sample relative-transform dirtiness                                                     |

Plugins install optional rows such as physics, animation, text, and particles.
Every world installs the builtin rows.

Extraction runs in `RenderFirst`. A system that changes what the current frame
draws must run before extraction. `PostUpdate` provides the last general phase
for that work.

A change made after extraction draws one frame late rather than never. Spawning,
despawning, and writing a component the renderer draws from all reach the
instance buffer on the next frame's extraction, even though the frame's dirty
marks are cleared in between. Latency is the whole of the cost, so a system that
has to run in `Render`, `PostRender`, `RenderLast`, or `Last` is free to write;
one that needs the current frame to show its change still belongs earlier.

GPU submission does not run as a system. After `world:update` returns,
`Application` acquires a frame, calls `Renderer:render`, and submits it.
`Render`, `PostRender`, and `RenderLast` remain available to game systems even
though the renderer itself does not submit there.

## Fixed and presentation clocks

Fixed phases receive the configured timestep as `dt`. `world:update` consumes
accumulated time in whole steps and caps one frame at ten steps, so a long
stall cannot create an unbounded catch-up loop.

Variable phases receive the frame `dt`. Use them for presentation work that
should follow display rate rather than simulation rate.

`world:getFixedTiming()` returns the timestep, the unconsumed accumulator, and
an interpolation alpha clamped to `[0, 1]`:

```teal
local timestep, accumulator, alpha = world:getFixedTiming()
```

`PreviousTransform2D` lets the renderer interpolate an entity between its last
two fixed poses. `tecs.SnapshotTransforms` copies the current pose in
`FixedFirst` before simulation changes it.

`world:fixedStepCount()` counts completed fixed steps. The fixed clock and its
count advance even when no fixed system exists or callers disable the fixed
group.

## System placement

Systems within one phase follow insertion order unless `before` or `after`
names another system. The engine table above supplies the names and boundaries
that game plugins commonly order around; [Systems](/modules/ecs/systems) covers those
constraints.

Concrete phases expose `position` for inspection. The world assigns it, and
callers must treat it as read-only. Groups expose a read-only `children` tree
and have no position. Select phases by object instead of storing numeric
positions.

A custom phase must enter the world's pipeline before a system can use it:

```teal
world:registerPhase(MyPhase)
world:addSystem({
    name = "game.CustomStep",
    phase = MyPhase,
    run = customStep,
})
```

`registerPhase` assigns a missing position and enables the phase. Registration
rejects an invalid phase object, and system registration rejects a phase that
the pipeline does not know.

## Disabling phases

Disabling a group also disables its descendants:

```teal
world:disablePhase(tecs.ecs.phases.FixedUpdateGroup)
world:enablePhase(tecs.ecs.phases.FixedUpdateGroup)
```

Disabling `FixedUpdateGroup` stops its systems but not the fixed clock.

Disabling `RenderGroup` also stops `RenderFirst`, so extraction stops updating
the frame packet. GPU submission still draws the last packet because it runs
outside the phase tree. To pause gameplay while presentation continues, use
the [state stack](/modules/ecs/states) and logic
[queries](/modules/ecs/queries/#paused-entities).

## Direct phase execution

`world:runPhase(phase, dt)` dispatches one phase or group immediately:

```teal
world:runPhase(tecs.ecs.phases.RenderGroup, dt)
```

It honors disabled state, including disabled ancestors. Re-enable a phase
before calling it directly.

Unlike `world:update`, `runPhase` neither unwinds existing deferred scopes nor
clears dirty bits afterwards. That contract supports custom loops that run
parts of the phase tree on separate ticks.
