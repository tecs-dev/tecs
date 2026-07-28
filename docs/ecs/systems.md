---
description: "Adding and removing systems, the SystemConfig shape, ordering with before and after, and the tecs.runif predicates"
outline: deep
---

# Systems

A system is a function that runs in one [phase](/ecs/phases) of a [world](/ecs/world). Systems are how per-frame
work happens at all: the engine's own extraction, transform interpolation and input latching are systems, and so
is everything a game writes. The phase decides when a system runs, and a `runIf` predicate decides whether it
runs at all this frame.

## Requiring it

```teal
local tecs <const> = require("tecs")
```

The whole surface is `require("tecs")` and every module is a field on it. `tecs` is also set as a global, which
makes the require line optional.

## Creating a system

Add systems to a world with `world:addSystem()`, passing a configuration table. The `run` function receives the
frame's delta time and the world.

Systems are registered from a plugin, and a game's entry plugin is the one `tecs.application` takes. That is
where queries are built once and the systems that use them are declared:

```teal
local tecs <const> = require("tecs")
local Transform <const> = tecs.components.Transform
local Tint <const> = tecs.components.Tint
local Renderable <const> = tecs.components.Renderable

return tecs.application({
    plugin = function(world: tecs.World, app: tecs.Application)
        local movers <const> = world:query({ include = { Transform, Renderable } })

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

        world:spawn(Transform(100, 100), Tint(1, 0.4, 0.3, 1), Renderable())
    end,
})
```

The examples below show the `world:addSystem` call on its own for brevity; each belongs inside a plugin body
like that one. See [Plugins](/ecs/plugins) for how a game with several modules composes them, and
[Getting started](/getting-started) for the entry file around it.

## Where a system runs in the frame

Three calls drive the phases, and [`Application`](/modules/Application) makes them:

| Call             | Phases                                        | When                                                  |
| ---------------- | --------------------------------------------- | ----------------------------------------------------- |
| `world:startup`  | `PreStartup`, `Startup`, `PostStartup`        | once, after the game plugin has registered everything |
| `world:update`   | `First` through `Last`, fixed phases included | once per frame                                        |
| `world:shutdown` | `PreShutdown`, `Shutdown`, `PostShutdown`     | once, before anything is destroyed                    |

The engine's own systems are ordinary systems in those phases, and they are what makes phase choice concrete:

| System                         | Phase         | What it does                                                                      |
| ------------------------------ | ------------- | --------------------------------------------------------------------------------- |
| `tecs.EnterFixedInput`         | `FixedFirst`  | Latches input so a fixed step sees a press that began and ended between two steps |
| `tecs.SnapshotTransforms`      | `FixedFirst`  | Copies `Transform` into `PreviousTransform` before the step moves anything        |
| `sequence.Advance`             | `FixedFirst`  | Advances sequences on the fixed clock                                             |
| `tecs.ExitFixedInput`          | `FixedLast`   | Ends the latched window                                                           |
| `sequence.AdvanceFrame`        | `First`       | Advances frame-clock sequences, ahead of the fixed group                          |
| `sequence.AdvancePresentation` | `Update`      | Advances presentation sequences on the frame's real delta                         |
| `RelativeTransform`            | `PostUpdate`  | Composes child transforms from their parents                                      |
| `tecs.SyncRenderState`         | `RenderFirst` | Extracts the world into the frame packet the renderer consumes                    |

Extraction runs in `RenderFirst`, so a system that changes what is drawn has to run before that: `PostUpdate` is
the last phase that still lands in the same frame. A write made in `Render` or later is seen a frame late.

`world:update` clears every component's dirty bit once the pipeline finishes, so a dirty-gated consumer has to
read within the same update that produced the write.

## World methods

These methods are available on every `World`.

