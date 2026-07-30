---
description: "System configuration, ordering, removal, and tecs.ecs.runif predicates"
outline: deep
---

# Systems

A system runs one function in one [phase](/modules/ecs/phases). Build its query once
inside a plugin, then close over that query:

```teal
local Transform <const> = tecs.Transform

local function spinPlugin(world: tecs.World)
    local spinning <const> = world:newQuery({
        include = {Transform, Spin},
        type = "logic",
    })

    world:addSystem({
        name = "game.Spin",
        phase = tecs.ecs.phases.Update,
        run = function(dt: number)
            for archetype, length in spinning:iter() do
                local transforms <const> = archetype:getMut(Transform)
                local speeds <const> = archetype:get(Spin)

                for row = 1, length do
                    transforms[row].rotation =
                        transforms[row].rotation + speeds[row] * dt
                end
            end
        end,
    })
end

world:addPlugin(spinPlugin)
```

The pipeline calls `run(dt, world)`. Fixed phases supply the fixed timestep;
variable phases supply the frame delta.

## Frame placement

`Application` drives three groups:

| Call               | Work                                               |
| ------------------ | -------------------------------------------------- |
| `world:startup()`  | Runs startup phases after plugin registration.     |
| `world:update(dt)` | Runs fixed and variable frame phases.              |
| `world:shutdown()` | Runs teardown phases before subsystem destruction. |

Engine systems share the same schedule. `tecs.SyncRenderState` extracts the
world in `RenderFirst`, so a system that must affect the current frame runs no
later than `PostUpdate`.

`world:update` clears dirty bits after the pipeline. Dirty-gated consumers must
run in the same update as the writes they consume.

## System failures

Under an application, the crash guard catches a system error, logs its
traceback, returns frame resources, and calls `world:unwind()` to close scopes
left by interrupted query iteration. Simulation stops while the host continues
to drain events and serve the debug connection.

The guard restores engine invariants, not game invariants. A system may have
updated only part of a query before it threw. Development code may resume
through `app:clearCrash()` after inspection.

## Names and ordering

Give every system that participates in ordering or removal an explicit,
stable name:

```teal
world:addSystem({
    name = "game.ResolveDamage",
    phase = tecs.ecs.phases.PostUpdate,
    after = {"game.ApplyDamage"},
    before = {"tecs.PlaySounds"},
    run = resolveDamage,
})
```

Within one phase, the pipeline preserves registration order and then applies
`before` and `after` constraints. A missing target name contributes no edge,
which lets optional plugins declare ordering without requiring one another.
The pipeline rejects cycles and duplicate system names.

The pipeline generates a private name for an unnamed system. Treat that name
as engine-owned and unstable. `world:removeSystem(name)` requires an existing
name, so callers should remove only explicitly named systems.

## Conditional execution

`runIf(dt, world, systemName)` gates `run`. Any function with that shape may
serve as a predicate:

```teal
world:addSystem({
    name = "game.LowHealthWarning",
    phase = tecs.ecs.phases.Update,
    runIf = function(_dt: number, world: tecs.World): boolean
        return world.resources[PLAYER_HEALTH] < 25
    end,
    run = showLowHealthWarning,
})
```

`tecs.ecs.runif` supplies stateful predicates for common schedules.

### Delayed one-shot {#after}

`runif.after(delay)` waits for the named duration, allows one run, then removes
the system. The predicate uses the system name passed by the pipeline, so even
an unnamed one-shot can clean itself up.

### Repeating interval {#every}

`runif.every(interval, jitter?)` repeats on an interval. Jitter chooses the next
interval within the requested variance and draws from the world's
`"tecs.runif"` random stream. The stream makes schedules deterministic under
seeding and snapshots. Clamping keeps a large jitter from producing a
zero-length interval.

```teal
world:addSystem({
    name = "game.SpawnWave",
    phase = tecs.ecs.phases.Update,
    runIf = tecs.ecs.runif.every(0.5, 0.1),
    run = spawnWave,
})
```

### Immediate cooldown {#cooldown}

`runif.cooldown(duration)` allows the first update immediately, then suppresses
the system until the duration elapses.

### Active state {#instate}

`runif.inState(name)` allows the system only while that state occupies the top
of the [state stack](/modules/ecs/states):

```teal
runIf = tecs.ecs.runif.inState("game")
```

### Negation {#negate}

`runif.negate(predicate)` inverts one predicate.

### Conjunction {#both}

`runif.both(lhs, rhs)` short-circuits like logical AND. Operand order changes
stateful timing:

- `both(inState("game"), every(2))` pauses the interval outside the state.
- `both(every(2), inState("game"))` keeps the interval advancing and spends
  ticks that land outside the state.

Put a gate first when its false state should pause the timer.

### Disjunction {#either}

`runif.either(lhs, rhs)` short-circuits like logical OR. The right predicate
receives `dt` only when the left predicate returns false, so stateful operands
make order part of the schedule.

```teal
world:addSystem({
    name = "game.AmbientAnimation",
    phase = tecs.ecs.phases.Update,
    runIf = tecs.ecs.runif.either(
        tecs.ecs.runif.inState("game"),
        tecs.ecs.runif.inState("editor")
    ),
    run = animateAmbientScene,
})
```
