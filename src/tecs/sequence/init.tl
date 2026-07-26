--- Deterministic, snapshot-safe gameplay sequencing.
---
--- A sequence is a compiled program of scheduled steps that advances on the
--- fixed step. Cutscenes, ability chains, spawn waves, and tutorials are
--- normally written as coroutines, whose suspended state lives in the Lua
--- stack and cannot be serialized. A sequence keeps its position as data, so
--- it survives snapshots, rewind, and hot reload.
---
--- Usage:
---   local sequence = require("tecs.sequence")
---
---   sequence.registerAction(world, "game.lockControls", function(_w, _ctx)
---       controlsLocked = true
---   end)
---
---   local intro = sequence.define("game.bossIntro", {
---       sequence.call("game.lockControls"),
---       sequence.wait(1.5),
---       sequence.emit("boss.ready"),
---   })
---
---   sequence.play(world, intro, {owner = encounter, bindings = {boss = bossId}})

local ecs <const> = require("tecs.ecs")
local seqtypes <const> = require("tecs.sequence.internal.types")
local seqprogram <const> = require("tecs.sequence.internal.program")
local seqregistry <const> = require("tecs.sequence.internal.registry")
local seqsnapshot <const> = require("tecs.sequence.internal.snapshot")
local seqvm <const> = require("tecs.sequence.internal.vm")
local seqcursors <const> = require("tecs.sequence.internal.cursors")
local seqawaitables <const> = require("tecs.sequence.internal.awaitables")
local seqevaluators <const> = require("tecs.sequence.internal.evaluators")
local seqjson <const> = require("tecs.sequence.internal.json")
local seqtweenrun <const> = require("tecs.sequence.internal.tweenrun")
local tweeneval <const> = require("tecs.sequence.internal.tweeneval")

local type World = ecs.World

-- Who holds a pause when the caller does not say.
local DEFAULT_HOLDER <const> = "user"

