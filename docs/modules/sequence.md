---
description: "Deterministic, snapshot-safe sequencing: compiled programs, playback handles, three clocks, and the tween timelines that run on the same runtime"
outline: deep
---

# tecs.sequence

`tecs.sequence` runs scripted gameplay logic that survives a save. Cutscenes, ability chains, spawn waves and
tutorials are normally written as coroutines, and a suspended coroutine lives in the Lua stack, which cannot be
serialized. A sequence keeps its position as data: a program is compiled to instructions, and a playback is an
instruction pointer plus its waits. That is what lets it snapshot, rewind and hot reload like any other game
state.

The tween runtime is inside it rather than beside it. A timeline compiles to a program with one instruction, so
an animation is a playback like any other: it is owned by an entity, it holds a channel, it can be paused,
cancelled and waited on, and it comes back from a snapshot where it was.

```teal
local sequence <const> = tecs.sequence

sequence.registerAction(world, "game.lockControls", function(_w, _ctx)
    controlsLocked = true
end)

local intro <const> = sequence.define("game.bossIntro", {
    sequence.call("game.lockControls"),
    sequence.wait(1.5),
    sequence.emit("boss.ready"),
})

sequence.play(world, intro, {owner = encounter, bindings = {boss = bossId}})
```

## Programs

### define

Compiles a program under a stable symbolic name.

```teal
function sequence.define(name: string, nodes: {Node}, options?: DefineOptions): Program
```

**Parameters:**

- `name`: the symbolic name a snapshot stores, so it has to survive builds. Dotted names keep them
  unambiguous.
- `nodes`: the steps, in order, from the node constructors below.
- `options.clock`: which clock the program's waits count. `"fixed"` by default. Anything else raises.

**Returns:** a `Program`, which is immutable and shared by every playback of it. It carries `name` and a
monotonic `version` starting at 1.

Redefining a name compiles a new version rather than mutating the existing one. Playbacks already running keep
the version they started with, so a hot reload continues against the instructions it started with rather than
resuming into edited control flow. Later `play` calls use the newest version, and a superseded version is
released once its last playback finishes. Actions are resolved by name at the moment they run, so editing an
action's body does take effect immediately.

Node values are opaque, and a node must not be reused across programs.

### The clocks

A program is scheduled against exactly one clock, and its waits are counted in that clock's ticks.

| Clock            | Advances                                                        | For                                                                                                               |
| ---------------- | --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `"fixed"`        | In the `FixedFirst` phase, once per fixed step                  | Gameplay logic. The default, and what a deterministic program wants.                                              |
| `"frame"`        | In the `First` phase, once per gameplay frame                   | Scripted input: one decision per frame, taken before anything reads it, however many fixed steps that frame runs. |
| `"presentation"` | In the `Update` phase, once per frame with the frame's own `dt` | Continuous evaluation that has to look smooth at the display's rate rather than the simulation's.                 |

Seconds are authored and a clock counts ticks, so `wait` converts: the fixed clock uses the world's fixed
timestep and the frame clock uses the loop's nominal frame `dt`, which is what keeps the same program waiting
the same wall-clock time on either.

### defineData

Compiles a program written as plain data rather than node calls.

```teal
function sequence.defineData(name: string, rows: {any}, options?: DefineOptions): Program, string
```

The same authoring model as a list of steps, for callers that cannot invoke Lua: a tool over the debug
server, a file on disk, a hand-written table.

**Returns:** the program, or nil plus the path to the first bad entry. Decoding validates as it goes, since the
author is usually a tool and the message is all it gets.

```teal
local intro <const> = sequence.defineData("game.intro", {
    {op = "call", action = "game.lockControls"},
    {op = "wait", seconds = 1.5},
    {op = "parallel", blocks = {
        {{op = "playTween", preset = "boss.enter", bind = "boss"},
         {op = "waitTween"}},
        {{op = "waitQuery", query = "game.adds", condition = "empty"}},
    }},
    {op = "emit", event = "boss.ready"},
})
```

An entity reference travels as `{bind = "name"}` wherever an argument is expected, because it is the one
argument that is not a plain constant.

### dataOps

The step names `defineData` accepts, sorted. For help text and tool schemas.

```teal
function sequence.dataOps(): {string}
```

**Returns:** `call`, `emit`, `fork`, `join`, `loop`, `parallel`, `playTween`, `wait`, `waitQuery`,
`waitSignal`, `waitSteps`, `waitTween`.

### program, programNames

```teal
function sequence.program(name: string, version?: integer): Program
function sequence.programNames(): {string}
```

`program` looks up the newest version of a defined program, or a specific one. Every version a playback still
runs stays reachable. `programNames` answers every defined name, sorted.

### disassemble

Renders a program as readable instructions.

```teal
function sequence.disassemble(program: Program, pc?: integer): string
```

**Parameters:**

- `pc`: marks this instruction, as a playback's `status` reports it.

## Steps

| Constructor                            | Effect                                                         |
| -------------------------------------- | -------------------------------------------------------------- |
| `call(action, ...)`                    | Run a registered action with constant arguments.               |
| `wait(seconds)`                        | Wait a duration.                                               |
| `waitSteps(steps)`                     | Wait a whole number of ticks.                                  |
| `waitSignal(name)`                     | Block until a named signal is raised.                          |
| `waitQuery(name, condition)`           | Block until a registered query matches, or stops matching.     |
| `emit(event, ...)`                     | Emit a `sequence.Event` at address 0.                          |
| `loop(count, nodes)`                   | Repeat a block, or repeat until cancelled when `count` is nil. |
| `fork(nodes)`                          | Start a branch alongside the rest of the program.              |
| `join()`                               | Wait for every branch forked and not yet joined.               |
| `parallel(...)`                        | Fork several blocks and wait for all of them.                  |
| `playTween(timeline, target, params?)` | Play a registered timeline on a bound entity.                  |
| `waitTween()`                          | Wait for the playback the most recent `playTween` started.     |
| `await(provider, target, key?)`        | Wait for something outside the sequencer to finish.            |
| `eval(evaluator, data?)`               | Evaluate a registered evaluator every tick until it finishes.  |
| `bind(name)`                           | Not a step: a reference to an entity supplied at `play` time.  |

### call

```teal
function sequence.call(action: string, ...: Argument): Node
```

Runs the action registered on this world under that name. Arguments are constants: numbers, strings, booleans,
and arrays or maps composed of those, plus `bind(name)` references, which resolve to entity ids when the
instruction runs. Anything else, a function, cdata or a raw entity, is rejected by `define`, because a program
has to survive a snapshot.

Naming an action this world has not registered faults the playback with `unregisteredAction`.

### wait

```teal
function sequence.wait(seconds: number): Node
```

Converted to whole ticks when the instruction runs, rounded to nearest, with any non-zero duration waiting at
least one tick: a frame-clock program converts with the loop's nominal frame `dt` and every other program with
the world's fixed timestep. Programs therefore stay independent of any one world's timestep. A negative
duration raises at authoring time.

### waitSteps

```teal
function sequence.waitSteps(steps: integer): Node
```

Waits an exact number of ticks, for when the count matters more than the wall-clock duration. `waitSteps(0)`
yields: the cursor resumes on the next tick rather than continuing within the current one.

### waitSignal

```teal
function sequence.waitSignal(name: string): Node
```

Blocks until `signal` raises that name. Signals are delivered on the tick after `signal` is called, so a signal
raised by one sequence never runs another within the same step. That bounds a chain of signals to one link per
step and keeps delivery order independent of which cursor happened to run first.

### waitQuery

```teal
function sequence.waitQuery(name: string, condition: QueryCondition): Node
```

**Parameters:**

- `name`: a query registered with `registerQuery`. An unregistered name faults with `unregisteredQuery`.
- `condition`: `"any"` for at least one matching entity, `"empty"` for none.

Unlike a signal, which is an edge, this is a condition on the world: a wait whose condition already holds
resumes rather than waiting for a transition that has already happened. The condition is evaluated at the start
of the next tick, never at the instruction itself, so it never reads a world that a spawn or despawn from the
current step has not been committed to yet. A query wait therefore costs at least one tick.

### emit

```teal
function sequence.emit(event: string, ...: Argument): Node
```

