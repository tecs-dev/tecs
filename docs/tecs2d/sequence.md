---
description: "Deterministic, snapshot-safe gameplay sequencing: programs, actions, bindings, playback handles, and the deterministic-action contract"
outline: deep
---

# Sequence

`tecs2d.sequence` runs scripted gameplay logic that survives a save. Cutscenes, ability chains,
spawn waves, tutorials, and scripted encounters are naturally written as coroutines, and a
suspended coroutine lives in the Lua stack, which cannot be serialized. A sequence keeps its
position as data, so it snapshots, rewinds, and hot reloads like any other game state.

## Quick start

```teal
local sequence = require("tecs2d.sequence")

sequence.registerAction(world, "game.lockControls", function(_world, _ctx)
    controlsLocked = true
end)

sequence.registerAction(world, "game.face", function(world, ctx)
    local boss = ctx:entity("boss")
    if boss then world:getMut(boss, Facing).dir = ctx.args[1] as number end
end)

local intro = sequence.define("game.bossIntro", {
    sequence.call("game.lockControls"),
    sequence.call("game.face", -1),
    sequence.wait(1.5),
    sequence.emit("boss.ready"),
})

sequence.play(world, intro, {
    owner = encounter,
    bindings = { boss = bossEntity, player = playerEntity },
})
```

## Programs

`define(name, nodes)` compiles a program under a **stable symbolic name**. That name is what
snapshots store, so it has to survive builds; dotted names like `"game.bossIntro"` keep them
unambiguous.

Programs are immutable. Redefining a name compiles a **new version** rather than mutating the
existing one:

- Playbacks already running keep the version they started with.
- Later `play` calls use the newest version.
- A superseded version is released once its last playback finishes.

That is what makes hot reload safe. A saved program counter points into specific instructions, so
a running sequence continues against the instructions it started with instead of resuming into
edited control flow. Actions are resolved by name against the freshly registered functions, so
editing an action's *body* does take effect immediately.

Adopting edited control flow into an already-running sequence would need stable instruction labels
and an explicit migration step. That is deliberately not supported.

## Steps

| Constructor | Effect |
| --- | --- |
| `call(action, ...)` | Run a registered action with constant arguments |
| `wait(seconds)` | Wait a duration |
| `waitSteps(n)` | Wait a whole number of fixed steps |
| `waitSignal(name)` | Block until a named signal is raised |
| `waitQuery(name, cond)` | Block until a registered query matches, or stops matching |
| `emit(event, ...)` | Emit a `sequence.Event` at address 0 |
| `loop(count, nodes)` | Repeat a block, or forever when `count` is nil |
| `playTween(preset, bind)` | Play a tween preset on a bound entity |
| `waitTween()` | Wait for the tween that `playTween` started |
| `fork(nodes)` | Start a branch that runs alongside the rest of the program |
| `join()` | Wait for every outstanding branch |
| `parallel(...)` | Fork several blocks and wait for all of them |

### Time

`wait` is authored in seconds and converted to whole fixed steps **when the instruction runs**,
using the world's fixed timestep, **rounded to nearest**, with any non-zero duration waiting at
least one step. Converting at execution rather than compile time keeps a program independent of
any one world's timestep. Use `waitSteps` when the exact
step count matters more than the wall-clock duration.

`waitSteps(0)` yields: the cursor resumes on the next fixed step rather than continuing within the
current one. That gives a loop body a way to make progress without consuming instruction budget.

### Arguments

`call` and `emit` take constants stored in the program: numbers, strings, booleans, and arrays or
maps of those. Entities are **not** arguments — they arrive through bindings, so a saved program
never embeds an entity id and stays independent of any one world.

## Ownership and bindings

`play` takes two distinct kinds of entity:

**`owner`** governs lifetime. When the owner despawns, the playback is cancelled. Omit it for a
world-scoped sequence such as a wave schedule.

**`bindings`** are the entities the program acts on, addressed by name. A cutscene with several
actors needs no distinguished "the" target:

