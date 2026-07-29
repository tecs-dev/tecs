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
canceled and waited on, and it comes back from a snapshot where it was.

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

### Clocks

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

| Constructor                            | Effect                                                        |
| -------------------------------------- | ------------------------------------------------------------- |
| `call(action, ...)`                    | Run a registered action with constant arguments.              |
| `wait(seconds)`                        | Wait a duration.                                              |
| `waitSteps(steps)`                     | Wait a whole number of ticks.                                 |
| `waitSignal(name)`                     | Block until a named signal is raised.                         |
| `waitQuery(name, condition)`           | Block until a registered query matches, or stops matching.    |
| `emit(event, ...)`                     | Emit a `sequence.Event` at address 0.                         |
| `loop(count, nodes)`                   | Repeat a block, or repeat until canceled when `count` is nil. |
| `fork(nodes)`                          | Start a branch alongside the rest of the program.             |
| `join()`                               | Wait for every branch forked and not yet joined.              |
| `parallel(...)`                        | Fork several blocks and wait for all of them.                 |
| `playTween(timeline, target, params?)` | Play a registered timeline on a bound entity.                 |
| `waitTween()`                          | Wait for the playback the most recent `playTween` started.    |
| `await(provider, target, key?)`        | Wait for something outside the sequencer to finish.           |
| `eval(evaluator, data?)`               | Evaluate a registered evaluator every tick until it finishes. |
| `bind(name)`                           | Not a step: a reference to an entity supplied at `play` time. |

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

Repeats a block `count` times, or until the playback is canceled when `count` is nil. The count must be a
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

A branch never outlives the playback that forked it: finishing or canceling that playback cancels the branches
it has not joined. A branch that faults faults its parent with `branchFaulted`, because that is a defect in the
program; a branch that is canceled is deliberate, and a `join` simply proceeds without it.

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

`waitTween` resumes when that specific playback completes, is canceled, is replaced on its channel, or loses
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
| `owner`    | `integer`           | `0`                | Entity whose lifetime governs the playback. When it despawns the playback is canceled. Omit for a world-scoped sequence.       |
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

Stops a playback and releases its cursor, canceling its branches and anything it started. Safe on a finished
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
| `state`                  | `PlaybackState`  | `"running"`, `"paused"`, `"completed"`, `"canceled"` or `"faulted"`.         |
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

**Returns:** how many were canceled.

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
one for a scalar field, two for a pair, four for a color.

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
        sequence.source.tracking(tecs.Transform, {"x", "y"})),
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
`"canceled"`, `"replaced"` or `"targetLost"`.

## Installing it

```teal
function sequence.plugin(world: World)
```

[`Application`](/modules/Application) installs the sequencer, so a game that builds one never calls this. A
world built by hand, a test or a tool that scripts input installs it itself; a second install on the same world
does nothing.

Installing adds one system per clock, `sequence.Advance` in `FixedFirst`, `sequence.AdvanceFrame` in `First` and
`sequence.AdvancePresentation` in `Update`, a snapshot handler named `tecs.sequence`, and an observer that
cancels an owner's playbacks with `targetLost` when it despawns.