-- The runtime records live in the leaf types module; bind them so the body
-- below reads the same as when they were declared here.
local type ProgramImpl = seqtypes.ProgramImpl
local record sequence
    ---------------------------------------------------------------------------
    -- Types
    ---------------------------------------------------------------------------

    --- Why a cursor stopped running.
    type FaultReason = seqtypes.FaultReason

    --- The lifecycle state of one playback.
    type PlaybackState = seqtypes.PlaybackState

    --- What a `waitQuery` step is waiting for.
    type QueryCondition = seqtypes.QueryCondition

    --- How the tween a `waitTween` step was waiting on ended.
    type TweenOutcome = seqtypes.TweenOutcome

    --- A compiled, immutable program, produced by `define` and shared by
    --- every playback of it. See `internal/types` for the full contract.
    type Program = seqtypes.Program

    --- One authored step, produced by the node constructors below. Treat the
    --- returned value as opaque and do not reuse a node across programs.
    type Node = seqtypes.Node

    --- A reference to an entity supplied at `play` time, resolved when the
    --- instruction that uses it runs.
    type EntityRef = seqtypes.EntityRef

    --- A generation-checked reference to one playback, meaningful across a
    --- snapshot load.
    type Handle = seqtypes.Handle

    --- Constants a `call` passes to its action.
    type Argument = seqtypes.Argument

    --- Options for `play`.
    type PlayOptions = seqtypes.PlayOptions

    ---------------------------------------------------------------------------
    -- Timelines
    ---------------------------------------------------------------------------

    --- Name of a built-in easing curve, and the shape of any curve.
    type EasingName = tweeneval.EasingName
    type EasingFunction = tweeneval.EasingFunction

    --- Name of a built-in component-field target, and a target value.
    type TargetName = tweeneval.TargetName
    type Target = tweeneval.Target

    --- A live component-field tracking source.
    type TrackSource = tweeneval.TrackSource

    --- One authored timeline operation, and a list of them.
    type TimelineNode = tweeneval.TimelineNode
    type TimelineSpec = tweeneval.TimelineSpec

    --- How a timeline repeats, and the options a nested run takes.
    type PlaybackMode = tweeneval.PlaybackMode
    type RunOptions = tweeneval.RunOptions

    --- The built-in easing curves: `sequence.easing.quadOut`.
    easing: tweeneval.Easings

    --- The built-in targets and the constructors for new ones:
    --- `sequence.target.translateX`, `sequence.target.field(C, "hp")`.
    target: tweeneval.Targets

    --- Where a `tweenTrack` step reads the value it chases:
    --- `sequence.source.own(Transform, "x")`.
    source: tweeneval.Sources

    --- Component selecting a dynamic tracking source entity.
    TrackingTarget: tweeneval.TrackingTarget

    --- Interpolate to an absolute destination.
    tweenTo: function(
        duration: number, curve: EasingName | EasingFunction,
        target: TargetName | Target,
        t1: number, t2?: number, t3?: number, t4?: number
    ): TimelineNode

    --- Interpolate by a relative delta, read from wherever the value starts.
    tweenAdjust: function(
        duration: number, curve: EasingName | EasingFunction,
        target: TargetName | Target,
        t1: number, t2?: number, t3?: number, t4?: number
    ): TimelineNode

    --- Interpolate toward a destination that keeps moving.
    tweenTrack: function(
        duration: number, curve: EasingName | EasingFunction,
        target: TargetName | Target, from: TrackSource
    ): TimelineNode

    --- Advance the timeline cursor without changing anything.
    tweenWait: function(duration: number): TimelineNode

    --- Emit a named `sequence.Event` when the cursor reaches this point.
    tweenEmit: function(name: string): TimelineNode

    --- Run a nested timeline, given as its own spec.
    tweenRun: function(spec: TimelineSpec, options?: RunOptions): TimelineNode

    --- Run timeline nodes concurrently, ending with the longest.
    tweenParallel: function(...: TimelineNode): TimelineNode

    --- Which clock a program is scheduled against.
    type ClockId = seqtypes.ClockId

    --- Options for `define`.
    record DefineOptions
        --- Clock the program's waits count. Defaults to `"fixed"`.
        clock: ClockId
    end

    --- What a registered action receives. The context and its `args` belong
    --- to the sequencer and are reused by the next call.
    type ActionContext = seqtypes.ActionContext

    --- A registered effect. Runs synchronously and may not yield.
    type Action = seqtypes.Action

    --- A playback's current state.
    type Status = seqtypes.Status

    --- Emitted by an `emit` step, at address 0.
    Event: seqtypes.Event

    ---------------------------------------------------------------------------
    -- Authoring
    ---------------------------------------------------------------------------

    --- Compile a program written as plain data rather than node calls.
    ---
    --- The same authoring surface as a list of steps, for callers that
    --- cannot invoke Lua: a tool over MCP, a file on disk, a hand-written
    --- table. Returns nil plus the path to the first bad entry.
    ---
    ---     sequence.defineData("game.intro", {
    ---         {op = "call", action = "game.lockControls"},
    ---         {op = "wait", seconds = 1.5},
    ---     })
    defineData: function(name: string, rows: {any}, options?: DefineOptions): Program, string

    --- The step names `defineData` accepts, sorted.
    dataOps: function(): {string}

    --- Compile a program under a stable symbolic name.
    ---
    --- `options.clock` picks what the program's waits count. `"fixed"`, the
    --- default, counts fixed steps and is what gameplay logic wants.
    --- `"frame"` counts gameplay frames, one tick per frame however many fixed
    --- steps that frame runs, which is what scripted input needs.
    define: function(name: string, nodes: {Node}, options?: DefineOptions): Program

    --- Options for `timeline`.
    record TimelineOptions
        --- Clock the timeline is evaluated on. Defaults to `"presentation"`,
        --- which moves at the display's rate. `"fixed"` makes it
        --- deterministic from a snapshot alone, at the cost of stepping at
        --- the simulation's rate: only `Transform` is interpolated between
        --- fixed steps, so a fixed-clock tween of anything else visibly
        --- steps. If the simulation can observe the value, put it on
        --- `"fixed"`.
        clock: ClockId
    end

    --- Compile a tween timeline into a program under a stable name.
    ---
    --- The compiled slots travel in the program's const pool, so a timeline
    --- is snapshot-safe for the same reason every other program is. Play it
    --- with `play`, giving the entity it animates as the `owner`.
    ---
    --- It reads four `params`, all optional:
    ---
    ---   mode   "once" (default), "loop", or "pingPong"
    ---   count  passes for a finite loop or ping-pong; endless without it
    ---   speed  playback multiplier, defaulting to 1
    ---   delay  seconds to wait before the first frame
    ---
    ---     local fade = sequence.timeline("game.fade", {
    ---         sequence.tweenTo(0.4, "quadOut", "color.a", 0),
    ---     })
    ---     sequence.play(world, fade, {owner = e, params = {delay = 0.2}})
    timeline: function(
        name: string, spec: TimelineSpec, options?: TimelineOptions
    ): Program

    --- Look up a defined program: the newest version, or a specific one.
    --- Every version a playback still runs stays reachable.
    program: function(name: string, version?: integer): Program

    --- Names of every defined program, sorted.
    programNames: function(): {string}

    --- Reference an entity supplied through `PlayOptions.bindings`.
    bind: function(name: string): EntityRef

    --- Run a registered action.
    call: function(action: string, ...: Argument): Node

    --- Wait for a duration in seconds.
    ---
    --- Converted to whole fixed steps when the instruction runs, using the
    --- world's fixed timestep, rounded to nearest, with any non-zero duration
    --- waiting at least one step. Programs therefore stay independent of any
    --- one world's timestep. Use `waitSteps` when the exact step count
    --- matters more than the wall-clock duration.
    wait: function(seconds: number): Node

    --- Block until a named signal is raised.
    ---
    --- Signals are delivered on the fixed step after `signal` is called, so a
    --- signal raised by one sequence never runs another within the same step.
    --- That bounds a chain of signals to one link per step and keeps delivery
    --- order independent of which cursor happened to run first.
    waitSignal: function(name: string): Node

    --- Block until a registered query matches, or stops matching.
    ---
    --- Unlike a signal, which is an edge, this is a condition on the world:
    --- a wait whose condition already holds resumes rather than waiting for
    --- a transition that has already happened.
    ---
    --- The condition is evaluated at the start of the next fixed step, never
    --- at the instruction itself, so it never reads a world that a spawn or
    --- despawn from the current step has not been committed to yet. A query
    --- wait therefore costs at least one step.
    waitQuery: function(name: string, condition: QueryCondition): Node

    --- Wait for a whole number of fixed steps.
    ---
    --- `waitSteps(0)` yields: the cursor resumes on the next fixed step
    --- rather than continuing within the current one.
    waitSteps: function(steps: integer): Node

    --- Emit an ECS event at address 0.
    emit: function(event: string, ...: Argument): Node

    --- Repeat a block.
    --- @param count Iterations, or nil to repeat until cancelled.
    loop: function(count: integer, nodes: {Node}): Node

    --- Start a branch that runs alongside the rest of the program.
    ---
    --- The branch is a playback of its own running the same program at a
    --- different instruction, and it inherits the owner, bindings, and
    --- instruction budget of the playback that forked it. It starts once
    --- that playback next waits, joins, or ends, within the same fixed step.
    ---
    --- A branch never outlives the playback that forked it: finishing or
    --- cancelling that playback cancels the branches it has not joined.
    fork: function(nodes: {Node}): Node

    --- Wait for every branch forked and not yet joined.
    ---
    --- Falls straight through when there are none. When the last branch
    --- finishes, the waiting playback resumes within that same step.
    join: function(): Node

    --- Play a registered tween preset on a bound entity.
    ---
    --- Needs the sequencer, which `tecs.application` installs. A binding
    --- that is missing or dead is not a fault: nothing plays, and a following
    --- `waitTween` resumes at once reporting `targetLost`.
    playTween: function(
        timeline: string, target: EntityRef, params?: {string: any}
    ): Node

    --- Evaluate a registered evaluator every tick until it finishes.
    ---
    --- Unlike every other step, this one does not hand the tick back: the
    --- playback joins its clock's active set and is stepped each tick, which
    --- is what a value that has to move every frame needs.
    ---
    --- `data` is compiled into the program alongside the evaluator's name,
    --- so it travels with a snapshot and has to be plain data for the same
    --- reason a `call` argument does. What the evaluator makes of it is its
    --- own business.
    eval: function(evaluator: string, data?: any): Node

    --- Wait for something outside the sequencer to finish.
    ---
    --- A subsystem registers a provider under a name and answers whether the
    --- work is still going; this parks the playback until it is not. The
    --- sequencer never learns what the work is, which is how a program waits
    --- on a sprite animation without the sequencer requiring the renderer.
    ---
    --- A binding that is missing or dead is not a fault: there is nothing to
    --- wait for and the program carries on. So is a provider reporting a
    --- thing that never started.
    ---
    ---     sequence.call("game.playTag", sequence.bind("hero"), "hurt"),
    ---     sequence.await("game.spriteAnimation", sequence.bind("hero")),
    await: function(provider: string, target: EntityRef, key?: string): Node

    --- What a registered awaitable provider has to answer.
    type Awaitable = seqawaitables.Provider

    --- Register something an `await` step can name. Global, like an
    --- evaluator, because a provider is code.
    registerAwaitable: function(name: string, provider: Awaitable)

    --- Wait for the tween the most recent `playTween` started.
    ---
    --- Resumes when that specific playback completes, is cancelled, is
    --- replaced on its channel, or loses its entity, so it never waits
    --- forever. `status` reports which of those happened.
    waitTween: function(): Node

    --- Fork several blocks and wait for all of them.
    ---
    --- Sugar for a `fork` per block followed by one `join`. Blocks start in
    --- the order they are given.
    parallel: function(...: {Node}): Node

    ---------------------------------------------------------------------------
    -- Actions
    ---------------------------------------------------------------------------

    --- Register something an `eval` step can name.
    ---
    --- Registration is global, like a program: an evaluator is code, and two
    --- worlds evaluating the same name run the same thing.
    registerEvaluator: function(name: string, evaluator: Evaluator)

    --- What an `eval` step runs every tick.
    type Evaluator = seqtypes.Evaluator

    --- Register an effect a `call` node can name.
    ---
    --- Actions must obey the deterministic-action contract to keep replay and
    --- rewind meaningful: no wall-clock reads, no file or network access, and
    --- randomness only from a generator whose state travels with the snapshot.
    registerAction: function(world: World, name: string, action: Action)

    --- Whether an action name is registered on this world.
    hasAction: function(world: World, name: string): boolean

    --- Register a query a `waitQuery` step can name.
    ---
    --- The query subscribes to archetype transitions, so a wait on it stays
    --- event driven rather than polling. Registration is startup work: a
    --- name registered twice keeps the newer query, and the replaced one
    --- holds its subscriptions for the life of the world.
    registerQuery: function(world: World, name: string, descriptor: ecs.Query.Descriptor)

    --- Whether a query name is registered on this world.
    hasQuery: function(world: World, name: string): boolean

    --- Raise a signal every time an event is emitted at address 0.
    ---
    --- An ECS event is an edge, like a signal, so this wires one to the
    --- other rather than adding a separate kind of wait. Delivery follows
    --- the ordinary signal rule: waiters wake on the next fixed step.
    signalOnEvent: function<T is ecs.Event>(world: World, name: string, event: T)

    --- Raise a named signal, waking every playback blocked on it.
    ---
    --- Delivery happens on the next fixed step. Raising a signal nothing is
    --- waiting on is not an error and is not remembered: a playback that
    --- reaches `waitSignal` afterwards keeps waiting.
    --- @return Playbacks that will wake.
    signal: function(world: World, name: string): integer

    --- Playbacks currently blocked on a signal name.
    waitingOn: function(world: World, name: string): integer

    ---------------------------------------------------------------------------
    -- Playback
    ---------------------------------------------------------------------------

    --- Start a program. The first instruction runs on the next fixed step.
    play: function(world: World, program: Program, options?: PlayOptions): Handle

    --- Stop a playback and release its cursor. Safe on a finished handle.
    cancel: function(world: World, handle: Handle): boolean

    --- Suspend a playback, its branches, and anything it started.
    ---
    --- Pause is holder counted: two systems can hold the same playback for
    --- unrelated reasons, and it runs again only when the last one lets go,
    --- so whichever resumes first cannot undo the other. `holder` names who
    --- is holding it and defaults to `"user"`.
    ---
    --- Its wait, if any, resumes from where it paused. What it is waiting on
    --- stops with it when the awaitable provider knows how.
    ---
    --- @return Whether the playback stopped. A second holder taking a hold on
    --- one that is already paused registers the hold and returns false,
    --- because nothing observable changed.
    pause: function(world: World, handle: Handle, holder?: string): boolean

    --- Release one holder's claim.
    --- @return Whether the playback started running again, which is only
    --- true for the last holder to let go.
    resume: function(world: World, handle: Handle, holder?: string): boolean

    --- Inspect a playback. Returns nil for a handle this world never issued.
    status: function(world: World, handle: Handle): Status

    --- Cancel every playback owned by an entity.
    ---
    --- `reason` is what anything waiting on one of them is told. The owner
    --- despawning reports `targetLost`, which is what a waiter needs to tell
    --- "it was stopped" from "what it was moving is gone".
    cancelOwnedBy: function(
        world: World, owner: integer, reason?: TweenOutcome
    ): integer

    --- Number of live playbacks, for tests and diagnostics.
    activeCount: function(world: World): integer

    --- Handles of every live playback, branches included, in a stable
    --- order. For diagnostics and the debugger, not for hot paths.
    playbacks: function(world: World): {Handle}

    ---------------------------------------------------------------------------
    -- Configuration and tooling
    ---------------------------------------------------------------------------

    --- Per-step instruction budget for playbacks that do not set their own.
    setInstructionBudget: function(world: World, instructions: integer)

    --- A clock's current tick, as counted by the sequencer. Defaults to the
    --- fixed clock.
    currentStep: function(world: World, clock?: ClockId): integer

    --- What a playback will certainly do next, and when.
    ---
    --- Walks the straight-line run ahead of where it sits, accumulating
    --- waits, and stops at the first instruction whose successor cannot be
    --- known without running it. Ticks are counted in the playback's own
    --- clock, from now.
    --- @param withinTicks Report only what is due within this many ticks.
    upcoming: function(world: World, handle: Handle, withinTicks?: integer): {Step}

    --- One step a playback will reach without branching.
    type Step = seqprogram.Step

    --- Render a program as readable instructions.
    --- @param pc Mark this instruction, as a playback's `status` reports it.
    disassemble: function(program: Program, pc?: integer): string

    --- Install the sequencer. Auto-installed by `tecs.application`, and safe
    --- to call again: a second install on the same world does nothing.
    plugin: function(world: World)