Emits a [`sequence.Event`](#events) at address 0, with the bindings among its arguments already resolved.

### loop

```teal
function sequence.loop(count: integer, nodes: {Node}): Node
```

Repeats a block `count` times, or until the playback is cancelled when `count` is nil. The count must be a
positive whole number and the block must not be empty.

### fork, join, parallel

```teal
function sequence.fork(nodes: {Node}): Node
function sequence.join(): Node
function sequence.parallel(...: {Node}): Node
```

A branch is a playback of its own running the same program at a different instruction, and it inherits the
owner, bindings and instruction budget of the playback that forked it. It starts once that playback next waits,
joins or ends, within the same tick.

A branch never outlives the playback that forked it: finishing or cancelling that playback cancels the branches
it has not joined. A branch that faults faults its parent with `branchFaulted`, because that is a defect in the
program; a branch that is cancelled is deliberate, and a `join` simply proceeds without it.

`join` falls straight through when there are no branches. When the last branch finishes, the waiting playback
resumes within that same tick. `parallel` is sugar for a `fork` per block followed by one `join`, and blocks
start in the order they are given.

### playTween, waitTween

```teal
function sequence.playTween(timeline: string, target: EntityRef, params?: {string: any}): Node
function sequence.waitTween(): Node
```

`playTween` names a timeline compiled with [`timeline`](#timeline) and a `bind(name)` target, and starts it as
a playback of its own: the bound entity is its owner, `params` is what it runs with, and the playback that
started it holds its handle. An unregistered name faults with `unregisteredTween`. A binding that is missing or
dead is not a fault: nothing plays, and a following `waitTween` resumes at once reporting `targetLost`.

`waitTween` resumes when that specific playback completes, is cancelled, is replaced on its channel, or loses
its entity, so it never waits forever. Which of those happened is `status.tweenOutcome`.

```teal
sequence.playTween("boss.enter", sequence.bind("boss"), {speed = 1.5, channel = "move"}),
sequence.waitTween(),
```

### await

```teal
function sequence.await(provider: string, target: EntityRef, key?: string): Node
```

Waits for something outside the sequencer to finish. A subsystem registers a provider under a name and answers
whether the work is still going; this parks the playback until it is not. The sequencer never learns what the
work is, which is how a program waits on a sprite animation without the sequencer requiring the renderer.

A binding that is missing or dead is not a fault: there is nothing to wait for and the program carries on. So
is a provider reporting a thing that never started. An unregistered provider faults with
`unregisteredAwaitable`.

```teal
sequence.call("game.playTag", sequence.bind("hero"), "hurt"),
sequence.await("game.spriteAnimation", sequence.bind("hero")),
```

`"tecs.future"` is the one provider the engine registers, so a program can park on an asset decode, a child
process or a request. `Future.track(world, entity, key, future)` is what puts a future under a name this can
await, and it is keyed by entity and key rather than by the future's identity for a reason a program has to know
about: a future is never in a snapshot, since it holds listeners, a source and a native handle. So the wait
survives a load and the future does not. Nothing is tracked afterwards, `isPending` answers false, and the parked
playback carries on at the next fixed step. A program that needs the wait to still mean something re-issues the
work on load and re-tracks it under the same key.

### eval

```teal
function sequence.eval(evaluator: string, data?: any): Node
```

Unlike every other step, this one does not hand the tick back: the playback joins its clock's active set and is
stepped each tick, which is what a value that has to move every frame needs. `data` is compiled into the
program alongside the evaluator's name, so it travels with a snapshot and has to be plain data for the same
reason a `call` argument does. An unregistered name faults with `unregisteredEvaluator`.

This is the step a compiled timeline is made of.

### bind

```teal
function sequence.bind(name: string): EntityRef
```

References an entity supplied through `PlayOptions.bindings`, resolved when the instruction that uses it runs
rather than when the program is defined. An empty name raises.

## Actions

An action is the effect half of a program: a registered function a `call` step names.

### registerAction

```teal
function sequence.registerAction(world: World, name: string, action: Action)
function sequence.hasAction(world: World, name: string): boolean
```

`Action` is `function(world: World, ctx: ActionContext)`. It runs synchronously and must return before the
cursor advances; it may not yield. Raising faults the playback with `actionError`, and mutations the action
already made are kept: the sequencer does not roll them back.

Registration is per world, unlike evaluators and awaitables, because an action closes over a game's own state.

::: warning The deterministic-action contract
Actions must obey it to keep replay and rewind meaningful: no wall-clock reads, no file or network access, and
randomness only from a generator whose state travels with the snapshot.
:::

### ActionContext

| Field                  | Type                                      | Description                                                                                 |
| ---------------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------- |
| `world`                | `World`                                   | The world this playback belongs to.                                                         |
| `handle`               | `Handle`                                  | The playback, for `status` or `cancel` from inside an action.                               |
| `owner`                | `integer`                                 | The `owner` supplied at `play`, or 0 for a world-scoped sequence.                           |
| `args`                 | `{any}`                                   | Constants supplied by the `call` node, with `bind` references already resolved.             |
| `params`               | `{string: any}`                           | The `params` supplied at `play`, or nil.                                                    |
| `entity(self, name)`   | `function(name: string): integer`         | Resolves a named binding, or nil when it was not supplied or its entity is no longer alive. |
| `bind(self, name, id)` | `function(name: string, entity: integer)` | Names an entity for the steps that follow. Passing nil forgets the name.                    |

The context and its `args` belong to the sequencer and are reused by the next call. Read them; do not keep or
modify them. `params` is the exception: it is the playback's own table, and it is the same one every step of
the playback sees. Bindings written with `ctx:bind` travel with the playback and survive a snapshot, so an
action that creates an entity can hand it on.

```teal
sequence.registerAction(world, "game.face", function(w, ctx)
    local boss <const> = ctx:entity("boss")
    if boss then w:getMut(boss, Facing).dir = ctx.args[1] as number end
end)
```

### registerQuery

```teal
function sequence.registerQuery(world: World, name: string, descriptor: ecs.Query.Descriptor)
function sequence.hasQuery(world: World, name: string): boolean
```

Registers a query a `waitQuery` step can name. The query subscribes to archetype transitions, so a wait on it
stays event driven rather than polling; the callbacks only mark the name, and the condition is tested once per
step for every name that moved rather than once per entity. A descriptor's own `onEntitiesAdded` and
`onEntitiesRemoved` are still called.

Registration is startup work. A name registered twice keeps the newer query, and the replaced one holds its
subscriptions for the life of the world.

### registerEvaluator

```teal
function sequence.registerEvaluator(name: string, evaluator: Evaluator)
```

Registers something an `eval` step can name. Registration is global, like a program: an evaluator is code, and
two worlds evaluating the same name run the same thing. Registering a name twice replaces it, which is what a
hot reload wants.

| Field                          | Description                                                                                                                                                                  |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `resolve(data)`                | Turns the constants an `eval` step carries into whatever form is cheapest to read every tick. Called once per program constant and shared by every playback of it. Optional. |
| `newState(prog, data, cursor)` | Per-playback working state, or nil when it needs none.                                                                                                                       |
| `step(world, cursor, dt)`      | Advances one playback by `dt`. Returns true when it is finished and the playback moves to the next instruction. Required.                                                    |
| `save(state)`                  | Turns working state into something a snapshot can carry.                                                                                                                     |
| `load(prog, data, saved)`      | Turns it back. Without both, an evaluating playback comes back at the start of its state rather than where it was.                                                           |

### registerAwaitable

```teal
function sequence.registerAwaitable(name: string, provider: Awaitable)
```

Registers something an `await` step can name. Global, like an evaluator, and for the same reason: a provider is
code, and a snapshot carries the name it was registered under.

| Field                                   | Description                                                                                                                                                                                                                                                                                                                                 |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `isPending(world, entity, key)`         | Whether the work named by `entity` and `key` is still going. Required. Called at a step boundary for every playback parked on this name, so it must be cheap and must not mutate the world. Returning false for something that never started is correct: a program waiting for an animation that is already over should carry on, not hang. |
| `setPaused(world, entity, key, paused)` | Stops and starts the work. Optional. Called when the playback parked on it is paused or resumed, so a cutscene that is waiting for an animation stops it rather than leaving it running underneath.                                                                                                                                         |

## Signals

### signal

```teal
function sequence.signal(world: World, name: string): integer
```

Raises a named signal, waking every playback blocked on it.

**Returns:** how many playbacks will wake.

Delivery happens on the next tick. Raising a signal nothing is waiting on is not an error and is not
remembered: a playback that reaches `waitSignal` afterwards keeps waiting.

### waitingOn

```teal
function sequence.waitingOn(world: World, name: string): integer
```

**Returns:** how many playbacks are currently blocked on that signal name.

### signalOnEvent

```teal
function sequence.signalOnEvent<T is ecs.Event>(world: World, name: string, event: T)
```

Raises a signal every time an event is emitted at address 0. An ECS event is an edge, like a signal, so this
wires one to the other rather than adding a separate kind of wait. Delivery follows the ordinary signal rule:
waiters wake on the next tick.

## Playback

### play

Starts a program. The first instruction runs on the next tick of its clock, never inside the `play` call.

```teal
function sequence.play(world: World, program: Program, options?: PlayOptions): Handle
```

| Option     | Type                | Default            | Description                                                                                                                    |
| ---------- | ------------------- | ------------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| `owner`    | `integer`           | `0`                | Entity whose lifetime governs the playback. When it despawns the playback is cancelled. Omit for a world-scoped sequence.      |
| `bindings` | `{string: integer}` | none               | Entities the program acts on, addressed by `sequence.bind(name)`.                                                              |
| `params`   | `{string: any}`     | none               | Constants this playback runs with, readable by its actions and its evaluators. Plain data, because it travels with a snapshot. |
| `budget`   | `integer`           | the world's budget | Per-step instruction budget for this playback.                                                                                 |
| `channel`  | `string`            | none               | Names a slot this playback occupies on its owner.                                                                              |

**Returns:** a `Handle`, a generation-checked integer. It remains meaningful across a snapshot load: a handle
refers to the same playback before and after a restore. A handle whose playback the snapshot did not carry
reports no status at all, the same as a handle this world never issued.

A program is shared by every playback of it, so anything that differs between two of them belongs in `params`
rather than in the program.

Taking a channel cancels whatever held it, reporting `replaced` to anything that was waiting on it. Channels are
per owner: one entity's `"move"` is not another's, and a world-scoped playback has no owner to hold a channel
on and so holds none. That is how a second fade replaces the first rather than fighting it.

### cancel

```teal
function sequence.cancel(world: World, handle: Handle): boolean
```

Stops a playback and releases its cursor, cancelling its branches and anything it started. Safe on a finished
handle, which answers false.

### pause, resume

```teal
function sequence.pause(world: World, handle: Handle, holder?: string): boolean
function sequence.resume(world: World, handle: Handle, holder?: string): boolean
```

Suspends a playback, its branches, and anything it started. Pause is holder counted: two systems can hold the
same playback for unrelated reasons, a menu being open and the window losing focus, and it runs again only when
the last one lets go, so whichever resumes first cannot undo the other. `holder` defaults to `"user"`.

`pause` returns whether the playback stopped. A second holder taking a hold on one that is already paused
registers the hold and returns false, because nothing observable changed. `resume` returns whether the playback
started running again, which is only true for the last holder to let go.

A wait resumes from where it paused. What the playback is waiting on stops with it when the awaitable provider
knows how. A playback whose wake time passed while it was paused runs on the next tick rather than immediately.

### status

```teal
function sequence.status(world: World, handle: Handle): Status
```

**Returns:** the playback's current state, or nil for a handle this world never issued.

| Field                    | Type             | Description                                                                  |
| ------------------------ | ---------------- | ---------------------------------------------------------------------------- |
| `state`                  | `PlaybackState`  | `"running"`, `"paused"`, `"completed"`, `"cancelled"` or `"faulted"`.        |
| `program`                | `string`         | Program name this playback is running.                                       |
| `version`                | `integer`        | Program version it started with.                                             |
| `pc`                     | `integer`        | Instruction index, for disassembly and debugging.                            |
| `wakeAt`                 | `integer`        | Tick it next runs on. Nil when it is blocked on something other than a time. |
| `waitingFor`             | `string`         | Signal name it is blocked on, when it is.                                    |
| `waitingQuery`           | `string`         | Query name it is blocked on, when it is.                                     |
| `waitingCondition`       | `QueryCondition` | The condition that query wait is for.                                        |
| `waitingAwaitable`       | `string`         | Awaitable provider it is blocked on, when it is.                             |
| `waitingAwaitableEntity` | `integer`        | The entity that await is on.                                                 |
| `waitingTween`           | `integer`        | Handle of the tween playback it is blocked on, when it is.                   |
| `tweenOutcome`           | `TweenOutcome`   | How the last tween it waited on ended.                                       |
| `branches`               | `integer`        | Live branches it forked and has not joined.                                  |
| `joining`                | `boolean`        | Whether it is parked at a `join` waiting for those branches.                 |
| `fault`                  | `FaultReason`    | Set when `state` is `"faulted"`.                                             |
| `faultMessage`           | `string`         | Set when `state` is `"faulted"`.                                             |

A finished playback frees its slot immediately, so the arena is bounded by peak concurrency. Its record stays
until the slot is handed out again, which is what lets `status` report a final state; once reused, the
generation check makes the old handle report nothing rather than another playback's state.

### cancelOwnedBy

```teal
function sequence.cancelOwnedBy(world: World, owner: integer, reason?: TweenOutcome): integer
```

Cancels every playback owned by an entity, in a stable order.

**Parameters:**

- `reason`: what anything waiting on one of them is told. The owner despawning reports `targetLost`, which is
  what a waiter needs to tell "it was stopped" from "what it was moving is gone".

**Returns:** how many were cancelled.

### activeCount, playbacks

```teal
function sequence.activeCount(world: World): integer
function sequence.playbacks(world: World): {Handle}
```

`activeCount` is the number of live playbacks. `playbacks` answers handles for every one of them, branches
included, in a stable order. For diagnostics and the debugger, not for hot paths.

## Budget and introspection

### setInstructionBudget

```teal
function sequence.setInstructionBudget(world: World, instructions: integer)
```

Sets the per-step instruction budget for playbacks that do not set their own. It defaults to 512. The budget is
spent per tick rather than per resume, so a playback that wakes again within the same tick cannot re-arm it, and
a playback that runs past it faults with `budgetExceeded`. That is what stops a `loop` with no wait in it from
hanging the frame.

### currentStep

```teal
function sequence.currentStep(world: World, clock?: ClockId): integer
```

**Returns:** a clock's current tick, as counted by the sequencer. Defaults to the fixed clock.

### upcoming

What a playback will certainly do next, and when.

```teal
function sequence.upcoming(world: World, handle: Handle, withinTicks?: integer): {Step}
```

Walks the straight-line run ahead of where the playback sits, accumulating waits, and stops at the first
instruction whose successor cannot be known without running it: a jump, a fork, a join, or a wait on something
other than time. Ticks are counted in the playback's own clock, from now. A playback parked on a signal, a
query, a join or a tween has no predictable start at all and answers an empty list.

**Parameters:**

- `withinTicks`: report only what is due within this many ticks.

Each `Step` carries `ticks`, `kind` (`"call"` or `"emit"`), `name`, and the `args` the step holds, unresolved.

## Events

`sequence.Event` is emitted at address 0 by an `emit` step and by a timeline's `tweenEmit`.

| Field    | Type     | Description                                                                             |
| -------- | -------- | --------------------------------------------------------------------------------------- |
| `name`   | `string` | The name the step was given.                                                            |
| `args`   | `{any}`  | The arguments, with bindings resolved. Built per emit, so it is the observer's to keep. |
| `handle` | `Handle` | The playback that emitted it.                                                           |

```teal
world:observe(0, sequence.Event, function(event: sequence.Event)
    if event.name == "boss.ready" then startFight() end
end)
```

A timeline emit carries the entity it played on as its single argument.

## Timelines

A timeline is a tween program: a list of interpolations placed on a shared clock, compiled into the const pool
of an ordinary program. It is snapshot-safe for the same reason every other program is.

### timeline

```teal
function sequence.timeline(name: string, spec: TimelineSpec, options?: TimelineOptions): Program
```

**Parameters:**

- `name`: the stable symbolic name, as for `define`. This is also the name a `playTween` step gives.
- `spec`: a list of timeline nodes, run in order unless nested inside `tweenParallel`.
- `options.clock`: `"presentation"` by default, which moves at the display's rate. `"fixed"` makes it
  deterministic from a snapshot alone, at the cost of stepping at the simulation's rate. Anything else raises.

**Returns:** a `Program`. Play it with `play`, giving the entity it animates as the `owner`, or name it from a
`playTween` step.

::: warning Only `Transform` is interpolated between fixed steps
So a fixed-clock tween of anything else visibly steps. If the simulation can observe the value, put it on
`"fixed"` anyway; if only the player does, leave it on `"presentation"`.
:::

```teal
local fade <const> = sequence.timeline("game.fade", {
    sequence.tweenTo(0.4, "quadOut", "color.a", 0),
})
sequence.play(world, fade, {owner = e, params = {delay = 0.2}})
```

### Playback params

A timeline reads four values out of the playback's `params`, all optional:

| Param   | Type                                 | Default  | Description                                                                                                 |
| ------- | ------------------------------------ | -------- | ----------------------------------------------------------------------------------------------------------- |
| `mode`  | `"once"` \| `"loop"` \| `"pingPong"` | `"once"` | How it repeats.                                                                                             |
| `count` | `integer`                            | endless  | Passes for a finite loop or ping-pong. Only valid with `loop` or `pingPong`, and must be greater than zero. |
| `speed` | `number`                             | `1`      | Playback multiplier. Must be greater than zero.                                                             |
| `delay` | `number`                             | `0`      | Seconds to wait before the first frame. Must be at least zero.                                              |

A repeating timeline has to have a duration; a mode other than `once` on one with none raises. A playback with
no owner has nothing to write to, so it finishes rather than faulting, which is the same answer a despawned
target gives.

`channel` in `params` is read by a `playTween` step and becomes the started playback's channel, so two tweens
sharing a channel on one entity replace rather than fight.

### Timeline nodes

```teal
function sequence.tweenTo(duration, curve, target, t1, t2?, t3?, t4?): TimelineNode
function sequence.tweenAdjust(duration, curve, target, t1, t2?, t3?, t4?): TimelineNode
function sequence.tweenTrack(duration, curve, target, from: TrackSource): TimelineNode
function sequence.tweenWait(duration: number): TimelineNode
function sequence.tweenEmit(name: string): TimelineNode
function sequence.tweenRun(spec: TimelineSpec, options?: RunOptions): TimelineNode
function sequence.tweenParallel(...: TimelineNode): TimelineNode
```

| Node            | Effect                                                                           |
| --------------- | -------------------------------------------------------------------------------- |
| `tweenTo`       | Interpolates to an absolute destination.                                         |
| `tweenAdjust`   | Interpolates by a relative delta, read from wherever the value starts.           |
| `tweenTrack`    | Interpolates toward a destination that keeps moving, re-read every tick.         |
| `tweenWait`     | Advances the timeline cursor without changing anything.                          |
| `tweenEmit`     | Emits a named `sequence.Event` when the cursor reaches that point.               |
| `tweenRun`      | Runs a nested timeline, given as its own spec, with its own mode and pass count. |
| `tweenParallel` | Runs nodes concurrently, ending with the longest.                                |

`duration` must be greater than zero for the three interpolating nodes, and at least zero for `tweenWait`.
`curve` is an easing name or one of the built-in easing values. `target` is a built-in target name or a target
value. The `t1` to `t4` numbers are the destination, and how many of them mean anything depends on the target:
one for a scalar field, two for a pair, four for a colour.

`RunOptions` takes `mode` and `count`, with the same meanings as the playback params. A nested run must be
finite: `loop` or `pingPong` without a count raises, because a nested timeline occupies a window of its parent
and an endless one has no end for the parent to continue from.

A timeline node is opaque and compiling one writes its resolved form into it, so a node must not be reused
across timelines.

```teal
local hit <const> = sequence.timeline("game.hit", {
    sequence.tweenParallel(
        sequence.tweenTo(0.08, "quadOut", "transform.scaleXY", 1.2, 1.2),
        sequence.tweenTo(0.08, "linear", "color.rgba", 1, 0.3, 0.3, 1)
    ),
    sequence.tweenTo(0.12, "quadIn", "transform.scaleXY", 1, 1),
    sequence.tweenEmit("game.hitDone"),
})
```

### Easing

`sequence.easing` holds the built-in curves, and their names are what a node takes as a string. Every curve
maps 0 to 0 and 1 to 1; what varies is the path between them. `In` accelerates, `Out` decelerates, `InOut` does
both, and `OutIn` does them in the opposite order.

| Family    | Variants                                               |
| --------- | ------------------------------------------------------ |
| `linear`  | `linear`                                               |
| `quad`    | `quadIn` `quadOut` `quadInOut` `quadOutIn`             |
| `cubic`   | `cubicIn` `cubicOut` `cubicInOut` `cubicOutIn`         |
| `quart`   | `quartIn` `quartOut` `quartInOut` `quartOutIn`         |
| `quint`   | `quintIn` `quintOut` `quintInOut` `quintOutIn`         |
| `sine`    | `sineIn` `sineOut` `sineInOut` `sineOutIn`             |
| `expo`    | `expoIn` `expoOut` `expoInOut` `expoOutIn`             |
| `back`    | `backIn` `backOut` `backInOut` `backOutIn`             |
| `elastic` | `elasticIn` `elasticOut` `elasticInOut` `elasticOutIn` |
| `bounce`  | `bounceIn` `bounceOut` `bounceInOut` `bounceOutIn`     |

A curve may be given either way: `"quadOut"` or `sequence.easing.quadOut`. Both compile to the same slot,
because a compiled timeline stores the name so a snapshot can carry it, and a curve that is not one of these has
no name to store.

### Targets

`sequence.target` holds the built-in animation targets and the constructors for new ones.

| Name                         | Component   | Fields             | Notes                                                             |
| ---------------------------- | ----------- | ------------------ | ----------------------------------------------------------------- |
| `transform.x`                | `Transform` | `x`                | `sequence.target.translateX`                                      |
| `transform.y`                | `Transform` | `y`                | `sequence.target.translateY`                                      |
| `transform.xy`               | `Transform` | `x`, `y`           | `sequence.target.translateXY`                                     |
| `transform.rotation`         | `Transform` | `rotation`         | `sequence.target.rotation`                                        |
| `transform.rotationShortest` | `Transform` | `rotation`         | `sequence.target.rotationShortest`, taking the shortest way round |
| `transform.scaleX`           | `Transform` | `scaleX`           | `sequence.target.scaleX`                                          |
| `transform.scaleY`           | `Transform` | `scaleY`           | `sequence.target.scaleY`                                          |
| `transform.scaleXY`          | `Transform` | `scaleX`, `scaleY` | `sequence.target.scaleXY`                                         |
| `color.a`                    | `Tint`      | `a`                | `sequence.target.alpha`                                           |
| `color.rgba`                 | `Tint`      | `r`, `g`, `b`, `a` | `sequence.target.color`                                           |

New targets are built against any registered component:

```teal
function sequence.target.field(component: Component, fieldName: string): Target
function sequence.target.field2(component: Component, fieldA: string, fieldB: string): Target
function sequence.target.angle(component: Component, fieldName: string): Target
function sequence.target.of(component: Component, field: string | {string}): Target
```

`field` animates one numeric field, `field2` animates two together, `angle` animates one field as an angle by
the shortest rotation, and `of` infers a scalar or pair target from one or two field names. Writes go through
`getMut`, so the component's column is marked dirty. A target whose component the entity does not carry writes
nothing.

### Tracking sources

`sequence.source` says where a `tweenTrack` node reads the value it is chasing.

```teal
function sequence.source.own(component: Component, field: string | {string}): TrackSource
function sequence.source.key(key: string, component: Component, field: string | {string}): TrackSource
function sequence.source.tracking(component: Component, field: string | {string}): TrackSource
function sequence.source.related(relationship: Component, component: Component, field: string | {string}): TrackSource
```

| Constructor | Reads from                                                                    |
| ----------- | ----------------------------------------------------------------------------- |
| `own`       | Fields on the tweened entity itself.                                          |
| `key`       | Fields on the entity registered under a world key.                            |
| `tracking`  | Fields on the entity the tweened entity's `TrackingTarget` component selects. |
| `related`   | Fields on the target of a relationship component the tweened entity carries.  |

`sequence.TrackingTarget` is the component `source.tracking` reads. It is registered as `TweenTrackingTarget`
and carries `entity`, defaulting to `0`, and `key`, defaulting to `""`: a non-zero `entity` names the source
directly, and otherwise a non-empty `key` is looked up as a world key. Changing what a tween chases is then a
component write rather than a new timeline.

```teal
local chase <const> = sequence.timeline("game.chase", {
    sequence.tweenTrack(0.5, "sineInOut", "transform.xy",
        sequence.source.tracking(tecs.ecs.builtins.Transform, {"x", "y"})),
})
```

## Faults

A playback that faults is retired in the `"faulted"` state, and the reason is on its `status`.

| Reason                  | Cause                                                             |
| ----------------------- | ----------------------------------------------------------------- |
| `unregisteredAction`    | A `call` named an action that is not registered on this world.    |
| `actionError`           | A registered action raised.                                       |
| `budgetExceeded`        | The playback exceeded its per-step instruction budget.            |
| `branchFaulted`         | A branch this playback forked faulted.                            |
| `unregisteredQuery`     | A `waitQuery` named a query that is not registered on this world. |
| `unregisteredEvaluator` | An `eval` named an evaluator that is not registered.              |
| `unregisteredAwaitable` | An `await` named a provider that is not registered on this build. |
| `unregisteredTween`     | A `playTween` named a timeline that is not defined.               |

`TweenOutcome`, which is what a `waitTween` reports and what `cancelOwnedBy` can send, is `"completed"`,
`"cancelled"`, `"replaced"` or `"targetLost"`.

## Installing it

```teal
function sequence.plugin(world: World)
```

[`Application`](/modules/application) installs the sequencer, so a game that builds one never calls this. A
world built by hand, a test or a tool that scripts input installs it itself; a second install on the same world
does nothing.

Installing adds one system per clock, `sequence.Advance` in `FixedFirst`, `sequence.AdvanceFrame` in `First` and
`sequence.AdvancePresentation` in `Update`, a snapshot handler named `tecs.sequence`, and an observer that
cancels an owner's playbacks with `targetLost` when it despawns.
<!-- @generated by docs/scripts/reference.py from src/tecs/sequence/init.tl. Do not edit below this line. -->

## Reference

Every function and type this module carries, rendered from `src/tecs/sequence/init.tl`.

<a id="tecs.sequence.Action"></a>

### tecs.sequence.Action

<pre><code v-pre>type <a href="#tecs.sequence.Action">tecs.sequence.Action</a> = seqtypes.Action
</code></pre>

A registered effect. Runs synchronously and may not yield.
<a id="tecs.sequence.ActionContext"></a>

### tecs.sequence.ActionContext

<pre><code v-pre>type <a href="#tecs.sequence.ActionContext">tecs.sequence.ActionContext</a> = seqtypes.ActionContext
</code></pre>

What a registered action receives. The context and its `args` belong
to the sequencer and are reused by the next call.
<a id="tecs.sequence.Argument"></a>

### tecs.sequence.Argument

<pre><code v-pre>type <a href="#tecs.sequence.Argument">tecs.sequence.Argument</a> = seqtypes.Argument
</code></pre>

Constants a `call` passes to its action.
<a id="tecs.sequence.Awaitable"></a>

### tecs.sequence.Awaitable

<pre><code v-pre>type <a href="#tecs.sequence.Awaitable">tecs.sequence.Awaitable</a> = seqawaitables.Provider
</code></pre>

What a registered awaitable provider has to answer.
<a id="tecs.sequence.ClockId"></a>

### tecs.sequence.ClockId

<pre><code v-pre>type <a href="#tecs.sequence.ClockId">tecs.sequence.ClockId</a> = seqtypes.ClockId
</code></pre>

Which clock a program is scheduled against.
<a id="tecs.sequence.DefineOptions"></a>

### tecs.sequence.DefineOptions

<pre><code v-pre>record <a href="#tecs.sequence.DefineOptions">tecs.sequence.DefineOptions</a>
</code></pre>

Options for `define`.
<a id="tecs.sequence.DefineOptions.clock"></a>

### tecs.sequence.DefineOptions.clock

<pre><code v-pre><a href="#tecs.sequence.DefineOptions.clock">tecs.sequence.DefineOptions.clock</a>: <a href="#tecs.sequence.ClockId">ClockId</a>
</code></pre>

Clock the program's waits count. Defaults to `"fixed"`.
<a id="tecs.sequence.EasingFunction"></a>

### tecs.sequence.EasingFunction

<pre><code v-pre>type <a href="#tecs.sequence.EasingFunction">tecs.sequence.EasingFunction</a> = tweeneval.EasingFunction
</code></pre>

A curve, as normalized progress in to eased progress out.

Easing shapes the value, not the schedule: the argument is how far
through its own window the interpolation is, clamped to [0, 1], and the
result is the fraction of the way from start to destination to place
the target at. A curve that leaves [0, 1] overshoots the destination
rather than the duration, which is what `backOut` and `elasticOut` are
for. The window itself is fixed at compile time, so no curve can make a
timeline longer or shorter or move what follows it.
<a id="tecs.sequence.EasingName"></a>

### tecs.sequence.EasingName

<pre><code v-pre>type <a href="#tecs.sequence.EasingName">tecs.sequence.EasingName</a> = tweeneval.EasingName
</code></pre>

Name of a built-in easing curve, and the shape of any curve.
<a id="tecs.sequence.EntityRef"></a>

### tecs.sequence.EntityRef

<pre><code v-pre>type <a href="#tecs.sequence.EntityRef">tecs.sequence.EntityRef</a> = seqtypes.EntityRef
</code></pre>

A reference to an entity supplied at `play` time, resolved when the
instruction that uses it runs.
<a id="tecs.sequence.Evaluator"></a>

### tecs.sequence.Evaluator

<pre><code v-pre>type <a href="#tecs.sequence.Evaluator">tecs.sequence.Evaluator</a> = seqtypes.Evaluator
</code></pre>

What an `eval` step runs every tick.
<a id="tecs.sequence.Event"></a>

### tecs.sequence.Event

<pre><code v-pre><a href="#tecs.sequence.Event">tecs.sequence.Event</a>: seqtypes.Event
</code></pre>

Emitted by an `emit` step, at address 0.
<a id="tecs.sequence.FaultReason"></a>

### tecs.sequence.FaultReason

<pre><code v-pre>type <a href="#tecs.sequence.FaultReason">tecs.sequence.FaultReason</a> = seqtypes.FaultReason
</code></pre>

Why a cursor stopped running.
<a id="tecs.sequence.Handle"></a>

### tecs.sequence.Handle

<pre><code v-pre>type <a href="#tecs.sequence.Handle">tecs.sequence.Handle</a> = seqtypes.Handle
</code></pre>

A generation-checked reference to one playback, meaningful across a
snapshot load.
<a id="tecs.sequence.Node"></a>

### tecs.sequence.Node

<pre><code v-pre>type <a href="#tecs.sequence.Node">tecs.sequence.Node</a> = seqtypes.Node
</code></pre>

One authored step, produced by the node constructors below. Treat the
returned value as opaque and do not reuse a node across programs.
<a id="tecs.sequence.PlayOptions"></a>

### tecs.sequence.PlayOptions

<pre><code v-pre>type <a href="#tecs.sequence.PlayOptions">tecs.sequence.PlayOptions</a> = seqtypes.PlayOptions
</code></pre>

Options for `play`.
<a id="tecs.sequence.PlaybackMode"></a>

### tecs.sequence.PlaybackMode

<pre><code v-pre>type <a href="#tecs.sequence.PlaybackMode">tecs.sequence.PlaybackMode</a> = tweeneval.PlaybackMode
</code></pre>

How a timeline repeats.
<a id="tecs.sequence.PlaybackState"></a>

### tecs.sequence.PlaybackState

<pre><code v-pre>type <a href="#tecs.sequence.PlaybackState">tecs.sequence.PlaybackState</a> = seqtypes.PlaybackState
</code></pre>

The lifecycle state of one playback.
<a id="tecs.sequence.Program"></a>

### tecs.sequence.Program

<pre><code v-pre>type <a href="#tecs.sequence.Program">tecs.sequence.Program</a> = seqtypes.Program
</code></pre>

A compiled, immutable program, produced by `define` and shared by
every playback of it. See `internal/types` for the full contract.
<a id="tecs.sequence.QueryCondition"></a>

### tecs.sequence.QueryCondition

<pre><code v-pre>type <a href="#tecs.sequence.QueryCondition">tecs.sequence.QueryCondition</a> = seqtypes.QueryCondition
</code></pre>

What a `waitQuery` step is waiting for.
<a id="tecs.sequence.RunOptions"></a>

### tecs.sequence.RunOptions

<pre><code v-pre>type <a href="#tecs.sequence.RunOptions">tecs.sequence.RunOptions</a> = tweeneval.RunOptions
</code></pre>

What a `tweenRun` does with the timeline it nests.

Omitting it runs the nested timeline once. A nested `"loop"` or
`"pingPong"` must set `count`, because a parent has to know how long
its own window is; only the root timeline of a `sequence.timeline`,
through `params`, may repeat without one.
<a id="tecs.sequence.Status"></a>

### tecs.sequence.Status

<pre><code v-pre>type <a href="#tecs.sequence.Status">tecs.sequence.Status</a> = seqtypes.Status
</code></pre>

A playback's current state.
<a id="tecs.sequence.Step"></a>

### tecs.sequence.Step

<pre><code v-pre>type <a href="#tecs.sequence.Step">tecs.sequence.Step</a> = seqprogram.Step
</code></pre>

One step a playback will reach without branching.
<a id="tecs.sequence.Target"></a>

### tecs.sequence.Target

<pre><code v-pre>type <a href="#tecs.sequence.Target">tecs.sequence.Target</a> = tweeneval.Target
</code></pre>

What a timeline operation writes: a component and the one to four
numeric fields of it to interpolate.

Opaque, and built only through `sequence.target`: a built-in such as
`sequence.target.translateXY`, or `sequence.target.field(C, "hp")` for a
component of your own. Every operation that takes one also accepts a
`TargetName` naming the same built-in, which is the form that survives
`defineData`. Safe to share between timelines: a target holds no
per-playback state.
<a id="tecs.sequence.TargetName"></a>

### tecs.sequence.TargetName

<pre><code v-pre>type <a href="#tecs.sequence.TargetName">tecs.sequence.TargetName</a> = tweeneval.TargetName
</code></pre>

Name of a built-in component-field target.
<a id="tecs.sequence.TimelineNode"></a>

### tecs.sequence.TimelineNode

<pre><code v-pre>type <a href="#tecs.sequence.TimelineNode">tecs.sequence.TimelineNode</a> = tweeneval.TimelineNode
</code></pre>

One authored timeline operation.
<a id="tecs.sequence.TimelineOptions"></a>

### tecs.sequence.TimelineOptions

<pre><code v-pre>record <a href="#tecs.sequence.TimelineOptions">tecs.sequence.TimelineOptions</a>
</code></pre>

Options for `timeline`.
<a id="tecs.sequence.TimelineOptions.clock"></a>

### tecs.sequence.TimelineOptions.clock

<pre><code v-pre><a href="#tecs.sequence.TimelineOptions.clock">tecs.sequence.TimelineOptions.clock</a>: <a href="#tecs.sequence.ClockId">ClockId</a>
</code></pre>

Clock the timeline is evaluated on. Defaults to `"presentation"`,
which moves at the display's rate. `"fixed"` makes it
deterministic from a snapshot alone, at the cost of stepping at
the simulation's rate: only `Transform` is interpolated between
fixed steps, so a fixed-clock tween of anything else visibly
steps. If the simulation can observe the value, put it on
`"fixed"`.
<a id="tecs.sequence.TimelineSpec"></a>

### tecs.sequence.TimelineSpec

<pre><code v-pre>type <a href="#tecs.sequence.TimelineSpec">tecs.sequence.TimelineSpec</a> = tweeneval.TimelineSpec
</code></pre>

Timeline operations in order, as one list.

Entries run one after the next, each starting where the one before it
ended, except that a `tweenParallel` runs its arguments from a shared
start. A nested list is read as a block and behaves the same as one.

Compiling a spec writes the resolved form into the same table, so a
spec is consumed by the `timeline` or `tweenRun` that takes it: pass a
fresh one per timeline rather than holding one and reusing it.
<a id="tecs.sequence.TrackSource"></a>

### tecs.sequence.TrackSource

<pre><code v-pre>type <a href="#tecs.sequence.TrackSource">tecs.sequence.TrackSource</a> = tweeneval.TrackSource
</code></pre>

A live component-field tracking source.
<a id="tecs.sequence.TrackingTarget"></a>

### tecs.sequence.TrackingTarget

<pre><code v-pre><a href="#tecs.sequence.TrackingTarget">tecs.sequence.TrackingTarget</a>: tweeneval.TrackingTarget
</code></pre>

Component selecting a dynamic tracking source entity.
<a id="tecs.sequence.TweenOutcome"></a>

### tecs.sequence.TweenOutcome

<pre><code v-pre>type <a href="#tecs.sequence.TweenOutcome">tecs.sequence.TweenOutcome</a> = seqtypes.TweenOutcome
</code></pre>

How the tween a `waitTween` step was waiting on ended.
<a id="tecs.sequence.activeCount"></a>

### tecs.sequence.activeCount

<pre><code v-pre>function <a href="#tecs.sequence.activeCount">tecs.sequence.activeCount</a>(World): integer
</code></pre>

Number of live playbacks, for tests and diagnostics.

#### Parameters

| Type                     | Name | Description |
| ------------------------ | ---- | ----------- |
| <code v-pre>World</code> |      |             |

#### Returns

| Type                       | Description                                                                                                             |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | Branches counted individually, since a branch is a playback of its own, and so are the playbacks a `playTween` started. |

<a id="tecs.sequence.await"></a>

### tecs.sequence.await

<pre><code v-pre>function <a href="#tecs.sequence.await">tecs.sequence.await</a>(provider: string, target: <a href="#tecs.sequence.EntityRef">EntityRef</a>, key: string): <a href="#tecs.sequence.Node">Node</a>
</code></pre>

Wait for something outside the sequencer to finish.

A subsystem registers a provider under a name and answers whether the
work is still going; this parks the playback until it is not. The
sequencer never learns what the work is, which is how a program waits
on a sprite animation without the sequencer requiring the renderer.

A binding that is missing or dead is not a fault: there is nothing to
wait for and the program carries on. So is a provider reporting a
thing that never started.

sequence.call("game.playTag", sequence.bind("hero"), "hurt"),
sequence.await("game.spriteAnimation", sequence.bind("hero")),

#### Parameters

| Type                                                                | Name                        | Description                                                                                                                                                                                                                                                                                             |
| ------------------------------------------------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code>                                           | <code v-pre>provider</code> | Resolved globally when the instruction runs, and checked before the binding: a name no build registered faults the playback with `unregisteredAwaitable`. It is asked again at each fixed step boundary while the playback is parked, and an answer that raises faults the playback with `actionError`. |
| <code v-pre><a href="#tecs.sequence.EntityRef">EntityRef</a></code> | <code v-pre>target</code>   | A `bind` reference and nothing else, as `playTween`'s is. An entity that dies while the step is parked releases the playback rather than stranding it for the life of the world.                                                                                                                        |
| <code v-pre>string</code>                                           | <code v-pre>key</code>      | Handed to the provider unread, for a provider that answers about more than one thing per entity. Nil when omitted, which is what a provider with one answer per entity sees.                                                                                                                            |

#### Returns

| Type                                                      | Description                                                 |
| --------------------------------------------------------- | ----------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.Node">Node</a></code> | A node for `define`, and not to be put in a second program. |

<a id="tecs.sequence.bind"></a>

### tecs.sequence.bind

<pre><code v-pre>function <a href="#tecs.sequence.bind">tecs.sequence.bind</a>(name: string): <a href="#tecs.sequence.EntityRef">EntityRef</a>
</code></pre>

Reference an entity supplied through `PlayOptions.bindings`.

Resolved when the instruction using it runs, not at `play`, so a
binding may name an entity that does not exist yet.

#### Parameters

| Type                      | Name                    | Description                                                                                                                                                                                             |
| ------------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | <code v-pre>name</code> | Must be non-empty, and an empty one raises here rather than at `define`. It is matched against the keys of `PlayOptions.bindings`, and a name with no binding resolves to nothing rather than faulting. |

#### Returns

| Type                                                                | Description                                                                                                                                                                                                                 |
| ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.EntityRef">EntityRef</a></code> | A reference to put in a `call` or `emit` argument list, or to hand to `playTween` or `await`. It is interned into the program's const pool, so it is shared by every playback and resolved against each one's own bindings. |

<a id="tecs.sequence.call"></a>

### tecs.sequence.call

<pre><code v-pre>function <a href="#tecs.sequence.call">tecs.sequence.call</a>(action: string, ...: <a href="#tecs.sequence.Argument">Argument</a>): <a href="#tecs.sequence.Node">Node</a>
</code></pre>

Run a registered action.

#### Parameters

| Type                                                              | Name                      | Description                                                                                                                                                                        |
| ----------------------------------------------------------------- | ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code>                                         | <code v-pre>action</code> | Resolved per world when the instruction runs, not at `define`, so a program may name an action registered later. A name still unregistered when the step runs faults the playback. |
| <code v-pre><a href="#tecs.sequence.Argument">Argument</a></code> | <code v-pre>...</code>    | Compiled into the program's const pool, so they are the same values for every playback of it. Put anything that differs between two playbacks in `PlayOptions.params` instead.     |

#### Returns

| Type                                                      | Description                                                 |
| --------------------------------------------------------- | ----------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.Node">Node</a></code> | A node for `define`, and not to be put in a second program. |

<a id="tecs.sequence.cancel"></a>

### tecs.sequence.cancel

<pre><code v-pre>function <a href="#tecs.sequence.cancel">tecs.sequence.cancel</a>(handle: World, <a href="#tecs.sequence.Handle">Handle</a>): boolean
</code></pre>

Stop a playback and release its cursor. Safe on a finished handle.

It takes the branches it forked with it, and a playback parked in a
`waitTween` on the one cancelled is told `cancelled` and resumes. What
a `playTween` started is a playback in its own right and is not
cancelled with the one that started it, unlike a pause, which cascades
to it: stop it through its owner with `cancelOwnedBy`.

#### Parameters

| Type                                                          | Name                      | Description                                                                                                              |
| ------------------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre>World</code>                                      | <code v-pre>handle</code> | Read against this world's cursor arena, so one issued by another world is meaningless here rather than reliably ignored. |
| <code v-pre><a href="#tecs.sequence.Handle">Handle</a></code> |                           |                                                                                                                          |

#### Returns

| Type                       | Description                                                                                        |
| -------------------------- | -------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | false when the handle names nothing running, whether it already finished or was already cancelled. |

<a id="tecs.sequence.cancelOwnedBy"></a>

### tecs.sequence.cancelOwnedBy

<pre><code v-pre>function <a href="#tecs.sequence.cancelOwnedBy">tecs.sequence.cancelOwnedBy</a>(owner: World, reason: integer, <a href="#tecs.sequence.TweenOutcome">TweenOutcome</a>): integer
</code></pre>

Cancel every playback owned by an entity.

`reason` is what anything waiting on one of them is told. The owner
despawning reports `targetLost`, which is what a waiter needs to tell
"it was stopped" from "what it was moving is gone".

#### Parameters

| Type                                                                      | Name                      | Description                                                                                                                                                         |
| ------------------------------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>World</code>                                                  | <code v-pre>owner</code>  | An entity id. A playback started without an owner is owned by nothing rather than by entity 0, so no argument reaches one and only `cancel` on its handle stops it. |
| <code v-pre>integer</code>                                                | <code v-pre>reason</code> | What a playback parked in a `waitTween` on one of these is told, and what its `status` reports afterwards as `tweenOutcome`. Omitted, a waiter is told `cancelled`. |
| <code v-pre><a href="#tecs.sequence.TweenOutcome">TweenOutcome</a></code> |                           |                                                                                                                                                                     |

#### Returns

| Type                       | Description                                                                                                                                                                                                                     |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | How many were running and are now cancelled; 0 when the entity owns none. A branch carries the owner of the playback that forked it, so it is reached by the same call, and each cursor is counted once however it was reached. |

<a id="tecs.sequence.currentStep"></a>

### tecs.sequence.currentStep

<pre><code v-pre>function <a href="#tecs.sequence.currentStep">tecs.sequence.currentStep</a>(clock: World, <a href="#tecs.sequence.ClockId">ClockId</a>): integer
</code></pre>

A clock's current tick, as counted by the sequencer. Defaults to the
fixed clock.

#### Parameters

| Type                                                            | Name                     | Description                                              |
| --------------------------------------------------------------- | ------------------------ | -------------------------------------------------------- |
| <code v-pre>World</code>                                        | <code v-pre>clock</code> | Which of the three counters to read. Omitted, `"fixed"`. |
| <code v-pre><a href="#tecs.sequence.ClockId">ClockId</a></code> |                          |                                                          |

#### Returns

| Type                       | Description                                                                                                                                                                                                                                                                                                           |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | Ticks of that one clock, rising by one each time the sequencer advances it and by nothing else. It counts from when this world's sequencer state was created, not from the process starting, and a snapshot load puts back the count the snapshot carried. Comparable only against another reading of the same clock. |

<a id="tecs.sequence.dataOps"></a>

### tecs.sequence.dataOps

<pre><code v-pre>function <a href="#tecs.sequence.dataOps">tecs.sequence.dataOps</a>(): {string}
</code></pre>

The step names `defineData` accepts, sorted.

#### Returns

| Type                        | Description                                                                                                                                             |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>{string}</code> | A fresh table each call, which the caller owns. It is narrower than the node constructors: `await` and `eval` have no data form and are not among them. |

<a id="tecs.sequence.define"></a>

### tecs.sequence.define

<pre><code v-pre>function <a href="#tecs.sequence.define">tecs.sequence.define</a>(name: string, nodes: {<a href="#tecs.sequence.Node">Node</a>}, options: <a href="#tecs.sequence.DefineOptions">DefineOptions</a>): <a href="#tecs.sequence.Program">Program</a>
</code></pre>

Compile a program under a stable symbolic name.

`options.clock` picks what the program's waits count. `"fixed"`, the
default, counts fixed steps and is what gameplay logic wants.
`"frame"` counts gameplay frames, one tick per frame however many fixed
steps that frame runs, which is what scripted input needs.
`"presentation"` is also accepted and ticks once per gameplay frame
carrying the frame's real elapsed time.

#### Parameters

| Type                                                                        | Name                       | Description                                                                                                                                                                                             |
| --------------------------------------------------------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code>                                                   | <code v-pre>name</code>    | Defining over a name already in use publishes a new version rather than replacing the old one: playbacks already running keep the version they started on, and only later `play` calls see the new one. |
| <code v-pre>{<a href="#tecs.sequence.Node">Node</a>}</code>                 | <code v-pre>nodes</code>   | An empty list is accepted and compiles to a program that completes on its first tick.                                                                                                                   |
| <code v-pre><a href="#tecs.sequence.DefineOptions">DefineOptions</a></code> | <code v-pre>options</code> | Omitted, the program counts fixed steps. A `clock` that is none of the three names raises here.                                                                                                         |

#### Returns

| Type                                                            | Description                                                                                                          |
| --------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.Program">Program</a></code> | The compiled program, immutable and shared by every playback of it, so the same value plays on any number of worlds. |

<a id="tecs.sequence.defineData"></a>

### tecs.sequence.defineData

<pre><code v-pre>function <a href="#tecs.sequence.defineData">tecs.sequence.defineData</a>(name: string, rows: {&lt;any type&gt;}, options: <a href="#tecs.sequence.DefineOptions">DefineOptions</a>): <a href="#tecs.sequence.Program">Program</a>, string
</code></pre>

Compile a program written as plain data rather than node calls.

The same authoring surface as a list of steps, for callers that
cannot invoke Lua: a tool over MCP, a file on disk, a hand-written
table. Returns nil plus the path to the first bad entry.

sequence.defineData("game.intro", {
{op = "call", action = "game.lockControls"},
{op = "wait", seconds = 1.5},
})

#### Parameters

| Type                                                                        | Name                       | Description                                                                                                                                                                                                                                 |
| --------------------------------------------------------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code>                                                   | <code v-pre>name</code>    | As `define`'s, and sharing its namespace and its versioning.                                                                                                                                                                                |
| <code v-pre>{&lt;any type&gt;}</code>                                       | <code v-pre>rows</code>    | One table per step, keyed by `op` and the fields that step takes. Names of the steps are `dataOps`. An empty list is rejected here, unlike `define`'s, since a program of no steps is a mistake in the caller rather than something to run. |
| <code v-pre><a href="#tecs.sequence.DefineOptions">DefineOptions</a></code> | <code v-pre>options</code> | As `define`'s.                                                                                                                                                                                                                              |

#### Returns

| Type                                                            | Description                                                                                                                                                                                                                                                                                                                       |
| --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.Program">Program</a></code> | The compiled program, or nil when a row is bad.                                                                                                                                                                                                                                                                                   |
| <code v-pre>string</code>                                       | nil on success; on failure the path to the first bad entry, as `program[2].loop[1]`, and what it was missing. That is why the two are never both set. A row whose shape is right and whose value is not, a negative wait among them, raises instead: the path covers what this decoder checks, not what the node constructors do. |

<a id="tecs.sequence.disassemble"></a>

### tecs.sequence.disassemble

<pre><code v-pre>function <a href="#tecs.sequence.disassemble">tecs.sequence.disassemble</a>(program: <a href="#tecs.sequence.Program">Program</a>, pc: integer): string
</code></pre>

Render a program as readable instructions.

#### Parameters

| Type                                                            | Name                       | Description                                                                                                                                                                |
| --------------------------------------------------------------- | -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.Program">Program</a></code> | <code v-pre>program</code> | A value from `define` or `timeline`; anything else raises.                                                                                                                 |
| <code v-pre>integer</code>                                      | <code v-pre>pc</code>      | Mark this instruction, as a playback's `status` reports it. Omit for an unmarked listing. One past the end, or any other address the program does not hold, marks nothing. |

#### Returns

| Type                      | Description                                                                                                                                                   |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | A header naming the program and its version, then one line per instruction, newline separated. For reading and not for parsing: the format is free to change. |

<a id="tecs.sequence.easing"></a>

### tecs.sequence.easing

<pre><code v-pre><a href="#tecs.sequence.easing">tecs.sequence.easing</a>: tweeneval.Easings
</code></pre>

The built-in easing curves: `sequence.easing.quadOut`.
<a id="tecs.sequence.emit"></a>

### tecs.sequence.emit

<pre><code v-pre>function <a href="#tecs.sequence.emit">tecs.sequence.emit</a>(event: string, ...: <a href="#tecs.sequence.Argument">Argument</a>): <a href="#tecs.sequence.Node">Node</a>
</code></pre>

Emit an ECS event at address 0.

Occupies no tick: the step after it runs in the same one.

#### Parameters

| Type                                                              | Name                     | Description                                                                                                                                                                                                                                                 |
| ----------------------------------------------------------------- | ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code>                                         | <code v-pre>event</code> | Carried as the `sequence.Event`'s name. Observers watch `sequence.Event` itself and filter on this, rather than each name being an event type of its own.                                                                                                   |
| <code v-pre><a href="#tecs.sequence.Argument">Argument</a></code> | <code v-pre>...</code>   | Const-pool values, as `call`'s are, delivered on the event's `args` with any `bind` reference already resolved to an entity id. That list is copied for each emit and leaves with the event, so an observer may keep it, unlike the one an action receives. |

#### Returns

| Type                                                      | Description                                                 |
| --------------------------------------------------------- | ----------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.Node">Node</a></code> | A node for `define`, and not to be put in a second program. |

<a id="tecs.sequence.eval"></a>

### tecs.sequence.eval

<pre><code v-pre>function <a href="#tecs.sequence.eval">tecs.sequence.eval</a>(evaluator: string, data: any): <a href="#tecs.sequence.Node">Node</a>
</code></pre>

Evaluate a registered evaluator every tick until it finishes.

Unlike every other step, this one does not hand the tick back: the
playback joins its clock's active set and is stepped each tick, which
is what a value that has to move every frame needs.

`data` is compiled into the program alongside the evaluator's name,
so it travels with a snapshot and has to be plain data for the same
reason a `call` argument does. What the evaluator makes of it is its
own business.

#### Parameters

| Type                      | Name                         | Description                                                                                                                                                                                                                                                                                                |
| ------------------------- | ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | <code v-pre>evaluator</code> | Resolved globally when the instruction runs, so a program may name an evaluator registered later. A name still unregistered when the step runs faults the playback with `unregisteredEvaluator`, and an evaluator that raises while resolving the data or building its state faults it with `actionError`. |
| <code v-pre>any</code>    | <code v-pre>data</code>      | Passed through the evaluator's `resolve` once per program constant and the answer shared by every playback of it, so an evaluator must not write per-playback state into what it gets back. Omit it for an evaluator that needs none.                                                                      |

#### Returns

| Type                                                      | Description                                                 |
| --------------------------------------------------------- | ----------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.Node">Node</a></code> | A node for `define`, and not to be put in a second program. |

<a id="tecs.sequence.fork"></a>

### tecs.sequence.fork

<pre><code v-pre>function <a href="#tecs.sequence.fork">tecs.sequence.fork</a>(nodes: {<a href="#tecs.sequence.Node">Node</a>}): <a href="#tecs.sequence.Node">Node</a>
</code></pre>

Start a branch that runs alongside the rest of the program.

The branch is a playback of its own running the same program at a
different instruction, and it inherits the owner, bindings, params and
instruction budget of the playback that forked it. It starts once
that playback next waits, joins, or ends, within the same tick.

A branch never outlives the playback that forked it: finishing or
cancelling that playback cancels the branches it has not joined. A
branch that faults takes its parent with it, faulted `branchFaulted`,
rather than leaving a `join` one branch short forever.

#### Parameters

| Type                                                        | Name                     | Description                                                                                                                                                                                |
| ----------------------------------------------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre>{<a href="#tecs.sequence.Node">Node</a>}</code> | <code v-pre>nodes</code> | The branch body, run in order. Must be non-empty. It reads and writes the forking playback's own bindings table rather than a copy, so a name an action binds in one is seen by the other. |

#### Returns

| Type                                                      | Description                                                 |
| --------------------------------------------------------- | ----------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.Node">Node</a></code> | A node for `define`, and not to be put in a second program. |

<a id="tecs.sequence.hasAction"></a>

### tecs.sequence.hasAction

<pre><code v-pre>function <a href="#tecs.sequence.hasAction">tecs.sequence.hasAction</a>(World, string): boolean
</code></pre>

Whether an action name is registered on this world.

#### Parameters

| Type                      | Name | Description |
| ------------------------- | ---- | ----------- |
| <code v-pre>World</code>  |      |             |
| <code v-pre>string</code> |      |             |

#### Returns

| Type                       | Description                                                                                           |
| -------------------------- | ----------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | false for a name this world never registered, including one another world has: actions are per world. |

<a id="tecs.sequence.hasQuery"></a>

### tecs.sequence.hasQuery

<pre><code v-pre>function <a href="#tecs.sequence.hasQuery">tecs.sequence.hasQuery</a>(World, string): boolean
</code></pre>

Whether a query name is registered on this world.

#### Parameters

| Type                      | Name | Description |
| ------------------------- | ---- | ----------- |
| <code v-pre>World</code>  |      |             |
| <code v-pre>string</code> |      |             |

#### Returns

| Type                       | Description                                                                                           |
| -------------------------- | ----------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | false for a name this world never registered, including one another world has: queries are per world. |

<a id="tecs.sequence.join"></a>

### tecs.sequence.join

<pre><code v-pre>function <a href="#tecs.sequence.join">tecs.sequence.join</a>(): <a href="#tecs.sequence.Node">Node</a>
</code></pre>

Wait for every branch forked and not yet joined.

Falls straight through when there are none. When the last branch
finishes, the waiting playback resumes within that same tick.

#### Returns

| Type                                                      | Description                                                 |
| --------------------------------------------------------- | ----------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.Node">Node</a></code> | A node for `define`, and not to be put in a second program. |

<a id="tecs.sequence.loop"></a>

### tecs.sequence.loop

<pre><code v-pre>function <a href="#tecs.sequence.loop">tecs.sequence.loop</a>(count: integer, nodes: {<a href="#tecs.sequence.Node">Node</a>}): <a href="#tecs.sequence.Node">Node</a>
</code></pre>

Repeat a block.

#### Parameters

| Type                                                        | Name                     | Description                                                                                                                                                                                                                                           |
| ----------------------------------------------------------- | ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code>                                  | <code v-pre>count</code> | Iterations, or nil to repeat until cancelled. A positive whole number; zero and a fraction are rejected here.                                                                                                                                         |
| <code v-pre>{<a href="#tecs.sequence.Node">Node</a>}</code> | <code v-pre>nodes</code> | The block, run in order and started again from its first node. Must be non-empty. A block with no wait in it spends the playback's per-step instruction budget within one tick and faults it with `budgetExceeded`, which is what that budget is for. |

#### Returns

| Type                                                      | Description                                                 |
| --------------------------------------------------------- | ----------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.Node">Node</a></code> | A node for `define`, and not to be put in a second program. |

<a id="tecs.sequence.parallel"></a>

### tecs.sequence.parallel

<pre><code v-pre>function <a href="#tecs.sequence.parallel">tecs.sequence.parallel</a>(...: {<a href="#tecs.sequence.Node">Node</a>}): <a href="#tecs.sequence.Node">Node</a>
</code></pre>

Fork several blocks and wait for all of them.

Sugar for a `fork` per block followed by one `join`. Blocks start in
the order they are given.

#### Parameters

| Type                                                        | Name                   | Description                                                                                                                                                                 |
| ----------------------------------------------------------- | ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>{<a href="#tecs.sequence.Node">Node</a>}</code> | <code v-pre>...</code> | One block per branch, each a non-empty list of nodes. At least one block is required, and an empty one raises. Each shares the playback's bindings table, as a `fork` does. |

#### Returns

| Type                                                      | Description                                                 |
| --------------------------------------------------------- | ----------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.Node">Node</a></code> | A node for `define`, and not to be put in a second program. |

<a id="tecs.sequence.pause"></a>

### tecs.sequence.pause

<pre><code v-pre>function <a href="#tecs.sequence.pause">tecs.sequence.pause</a>(holder: World, <a href="#tecs.sequence.Handle">Handle</a>, string): boolean
</code></pre>

Suspend a playback, its branches, and anything it started.

Pause is holder counted: two systems can hold the same playback for
unrelated reasons, and it runs again only when the last one lets go,
so whichever resumes first cannot undo the other. `holder` names who
is holding it and defaults to `"user"`.

Its wait, if any, resumes from where it paused. What it is waiting on
stops with it when the awaitable provider knows how.

#### Parameters

| Type                                                          | Name                      | Description                                                                                                                                                                                                     |
| ------------------------------------------------------------- | ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>World</code>                                      | <code v-pre>holder</code> | Any string, and a set rather than a count: two pauses under the same holder are one hold, and one `resume` under it releases both. Two callers that both leave it at the default therefore share a single hold. |
| <code v-pre><a href="#tecs.sequence.Handle">Handle</a></code> |                           |                                                                                                                                                                                                                 |
| <code v-pre>string</code>                                     |                           |                                                                                                                                                                                                                 |

#### Returns

| Type                       | Description                                                                                                                                                                                                      |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | Whether the playback stopped. A second holder taking a hold on one that is already paused registers the hold and returns false, because nothing observable changed. So does a handle that names nothing running. |

<a id="tecs.sequence.play"></a>

### tecs.sequence.play

<pre><code v-pre>function <a href="#tecs.sequence.play">tecs.sequence.play</a>(program: World, options: <a href="#tecs.sequence.Program">Program</a>, <a href="#tecs.sequence.PlayOptions">PlayOptions</a>): <a href="#tecs.sequence.Handle">Handle</a>
</code></pre>

Start a program. The first instruction runs on the next tick of the
program's own clock, never inside this call.

#### Parameters

| Type                                                                    | Name                       | Description                                                                                                                                                                                                                                   |
| ----------------------------------------------------------------------- | -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>World</code>                                                | <code v-pre>program</code> | A value from `define` or `timeline`, not a name. The version handed in is the version this playback runs for its whole life, even if the name is redefined under it. Anything that is not a compiled program raises.                          |
| <code v-pre><a href="#tecs.sequence.Program">Program</a></code>         | <code v-pre>options</code> | Omitted, the playback has no owner, no bindings, no params, no channel, and the world's instruction budget. Taking a channel another playback on the same owner holds cancels that one first, reporting `replaced` to anything waiting on it. |
| <code v-pre><a href="#tecs.sequence.PlayOptions">PlayOptions</a></code> |                            |                                                                                                                                                                                                                                               |

#### Returns

| Type                                                          | Description                                                                                                                                                             |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.Handle">Handle</a></code> | A handle to the new playback, valid until it ends. A handle carries a generation, so one whose playback has ended never names a later playback that took the same slot. |

<a id="tecs.sequence.playTween"></a>

### tecs.sequence.playTween

<pre><code v-pre>function <a href="#tecs.sequence.playTween">tecs.sequence.playTween</a>(timeline: string, target: <a href="#tecs.sequence.EntityRef">EntityRef</a>, params: {string : &lt;any type&gt;}): <a href="#tecs.sequence.Node">Node</a>
</code></pre>

Play a registered tween preset on a bound entity.

Needs the sequencer, which `tecs.application.create` installs. A binding
that is missing or dead is not a fault: nothing plays, and a following
`waitTween` resumes at once reporting `targetLost`.

The step itself costs no tick. What it starts is a playback of its own,
owned by the bound entity, running on the named program's clock, and
holding this playback's instruction budget.

#### Parameters

| Type                                                                | Name                        | Description                                                                                                                                                                                                                                                        |
| ------------------------------------------------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre>string</code>                                           | <code v-pre>timeline</code> | Resolved when the instruction runs, and always to the newest version of the name; any program defined under it will do, though `timeline` is what normally publishes one. A name that is not defined faults the playback with `unregisteredTween`.                 |
| <code v-pre><a href="#tecs.sequence.EntityRef">EntityRef</a></code> | <code v-pre>target</code>   | A `bind` reference and nothing else: an entity id raises here, for the same reason `define` rejects one as a constant.                                                                                                                                             |
| <code v-pre>{string : &lt;any type&gt;}</code>                      | <code v-pre>params</code>   | The started playback's `params`, so `mode`, `count`, `speed` and `delay` shape it as they do for `play`. A `channel` in it names the slot the playback takes on that entity, cancelling whatever held the slot and reporting `replaced` to anything waiting on it. |

#### Returns

| Type                                                      | Description                                                 |
| --------------------------------------------------------- | ----------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.Node">Node</a></code> | A node for `define`, and not to be put in a second program. |

<a id="tecs.sequence.playbacks"></a>

### tecs.sequence.playbacks

<pre><code v-pre>function <a href="#tecs.sequence.playbacks">tecs.sequence.playbacks</a>(World): {<a href="#tecs.sequence.Handle">Handle</a>}
</code></pre>

Handles of every live playback, branches included, in a stable
order. For diagnostics and the debugger, not for hot paths.

#### Parameters

| Type                     | Name | Description |
| ------------------------ | ---- | ----------- |
| <code v-pre>World</code> |      |             |

#### Returns

| Type                                                            | Description                                                                                                                                                                                                                        |
| --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>{<a href="#tecs.sequence.Handle">Handle</a>}</code> | A fresh table each call, ordered by cursor slot, which is stable within a run but is not creation order: a slot freed by a finished playback is handed to the next one started. The playbacks a `playTween` started are in it too. |

<a id="tecs.sequence.plugin"></a>

### tecs.sequence.plugin

<pre><code v-pre>function <a href="#tecs.sequence.plugin">tecs.sequence.plugin</a>(World)
</code></pre>

Install the sequencer. Auto-installed by `tecs.application.create`, and safe
to call again: a second install on the same world does nothing.

#### Parameters

| Type                     | Name | Description |
| ------------------------ | ---- | ----------- |
| <code v-pre>World</code> |      |             |

<a id="tecs.sequence.program"></a>

### tecs.sequence.program

<pre><code v-pre>function <a href="#tecs.sequence.program">tecs.sequence.program</a>(version: string, integer): <a href="#tecs.sequence.Program">Program</a>
</code></pre>

Look up a defined program: the newest version, or a specific one.
Every version a playback still runs stays reachable.

#### Parameters

| Type                       | Name                       | Description                                                                                |
| -------------------------- | -------------------------- | ------------------------------------------------------------------------------------------ |
| <code v-pre>string</code>  | <code v-pre>version</code> | Versions start at 1 and rise by one per `define` of the same name. Omit it for the newest. |
| <code v-pre>integer</code> |                            |                                                                                            |

#### Returns

| Type                                                            | Description                                                                                                                                                          |
| --------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.Program">Program</a></code> | nil when the name was never defined, or when that version was superseded and the last playback of it has since ended. The newest version of a name is never dropped. |

<a id="tecs.sequence.programNames"></a>

### tecs.sequence.programNames

<pre><code v-pre>function <a href="#tecs.sequence.programNames">tecs.sequence.programNames</a>(): {string}
</code></pre>

Names of every defined program, sorted.

#### Returns

| Type                        | Description                                                                                                       |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| <code v-pre>{string}</code> | A fresh table each call, which the caller owns. Registration is global, so this spans every world in the process. |

<a id="tecs.sequence.registerAction"></a>

### tecs.sequence.registerAction

<pre><code v-pre>function <a href="#tecs.sequence.registerAction">tecs.sequence.registerAction</a>(name: World, action: string, <a href="#tecs.sequence.Action">Action</a>)
</code></pre>

Register an effect a `call` node can name.

Actions must obey the deterministic-action contract to keep replay and
rewind meaningful: no wall-clock reads, no file or network access, and
randomness only from a generator whose state travels with the snapshot.

#### Parameters

| Type                                                          | Name                      | Description                                                                                                                                                                                                   |
| ------------------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>World</code>                                      | <code v-pre>name</code>   | Per world, unlike an evaluator or an awaitable. Registering it twice replaces the action, and a playback resolves the name at each `call`, so one already running picks the new one up. An empty name raises. |
| <code v-pre>string</code>                                     | <code v-pre>action</code> | Must be a function, or this raises. Raising when it runs faults the playback with `actionError`, and whatever it already wrote to the world stays written: the sequencer rolls nothing back.                  |
| <code v-pre><a href="#tecs.sequence.Action">Action</a></code> |                           |                                                                                                                                                                                                               |

<a id="tecs.sequence.registerAwaitable"></a>

### tecs.sequence.registerAwaitable

<pre><code v-pre>function <a href="#tecs.sequence.registerAwaitable">tecs.sequence.registerAwaitable</a>(name: string, provider: <a href="#tecs.sequence.Awaitable">Awaitable</a>)
</code></pre>

Register something an `await` step can name. Global, like an
evaluator, because a provider is code.

#### Parameters

| Type                                                                | Name                        | Description                                                                                                                                                                      |
| ------------------------------------------------------------------- | --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code>                                           | <code v-pre>name</code>     | Registering a name twice replaces the provider, which is what a hot reload wants: a playback already parked on the name asks the new one at the next step. An empty name raises. |
| <code v-pre><a href="#tecs.sequence.Awaitable">Awaitable</a></code> | <code v-pre>provider</code> | Must carry `isPending`, or this raises. `setPaused` is optional, and a provider without one leaves its work running when the playback waiting on it is paused.                   |

<a id="tecs.sequence.registerEvaluator"></a>

### tecs.sequence.registerEvaluator

<pre><code v-pre>function <a href="#tecs.sequence.registerEvaluator">tecs.sequence.registerEvaluator</a>(name: string, evaluator: <a href="#tecs.sequence.Evaluator">Evaluator</a>)
</code></pre>

Register something an `eval` step can name.

Registration is global, like a program: an evaluator is code, and two
worlds evaluating the same name run the same thing.

#### Parameters

| Type                                                                | Name                         | Description                                                                                                                                                                                            |
| ------------------------------------------------------------------- | ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre>string</code>                                           | <code v-pre>name</code>      | Registering a name twice replaces it. An empty name raises.                                                                                                                                            |
| <code v-pre><a href="#tecs.sequence.Evaluator">Evaluator</a></code> | <code v-pre>evaluator</code> | Must carry `step`, or this raises. The rest are optional, and without `save` and `load` a playback evaluating this name comes back from a snapshot at the start of its state rather than where it was. |

<a id="tecs.sequence.registerQuery"></a>

### tecs.sequence.registerQuery

<pre><code v-pre>function <a href="#tecs.sequence.registerQuery">tecs.sequence.registerQuery</a>(name: World, descriptor: string, ecs.Query.Descriptor)
</code></pre>

Register a query a `waitQuery` step can name.

The query subscribes to archetype transitions, so a wait on it stays
event driven rather than polling. Registration is startup work: a
name registered twice keeps the newer query, and the replaced one
holds its subscriptions for the life of the world.

#### Parameters

| Type                                    | Name                          | Description                                                                                                                                                                                      |
| --------------------------------------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre>World</code>                | <code v-pre>name</code>       | Empty raises. Registering it again re-tests every playback already parked on the name, against the new query, at the next fixed step.                                                            |
| <code v-pre>string</code>               | <code v-pre>descriptor</code> | Copied rather than kept, and its `onEntitiesAdded` and `onEntitiesRemoved` are wrapped rather than replaced: the ones you supply are still called, after the name is marked. A non-table raises. |
| <code v-pre>ecs.Query.Descriptor</code> |                               |                                                                                                                                                                                                  |

<a id="tecs.sequence.resume"></a>

### tecs.sequence.resume

<pre><code v-pre>function <a href="#tecs.sequence.resume">tecs.sequence.resume</a>(holder: World, <a href="#tecs.sequence.Handle">Handle</a>, string): boolean
</code></pre>

Release one holder's claim.

#### Parameters

| Type                                                          | Name                      | Description                                                                                                                       |
| ------------------------------------------------------------- | ------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>World</code>                                      | <code v-pre>holder</code> | Must be the string that took the hold; releasing one that never held it changes nothing. Defaults to `"user"`, as `pause`'s does. |
| <code v-pre><a href="#tecs.sequence.Handle">Handle</a></code> |                           |                                                                                                                                   |
| <code v-pre>string</code>                                     |                           |                                                                                                                                   |

#### Returns

| Type                       | Description                                                                                                                                                                               |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | Whether the playback started running again, which is only true for the last holder to let go. A wake time that passed while it was held runs it on the next tick rather than immediately. |

<a id="tecs.sequence.setInstructionBudget"></a>

### tecs.sequence.setInstructionBudget

<pre><code v-pre>function <a href="#tecs.sequence.setInstructionBudget">tecs.sequence.setInstructionBudget</a>(instructions: World, integer)
</code></pre>

Per-step instruction budget for playbacks that do not set their own.

#### Parameters

| Type                       | Name                            | Description                                                                                                                                                                                                                                                                                                                                   |
| -------------------------- | ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>World</code>   | <code v-pre>instructions</code> | Must be at least 1. It caps how many instructions one playback runs per tick, and exceeding it faults the playback with `budgetExceeded` rather than deferring the rest, so it is a guard against a `loop` with no wait in it, not a scheduler. Applies to playbacks started after this call; a running one keeps the budget it started with. |
| <code v-pre>integer</code> |                                 |                                                                                                                                                                                                                                                                                                                                               |

<a id="tecs.sequence.signal"></a>

### tecs.sequence.signal

<pre><code v-pre>function <a href="#tecs.sequence.signal">tecs.sequence.signal</a>(name: World, string): integer
</code></pre>

Raise a named signal, waking every playback blocked on it.

Delivery happens on the next fixed step. Raising a signal nothing is
waiting on is not an error and is not remembered: a playback that
reaches `waitSignal` afterwards keeps waiting.

#### Parameters

| Type                      | Name                    | Description                                          |
| ------------------------- | ----------------------- | ---------------------------------------------------- |
| <code v-pre>World</code>  | <code v-pre>name</code> | Any string, registered nowhere. An empty one raises. |
| <code v-pre>string</code> |                         |                                                      |

#### Returns

| Type                       | Description                                                                                                                                                                                                           |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | How many playbacks are parked on the name at this call. It is a reading rather than a promise: delivery wakes whatever is parked on the name when the next fixed step arrives, which is not necessarily the same set. |

<a id="tecs.sequence.signalOnEvent"></a>

### tecs.sequence.signalOnEvent

<pre><code v-pre>function <a href="#tecs.sequence.signalOnEvent">tecs.sequence.signalOnEvent</a>&lt;T is ecs.Event&gt;(name: World, event: string, T)
</code></pre>

Raise a signal every time an event is emitted at address 0.

An ECS event is an edge, like a signal, so this wires one to the
other rather than adding a separate kind of wait. Delivery follows
the ordinary signal rule: waiters wake on the next fixed step.

#### Type Parameters

| Name                 | Constraint                   | Description |
| -------------------- | ---------------------------- | ----------- |
| <code v-pre>T</code> | <code v-pre>ecs.Event</code> |             |

#### Parameters

| Type                      | Name                     | Description                                                                                                                                                               |
| ------------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>World</code>  | <code v-pre>name</code>  | The signal to raise, once per emission. An empty one raises.                                                                                                              |
| <code v-pre>string</code> | <code v-pre>event</code> | Observed at address 0, and only there. The observer lasts for the life of the world; wiring the same pair twice observes it twice, and there is nothing that unwires one. |
| <code v-pre>T</code>      |                          |                                                                                                                                                                           |

<a id="tecs.sequence.source"></a>

### tecs.sequence.source

<pre><code v-pre><a href="#tecs.sequence.source">tecs.sequence.source</a>: tweeneval.Sources
</code></pre>

Where a `tweenTrack` step reads the value it chases:
`sequence.source.own(Transform, "x")`.
<a id="tecs.sequence.status"></a>

### tecs.sequence.status

<pre><code v-pre>function <a href="#tecs.sequence.status">tecs.sequence.status</a>(handle: World, <a href="#tecs.sequence.Handle">Handle</a>): <a href="#tecs.sequence.Status">Status</a>
</code></pre>

Inspect a playback. Returns nil for a handle this world never issued.

#### Parameters

| Type                                                          | Name                      | Description                                               |
| ------------------------------------------------------------- | ------------------------- | --------------------------------------------------------- |
| <code v-pre>World</code>                                      | <code v-pre>handle</code> | Read against this world's cursor arena, as `cancel`'s is. |
| <code v-pre><a href="#tecs.sequence.Handle">Handle</a></code> |                           |                                                           |

#### Returns

| Type                                                          | Description                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.Status">Status</a></code> | A fresh table each call, which the caller owns. A finished playback still answers, with `state` saying how it ended, until its slot is taken by a later `play`; after that the generation no longer matches and the answer is nil. The fields naming what it is waiting on are filled only while it is alive, so a finished playback reports its program, the `pc` it stopped at, how it ended and its last tween outcome, with the rest nil. |

<a id="tecs.sequence.target"></a>

### tecs.sequence.target

<pre><code v-pre><a href="#tecs.sequence.target">tecs.sequence.target</a>: tweeneval.Targets
</code></pre>

The built-in targets and the constructors for new ones:
`sequence.target.translateX`, `sequence.target.field(C, "hp")`.
<a id="tecs.sequence.timeline"></a>

### tecs.sequence.timeline

<pre><code v-pre>function <a href="#tecs.sequence.timeline">tecs.sequence.timeline</a>(name: string, spec: <a href="#tecs.sequence.TimelineSpec">TimelineSpec</a>, options: <a href="#tecs.sequence.TimelineOptions">TimelineOptions</a>): <a href="#tecs.sequence.Program">Program</a>
</code></pre>

Compile a tween timeline into a program under a stable name.

The compiled slots travel in the program's const pool, so a timeline
is snapshot-safe for the same reason every other program is. Play it
with `play`, giving the entity it animates as the `owner`.

It reads four `params`, all optional:

mode "once" (default), "loop", or "pingPong"
count passes for a finite loop or ping-pong; endless without it
speed playback multiplier, defaulting to 1
delay seconds to wait before the first frame

local fade = sequence.timeline("game.fade", {
sequence.tweenTo(0.4, "quadOut", "color.a", 0),
})
sequence.play(world, fade, {owner = e, params = {delay = 0.2}})

#### Parameters

| Type                                                                            | Name                       | Description                                                                                                                                                      |
| ------------------------------------------------------------------------------- | -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code>                                                       | <code v-pre>name</code>    | Shared with `define`'s namespace, and versioned the same way: compiling over a live name publishes a new version and leaves playbacks of the old one running it. |
| <code v-pre><a href="#tecs.sequence.TimelineSpec">TimelineSpec</a></code>       | <code v-pre>spec</code>    | Compiled in place, so the table given here belongs to the timeline afterwards and must not be compiled a second time.                                            |
| <code v-pre><a href="#tecs.sequence.TimelineOptions">TimelineOptions</a></code> | <code v-pre>options</code> | Omitted, the timeline runs on the presentation clock. `"fixed"` and `"presentation"` are the only two accepted; `"frame"` raises, though `define` takes it.      |

#### Returns

| Type                                                            | Description                                                                                                                                                                                                                                                                                                                                                                                                                           |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.Program">Program</a></code> | The compiled program, also reachable by name through `program`. Play it on an entity: a playback with no `owner` has nothing to write to and completes on its first tick without animating anything. The `params` above are read when that playback builds its state, so a `speed` of zero or less, a negative `delay`, or a repeat of a zero-length timeline faults the playback with `actionError` rather than raising from `play`. |

<a id="tecs.sequence.tweenAdjust"></a>

### tecs.sequence.tweenAdjust

<pre><code v-pre>function <a href="#tecs.sequence.tweenAdjust">tecs.sequence.tweenAdjust</a>(duration: number, curve: <a href="#tecs.sequence.EasingName">EasingName</a> | <a href="#tecs.sequence.EasingFunction">EasingFunction</a>, target: <a href="#tecs.sequence.TargetName">TargetName</a> | <a href="#tecs.sequence.Target">Target</a>, t1: number, t2: number, t3: number, t4: number): <a href="#tecs.sequence.TimelineNode">TimelineNode</a>
</code></pre>

Interpolate by a relative delta, read from wherever the value starts.

Identical to `tweenTo` except that `t1` through `t4` are the amount to
move by rather than where to end up, so the destination depends on the
entity's value the first tick the operation is evaluated.

#### Parameters

| Type                                                                                                                                | Name                        | Description                                                                                                                                                            |
| ----------------------------------------------------------------------------------------------------------------------------------- | --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>number</code>                                                                                                           | <code v-pre>duration</code> | Seconds, and strictly positive.                                                                                                                                        |
| <code v-pre><a href="#tecs.sequence.EasingName">EasingName</a> \| <a href="#tecs.sequence.EasingFunction">EasingFunction</a></code> | <code v-pre>curve</code>    | As `tweenTo`'s, and built in for the same reason.                                                                                                                      |
| <code v-pre><a href="#tecs.sequence.TargetName">TargetName</a> \| <a href="#tecs.sequence.Target">Target</a></code>                 | <code v-pre>target</code>   | Which component fields move, and in which order `t1` through `t4` line up with them.                                                                                   |
| <code v-pre>number</code>                                                                                                           | <code v-pre>t1</code>       | Change applied to the target's first field, in that field's own units, and signed: negative moves the other way.                                                       |
| <code v-pre>number</code>                                                                                                           | <code v-pre>t2</code>       | Change applied to the second field.                                                                                                                                    |
| <code v-pre>number</code>                                                                                                           | <code v-pre>t3</code>       | Change applied to the third field.                                                                                                                                     |
| <code v-pre>number</code>                                                                                                           | <code v-pre>t4</code>       | Change applied to the fourth field. An argument past the target's field count is ignored; an omitted one is a change of zero, which holds that field where it started. |

#### Returns

| Type                                                                      | Description                                                             |
| ------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.TimelineNode">TimelineNode</a></code> | A node for a `TimelineSpec`, consumed by the timeline that compiles it. |

<a id="tecs.sequence.tweenEmit"></a>

### tecs.sequence.tweenEmit

<pre><code v-pre>function <a href="#tecs.sequence.tweenEmit">tecs.sequence.tweenEmit</a>(name: string): <a href="#tecs.sequence.TimelineNode">TimelineNode</a>
</code></pre>

Emit a named `sequence.Event` when the cursor reaches this point.

Occupies no time, so what follows it starts at the same instant. The
event carries the entity the timeline is animating as its one argument,
and the timeline's own playback as its handle. It fires as the cursor
passes the point going forward, so a `pingPong`'s return leg does not
fire it a second time.

#### Parameters

| Type                      | Name                    | Description                                                                |
| ------------------------- | ----------------------- | -------------------------------------------------------------------------- |
| <code v-pre>string</code> | <code v-pre>name</code> | Carried on the event as its name; the sequencer attaches no meaning to it. |

#### Returns

| Type                                                                      | Description                  |
| ------------------------------------------------------------------------- | ---------------------------- |
| <code v-pre><a href="#tecs.sequence.TimelineNode">TimelineNode</a></code> | A node for a `TimelineSpec`. |

<a id="tecs.sequence.tweenParallel"></a>

### tecs.sequence.tweenParallel

<pre><code v-pre>function <a href="#tecs.sequence.tweenParallel">tecs.sequence.tweenParallel</a>(...: <a href="#tecs.sequence.TimelineNode">TimelineNode</a>): <a href="#tecs.sequence.TimelineNode">TimelineNode</a>
</code></pre>

Run timeline nodes concurrently, ending with the longest.

Every argument starts at the point the `tweenParallel` sits at, and
what follows starts after the last of them ends. Two arguments writing
the same component field is not an error and the later one in argument
order wins each tick.

#### Parameters

| Type                                                                      | Name                   | Description                                                                                                                                                                |
| ------------------------------------------------------------------------- | ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.TimelineNode">TimelineNode</a></code> | <code v-pre>...</code> | One node per concurrent operation. A list of nodes counts as one argument and runs in sequence within it, which is how a branch longer than a single operation is written. |

#### Returns

| Type                                                                      | Description                  |
| ------------------------------------------------------------------------- | ---------------------------- |
| <code v-pre><a href="#tecs.sequence.TimelineNode">TimelineNode</a></code> | A node for a `TimelineSpec`. |

<a id="tecs.sequence.tweenRun"></a>

### tecs.sequence.tweenRun

<pre><code v-pre>function <a href="#tecs.sequence.tweenRun">tecs.sequence.tweenRun</a>(spec: <a href="#tecs.sequence.TimelineSpec">TimelineSpec</a>, options: <a href="#tecs.sequence.RunOptions">RunOptions</a>): <a href="#tecs.sequence.TimelineNode">TimelineNode</a>
</code></pre>

Run a nested timeline, given as its own spec.

The nested timeline occupies a window of the parent equal to its own
length times its pass count, so a repeating nested run needs a finite
`count`. Its own operations keep their per-playback state separately
from the parent's.

#### Parameters

| Type                                                                      | Name                       | Description                                                                                                            |
| ------------------------------------------------------------------------- | -------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.TimelineSpec">TimelineSpec</a></code> | <code v-pre>spec</code>    | Compiled in place if it has not been already, so the table given here belongs to this node afterwards.                 |
| <code v-pre><a href="#tecs.sequence.RunOptions">RunOptions</a></code>     | <code v-pre>options</code> | Omit to run the nested timeline once. `"loop"` and `"pingPong"` need a `count` here, and compiling raises without one. |

#### Returns

| Type                                                                      | Description                  |
| ------------------------------------------------------------------------- | ---------------------------- |
| <code v-pre><a href="#tecs.sequence.TimelineNode">TimelineNode</a></code> | A node for a `TimelineSpec`. |

<a id="tecs.sequence.tweenTo"></a>

### tecs.sequence.tweenTo

<pre><code v-pre>function <a href="#tecs.sequence.tweenTo">tecs.sequence.tweenTo</a>(duration: number, curve: <a href="#tecs.sequence.EasingName">EasingName</a> | <a href="#tecs.sequence.EasingFunction">EasingFunction</a>, target: <a href="#tecs.sequence.TargetName">TargetName</a> | <a href="#tecs.sequence.Target">Target</a>, t1: number, t2: number, t3: number, t4: number): <a href="#tecs.sequence.TimelineNode">TimelineNode</a>
</code></pre>

Interpolate to an absolute destination.

The starting values are read off the entity the first tick the
operation is evaluated, not when the timeline is compiled, so the same
timeline played on two entities starts from wherever each of them is.

#### Parameters

| Type                                                                                                                                | Name                        | Description                                                                                                                                                                                                                                          |
| ----------------------------------------------------------------------------------------------------------------------------------- | --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>number</code>                                                                                                           | <code v-pre>duration</code> | Seconds, and strictly positive: a zero is rejected at compile time. Use `tweenWait` for a gap that moves nothing.                                                                                                                                    |
| <code v-pre><a href="#tecs.sequence.EasingName">EasingName</a> \| <a href="#tecs.sequence.EasingFunction">EasingFunction</a></code> | <code v-pre>curve</code>    | A name from `sequence.easing`, or one of those functions itself. A curve of your own is rejected when the timeline compiles: a compiled slot carries the curve's name so it can travel in a const pool, and a function it cannot name has none.      |
| <code v-pre><a href="#tecs.sequence.TargetName">TargetName</a> \| <a href="#tecs.sequence.Target">Target</a></code>                 | <code v-pre>target</code>   | Which component fields move, and in which order `t1` through `t4` line up with them.                                                                                                                                                                 |
| <code v-pre>number</code>                                                                                                           | <code v-pre>t1</code>       | Destination for the target's first field, in that field's own units: pixels for a translate, radians for a rotation, 0 to 1 for a colour channel. A shortest-path rotation target still takes an absolute angle and picks the short way round to it. |
| <code v-pre>number</code>                                                                                                           | <code v-pre>t2</code>       | Destination for the second field, for a target that has one.                                                                                                                                                                                         |
| <code v-pre>number</code>                                                                                                           | <code v-pre>t3</code>       | Destination for the third field, for a four-field target.                                                                                                                                                                                            |
| <code v-pre>number</code>                                                                                                           | <code v-pre>t4</code>       | Destination for the fourth field, for a four-field target. An argument past the target's field count is ignored; one the target has and you omit counts as a destination of zero.                                                                    |

#### Returns

| Type                                                                      | Description                                                                                              |
| ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.TimelineNode">TimelineNode</a></code> | A node for a `TimelineSpec`, consumed by the timeline that compiles it and not reusable in a second one. |

<a id="tecs.sequence.tweenTrack"></a>

### tecs.sequence.tweenTrack

<pre><code v-pre>function <a href="#tecs.sequence.tweenTrack">tecs.sequence.tweenTrack</a>(duration: number, curve: <a href="#tecs.sequence.EasingName">EasingName</a> | <a href="#tecs.sequence.EasingFunction">EasingFunction</a>, target: <a href="#tecs.sequence.TargetName">TargetName</a> | <a href="#tecs.sequence.Target">Target</a>, from: <a href="#tecs.sequence.TrackSource">TrackSource</a>): <a href="#tecs.sequence.TimelineNode">TimelineNode</a>
</code></pre>

Interpolate toward a destination that keeps moving.

The start is fixed the first tick, as with `tweenTo`, but the
destination is re-read from `from` every tick the operation is inside
its window, so the entity chases a value that is still changing. Once
the window ends the last destination is held rather than followed.

#### Parameters

| Type                                                                                                                                | Name                        | Description                                                                                                                                                                                                                                                                 |
| ----------------------------------------------------------------------------------------------------------------------------------- | --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>number</code>                                                                                                           | <code v-pre>duration</code> | Seconds, and strictly positive.                                                                                                                                                                                                                                             |
| <code v-pre><a href="#tecs.sequence.EasingName">EasingName</a> \| <a href="#tecs.sequence.EasingFunction">EasingFunction</a></code> | <code v-pre>curve</code>    | As `tweenTo`'s. It shapes how far toward the current destination the value sits, and that destination keeps moving underneath it.                                                                                                                                           |
| <code v-pre><a href="#tecs.sequence.TargetName">TargetName</a> \| <a href="#tecs.sequence.Target">Target</a></code>                 | <code v-pre>target</code>   | Which component fields move, and which fields of `from` line up with them: the source is read into the same one to four numbers the target writes.                                                                                                                          |
| <code v-pre><a href="#tecs.sequence.TrackSource">TrackSource</a></code>                                                             | <code v-pre>from</code>     | Where the destination is read each tick. A source whose entity or component is missing reads as zero rather than faulting, so an entity chasing something that despawned drifts to the origin. A source named by world key is the exception and requires the key to be set. |

#### Returns

| Type                                                                      | Description                                                             |
| ------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.TimelineNode">TimelineNode</a></code> | A node for a `TimelineSpec`, consumed by the timeline that compiles it. |

<a id="tecs.sequence.tweenWait"></a>

### tecs.sequence.tweenWait

<pre><code v-pre>function <a href="#tecs.sequence.tweenWait">tecs.sequence.tweenWait</a>(duration: number): <a href="#tecs.sequence.TimelineNode">TimelineNode</a>
</code></pre>

Advance the timeline cursor without changing anything.

#### Parameters

| Type                      | Name                        | Description                                                                                 |
| ------------------------- | --------------------------- | ------------------------------------------------------------------------------------------- |
| <code v-pre>number</code> | <code v-pre>duration</code> | Seconds. Zero is allowed and is a no-op, unlike the duration of an interpolating operation. |

#### Returns

| Type                                                                      | Description                  |
| ------------------------------------------------------------------------- | ---------------------------- |
| <code v-pre><a href="#tecs.sequence.TimelineNode">TimelineNode</a></code> | A node for a `TimelineSpec`. |

<a id="tecs.sequence.upcoming"></a>

### tecs.sequence.upcoming

<pre><code v-pre>function <a href="#tecs.sequence.upcoming">tecs.sequence.upcoming</a>(withinTicks: World, <a href="#tecs.sequence.Handle">Handle</a>, integer): {<a href="#tecs.sequence.Step">Step</a>}
</code></pre>

What a playback will certainly do next, and when.

Walks the straight-line run ahead of where it sits, accumulating
waits, and stops at the first instruction whose successor cannot be
known without running it. Ticks are counted in the playback's own
clock, from now.

#### Parameters

| Type                                                          | Name                           | Description                                                                                                                            |
| ------------------------------------------------------------- | ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>World</code>                                      | <code v-pre>withinTicks</code> | Report only what is due within this many ticks. Counted in the playback's own clock, from now. Omit for everything the walk can reach. |
| <code v-pre><a href="#tecs.sequence.Handle">Handle</a></code> |                                |                                                                                                                                        |
| <code v-pre>integer</code>                                    |                                |                                                                                                                                        |

#### Returns

| Type                                                        | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| ----------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>{<a href="#tecs.sequence.Step">Step</a>}</code> | A fresh table each call, holding the calls and emits ahead in order. Empty for a handle that names nothing running, and also for one parked on a signal, a query, a join, a tween or an evaluator, since none of those has a predictable start. A wait written in seconds also ends the walk, because converting it needs a clock the program does not carry. Each step's `args` is the program's own constant list rather than a copy of it, so read it and do not write to it. A paused playback still answers, counted as though it were running. |

<a id="tecs.sequence.wait"></a>

### tecs.sequence.wait

<pre><code v-pre>function <a href="#tecs.sequence.wait">tecs.sequence.wait</a>(seconds: number): <a href="#tecs.sequence.Node">Node</a>
</code></pre>

Wait for a duration in seconds.

Converted to whole ticks when the instruction runs, rounded to nearest,
with any non-zero duration waiting at least one tick. A program on the
frame clock divides the duration by the loop's nominal frame dt; every
other clock divides by the world's fixed timestep. Programs therefore
stay independent of any one world's timing. Use `waitSteps` when the
exact tick count matters more than the wall-clock duration.

#### Parameters

| Type                      | Name                       | Description                                                                                                                                                                                                                  |
| ------------------------- | -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>number</code> | <code v-pre>seconds</code> | Non-negative; a negative one is rejected here rather than at compile time. Zero still costs a tick: the cursor resumes on the program's next tick rather than carrying on within this one, so no duration makes `wait` free. |

#### Returns

| Type                                                      | Description                                                 |
| --------------------------------------------------------- | ----------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.Node">Node</a></code> | A node for `define`, and not to be put in a second program. |

<a id="tecs.sequence.waitQuery"></a>

### tecs.sequence.waitQuery

<pre><code v-pre>function <a href="#tecs.sequence.waitQuery">tecs.sequence.waitQuery</a>(name: string, condition: <a href="#tecs.sequence.QueryCondition">QueryCondition</a>): <a href="#tecs.sequence.Node">Node</a>
</code></pre>

Block until a registered query matches, or stops matching.

Unlike a signal, which is an edge, this is a condition on the world:
a wait whose condition already holds resumes rather than waiting for
a transition that has already happened.

The condition is evaluated at the start of the next fixed step, never
at the instruction itself, so it never reads a world that a spawn or
despawn from the current step has not been committed to yet. A query
wait therefore costs at least one step.

#### Parameters

| Type                                                                          | Name                         | Description                                                                                                                                                                                               |
| ----------------------------------------------------------------------------- | ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code>                                                     | <code v-pre>name</code>      | Resolved per world when the instruction runs, not at `define`, so a program may name a query registered later. A name still unregistered when the step runs faults the playback with `unregisteredQuery`. |
| <code v-pre><a href="#tecs.sequence.QueryCondition">QueryCondition</a></code> | <code v-pre>condition</code> | Rejected here, not at compile time, when it is neither `"any"` nor `"empty"`.                                                                                                                             |

#### Returns

| Type                                                      | Description                                                 |
| --------------------------------------------------------- | ----------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.Node">Node</a></code> | A node for `define`, and not to be put in a second program. |

<a id="tecs.sequence.waitSignal"></a>

### tecs.sequence.waitSignal

<pre><code v-pre>function <a href="#tecs.sequence.waitSignal">tecs.sequence.waitSignal</a>(name: string): <a href="#tecs.sequence.Node">Node</a>
</code></pre>

Block until a named signal is raised.

Signals are delivered on the fixed step after `signal` is called, so a
signal raised by one sequence never runs another within the same step.
That bounds a chain of signals to one link per step and keeps delivery
order independent of which cursor happened to run first. Delivery runs
on the fixed clock whatever clock the program is on, so a frame or
presentation program wakes at its own clock's next tick after the fixed
step that delivered it.

#### Parameters

| Type                      | Name                    | Description                                                                                                                                                                                                              |
| ------------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre>string</code> | <code v-pre>name</code> | Matched by value against `signal`'s, and registered nowhere: any string names a channel. A name nothing raises parks the playback until something cancels it, because a signal raised before the wait is not remembered. |

#### Returns

| Type                                                      | Description                                                 |
| --------------------------------------------------------- | ----------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.Node">Node</a></code> | A node for `define`, and not to be put in a second program. |

<a id="tecs.sequence.waitSteps"></a>

### tecs.sequence.waitSteps

<pre><code v-pre>function <a href="#tecs.sequence.waitSteps">tecs.sequence.waitSteps</a>(steps: integer): <a href="#tecs.sequence.Node">Node</a>
</code></pre>

Wait for a whole number of ticks of the program's clock.

`waitSteps(0)` yields: the cursor resumes on its program's next tick
rather than continuing within the current one.

#### Parameters

| Type                       | Name                     | Description                                                                                                                                                                         |
| -------------------------- | ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | <code v-pre>steps</code> | Ticks of the program's own clock, so a program defined against `"frame"` or `"presentation"` counts those and not fixed steps. Non-negative and whole; a fraction is rejected here. |

#### Returns

| Type                                                      | Description                                                 |
| --------------------------------------------------------- | ----------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.Node">Node</a></code> | A node for `define`, and not to be put in a second program. |

<a id="tecs.sequence.waitTween"></a>

### tecs.sequence.waitTween

<pre><code v-pre>function <a href="#tecs.sequence.waitTween">tecs.sequence.waitTween</a>(): <a href="#tecs.sequence.Node">Node</a>
</code></pre>

Wait for the tween the most recent `playTween` started.

Resumes when that specific playback completes, is cancelled, is
replaced on its channel, or loses its entity, so it never waits
forever. `status` reports which of those happened, as `tweenOutcome`.

A `waitTween` that no `playTween` in this playback preceded falls
straight through without costing a tick.

#### Returns

| Type                                                      | Description                                                 |
| --------------------------------------------------------- | ----------------------------------------------------------- |
| <code v-pre><a href="#tecs.sequence.Node">Node</a></code> | A node for `define`, and not to be put in a second program. |

<a id="tecs.sequence.waitingOn"></a>

### tecs.sequence.waitingOn

<pre><code v-pre>function <a href="#tecs.sequence.waitingOn">tecs.sequence.waitingOn</a>(World, string): integer
</code></pre>

Playbacks currently blocked on a signal name.

#### Parameters

| Type                      | Name | Description |
| ------------------------- | ---- | ----------- |
| <code v-pre>World</code>  |      |             |
| <code v-pre>string</code> |      |             |

#### Returns

| Type                       | Description                                                                                                                                                                           |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | 0 for a name nothing waits on, including one never signalled. Counts what is parked right now, so a signal already raised this step is still counted until the next step delivers it. |
