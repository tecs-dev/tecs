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

## Coroutine systems

A system declared with `coroutine` instead of `run` keeps its place across frames.
The body calls `world:yield()` to give up the rest of its slot, and the next
frame carries on from the following line with every local intact:

```teal
world:addSystem({
    name = "game.StreamLevel",
    phase = tecs.ecs.phases.Update,
    coroutine = function(world: tecs.World)
        local document <const> =
            tecs.assets.loadString("levels/1.json", "level"):yield(world, 30000)

        local chunks <const> = parseChunks(document)
        for i = 1, #chunks do
            spawnChunk(world, chunks[i])
            if i % 256 == 0 then
                world:yield()
            end
        end

        world:emit(0, LevelReady())
    end,
})
```

Written as a `run` system, the stage this reached and the chunk it stopped at
have to live in a table beside the world, because a function that returns every
frame cannot hold them. Here they are the coroutine's own program counter and
loop variable, which is the whole of what the kind buys.

The body runs top to bottom and stops, and reaching the end unregisters the
system. Nothing resumes a body with a value of its own choosing, so a resident
streamer that serves requests reads them from a resource or a message on the
world rather than expecting `world:yield()` to hand one over.

### Values from a wait

`world:yield()` parks until the next slot and returns the delta time of the
frame it resumed on. Take it from there rather than from a variable captured
earlier, which is a frame older each time round. `world:yield(0.5)` sleeps for
half a second counted in that phase's own delta, and returns a delta time too.

To wait for a value, park on the thing producing it. `Future.yield` takes the
world and answers with that future's own value:

```teal
local sprite <const> = tecs.assets.loadImage("hero.png"):yield(world)
```

No cast. The world is the argument rather than the receiver so the answer
carries the future's value type, which a method on the world could not do:
`tecs.types` declares `World` and sits below `tecs.Future`, so it cannot name a
future without a require cycle.

A future that settles without a value raises at that line, rather than handing
back something to inspect. That is what keeps the ordinary path ordinary: the
line after a wait holds the value and never has to ask whether it does. A body
that wants the other outcome says so with `pcall`:

```teal
local ok <const>, document <const> = pcall(manifest.yield, manifest, world, 30000)
if not ok then
    useFallbackLevel()
    return
end
```

The same raise covers a failed future, a canceled one, and an expired timeout,
and each message names the system and the reason. A future that has already
settled does not park at all, so a run of cached loads finishes in the frame
that asked for them.

`Future.wait` is the other way to wait on a future, and a coroutine system must
not call it: it blocks the thread, which inside a frame is a stalled frame.
`Future.yield` gives up the system's slot instead and lets the rest of the
pipeline run.

### Legal phases

A body that parks needs a slot every frame to resume from, so `coroutine` is legal
only in the phases that run exactly once per frame: `First`, `PreUpdate`,
`Update`, `PostUpdate`, `Last`, and any custom phase dispatched every frame.
`addSystem` rejects the rest and says why:

| Group    | Reason                                                                                                                     |
| -------- | -------------------------------------------------------------------------------------------------------------------------- |
| Startup  | Runs once, so a parked body never gets a second slot.                                                                      |
| Fixed    | Runs zero to `fixedMaxSteps` times per frame, and a wall-clock wait there is nondeterminism inside the deterministic step. |
| Render   | Builds the frame packet, so a suspended body yields a wrong frame rather than a late one.                                  |
| Shutdown | Runs once, while the process is leaving.                                                                                   |

A boot sequence therefore registers in `First` and unregisters itself, rather
than registering in `Startup`.

### Yielding and query iteration

**A coroutine body may not yield during query iteration.** Iteration holds a
world-wide scope, and a body suspended inside one leaves every later system's
mutations staged instead of applied for the rest of the frame, which nothing
else reports. `world:yield()` raises rather than allowing it. Finish the loop
first, or take a [`QueryCursor`](/modules/ecs/queries) and close it before
yielding:

```teal
local cursor <const> = query:newCursor()
for archetype, length in cursor:iter() do
    collect(archetype, length)
    break
end
cursor:close()

world:yield()
```

A `runIf` gates a coroutine system exactly as it gates a `run` system: a false
answer skips the dispatch, and because waits are counted in the delta the
system is dispatched with, a gated-off body's wait is frozen rather than
running down while it is off.

A body parked far longer than expected is reported to the `tecs.coroutines` logger,
first after five seconds and then on a doubling interval. A body waiting on
something that never arrives otherwise stops running with no other symptom.

A parked body is not part of a snapshot. Keep anything that must survive a save
in the world, and use [`tecs.sequence`](/modules/sequence) for a wait that has
to be saved and restored.

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