end

-------------------------------------------------------------------------------
-- Program representation
-------------------------------------------------------------------------------

-- The event record lives in the leaf types module so the VM can emit it
-- without requiring this one back; re-exported here as the public handle.
sequence.Event = seqtypes.Event

-- The timeline authoring surface is the evaluation core's, re-exported here
-- so a game reaches for one module rather than two.
sequence.easing = tweeneval.easing
sequence.target = tweeneval.target
sequence.source = tweeneval.source
sequence.TrackingTarget = tweeneval.TrackingTarget
sequence.tweenTo = tweeneval.to
sequence.tweenAdjust = tweeneval.adjust
sequence.tweenTrack = tweeneval.track
sequence.tweenWait = tweeneval.wait
sequence.tweenEmit = tweeneval.emit
sequence.tweenRun = tweeneval.run
sequence.tweenParallel = tweeneval.parallel

-------------------------------------------------------------------------------
-- Authoring nodes
-------------------------------------------------------------------------------

function sequence.bind(name: string): sequence.EntityRef
    if type(name) ~= "string" or name == "" then
        error("sequence.bind requires a non-empty binding name", 2)
    end
    return {bindName = name, isBinding = true}
end

function sequence.call(action: string, ...: sequence.Argument): sequence.Node
    if type(action) ~= "string" or action == "" then
        error("sequence.call requires a non-empty action name", 2)
    end
    return {kind = "call", text = action, args = {...}} as sequence.Node
