---
description: "System configuration, ordering, removal, and conditional execution"
outline: deep
---

# Systems

A system runs one function in one phase. Build its query once
inside a plugin, then close over that query:

```nupp
local Transform2D = tecs.ecs.Transform2D

local function spinPlugin(exclusive world: tecs.ecs.World): nil
    local spinning = world:newQuery({
        include = {Transform2D, Spin},
        exclude = {tecs.ecs.Disabled, tecs.ecs.Paused},
    })

    world:addSystem({
        name = "game.Spin",
        phase = tecs.ecs.phases.Update,
        run = function(dt: number)
            for archetype, length in spinning:iter() do
                local transforms = assert(archetype:getMut(Transform2D))
                local speeds = assert(archetype:get(Spin))
                unsafe do
                    for row = 1, length as integer do
                        transforms[row].rotation =
                            transforms[row].rotation + speeds[row] * dt
                    end
                end
            end
        end,
    })
end

spinPlugin(world)
```

The pipeline calls `run(dt, world, scope)`, with a Nupp task scope. Fixed phases supply the fixed timestep;
variable phases supply the frame delta.

## Asynchronous work

Every frame system dispatched by `world:update` is resumable. Call a cooperative
function and use its returned value directly. Nupp owns files, networking,
tasks, and workers.

When the value is already available, the call returns inline. When it must
wait, the host parks the world update at that exact call. Events and I/O
continue to pump, and the application may render the last completed frame.
The next system and phase do not run early.

The coroutine preserves query iterators and locals. Structural mutations stay
staged while the system is suspended because the system has not returned, so
a spawn after a wait remains ordered and commits at the next declared barrier.
The same mechanism works in fixed phases: the fixed step resumes without
replaying its earlier systems or advancing its clock twice.

## Frame placement

`Application` drives three groups:

| Call               | Work                                               |
| ------------------ | -------------------------------------------------- |
| `world:startup()`  | Runs startup phases after plugin registration.     |
| `world:update(dt)` | Runs fixed and variable frame phases.              |
| `world:shutdown()` | Runs teardown phases before subsystem destruction. |

Engine systems share the same schedule. The frame runs Ingress, First and
PreUpdate, then zero or more FixedFirst through FixedLast groups, then Update,
PostUpdate, RenderFirst through RenderLast, and Last. The host extracts the
render packet after the completed update returns.

`world:update` clears dirty bits after the pipeline. Dirty-gated consumers must
run in the same update as the writes they consume.

## Structural barriers

Systems in one phase share a structural transaction by default. The pipeline
publishes it after the phase, so they normally see the same committed
archetypes while the next phase sees their combined changes.

Declare `commitBefore = true` when a system must consume structural output
from an earlier system in the same phase. Declare `commitAfter = true` when a
later system in that phase must consume this system's structural output.
These declarations make unconditional dependencies visible in system
configuration.

`world:commit()` publishes synchronously. Finish any query traversal before
calling it. Prefer declared phase barriers for systems so publication cannot
invalidate a loop's current row addresses.

Prefer moving the consumer to a later phase when that is the natural frame
dependency. Additional barriers reduce batching and make more archetype moves
observable within one phase.

## System failures

Under an application, the crash guard records a system error and stops
simulation while the host continues to drain events and serve the debug
connection. A system may have updated only part of a query before it threw.
Neither component writes nor pending structural changes are rolled back.

Development code may resume through `app:clearCrash()` after inspection. The
next update publishes any pending structural work at its opening barrier, so
inspect the world before resuming a partially completed operation.

## Names and ordering

Give every system that participates in removal or useful debug output an
explicit, stable name:

```nupp
world:addSystem({
    name = "game.ResolveDamage",
    phase = tecs.ecs.phases.PostUpdate,
    run = resolveDamage,
})
```

The pipeline visits phases in their fixed order and systems in registration
order within each phase. Place producers before consumers or select a later
phase for the consumer. Duplicate names are rejected.

`world:removeSystem(name)` returns whether a registered system was removed.

## Listing and stopping systems

`world:listSystems()` reports every system the world runs, ordered by phase and
by run order within each phase. Each row names the system and its phase, gives
its position in that phase, and says whether the system is enabled and whether
it declares a `runIf` of its own:

```nupp
for _, info in ipairs(world:listSystems()) do
    print(info.phase, info.position, info.name, info.enabled)
end
```

The list is a fresh copy, so a later enable or disable does not reach a list
already handed out.

`world:setSystemEnabled(name, enabled)` stops one system or starts it again. A
disabled system stays registered: it keeps its name, its position and its
ordering constraints, contributes to `world:getStats().systems`, and simply
does not run from the next `world:update`. Enabling restores the `runIf` it
declared for itself, so a gated system comes back gated:

```nupp
local stopped, reason = world:setSystemEnabled("game.Spin", false)
if not stopped then
    print(reason)
end
```

A name no system carries returns `false` and a reason rather than raising,
because that name usually comes from a person or a debugger rather than from
code. Disabling a system that is already disabled reports success and changes
nothing.

Use `removeSystem` when the system is never to run again, and
`setSystemEnabled` when it is a pause. The debug server exposes the same pair
as the `systems` command.

## Conditional execution

`runIf(dt, world, systemName)` gates `run`. Any function with that shape may
serve as a predicate:

```nupp
world:addSystem({
    name = "game.Update",
    phase = tecs.ecs.phases.Update,
    runIf = function(_dt: number, exclusive world: tecs.ecs.World): boolean
        return world:peekState() == "game"
    end,
    run = updateGame,
})
```

Keep stateful timing in the predicate's closure when a system needs an interval
or cooldown. Operand order matters for combined predicates: a gate evaluated
first can pause a later stateful timer.