```teal
sequence.play(world, cutscene, {
    owner = director,
    bindings = { hero = heroId, villain = villainId, camera = cameraId },
})
```

Inside an action, `ctx:entity("villain")` resolves a binding, returning `nil` when it was not
supplied or its entity is no longer alive. That is not a fault: an action decides for itself
whether a binding is optional.

## Actions

```teal
sequence.registerAction(world, "game.spawnWave", function(world, ctx)
    -- ctx.world, ctx.handle, ctx.owner, ctx.args, ctx:entity(name)
end)
```

Registration is per world and by stable name, so a snapshot load or hot reload rebinds a saved
program to the freshly registered function.

Actions run **synchronously and atomically from the sequencer's perspective**: they must return
before the cursor advances, and they may not yield. An action that raises faults the playback with
`actionError`, and mutations it already made are kept — the sequencer does not roll them back.

### Deterministic-action contract

The sequencer guarantees that **control flow and scheduling** are deterministic and snapshot-safe.
It cannot make an arbitrary action deterministic. For replay and rewind to stay meaningful, an
action must not:

- read wall-clock time or frame-rate-dependent values
- touch the filesystem or network
- use `math.random`, whose state is not captured

Use `love.math.random`, whose generator state travels with snapshots (see
[Save games](/tecs/save-games)).

## Playback

```teal
local handle = sequence.play(world, intro, opts)

sequence.pause(world, handle)
sequence.resume(world, handle)
sequence.cancel(world, handle)

local s = sequence.status(world, handle)   -- state, program, version, pc, wakeAt, fault
```

A finished playback frees its arena slot immediately, so the arena is bounded by peak concurrency
rather than by every sequence ever played. Its `status` stays readable until the slot is handed to
a new playback, after which the old handle reports `nil` rather than another playback's state.

A handle is generation checked and **remains meaningful across a snapshot load**: it refers to the
same playback before and after a restore. A handle whose playback the snapshot did not carry
reports no status at all, exactly like a handle this world never issued.

A snapshot's sequence payload carries a layout version. Loading a save written by a build whose
cursor layout this one does not understand raises rather than restoring a half-cursor, and the
world's live playbacks are left untouched.

`status` reports one of `running`, `paused`, `completed`, `cancelled`, or `faulted`, along with the
program name, version, and program counter — the same values the disassembler indexes.

## Execution model

Sequences advance in **`FixedFirst`**. A sequence establishes commands and state for that fixed
iteration and gameplay consumes them afterward, so a `call` runs before physics and before the
gameplay systems of the same iteration.

The first instruction of a new playback runs on the next fixed step, never inside the `play` call.

### Instruction budget

A program that loops without waiting would never yield. Each playback has an instruction budget
**per fixed step**, shared across every time it resumes within that step; exceeding it faults with
`budgetExceeded`, reporting the program name, version, and pc so the offending instruction is
identifiable in a disassembly. Counting per step rather than per resume is what bounds a
`fork`/`join` loop, which would otherwise re-arm its budget on every join.

```teal
sequence.setInstructionBudget(world, 512)   -- world default
sequence.play(world, program, {budget = 4096})
```

Prefer `waitSteps(0)` in a loop body over raising the budget.

### Faults

| Reason | Cause |
| --- | --- |
| `unregisteredAction` | A `call` named an action not registered on this world |
| `actionError` | A registered action raised |
| `budgetExceeded` | The per-step instruction budget was exhausted |
| `branchFaulted` | A forked branch faulted |
| `unregisteredQuery` | A `waitQuery` named a query not registered on this world |
| `unregisteredTween` | A `playTween` named a preset not registered on this world |

A faulted playback stops and retains its `pc`, so the failure is inspectable rather than silent.

## Signals

A sequence can block on game state instead of time. `waitSignal` parks a playback on a named
channel; `sequence.signal` wakes everything waiting on that name.