end

function sequence.wait(seconds: number): sequence.Node
    if type(seconds) ~= "number" or seconds < 0 then
        error("sequence.wait requires a non-negative duration", 2)
    end
    return {kind = "wait", number = seconds} as sequence.Node
end

function sequence.waitSteps(steps: integer): sequence.Node
    if type(steps) ~= "number" or steps < 0 or steps % 1 ~= 0 then
        error("sequence.waitSteps requires a non-negative whole number", 2)
    end
    return {kind = "waitSteps", number = steps} as sequence.Node
end

function sequence.waitSignal(name: string): sequence.Node
    if type(name) ~= "string" or name == "" then
        error("sequence.waitSignal requires a non-empty signal name", 2)
    end
    return {kind = "waitSignal", text = name} as sequence.Node
end

function sequence.waitQuery(
    name: string,
    condition: sequence.QueryCondition
): sequence.Node
    if type(name) ~= "string" or name == "" then
        error("sequence.waitQuery requires a non-empty query name", 2)
    end
    if condition ~= "any" and condition ~= "empty" then
        error("sequence.waitQuery condition must be 'any' or 'empty'", 2)
    end
    return {kind = "waitQuery", text = name, count = condition == "any" and 1 or 0}
        as sequence.Node
end

function sequence.emit(event: string, ...: sequence.Argument): sequence.Node
    if type(event) ~= "string" or event == "" then
        error("sequence.emit requires a non-empty event name", 2)
    end
    return {kind = "emit", text = event, args = {...}} as sequence.Node
