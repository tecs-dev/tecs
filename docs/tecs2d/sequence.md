---
description: "Deterministic, snapshot-safe gameplay sequencing: programs, actions, bindings, playback handles, and the deterministic-action contract"
outline: deep
---

# Sequence

`tecs2d.sequence` runs scripted gameplay logic that survives a save. Cutscenes, ability chains,
spawn waves, tutorials, and scripted encounters are naturally written as coroutines, and a
suspended coroutine lives in the Lua stack, which cannot be serialized. A sequence keeps its
position as data, so it snapshots, rewinds, and hot reloads like any other game state.

::: warning Runtime not implemented
This page documents the contract. `tecs2d.sequence` currently declares its public API and every
entry point raises. The runtime lands in the next phase.
:::

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
| `emit(event, ...)` | Emit an ECS event at address 0 |
| `loop(count, nodes)` | Repeat a block, or forever when `count` is nil |

### Time

`wait` is authored in seconds and converted to whole fixed steps at compile time, **rounded to
nearest**, with any non-zero duration waiting at least one step. Use `waitSteps` when the exact
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
supplied or its entity is no longer alive. A `call` whose action requires a missing binding faults
with `missingBinding`.

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

A handle is generation checked and **remains meaningful across a snapshot load**: a handle saved
before a snapshot refers to the same playback after restore, and reports `cancelled` if that
playback did not survive.

`status` reports one of `running`, `paused`, `completed`, `cancelled`, or `faulted`, along with the
program name, version, and program counter — the same values the disassembler indexes.

## Execution model

Sequences advance in **`FixedFirst`**. A sequence establishes commands and state for that fixed
iteration and gameplay consumes them afterward, so a `call` runs before physics and before the
gameplay systems of the same iteration.

The first instruction of a new playback runs on the next fixed step, never inside the `play` call.

### Instruction budget

A program that loops without waiting would never yield. Each playback has a per-step instruction
budget; exceeding it faults with `budgetExceeded`, reporting the program name, version, and pc so
the offending instruction is identifiable in a disassembly.

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
| `missingBinding` | A required binding was absent or its entity was not alive |

A faulted playback stops and retains its `pc`, so the failure is inspectable rather than silent.

## Debugging

`disassemble(program)` renders a program as readable instructions with their indices, so a `pc`
from `status` or a fault points at a specific step.

## Planned

Later phases add orchestration and tween composition:

- Signals, event waits, and query waits, so a sequence can block on game state rather than time
- `fork` and `join` for parallel branches
- `playTween` / `waitTween`, waiting on a specific tween playback and resuming on completion,
  cancellation, channel replacement, or binding destruction

## See also

- [Tween](/tecs2d/tween) for animating numeric component fields
- [Save games](/tecs/save-games) for what a snapshot captures
- [Phases](/tecs/phases) for where `FixedFirst` sits in the frame