```teal
local fight = sequence.define("game.bossFight", {
    sequence.call("game.spawnAdds"),
    sequence.waitSignal("adds.cleared"),
    sequence.call("game.phaseTwo"),
})

-- from an ordinary system, an observer, or another sequence
sequence.signal(world, "adds.cleared")
```

**Delivery is next-step.** A signal raised during step *N* wakes its waiters on step *N+1*. That
bounds a chain of signals to one link per step, and makes wake order independent of which cursor
happened to run first. Within a step, waiters wake in slot order, so the ordering is reproducible.

**Signals are not remembered.** Raising a signal nothing is waiting on is not an error and has no
lasting effect: a playback that reaches `waitSignal` afterwards keeps waiting. Signals are edges,
not state. Model "has this already happened" with a component or a resource and check it with an
action.

A blocked playback has no `wakeAt`; its `status` reports `waitingFor` instead. Undelivered signals
and blocked cursors both survive a snapshot.

`sequence.waitingOn(world, name)` reports how many playbacks are parked on a name, which is useful
in tests and in the debugger.

### Signals from events

An ECS event is an edge too, so it is wired to a signal rather than given a separate kind of wait:

```teal
sequence.signalOnEvent(world, "boss.died", BossDied)
```

Every `BossDied` emitted at address 0 now raises `boss.died`, delivered next step like any other
signal.

## Query waits

`waitQuery` blocks on a **condition on the world** rather than an edge:

```teal
sequence.registerQuery(world, "game.adds", {include = {Add}})

local fight = sequence.define("game.bossFight", {
    sequence.call("game.spawnAdds"),
    sequence.waitQuery("game.adds", "empty"),
    sequence.call("game.phaseTwo"),
})
```

The condition is `"any"` (at least one entity matches) or `"empty"` (none do). Because it is a
condition and not an edge, **a wait whose condition already holds resumes** instead of waiting
forever for a transition that has already happened — the failure mode that makes "wait until the
wave is cleared" hang when the wave was never spawned.

**The condition is tested at the start of the next fixed step, never at the instruction itself.**
Sequences advance first in a fixed iteration, so at the instruction the world still reflects the
previous one: nothing the rest of this iteration does has happened yet, and any mutation staged
inside a deferred scope has not landed. Testing one step later gives the condition a settled world.
A query wait therefore costs at least one step, including one that resolves immediately.

Waits stay event driven: the registered query subscribes to archetype transitions, and only names
that gained or lost entities since the last step are re-tested. Registration is startup work — a
name registered twice keeps the newer query, and the replaced one holds its subscriptions for the
life of the world.

Naming a query that is not registered faults with `unregisteredQuery`. A parked wait survives a
snapshot and is re-tested against the **restored** world, not the one it parked in.

## Tweens

`playTween` starts a registered tween preset on a bound entity, and `waitTween` waits for **that
playback**, not for the preset, the channel, or the entity:

```teal
local intro = sequence.define("game.bossIntro", {
    sequence.playTween("boss.enter", sequence.bind("boss")),
    sequence.waitTween(),
    sequence.call("game.startFight"),
})
```