end

function sequence.loop(count: integer, nodes: {sequence.Node}): sequence.Node
    if count ~= nil and (type(count) ~= "number" or count < 1 or count % 1 ~= 0) then
        error("sequence.loop count must be a positive whole number or nil", 2)
    end
    if type(nodes) ~= "table" or #nodes == 0 then
        error("sequence.loop requires a non-empty block", 2)
    end
    return {kind = "loop", count = count, nodes = nodes} as sequence.Node
end

function sequence.playTween(
    timeline: string,
    target: sequence.EntityRef,
    params?: {string: any}
): sequence.Node
    if type(timeline) ~= "string" or timeline == "" then
        error("sequence.playTween requires a non-empty timeline name", 2)
    end
    if not seqprogram.isEntityRef(target) then
        error("sequence.playTween requires a sequence.bind(name) target", 2)
    end
    return {kind = "playTween", text = timeline, args = {target, params}}
        as sequence.Node
end

function sequence.eval(evaluator: string, data?: any): sequence.Node
    if type(evaluator) ~= "string" or evaluator == "" then
        error("sequence.eval requires a non-empty evaluator name", 2)
    end
    return {kind = "eval", text = evaluator, args = data as {any}} as sequence.Node
end

function sequence.await(
    provider: string, target: sequence.EntityRef, key?: string
): sequence.Node
    if type(provider) ~= "string" or provider == "" then
        error("sequence.await requires a non-empty provider name", 2)
    end
    if not seqprogram.isEntityRef(target) then
        error("sequence.await requires a sequence.bind(name) target", 2)
    end
    return {kind = "await", text = provider, args = {target, key}} as sequence.Node
end

function sequence.registerAwaitable(name: string, provider: sequence.Awaitable)
    seqawaitables.register(name, provider)
end

function sequence.waitTween(): sequence.Node
    return {kind = "waitTween"} as sequence.Node
end

function sequence.fork(nodes: {sequence.Node}): sequence.Node
    if type(nodes) ~= "table" or #nodes == 0 then
        error("sequence.fork requires a non-empty block", 2)
    end
    return {kind = "fork", nodes = nodes} as sequence.Node
end

function sequence.join(): sequence.Node
    return {kind = "join"} as sequence.Node
end

