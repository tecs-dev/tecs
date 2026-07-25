---
description: "Adding and removing systems with addSystem, phases, ordering via before and after, and runIf scheduling predicates"
outline: deep
---

# Systems

A system is a function that runs game logic in specific [phases](/tecs/phases) of the
[World](/tecs/world).

## Creating a system

Add systems to the world with `world:addSystem()`, passing a configuration table. The `run` function receives
the current frame delta time and the world.

```teal
world:addSystem({
    phase = tecs.phases.Startup,
    run = function(dt: number, world: tecs.World)
        print("The game is starting up!")
    end
})
```

::: tip Organize systems with plugins
Systems are typically grouped into [plugins](/tecs/plugins) so related queries, resources, and systems
can be installed together with a single `world:addPlugin(...)` call. `addSystem` works anywhere you have a
world reference, but plugins keep related code localized.
:::

## World methods

These methods are available on every `World`.

| Method | Description |
| ------ | ----------- |
| [`world:addSystem`](#world-add-system) | Add a system to the world's pipeline. |
| [`world:removeSystem`](#world-remove-system) | Remove a named system from the world's pipeline. |

### world:addSystem {#world-add-system}

Adds a system to the world's pipeline.

```teal
function World:addSystem(config: SystemConfig)
```

**Parameters:**

- `config`: System configuration.

### world:removeSystem {#world-remove-system}

Removes a named system from the world's pipeline.

```teal
function World:removeSystem(systemName: string)
```

**Parameters:**

- `systemName`: Name of the system to remove.

::: warning
Give systems you plan to remove an explicit `name`. Auto-generated names are an internal scheduling detail and are
not a stable user-facing handle.
:::

## System configuration settings

| Field    | Type                                                          | Required | Description                                                            |
| -------- | ------------------------------------------------------------- | -------- | ---------------------------------------------------------------------- |
| `phase`  | `Phase`                                                       | **Yes**  | The phase the system runs in.                                          |
| `run`    | `function(dt: number, world: tecs.World)`                     | **Yes**  | The function to call each time the system runs.                        |
| `name`   | `string`                                                      | No       | Name of the system, used for debugging, ordering, and `removeSystem`.  |
| `runIf`  | `function(dt: number, world: tecs.World, name: string): boolean` | No    | Predicate that determines if the system should run this frame.         |
| `before` | `{string}`                                                    | No       | System names this one should run before (soft; ignored if missing).    |
| `after`  | `{string}`                                                    | No       | System names this one should run after (soft; ignored if missing).     |

Systems without an explicit `name` are auto-named on insertion so scheduling helpers such as `runif.after` can
remove them internally. User code should not depend on the generated naming scheme.

Within a phase, systems run in the order they were added unless `before` / `after` constraints re-sort them.
See [Deferred Operations](/tecs/world#deferred-operations) for the rules about when mutations inside a
system apply instantly versus stage.

## Naming systems

You can give systems a name using the `name` property. This makes it easier to debug, and also
allows other systems to be added relative to the system by referencing the name.

```teal{3}
world:addSystem({
    phase = tecs.phases.Update,
    name = "MyUpdateSystem",
    run = function(dt: number, world: tecs.World)
        -- update logic...
    end
})
```

## Conditionally running systems

To conditionally skip a system, provide a `runIf` predicate. It receives the frame delta, the world, and the
system's name, and returns `true` if the system should run this frame.

```teal
runIf = function(dt: number, world: tecs.World, systemName: string): boolean
    return world:peekState() == "game"
end
```

Tecs provides built-in scheduling helpers that cover the common cases.

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

The gameplay vocabulary maps directly onto the four helpers:

| You want                                              | Use                            |
| ----------------------------------------------------- | ------------------------------ |
| Spawn waves, tick AI, poll for a condition periodically | `every(interval, jitter?)`    |
| An ability, regen, or attack on a cooldown              | `cooldown(duration)`           |
| A delayed one-shot: a cutscene beat, a grace period     | `after(delay)`                 |
| Systems that belong to one screen or mode               | `inState(name)`                |

`every` takes jitter so a hundred enemies sharing one interval do not all think on the same frame. `after` removes
its own system once it fires, so a one-shot leaves nothing behind. Compose them with `both`, `either`, and `negate`.

#### `tecs.runif.after(delay)`

Runs a system once after a delay (in seconds), then automatically removes it from the world.

```teal
world:addSystem({
    phase = tecs.phases.Update,
    name = "DelayedMessage",
    runIf = tecs.runif.after(2.0),  -- Run after 2 seconds
    run = function(_dt: number, _world: tecs.World)
        print("This runs 2 seconds after the world started")
    end
})
```

#### `tecs.runif.every(interval, jitter?)`

Runs a system repeatedly at regular intervals.

```teal
world:addSystem({
    phase = tecs.phases.Update,
    name = "PeriodicUpdate",
    runIf = tecs.runif.every(1.0),  -- Run every second
    run = function(_dt: number, _world: tecs.World)
        print("One second has passed")
    end
})
```

Provide optional jitter in the second argument to desynchronize systems using the same interval. Jitter is the
± number of adjusted seconds.

#### `tecs.runif.cooldown(duration)`

Fires immediately on the first update, then suppresses execution for the cooldown duration before firing again.

```teal
world:addSystem({
    phase = tecs.phases.Update,
    name = "HealthRegen",
    -- Run immediately, then every 5 seconds
    runIf = tecs.runif.cooldown(5.0),
    run = function(dt: number, world: tecs.World)
        -- Regenerate health for all entities
    end
})
```

#### `tecs.runif.inState(name)`

Runs a system only when the given [state](/tecs/states) is on top of the state stack.

```teal
world:addSystem({
    phase = tecs.phases.Update,
    name = "GameplaySystem",
    runIf = tecs.runif.inState("game"),
    run = function(dt: number, world: tecs.World)
        -- Only runs when "game" is the current state
    end
})
```

#### `tecs.runif.negate(predicate)`

Inverts another runIf predicate, allowing you to compose conditional logic.

```teal
-- Run when NOT in game state
world:addSystem({
    phase = tecs.phases.Update,
    name = "PauseMenuSystem",
    runIf = tecs.runif.negate(tecs.runif.inState("game")),
    run = function(dt: number, world: tecs.World)
        -- Only runs when NOT in game state
    end
})
```

#### `tecs.runif.both(lhs, rhs)`

Combines two runIf predicates with logical AND. The system will only run if both predicates return true.

```teal
world:addSystem({
    phase = tecs.phases.Update,
    name = "PeriodicGameplayUpdate",
    runIf = tecs.runif.both(
        tecs.runif.inState("game"),
        tecs.runif.every(2.0)
    ),
    run = function(dt: number, world: tecs.World)
        -- Runs every 2 seconds, but only when in "game" state
    end
})
```

::: info Operand order matters for timers
`both` and `either` short-circuit, so the right operand only receives `dt` on ticks where evaluation
reaches it. That makes order part of the behavior when one side is a stateful predicate like `every`
or `cooldown`:

- `both(inState("game"), every(2))` pauses the timer outside the state; it resumes where it left off,
  with no burst of backlogged fires.
- `both(every(2), inState("game"))` keeps the timer running on its own cadence; fires that land
  outside the state are spent, not deferred.

Put the gate first to pause a timer with the gate, the timer first to keep its cadence independent
of the gate.
:::

#### `tecs.runif.either(lhs, rhs)`

Combines two runIf predicates with logical OR. The system will run if either predicate returns true.

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

### Custom runIf predicates

You can also write your own runIf predicates for more complex logic:

```teal
local health: number = 100

world:addSystem({
    phase = tecs.phases.Update,
    name = "LowHealthWarning",
    runIf = function(_dt: number, _world: tecs.World, _systemName: string): boolean
        return health < 25
    end,
    run = function(_dt: number, _world: tecs.World)
        print("Warning: Low health!")
    end
})
```

## Adding systems before or after other systems

Add systems before or after other systems in the same phase. Tecs topologically sorts systems to ensure
correct ordering with no cycles.

These ordering constraints are **soft**: if a referenced system doesn't exist in the phase, the constraint
is silently ignored. This makes plugins composable; a system can declare `after = {"physics.applyTransform"}`
without requiring the physics plugin to be present. If the referenced system is added later, the pipeline
automatically re-sorts to respect the constraint.

Add a system before another named system:

```teal{7}
world:addSystem({
    phase = tecs.phases.Update,
    name = "MyOtherUpdateSystem",
    run = function(dt: number, world: tecs.World)
        -- update logic...
    end,
    before = {"MyUpdateSystem"}
})
```

Add a system after another named system:

```teal{7}
world:addSystem({
    phase = tecs.phases.Update,
    name = "YetAnotherUpdateSystem",
    run = function(dt: number, world: tecs.World)
        -- update logic...
    end,
    after = {"MyUpdateSystem"}
})
```

## Removing systems

Call `world:removeSystem(name)` to pull a system out of the pipeline. The system must have been registered
with that explicit `name`; generated names are not a stable public handle.

```teal
world:removeSystem("MyUpdateSystem")
```

`tecs.runif.after(delay)` takes advantage of this to clean itself up after firing: the predicate calls
`removeSystem` internally once the delay elapses.