| Method                                       | Description                              |
| -------------------------------------------- | ---------------------------------------- |
| [`world:addSystem`](#world-add-system)       | Add a system to the world's pipeline.    |
| [`world:removeSystem`](#world-remove-system) | Remove a named system from the pipeline. |

### world:addSystem {#world-add-system}

Adds a system to the world's pipeline.

```teal
function World:addSystem(config: SystemConfig)
```

**Parameters:**

- `config`: the system configuration.

`config.run` and `config.phase` are both required, and the phase has to be one the world's pipeline has
registered. A `name` that is already taken by another system in the pipeline is an error, so two plugins cannot
silently claim the same handle.

### world:removeSystem {#world-remove-system}

Removes a named system from the world's pipeline. Removing a name the pipeline does not hold is an error.

```teal
function World:removeSystem(systemName: string)
```

**Parameters:**

- `systemName`: name of the system to remove.

::: warning
Give a system you plan to remove an explicit `name`. Systems added without one are auto-named on insertion so
that self-removing predicates have a handle to pass back; the generated scheme is an internal scheduling detail
and is not a stable user-facing handle.
:::

## SystemConfig

| Field    | Type                                                                   | Required | Description                                                  |
| -------- | ---------------------------------------------------------------------- | -------- | ------------------------------------------------------------ |
| `phase`  | `Phase`                                                                | **Yes**  | The phase the system runs in.                                |
| `run`    | `function(dt: number, world: tecs.World)`                              | **Yes**  | Called each time the system runs.                            |
| `name`   | `string`                                                               | No       | Name used for debugging, ordering, and `removeSystem`.       |
| `runIf`  | `function(dt: number, world: tecs.World, systemName: string): boolean` | No       | Predicate deciding whether the system runs this frame.       |
| `before` | `{string}`                                                             | No       | System names this one runs before. Soft; ignored if missing. |
| `after`  | `{string}`                                                             | No       | System names this one runs after. Soft; ignored if missing.  |

Within a phase, systems run in the order they were added unless `before` or `after` constraints re-sort them.
The sort is stable, so systems with no constraints keep their registration order.

## Naming systems

Give a system a `name` to make it easier to debug, to remove later, and to let other systems order themselves
relative to it.

```teal{3}
world:addSystem({
    phase = tecs.phases.Update,
    name = "MyUpdateSystem",
    run = function(dt: number, world: tecs.World)
        -- update logic
    end
})
```

## Conditionally running systems

To skip a system on some frames, give it a `runIf` predicate. It receives the frame delta, the world and the
system's name, and returns `true` when the system should run this frame.

```teal
runIf = function(dt: number, world: tecs.World, systemName: string): boolean
    return world:peekState() == "game"
end
```

Tecs ships built-in predicates on `tecs.runif` that cover the common cases.

### Scheduling helpers

These replace the accumulator most systems otherwise grow at the top of `run`:

```teal
-- Without a helper: every system that ticks on an interval repeats this
local elapsed = 0
world:addSystem({
    phase = tecs.phases.Update,
    run = function(dt: number)
        elapsed = elapsed + dt
        if elapsed < 0.5 then return end
        elapsed = 0
        spawnWave(world)
    end
})

-- With one: the schedule is declared, not reimplemented
world:addSystem({
    phase = tecs.phases.Update,
    runIf = tecs.runif.every(0.5),
    run = function() spawnWave(world) end
})
```

The gameplay vocabulary maps onto four of the helpers:

| You want                                                | Use                        |
| ------------------------------------------------------- | -------------------------- |
| Spawn waves, tick AI, poll for a condition periodically | `every(interval, jitter?)` |
| An ability, regeneration, or an attack on a cooldown    | `cooldown(duration)`       |
| A delayed one-shot: a cutscene beat, a grace period     | `after(delay)`             |
| Systems that belong to one screen or mode               | `inState(name)`            |

`every` takes jitter so a hundred enemies sharing one interval do not all think on the same frame. `after`
removes its own system once it fires, so a one-shot leaves nothing behind. Compose any of them with `both`,
`either` and `negate`.

#### runif.after {#after}

Fires once after a delay in seconds, then removes the system from the pipeline.

```teal
function runif.after(delay: number): RunIfFn
```

```teal
world:addSystem({
    phase = tecs.phases.Update,
    name = "DelayedMessage",
    runIf = tecs.runif.after(2.0),
    run = function(_dt: number, _world: tecs.World)
        print("This runs 2 seconds after the world started")
    end
})
```

The predicate calls `world:removeSystem` with the system's own name on the frame it fires, which is why an
unnamed system still gets a generated name at insertion.

#### runif.every {#every}

Fires repeatedly at an interval in seconds.

```teal
function runif.every(interval: number, jitter?: number): RunIfFn
```

```teal
world:addSystem({
    phase = tecs.phases.Update,
    name = "PeriodicUpdate",
    runIf = tecs.runif.every(1.0),
    run = function(_dt: number, _world: tecs.World)
        print("One second has passed")
    end
})
```

`jitter` is an optional variance of plus or minus that many seconds, applied to the next interval each time the
predicate fires, so systems sharing one interval desynchronize. The roll is drawn from the world's
`"tecs.runif"` random stream, so a run reseeded through `tecs.random` fires on the same frames every time and a
snapshot carries where the jitter had got to. A jitter large enough to reach zero is clamped, so the interval
never collapses to a fire-every-frame.

#### runif.cooldown {#cooldown}

Fires immediately on the first update, then suppresses the system until the cooldown has elapsed.

```teal
function runif.cooldown(duration: number): RunIfFn
```

```teal
world:addSystem({
    phase = tecs.phases.Update,
    name = "HealthRegen",
    -- Run immediately, then every 5 seconds
    runIf = tecs.runif.cooldown(5.0),
    run = function(dt: number, world: tecs.World)
        -- regenerate health
    end
})
```

#### runif.inState {#instate}

Fires only while the named [state](/ecs/states) is on top of the state stack.

```teal
function runif.inState(name: string): RunIfFn
```

```teal
world:addSystem({
    phase = tecs.phases.Update,
    name = "GameplaySystem",
    runIf = tecs.runif.inState("game"),
    run = function(dt: number, world: tecs.World)
        -- only runs when "game" is the current state
    end
})
```

#### runif.negate {#negate}

Inverts another predicate.

```teal
function runif.negate(predicate: RunIfFn): RunIfFn
```

```teal
world:addSystem({
    phase = tecs.phases.Update,
    name = "PauseMenuSystem",
    runIf = tecs.runif.negate(tecs.runif.inState("game")),
    run = function(dt: number, world: tecs.World)
        -- only runs when "game" is not the current state
    end
})
```

#### runif.both {#both}

Combines two predicates with logical AND. The system runs only when both return true.

```teal
function runif.both(lhs: RunIfFn, rhs: RunIfFn): RunIfFn
```

```teal
world:addSystem({
    phase = tecs.phases.Update,
    name = "PeriodicGameplayUpdate",
    runIf = tecs.runif.both(
        tecs.runif.inState("game"),
        tecs.runif.every(2.0)
    ),
    run = function(dt: number, world: tecs.World)
        -- runs every 2 seconds, but only in the "game" state
    end
})
```

::: info Operand order matters for timers
`both` and `either` short-circuit, so the right operand only receives `dt` on the ticks where evaluation reaches
it. That makes order part of the behavior when one side is a stateful predicate such as `every` or `cooldown`:

- `both(inState("game"), every(2))` pauses the timer outside the state; it resumes where it left off, with no
  burst of backlogged fires.
- `both(every(2), inState("game"))` keeps the timer running on its own cadence; fires that land outside the
  state are spent, not deferred.

Put the gate first to pause a timer with the gate, the timer first to keep its cadence independent of the gate.
:::

#### runif.either {#either}

Combines two predicates with logical OR. The system runs when either returns true.

```teal
function runif.either(lhs: RunIfFn, rhs: RunIfFn): RunIfFn
```

```teal
world:addSystem({
    phase = tecs.phases.FixedUpdate,
    name = "AnimateWater",
    runIf = tecs.runif.either(
        tecs.runif.inState("game"),
        tecs.runif.inState("editor")
    ),
    run = function(dt: number, world: tecs.World)
        -- animate water in the game or editor states
    end
})
```

### Custom predicates

Any function of the right shape works, so more complex conditions do not need a helper:

```teal
local health: number = 100

world:addSystem({
    phase = tecs.phases.Update,
    name = "LowHealthWarning",
    runIf = function(_dt: number, _world: tecs.World, _systemName: string): boolean
        return health < 25
    end,
    run = function(_dt: number, _world: tecs.World)
        print("Warning: low health")
    end
})
```

## Ordering with before and after

Systems in the same phase can declare that they run before or after named systems. Tecs topologically sorts each
phase, and a cycle in the constraints is an error rather than an arbitrary order.

The constraints are **soft**: a name that no system in the phase carries is silently ignored. That is what makes
plugins composable, because a system can declare `after = {"physics.applyTransform"}` without requiring the
physics plugin to be installed. Adding the referenced system later re-sorts the phase and the constraint starts
to apply.

Run before another named system:

```teal{7}
world:addSystem({
    phase = tecs.phases.Update,
    name = "MyOtherUpdateSystem",
    run = function(dt: number, world: tecs.World)
        -- update logic
    end,
    before = {"MyUpdateSystem"}
})
```

Run after another named system:

```teal{7}
world:addSystem({
    phase = tecs.phases.Update,
    name = "YetAnotherUpdateSystem",
    run = function(dt: number, world: tecs.World)
        -- update logic
    end,
    after = {"MyUpdateSystem"}
})
```

## Removing systems

Call `world:removeSystem(name)` to pull a system out of the pipeline.

```teal
world:removeSystem("MyUpdateSystem")
```

`tecs.runif.after` uses the same call to clean itself up once its delay elapses.

## Design record

- [One way in](https://github.com/tecs-dev/tecs/blob/main/README.md#one-way-in)