function sequence.parallel(...: {sequence.Node}): sequence.Node
    local blocks: {{sequence.Node}} = {...}
    if #blocks == 0 then
        error("sequence.parallel requires at least one block", 2)
    end
    for i = 1, #blocks do
        local block = blocks[i]
        if type(block) ~= "table" or #block == 0 then
            error("sequence.parallel block " .. tostring(i) .. " is empty", 2)
        end
    end
    return {kind = "parallel", blocks = blocks} as sequence.Node
end

-------------------------------------------------------------------------------
-- Compiler
-------------------------------------------------------------------------------

function sequence.define(
    name: string,
    nodes: {sequence.Node},
    options?: sequence.DefineOptions
): sequence.Program
    if type(name) ~= "string" or name == "" then
        error("sequence.define requires a non-empty program name", 2)
    end
    if type(nodes) ~= "table" then
        error("sequence.define requires an array of nodes", 2)
    end

    local clock: seqtypes.ClockId = options and options.clock or "fixed"
    if clock ~= "fixed" and clock ~= "frame" and clock ~= "presentation" then
        error("sequence.define clock must be 'fixed', 'frame', or 'presentation'", 2)
    end
    local prog = seqprogram.compile(name, seqregistry.nextVersion(name), clock, nodes)
    seqregistry.publish(prog)
    return prog
end

function sequence.defineData(
    name: string,
    rows: {any},
    options?: sequence.DefineOptions
): sequence.Program, string
    local nodes, err = seqjson.decode(sequence as seqjson.Builders, rows)
    if not nodes then return nil, err end
    return sequence.define(name, nodes, options)
end

function sequence.dataOps(): {string}
    return seqjson.ops()
end

function sequence.timeline(
    name: string,
    spec: sequence.TimelineSpec,
    options?: sequence.TimelineOptions
): sequence.Program
    local clock: seqtypes.ClockId = options and options.clock or "presentation"
    if clock ~= "fixed" and clock ~= "presentation" then
        error("sequence.timeline clock must be 'fixed' or 'presentation'", 2)
    end
    local compiled <const> = tweeneval.compile(spec)
    -- The serialized form is what the const pool carries; the evaluator
    -- resolves it back once, when the first playback of it starts.
    return sequence.define(name, {
        sequence.eval(seqtweenrun.EVALUATOR, tweeneval.serializeTimeline(compiled)),
    }, {clock = clock})
end

function sequence.program(name: string, version?: integer): sequence.Program
    if version then return seqregistry.version(name, version) end
    return seqregistry.newest(name)
end

function sequence.programNames(): {string}
    return seqregistry.names()
end

-------------------------------------------------------------------------------
-- Per-world state: cursor arena, action registry, scheduler
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- Actions
-------------------------------------------------------------------------------

function sequence.registerAction(world: World, name: string, action: sequence.Action)
    if type(name) ~= "string" or name == "" then
        error("sequence.registerAction requires a non-empty action name", 2)
    end
    if type(action) ~= "function" then
        error("sequence.registerAction requires a function", 2)
    end
    seqcursors.stateFor(world).actions[name] = action
end

function sequence.registerEvaluator(name: string, evaluator: sequence.Evaluator)
    seqevaluators.register(name, evaluator)
end

function sequence.hasAction(world: World, name: string): boolean
    return seqcursors.stateFor(world).actions[name] ~= nil
end

function sequence.registerQuery(
    world: World,
    name: string,
    descriptor: ecs.Query.Descriptor
)
    if type(name) ~= "string" or name == "" then
        error("sequence.registerQuery requires a non-empty query name", 2)
    end
    if type(descriptor) ~= "table" then
        error("sequence.registerQuery requires a query descriptor", 2)
    end
    local state = seqcursors.stateFor(world)

    -- The callbacks only mark the name; the condition is tested once per
    -- step for every name that moved, not once per entity.
    local userAdded = descriptor.onEntitiesAdded
    local userRemoved = descriptor.onEntitiesRemoved
    local spec: ecs.Query.Descriptor = {}
    for key, value in pairs(descriptor as {string: any}) do
        (spec as {string: any})[key] = value
    end
    spec.onEntitiesAdded = function(
        archetype: ecs.Archetype,
        firstRow: integer,
        lastRow: integer,
        count: integer
    )
        state.dirtyQueries[name] = true
        if userAdded then userAdded(archetype, firstRow, lastRow, count) end
    end
    spec.onEntitiesRemoved = function(
        archetype: ecs.Archetype,
        firstRow: integer,
        lastRow: integer,
        count: integer
    )
        state.dirtyQueries[name] = true
        if userRemoved then userRemoved(archetype, firstRow, lastRow, count) end
    end

    state.queries[name] = world:query(spec)
    -- Anything already parked on the name re-tests against the new query.
    state.dirtyQueries[name] = true
end

function sequence.hasQuery(world: World, name: string): boolean
    return seqcursors.stateFor(world).queries[name] ~= nil