`tween.play` returns a token identifying one run, and every playback ends exactly once, carrying
that token on `TweenComplete` or `TweenCancelled` (see [Tween](/tecs2d/tween#playback-tokens)).
`waitTween` follows the token, so the same tween running twice at once is never confused for
itself.

**`waitTween` never waits forever.** It resumes on any of four endings, and `status` reports which
in `tweenOutcome`:

| Outcome | Cause |
| --- | --- |
| `completed` | The playback finished |
| `cancelled` | `tween.cancel` matched it |
| `replaced` | Another playback took over its channel |
| `targetLost` | The bound entity died, was never bound, or lost its playback component |

A binding that is missing or already dead is not a fault. Nothing plays, and the following
`waitTween` resumes immediately reporting `targetLost` — the actor being gone is a game state, and
a program can branch on it. A preset that is not registered *is* a defect, and faults with
`unregisteredTween`.

`playTween` needs the tween plugin, which `tecs2d.run` installs. Playback options pass straight
through:

```teal
sequence.playTween("boss.hover", sequence.bind("boss"), {mode = "pingPong", count = 4})
```

## Branches

Most cutscenes are not a single line of steps. `parallel` runs several blocks at once and continues
once all of them finish:

```teal
local intro = sequence.define("game.bossIntro", {
    sequence.parallel(
        {sequence.call("game.panCamera"), sequence.wait(2.0)},
        {sequence.call("game.bossWalkIn"), sequence.waitSignal("boss.inPlace")}
    ),
    sequence.call("game.startFight"),
})
```

`fork(block)` and `join()` are the underlying pair: `fork` starts a branch and keeps going, `join`
waits for every branch started and not yet joined. `parallel` is exactly a run of forks followed by
a join.

A branch is a playback of its own, running the same program at a different instruction. It
inherits the parent's `owner`, bindings, and instruction budget, and it may fork branches of its
own.

**Ordering.** A branch is queued rather than entered: it starts once the playback that forked it
next waits, joins, or ends, still within the same fixed step. Branches forked in one place run in
the order they were forked. When the last branch of a joining playback finishes, that playback
resumes **in the same step**, so a `parallel` of short blocks costs no extra steps.

**Lifetime.** Branches never outlive the playback that forked them. Cancelling it, or letting it
run off the end of its program, cancels the branches it has not joined. Cancelling a branch on its
own is fine: `join` simply proceeds with one fewer branch. Despawning the owner cancels the whole
tree.

**Faults propagate up.** A branch that faults faults the playback that forked it, with reason
`branchFaulted`, which in turn tears down its siblings. A faulted branch is a bug in the program,
not a game state, so it surfaces rather than leaving a `join` short one branch. The branch's own
fault is logged with its own pc.

**`pause` and `resume` apply to the whole tree**, so pausing a cutscene pauses everything it
started.

`join` with no outstanding branches falls straight through, and `status` reports the number of live
branches.

## Events

`emit` dispatches a `sequence.Event` at address 0, carrying the authored name, the arguments with
bindings resolved, and the handle of the playback that emitted it:

```teal
world:observe(0, sequence.Event, function(e: sequence.Event)
    if e.name == "boss.ready" then startFight() end
end)
```

## Debugging

`disassemble(program, pc)` renders a program as readable instructions with their indices, marking
one of them, so a `pc` from `status` or a fault points at a specific step.

The debugger exposes the same view, in the overlay and as `cmd_*` MCP tools:

```
 Command              Shows
 ───────────────────  ──────────────────────────────────────────────────
 sequence list        every live playback, its pc, and what blocks it
 sequence info <h>    one playback's status plus its disassembly, pc marked
 sequence programs    defined programs and their newest version
 sequence disasm <n>  a program by name, or a specific version of it
 sequence signal <n>  raise a signal, waking the playbacks blocked on it
```

`sequence info` disassembles the exact version that playback is running, which is the version worth
reading when a hot reload has moved on without it.

## Performance

Playbacks are scheduled through a min-heap keyed on `(wakeAt, seq)`, so a step costs one
comparison plus the playbacks that actually wake on it. Measured with
`make bench-love SCENARIO=sequence`, and directly under LuaJIT at 1K through 100K playbacks all
waking on every step:

- About **200ns per playback per wake**, flat across that whole range — a thousand playbacks all
  running on the same step cost roughly 0.2ms.
- **Sleeping playbacks cost nothing.** Only the earliest wake time is examined per step, so a large
  population that mostly waits does not show up at all. This is why the heap is worth keeping over
  a scan of the arena, which would pay per playback per step regardless.
- **No steady-state allocation.** Waking, running, and rescheduling a playback allocates nothing,
  so the sequencer adds no GC pressure at any population size.

Actions are the exception: whatever a `call` does is the program's own cost.

## See also

- [Tween](/tecs2d/tween) for animating numeric component fields
- [Save games](/tecs/save-games) for what a snapshot captures
- [Phases](/tecs/phases) for where `FixedFirst` sits in the frame