end

function sequence.signalOnEvent<T is ecs.Event>(world: World, name: string, event: T)
    if type(name) ~= "string" or name == "" then
        error("sequence.signalOnEvent requires a non-empty signal name", 2)
    end
    world:observe(0, event, function()
        sequence.signal(world, name)
    end)
end

-------------------------------------------------------------------------------
-- Execution
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- Playback API
-------------------------------------------------------------------------------

function sequence.signal(world: World, name: string): integer
    if type(name) ~= "string" or name == "" then
        error("sequence.signal requires a non-empty signal name", 2)
    end
    local state = seqcursors.stateFor(world)
    local blocked = state.channels[name]
    if not blocked then return 0 end
    local count = 0
    for _ in pairs(blocked) do count = count + 1 end
    -- Delivery is deferred to the next step so a signal raised from inside a
    -- running cursor cannot cascade within the same step.
    state.pendingSignals[#state.pendingSignals + 1] = name
    return count
end

function sequence.waitingOn(world: World, name: string): integer
    local blocked = seqcursors.stateFor(world).channels[name]
    if not blocked then return 0 end
    local count = 0
    for _ in pairs(blocked) do count = count + 1 end
    return count
end

function sequence.play(
    world: World,
    program: sequence.Program,
    options?: sequence.PlayOptions
): sequence.Handle
    if type(program) ~= "table" or (program as ProgramImpl).code == nil then
        error("sequence.play requires a program from sequence.define", 2)
    end
    local state = seqcursors.stateFor(world)
    local cursor = seqcursors.alloc(state)
    cursor.program = program as ProgramImpl
    cursor.clock = cursor.program.clock or "fixed"
    cursor.pc = 0
    cursor.state = "running"
    seqregistry.retain(cursor.program)

    if options then
        cursor.owner = options.owner or 0
        cursor.bindings = options.bindings
        cursor.params = options.params
        cursor.channel = options.channel
        if options.budget then cursor.budget = options.budget end
    end

    seqcursors.linkOwner(state, cursor)
    -- Taking a channel cancels whatever held it, reporting "replaced" to
    -- anything that was waiting on it.
    seqcursors.claimChannel(state, cursor)

    -- The first instruction runs on the next tick of its clock, never inside
    -- the play call.
    seqcursors.schedule(state, cursor, seqcursors.clockOf(state, cursor).step + 1)
    return seqcursors.packHandle(cursor.slot, cursor.generation)
end

function sequence.cancel(world: World, handle: sequence.Handle): boolean
    local state = seqcursors.stateFor(world)
    local cursor = seqcursors.resolve(state, handle)
    if not cursor or not cursor.alive then return false end
    seqcursors.retire(state, cursor, "cancelled")
    return true
end

function sequence.pause(
    world: World, handle: sequence.Handle, holder?: string
): boolean
    local state = seqcursors.stateFor(world)
    local cursor = seqcursors.resolve(state, handle)
    if not cursor or not cursor.alive then return false end
    return seqcursors.pauseTree(state, cursor, holder or DEFAULT_HOLDER)
end

function sequence.resume(
    world: World, handle: sequence.Handle, holder?: string
): boolean
    local state = seqcursors.stateFor(world)
    local cursor = seqcursors.resolve(state, handle)
    if not cursor or not cursor.alive then return false end
    return seqcursors.resumeTree(state, cursor, holder or DEFAULT_HOLDER)
end

function sequence.status(world: World, handle: sequence.Handle): sequence.Status
    local state = seqcursors.stateFor(world)
    local cursor = seqcursors.resolve(state, handle)
    if not cursor then return nil end
    local branches = 0
    local children = cursor.children
    if children then
        for _ in pairs(children) do branches = branches + 1 end
    end

    local status: sequence.Status = {
        state = cursor.state,
        program = cursor.program.name,
        version = cursor.program.version,
        pc = cursor.pc,
        wakeAt = cursor.alive and cursor.wakeAt or nil,
        waitingFor = cursor.alive and cursor.waitChannel or nil,
        waitingQuery = cursor.alive and cursor.waitQuery or nil,
        waitingTween = cursor.waitingTween and cursor.tweenPlayback or nil,
        waitingAwaitable = cursor.alive and cursor.awaitProvider or nil,
        waitingAwaitableEntity = cursor.alive and cursor.awaitEntity or nil,
        tweenOutcome = cursor.tweenOutcome,
        waitingCondition = cursor.alive and cursor.waitQuery
            and (cursor.waitCondition == 1 and "any" or "empty") or nil,
        branches = branches,
        joining = cursor.joining or false,
        fault = cursor.fault,
        faultMessage = cursor.faultMessage,
    }
    return status
end

function sequence.cancelOwnedBy(
    world: World, owner: integer, reason?: sequence.TweenOutcome
): integer
    local state = seqcursors.stateFor(world)
    local owned = state.ownerIndex[owner]
    if not owned then return 0 end
    local slots: {integer} = {}
    for slot in pairs(owned) do slots[#slots + 1] = slot end
    table.sort(slots)
    local cancelled = 0
    for i = 1, #slots do
        local cursor = state.cursors[slots[i]]
        if cursor and cursor.alive then
            seqcursors.retire(state, cursor, "cancelled", reason)
            cancelled = cancelled + 1
        end
    end
    return cancelled
end

function sequence.activeCount(world: World): integer
    local state = seqcursors.stateFor(world)
    local count = 0
    for _, cursor in pairs(state.cursors) do
        if cursor.alive then count = count + 1 end
    end
    return count
end

function sequence.playbacks(world: World): {sequence.Handle}
    local state = seqcursors.stateFor(world)
    local slots: {integer} = {}
    for slot, cursor in pairs(state.cursors) do
        if cursor.alive then slots[#slots + 1] = slot end
    end
    table.sort(slots)
    local handles: {sequence.Handle} = {}
    for i = 1, #slots do
        local cursor = state.cursors[slots[i]]
        handles[i] = seqcursors.packHandle(cursor.slot, cursor.generation)
    end
    return handles
end

function sequence.setInstructionBudget(world: World, instructions: integer)
    if type(instructions) ~= "number" or instructions < 1 then
        error("sequence.setInstructionBudget requires a positive count", 2)
    end
    seqcursors.stateFor(world).budget = instructions
end

function sequence.currentStep(world: World, clock?: sequence.ClockId): integer
    return seqcursors.stateFor(world).clocks[clock or "fixed"].step
end

function sequence.upcoming(
    world: World,
    handle: sequence.Handle,
    withinTicks?: integer
): {sequence.Step}
    local state = seqcursors.stateFor(world)
    local cursor = seqcursors.resolve(state, handle)
    if not cursor or not cursor.alive then return {} end
    -- A scheduled cursor is already some ticks out; one parked on a signal,
    -- a query, a join, or a tween has no predictable start at all.
    if not cursor.wakeAt then return {} end
    local offset <const> = cursor.wakeAt - seqcursors.clockOf(state, cursor).step
    return seqprogram.ahead(cursor.program, cursor.pc,
        offset > 0 and offset or 0, withinTicks)
end

-------------------------------------------------------------------------------
-- Disassembler
-------------------------------------------------------------------------------

function sequence.disassemble(program: sequence.Program, pc?: integer): string
    local prog = program as ProgramImpl
    if type(prog) ~= "table" or prog.code == nil then
        error("sequence.disassemble requires a program from sequence.define", 2)
    end
    return seqprogram.disassemble(prog, pc)
end

-------------------------------------------------------------------------------
-- Plugin
-------------------------------------------------------------------------------

-- Worlds that script input install the sequencer themselves rather than
-- relying on the application having done it, so installing twice has to be
-- safe.
local installed: {World: boolean} =
    setmetatable({}, {__mode = "k"} as metatable<{World: boolean}>)

function sequence.plugin(world: World)
    if installed[world] then return end
    installed[world] = true
    local state = seqcursors.stateFor(world)

    -- Evaluators are global, so this registers once however many worlds
    -- install the sequencer.
    seqtweenrun.install()

    world:addSystem({
        name = "sequence.Advance",
        phase = ecs.phases.FixedFirst,
        run = function(dt: number)
            seqvm.tick(world, state, "fixed", dt)
        end,
    })

    -- phases.First is the earliest gameplay phase, ahead of the fixed group,
    -- so a frame-clock program has run before anything reads what it did. That
    -- is what scripted input needs and what the fixed clock cannot give it: a
    -- frame runs the fixed phases zero times or several, and a program driving
    -- input has to advance exactly once per frame either way.
    world:addSystem({
        name = "sequence.AdvanceFrame",
        phase = ecs.phases.First,
        run = function(dt: number)
            seqvm.tick(world, state, "frame", dt)
        end,
    })

    -- Presentation runs in Update with the frame's real dt: what it carries
    -- has to move at the display's rate, not the simulation's.
    world:addSystem({
        name = "sequence.AdvancePresentation",
        phase = ecs.phases.Update,
        run = function(dt: number)
            seqvm.tick(world, state, "presentation", dt)
        end,
    })

    world:addSnapshotHandler({
        name = "tecs.sequence",
        save = function(w: World): any
            return seqsnapshot.save(w)
        end,
        load = function(w: World, value: any)
            seqsnapshot.load(w, value)
        end,
    })

    -- Owner lifetime: a despawned owner cancels the playbacks it governs.
    world:observe(0, ecs.builtins.OnDespawn, function(event: ecs.builtins.OnDespawn)
        if state.ownerIndex[event.entity] then
            sequence.cancelOwnedBy(world, event.entity, "targetLost")
        end
    end)

end

return sequence
