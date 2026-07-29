--[=[
Snapshot-safe programs, waits, ownership, actions, and tween timelines.

Sequences store control flow as data. Snapshots, rewind, and hot reload can
therefore preserve a playback's program, instruction pointer, waits, bindings,
and parameters.

## Programs and actions

Register an action on the world, name it from a program, and bind each
playback to the entities it acts on:

```teal
local sequence <const> = tecs.sequence

sequence.registerAction(
    world,
    "game.lockControls",
    function(_world, _ctx)
        controlsLocked = true
    end
)

local intro <const> = sequence.define("game.bossIntro", {
    sequence.call("game.lockControls"),
    sequence.wait(1.5),
    sequence.emit("boss.ready"),
})

local playback <const> = sequence.play(world, intro, {
    owner = encounter,
    bindings = {boss = bossEntity},
})
```

Program names form a snapshot compatibility surface. Use stable, qualified
names for game and plugin programs. Redefining a name creates a new version.
Running playbacks keep their original instructions, while later calls to
`play` use the new program. Action bodies resolve by name when they run, so a
reload can replace action code without moving a live program counter.

Actions run synchronously and cannot yield. An action that raises faults its
playback after preserving mutations it already completed. Keep wall-clock,
file, and network access outside deterministic actions.

## Clocks and waits

`"fixed"` advances once per fixed step and serves deterministic gameplay.
`"frame"` advances once per gameplay frame. `"presentation"` advances with
display time and serves values simulation never reads.

Durations use seconds. Step and tick values count whole advances of the
program's clock. Every positive duration waits at least one tick.
`waitSteps(0)` yields until the next tick and gives a loop a fresh instruction
budget.

## Ownership

`owner` ties a playback to an entity. Despawning that entity cancels the
playback. A named `channel` gives one owner a replaceable slot, so starting a
second playback on the same channel cancels the first.

Pause uses named holders. The playback resumes only after every holder releases
it. Branches inherit owner, bindings, parameters, budget, and pause state. A
branch cannot outlive its parent.

Each playback receives a bounded instruction budget per tick. Exceeding it
faults with `budgetExceeded` instead of hanging the frame.

## Timelines

Timelines compile tweens into the same runtime and retain the same ownership,
clock, channel, pause, and snapshot rules. Targets interpolate component
fields. Parallel blocks share a start time, while sequential blocks start
after the previous block ends.
]=]
-- Implementation details:
-- A suspended Lua stack does not expose serializable control flow. The
-- sequencer compiles nodes into immutable instructions and stores each
-- playback cursor, wait, and branch as ordinary data.

local ecs <const> = require("tecs.ecs")
local type types = require("tecs.types")
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

local type World = types.World

-- Who holds a pause when the caller does not say.
local DEFAULT_HOLDER <const> = "user"

-- The runtime records live in the leaf types module; bind them so the body
-- below reads the same as when they were declared here.
local type ProgramImpl = seqtypes.ProgramImpl

local record sequence
    ---------------------------------------------------------------------------
    -- Types
    ---------------------------------------------------------------------------

    --- Explains why a cursor stopped running.
    type FaultReason = seqtypes.FaultReason

    --- Describes the lifecycle state of one playback.
    type PlaybackState = seqtypes.PlaybackState

    --- Describes the condition awaited by a `waitQuery` step.
    type QueryCondition = seqtypes.QueryCondition

    --- Reports how the tween awaited by `waitTween` ended.
    type TweenOutcome = seqtypes.TweenOutcome

    --- Represents a compiled, immutable program produced by `define` and
    --- shared by
    --- every playback of it. See `internal/types` for the full contract.
    type Program = seqtypes.Program

    --- Represents one authored step produced by the node constructors below.
    --- Treat the
    --- returned value as opaque and do not reuse a node across programs.
    type Node = seqtypes.Node

    --- References an entity supplied at `play` time and resolves it when the
    --- instruction that uses it runs.
    type EntityRef = seqtypes.EntityRef

    --- Identifies one playback through a generation-checked reference that
    --- remains meaningful across a
    --- snapshot load.
    type Handle = seqtypes.Handle

    --- Represents constants passed from `call` to its action.
    type Argument = seqtypes.Argument

    --- Configures `play`.
    type PlayOptions = seqtypes.PlayOptions

    ---------------------------------------------------------------------------
    -- Timelines
    ---------------------------------------------------------------------------

    --- Names a built-in easing curve and describes the shape of any curve.
    type EasingName = tweeneval.EasingName

    --- Maps normalized input progress to eased output progress.
    ---
    --- Easing shapes the value, not the schedule: the argument is how far
    --- through its own window the interpolation is, clamped to [0, 1], and the
    --- result is the fraction of the way from start to destination to place
    --- the target at. A curve that leaves [0, 1] overshoots the destination
    --- rather than the duration, which is what `backOut` and `elasticOut` are
    --- for. Compilation fixes the window, so no curve can make a
    --- timeline longer or shorter or move what follows it.
    type EasingFunction = tweeneval.EasingFunction

    --- Names a built-in component-field target.
    type TargetName = tweeneval.TargetName

    --- Describes the component and one to four numeric fields written by a
    --- timeline operation.
    --- numeric fields of it to interpolate.
    ---
    --- Opaque, and built only through `sequence.target`: a built-in such as
    --- `sequence.target.translateXY`, or `sequence.target.field(C, "hp")` for a
    --- component of your own. Every operation that takes one also accepts a
    --- [`TargetName`](tealdoc:tecs.sequence.TargetName) naming the same built-in,
    --- which is the form that survives `defineData`. Safe to share between
    --- timelines: a target holds no
    --- per-playback state.
    type Target = tweeneval.Target

    --- Provides a live component-field tracking source.
    type TrackSource = tweeneval.TrackSource

    --- Represents one authored timeline operation.
    type TimelineNode = tweeneval.TimelineNode

    --- Lists timeline operations in execution order.
    ---
    --- Entries run one after the next, each starting where the one before it
    --- ended, except that a `tweenParallel` runs its arguments from a shared
    --- start. A nested list is read as a block and behaves the same as one.
    ---
    --- `timeline` and `tweenRun` compile the resolved form into the same table,
    --- consuming the spec. Pass a fresh spec to each timeline.
    type TimelineSpec = tweeneval.TimelineSpec

    --- Selects how a timeline repeats.
    type PlaybackMode = tweeneval.PlaybackMode

    --- Configures how `tweenRun` plays its nested timeline.
    ---
    --- Omitting it runs the nested timeline once. A nested `"loop"` or
    --- `"pingPong"` must set `count`, because a parent has to know how long
    --- its own window is; only the root timeline of a `sequence.timeline`,
    --- through `params`, may repeat without one.
    type RunOptions = tweeneval.RunOptions

    --- Read-only. Exposes built-in easing curves such as
    --- `sequence.easing.quadOut`.
    easing: tweeneval.Easings

    --- Read-only. Exposes built-in targets and constructors for new ones:
    --- `sequence.target.translateX`, `sequence.target.field(C, "hp")`.
    target: tweeneval.Targets

    --- Read-only. Exposes sources from which `tweenTrack` reads changing
    --- values:
    --- `sequence.source.own(Transform, "x")`.
    source: tweeneval.Sources

    --- Read-only. Exposes the component that selects a dynamic tracking-source
    --- entity.
    TrackingTarget: tweeneval.TrackingTarget

    --- Interpolates to an absolute destination.
    ---
    --- The operation reads starting values from the entity on its first tick,
    --- not during compilation, so the same
    --- timeline played on two entities starts from wherever each of them is.
    ---
    --- @param duration Supplies a strictly positive number of seconds. The
    ---     compiler rejects zero. Use `tweenWait` for a gap that moves nothing.
    --- @param curve A name from `sequence.easing`, or one of those functions
    ---     itself. The compiler rejects a custom curve:
    ---     a compiled slot carries the curve's name so it can travel in a
    ---     const pool, and a function it cannot name has none.
    --- @param target Which component fields move, and in which order `t1`
    ---     through `t4` line up with them.
    --- @param t1 Destination for the target's first field, in that field's own
    ---     units: pixels for a translate, radians for a rotation, 0 to 1 for a
    ---     color channel. A shortest-path rotation target still takes an
    ---     absolute angle and picks the short way round to it.
    --- @param t2 Destination for the second field, for a target that has one.
    --- @param t3 Destination for the third field, for a four-field target.
    --- @param t4 Destination for the fourth field, for a four-field target.
    ---     The compiler ignores arguments past the target's field count and
    ---     treats each omitted target field as zero.
    --- @return Returns a node for a
    ---     [`TimelineSpec`](tealdoc:tecs.sequence.TimelineSpec). Its compiling
    ---     timeline consumes it.
    tweenTo: function(
        duration: number,
        curve: EasingName | EasingFunction,
        target: TargetName | Target,
        t1: number,
        t2?: number,
        t3?: number,
        t4?: number
    ): TimelineNode

    --- Interpolates by a relative delta from the starting value.
    ---
    --- Identical to `tweenTo` except that `t1` through `t4` are the amount to
    --- move by rather than where to end up, so the destination depends on the
    --- entity's value when the operation evaluates its first tick.
    ---
    --- @param duration Seconds, and strictly positive.
    --- @param curve As `tweenTo`'s, and built in for the same reason.
    --- @param target Which component fields move, and in which order `t1`
    ---     through `t4` line up with them.
    --- @param t1 Change applied to the target's first field, in that field's
    ---     own units, and signed: negative moves the other way.
    --- @param t2 Change applied to the second field.
    --- @param t3 Change applied to the third field.
    --- @param t4 Change applied to the fourth field. An argument past the
    ---     The compiler ignores arguments past the target's field count and
    ---     treats an omitted argument as zero.
    --- @return Returns a node for a
    ---     [`TimelineSpec`](tealdoc:tecs.sequence.TimelineSpec). Its compiling
    ---     timeline consumes it.
    tweenAdjust: function(
        duration: number,
        curve: EasingName | EasingFunction,
        target: TargetName | Target,
        t1: number,
        t2?: number,
        t3?: number,
        t4?: number
    ): TimelineNode

    --- Interpolates toward a destination that keeps moving.
    ---
    --- The first tick fixes the start, as with `tweenTo`, but each later tick
    --- reads the destination again from `from` while the operation remains inside
    --- its window, so the entity chases a value that is still changing. Once
    --- the window ends, the operation holds its last destination.
    ---
    --- @param duration Seconds, and strictly positive.
    --- @param curve As `tweenTo`'s. It shapes how far toward the current
    ---     destination the value sits, and that destination keeps moving
    ---     underneath it.
    --- @param target Which component fields move, and which fields of `from`
    ---     line up with them: the source is read into the same one to four
    ---     numbers the target writes.
    --- @param from Where the destination is read each tick. A source whose
    ---     entity or component is missing reads as zero rather than faulting,
    ---     so an entity chasing something that despawned drifts to the origin.
    ---     A source named by world key is the exception and requires the key
    ---     to be set.
    --- @return Returns a node for a
    ---     [`TimelineSpec`](tealdoc:tecs.sequence.TimelineSpec). Its compiling
    ---     timeline consumes it.
    tweenTrack: function(
        duration: number, curve: EasingName | EasingFunction, target: TargetName | Target, from: TrackSource
    ): TimelineNode

    --- Advances the timeline cursor without changing anything.
    ---
    --- @param duration Supplies seconds. Zero performs no work.
    --- @return Returns a node for a
    ---     [`TimelineSpec`](tealdoc:tecs.sequence.TimelineSpec).
    tweenWait: function(duration: number): TimelineNode

    --- Emits a named `sequence.Event` when the cursor reaches this point.
    ---
    --- Occupies no time, so what follows it starts at the same instant. The
    --- event carries the entity the timeline is animating as its one argument,
    --- and the timeline's own playback as its handle. It fires as the cursor
    --- passes the point going forward, so a `pingPong`'s return leg does not
    --- fire it a second time.
    ---
    --- @param name Carried on the event as its name; the sequencer attaches no
    ---     meaning to it.
    --- @return Returns a node for a
    ---     [`TimelineSpec`](tealdoc:tecs.sequence.TimelineSpec).
    tweenEmit: function(name: string): TimelineNode

    --- Runs a nested timeline from its own spec.
    ---
    --- The nested timeline occupies a window of the parent equal to its own
    --- length times its pass count, so a repeating nested run needs a finite
    --- `count`. Its own operations keep their per-playback state separately
    --- from the parent's.
    ---
    --- @param spec Compiled in place if it has not been already, so the table
    ---     given here belongs to this node afterwards.
    --- @param options Omit to run the nested timeline once. `"loop"` and
    ---     `"pingPong"` need a `count` here, and compiling raises without one.
    --- @return Returns a node for a
    ---     [`TimelineSpec`](tealdoc:tecs.sequence.TimelineSpec).
    tweenRun: function(spec: TimelineSpec, options?: RunOptions): TimelineNode

    --- Runs timeline nodes concurrently and ends with the longest.
    ---
    --- Every argument starts at the point the `tweenParallel` sits at, and
    --- what follows starts after the last of them ends. Two arguments writing
    --- the same component field is not an error and the later one in argument
    --- order wins each tick.
    ---
    --- @param ... One node per concurrent operation. A list of nodes counts as
    ---     one argument and runs in sequence within it, which describes a
    ---     branch longer than one operation.
    --- @return Returns a node for a
    ---     [`TimelineSpec`](tealdoc:tecs.sequence.TimelineSpec).
    tweenParallel: function(...: TimelineNode): TimelineNode

    --- Selects the clock against which a program runs.
    type ClockId = seqtypes.ClockId

    --- Configures `define`.
    record DefineOptions
        --- Caller-writable. Selects the clock counted by program waits and
        --- defaults to `"fixed"`.
        clock: ClockId
    end

    --- Provides the context received by a registered action. The context and
    --- its `args` belong to the sequencer, which reuses them for the next call.
    type ActionContext = seqtypes.ActionContext

    --- Defines a registered effect that runs synchronously and cannot yield.
    type Action = seqtypes.Action

    --- Reports a playback's current state.
    type Status = seqtypes.Status

    --- Read-only. Exposes the event emitted by an `emit` step at address zero.
    Event: seqtypes.Event

    ---------------------------------------------------------------------------
    -- Authoring
    ---------------------------------------------------------------------------

    --- Compiles a program written as plain data instead of node calls.
    ---
    --- The same authoring surface as a list of steps, for callers that
    --- cannot invoke Lua: a tool over MCP, a file on disk, a hand-written
    --- table. Returns nil plus the path to the first bad entry.
    ---
    ---     sequence.defineData("game.intro", {
    ---         {op = "call", action = "game.lockControls"},
    ---         {op = "wait", seconds = 1.5},
    ---     })
    ---
    --- @param name As `define`'s, and sharing its namespace and its versioning.
    --- @param rows One table per step, keyed by `op` and the fields that step
    ---     takes. `dataOps` lists the step names. This function rejects an empty
    ---     list, unlike `define`, because it has nothing to run.
    --- @param options As `define`'s.
    --- @return The compiled program, or nil when a row is bad.
    --- @return nil on success; on failure the path to the first bad entry, as
    ---     `program[2].loop[1]`, and what it was missing. That is why the two
    ---     are never both set. A row whose shape is right and whose value is
    ---     not, a negative wait among them, raises instead: the path covers
    ---     what this decoder checks, not what the node constructors do.
    defineData: function(name: string, rows: {any}, options?: DefineOptions): Program, string

    --- Returns the step names accepted by `defineData`, sorted.
    ---
    --- @return A fresh table each call, which the caller owns. It is narrower
    ---     than the node constructors: `await` and `eval` have no data form and
    ---     are not among them.
    dataOps: function(): {string}

    --- Compiles a program under a stable symbolic name.
    ---
    --- `options.clock` picks what the program's waits count. `"fixed"`, the
    --- default, counts fixed steps and is what gameplay logic wants.
    --- `"frame"` counts gameplay frames, one tick per frame however many fixed
    --- steps that frame runs, which is what scripted input needs.
    --- `"presentation"` also ticks once per gameplay frame
    --- carrying the frame's real elapsed time.
    ---
    --- @param name Defining over a name already in use publishes a new
    ---     version rather than replacing the old one: playbacks already
    ---     running keep the version they started on, and only later `play`
    ---     calls see the new one.
    --- @param nodes Accepts an empty list, which compiles to a program that
    ---     completes on its first tick.
    --- @param options Omitted, the program counts fixed steps. A `clock` that
    ---     is none of the three names raises here.
    --- @return The compiled program, immutable and shared by every playback
    ---     of it, so the same value plays on any number of worlds.
    define: function(name: string, nodes: {Node}, options?: DefineOptions): Program

    --- Configures `timeline`.
    record TimelineOptions
        --- Caller-writable. Selects the clock used to evaluate the timeline.
        --- It defaults to `"presentation"`,
        --- which moves at the display's rate. `"fixed"` makes it
        --- deterministic from a snapshot alone, at the cost of stepping at
        --- the simulation's rate: the renderer interpolates only
        --- [`Transform`](/modules/ecs/#tecs.ecs.Transform) between
        --- fixed steps, so a fixed-clock tween of anything else visibly
        --- steps. If the simulation can observe the value, put it on
        --- `"fixed"`.
        clock: ClockId
    end

    --- Compiles a tween timeline into a program under a stable name.
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
    ---
    --- @param name Shared with `define`'s namespace, and versioned the same
    ---     way: compiling over a live name publishes a new version and leaves
    ---     playbacks of the old one running it.
    --- @param spec The compiler consumes this table in place. Do not compile it
    ---     again.
    --- @param options Omitted, the timeline runs on the presentation clock.
    ---     `"fixed"` and `"presentation"` are the only two accepted; `"frame"`
    ---     raises, though `define` takes it.
    --- @return The compiled program, also reachable by name through `program`.
    ---     Play it on an entity: a playback with no `owner` has nothing to
    ---     write to and completes on its first tick without animating
    ---     anything. The `params` above are read when that playback builds its
    ---     state, so a `speed` of zero or less, a negative `delay`, or a
    ---     repeat of a zero-length timeline faults the playback with
    ---     `actionError` rather than raising from `play`.
    timeline: function(name: string, spec: TimelineSpec, options?: TimelineOptions): Program

    --- Returns the newest version of a defined program or a requested version.
    --- Every version a playback still runs stays reachable.
    ---
    --- @param name The caller supplies a name previously passed to `define` or
    ---     `timeline`.
    --- @param version Versions start at 1 and rise by one per `define` of the
    ---     same name. Omit it for the newest.
    --- @return nil when the name was never defined, or when that version was
    ---     after a newer definition replaces it and its last playback ends.
    ---     The newest
    ---     version of a name is never dropped.
    program: function(name: string, version?: integer): Program

    --- Returns the names of every defined program, sorted.
    ---
    --- @return A fresh table each call, which the caller owns. Registration is
    ---     global, so this spans every world in the process.
    programNames: function(): {string}

    --- References an entity supplied through `PlayOptions.bindings`.
    ---
    --- Resolved when the instruction using it runs, not at `play`, so a
    --- binding may name an entity that does not exist yet.
    ---
    --- @param name Must be non-empty, and an empty one raises here rather than
    ---     at `define`. The runtime matches it against `PlayOptions.bindings`.
    ---     A missing binding resolves to nothing instead of faulting.
    --- @return A reference to put in a `call` or `emit` argument list, or to
    ---     hand to `playTween` or `await`. The program interns it in the const
    ---     pool, and each playback resolves it against its own bindings.
    bind: function(name: string): EntityRef

    --- Runs a registered action.
    ---
    --- @param action Resolved per world when the instruction runs, not at
    ---     `define`, so a program may name an action registered later. A name
    ---     still unregistered when the step runs faults the playback.
    --- @param ... Compiled into the program's const pool, so they are the same
    ---     values for every playback of it. Put anything that differs between
    ---     two playbacks in `PlayOptions.params` instead.
    --- @return A node for `define`, and not to be put in a second program.
    call: function(action: string, ...: Argument): Node

    --- Waits for a duration in seconds.
    ---
    --- Converted to whole ticks when the instruction runs, rounded to nearest,
    --- with any non-zero duration waiting at least one tick. A program on the
    --- fixed clock divides the duration by the world's fixed timestep; the
    --- frame and presentation clocks both tick once per frame, so both divide
    --- by the loop's nominal frame dt. Programs therefore stay independent of
    --- any one world's timing, and the same duration is the same wall-clock
    --- wait on all three. Use `waitSteps` when the exact tick count matters
    --- more than the wall-clock duration.
    ---
    --- @param seconds Supplies a non-negative duration. This function rejects a
    ---     negative value. Zero still costs a tick: the cursor resumes
    ---     on the program's next tick rather than carrying on within this one,
    ---     so no duration makes `wait` free.
    --- @return A node for `define`, and not to be put in a second program.
    wait: function(seconds: number): Node

    --- Blocks until `signal` raises the named signal.
    ---
    --- The next fixed step delivers signals after `signal` runs, so a
    --- signal raised by one sequence never runs another within the same step.
    --- That bounds a chain of signals to one link per step and keeps delivery
    --- order independent of which cursor happened to run first. Delivery runs
    --- on the fixed clock whatever clock the program is on, so a frame or
    --- presentation program wakes at its own clock's next tick after the fixed
    --- step that delivered it.
    ---
    --- @param name Matched by value against `signal`'s, and registered
    ---     nowhere: any string names a channel. A name nothing raises parks
    ---     the playback until something cancels it, because a signal raised
    ---     before the wait is not remembered.
    --- @return A node for `define`, and not to be put in a second program.
    waitSignal: function(name: string): Node

    --- Blocks until a registered query matches or stops matching.
    ---
    --- Unlike a signal, which is an edge, this is a condition on the world:
    --- a wait whose condition already holds resumes rather than waiting for
    --- a transition that has already happened.
    ---
    --- The runtime evaluates the condition at the start of the next fixed step, never
    --- at the instruction itself, so it never reads a world that a spawn or
    --- the world has not committed a current-step despawn yet. A query
    --- wait therefore costs at least one step.
    ---
    --- @param name Resolved per world when the instruction runs, not at
    ---     `define`, so a program may name a query registered later. A name
    ---     still unregistered when the step runs faults the playback with
    ---     `unregisteredQuery`.
    --- @param condition Rejected here, not at compile time, when it is neither
    ---     `"any"` nor `"empty"`.
    --- @return A node for `define`, and not to be put in a second program.
    waitQuery: function(name: string, condition: QueryCondition): Node

    --- Waits for a whole number of ticks of the program's clock.
    ---
    --- `waitSteps(0)` yields: the cursor resumes on its program's next tick
    --- rather than continuing within the current one.
    ---
    --- @param steps Ticks of the program's own clock, so a program defined
    ---     against `"frame"` or `"presentation"` counts those and not fixed
    ---     steps. This function requires a non-negative whole number.
    --- @return A node for `define`, and not to be put in a second program.
    waitSteps: function(steps: integer): Node

    --- Emits an ECS event at address zero.
    ---
    --- Occupies no tick: the step after it runs in the same one.
    ---
    --- @param event Carried as the `sequence.Event`'s name. Observers watch
    ---     `sequence.Event` itself and filter on this, rather than each name
    ---     being an event type of its own.
    --- @param ... Const-pool values, as `call`'s are, delivered on the event's
    ---     `args` with any `bind` reference already resolved to an entity id.
    ---     Each emit copies the list and sends it with the event, so an
    ---     observer may keep it, unlike the one an action receives.
    --- @return A node for `define`, and not to be put in a second program.
    emit: function(event: string, ...: Argument): Node

    --- Repeats a block.
    ---
    --- @param count Iterations, or nil to repeat until canceled. A positive
    ---     whole number. This function rejects zero and fractions.
    --- @param nodes The block, run in order and started again from its first
    ---     node. Must be non-empty. A block with no wait in it spends the
    ---     playback's per-step instruction budget within one tick and faults
    ---     it with `budgetExceeded`, which is what that budget is for.
    --- @return A node for `define`, and not to be put in a second program.
    loop: function(count: integer, nodes: {Node}): Node

    --- Starts a branch that runs alongside the rest of the program.
    ---
    --- The branch is a playback of its own running the same program at a
    --- different instruction, and it inherits the owner, bindings, params and
    --- instruction budget of the playback that forked it. It starts once
    --- that playback next waits, joins, or ends, within the same tick.
    ---
    --- A branch never outlives the playback that forked it: finishing or
    --- canceling that playback cancels the branches it has not joined. A
    --- branch that faults takes its parent with it, faulted `branchFaulted`,
    --- rather than leaving a `join` one branch short forever.
    ---
    --- @param nodes The branch body, run in order. Must be non-empty. It reads
    ---     and writes the forking playback's own bindings table rather than a
    ---     copy, so both see any name an action binds.
    --- @return A node for `define`, and not to be put in a second program.
    fork: function(nodes: {Node}): Node

    --- Waits for every branch that has not yet joined.
    ---
    --- Falls straight through when there are none. When the last branch
    --- finishes, the waiting playback resumes within that same tick.
    ---
    --- @return A node for `define`, and not to be put in a second program.
    join: function(): Node

    --- Plays a registered tween preset on a bound entity.
    ---
    --- Needs the sequencer, which `tecs.newApplication` installs. A binding
    --- that is missing or dead is not a fault: nothing plays, and a following
    --- `waitTween` resumes at once reporting `targetLost`.
    ---
    --- The step itself costs no tick. It starts a separate playback owned by
    --- the bound entity, running on the named program's clock and using this
    --- playback's instruction budget.
    ---
    --- @param timeline Resolved when the instruction runs, and always to the
    ---     newest version of the name; any program defined under it will do,
    ---     though `timeline` is what normally publishes one. A name that is
    ---     not defined faults the playback with `unregisteredTween`.
    --- @param target A `bind` reference and nothing else: an entity id raises
    ---     here, for the same reason `define` rejects one as a constant.
    --- @param params The started playback's `params`, so `mode`, `count`,
    ---     `speed` and `delay` shape it as they do for `play`. A `channel` in
    ---     it names the slot the playback takes on that entity, canceling
    ---     whatever held the slot and reporting `replaced` to anything waiting
    ---     on it.
    --- @return A node for `define`, and not to be put in a second program.
    playTween: function(timeline: string, target: EntityRef, params?: {string: any}): Node

    --- Evaluates a registered evaluator every tick until it finishes.
    ---
    --- Unlike every other step, this one does not hand the tick back: the
    --- playback joins its clock's active set, and the runtime steps it each
    --- tick. Values that move every frame need this behavior.
    ---
    --- Compilation stores `data` beside the evaluator's name in the program,
    --- so it travels with a snapshot and must remain plain data for the same
    --- reason a `call` argument does. What the evaluator makes of it is its
    --- own business.
    ---
    --- @param evaluator Resolved globally when the instruction runs, so a
    ---     program may name an evaluator registered later. A name still
    ---     unregistered when the step runs faults the playback with
    ---     `unregisteredEvaluator`, and an evaluator that raises while
    ---     resolving the data or building its state faults it with
    ---     `actionError`.
    --- @param data Passed through the evaluator's `resolve` once per program
    ---     constant and the answer shared by every playback of it, so an
    ---     evaluator must not write per-playback state into what it gets back.
    ---     Omit it for an evaluator that needs none.
    --- @return A node for `define`, and not to be put in a second program.
    eval: function(evaluator: string, data?: any): Node

    --- Waits for work outside the sequencer to finish.
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
    ---
    --- @param provider Resolved globally when the instruction runs, and
    ---     checked before the binding: a name no build registered faults the
    ---     playback with `unregisteredAwaitable`. The runtime asks the provider
    ---     again at each fixed step boundary while the playback waits. An error
    ---     faults the playback with `actionError`.
    --- @param target A `bind` reference and nothing else, as `playTween`'s is.
    ---     An entity that dies while the playback waits releases it
    ---     rather than stranding it for the life of the world.
    --- @param key Handed to the provider unread, for a provider that answers
    ---     about more than one thing per entity. Nil when omitted, which is
    ---     what a provider with one answer per entity sees.
    --- @return A node for `define`, and not to be put in a second program.
    await: function(provider: string, target: EntityRef, key?: string): Node

    --- Defines the response required from an awaitable provider.
    type Awaitable = seqawaitables.Provider

    --- Registers a provider that an `await` step can name. Registration remains
    --- global, like an
    --- evaluator, because a provider is code.
    ---
    --- @param name Registering a name twice replaces the provider, which is
    ---     what a hot reload wants: a playback already parked on the name asks
    ---     the new one at the next step. An empty name raises.
    --- @param provider Must carry `isPending`, or this raises. `setPaused` is
    ---     optional. Without it, the provider leaves its work running when a
    ---     pause stops the waiting playback.
    registerAwaitable: function(name: string, provider: Awaitable)

    --- Waits for the tween started by the most recent `playTween`.
    ---
    --- Resumes when that specific playback completes, gets canceled, loses its
    --- channel, or loses its entity, so it never waits forever. `status`
    --- reports the outcome as `tweenOutcome`.
    ---
    --- A `waitTween` that no `playTween` in this playback preceded falls
    --- straight through without costing a tick.
    ---
    --- @return A node for `define`, and not to be put in a second program.
    waitTween: function(): Node

    --- Forks several blocks and waits for all of them.
    ---
    --- Sugar for a `fork` per block followed by one `join`. Blocks start in
    --- argument order.
    ---
    --- @param ... Supplies at least one non-empty node list, one per branch.
    ---     Each shares the playback's bindings table, as a `fork` does.
    --- @return A node for `define`, and not to be put in a second program.
    parallel: function(...: {Node}): Node

    ---------------------------------------------------------------------------
    -- Actions
    ---------------------------------------------------------------------------

    --- Registers an evaluator that an `eval` step can name.
    ---
    --- Registration is global, like a program: an evaluator is code, and two
    --- worlds evaluating the same name run the same thing.
    ---
    --- @param name Registering a name twice replaces it. An empty name raises.
    --- @param evaluator Must carry `step`, or this raises. The rest are
    ---     optional, and without `save` and `load` a playback evaluating this
    ---     name comes back from a snapshot at the start of its state rather
    ---     than where it was.
    registerEvaluator: function(name: string, evaluator: Evaluator)

    --- Defines the evaluator run by an `eval` step every tick.
    type Evaluator = seqtypes.Evaluator

    --- Registers an action that a `call` node can name.
    ---
    --- Actions must obey the deterministic-action contract to keep replay and
    --- rewind meaningful: no wall-clock reads, no file or network access, and
    --- randomness only from a generator whose state travels with the snapshot.
    ---
    --- @param world The world owns the action registry.
    --- @param name Per world, unlike an evaluator or an awaitable. Registering
    ---     it twice replaces the action, and a playback resolves the name at
    ---     each `call`, so one already running picks the new one up. An empty
    ---     name raises.
    --- @param action Must be a function, or this raises. Raising when it runs
    ---     faults the playback with `actionError`, and whatever it already
    ---     wrote to the world stays written: the sequencer rolls nothing back.
    registerAction: function(world: World, name: string, action: Action)

    --- Returns whether this world has registered an action name.
    ---
    --- @param world The world owns the action registry.
    --- @param name The caller supplies the action name to find.
    --- @return false for a name this world never registered, including one
    ---     another world has: actions are per world.
    hasAction: function(world: World, name: string): boolean

    --- Registers a query that a `waitQuery` step can name.
    ---
    --- The query subscribes to archetype transitions, so a wait on it stays
    --- event driven rather than polling. Registration is startup work: a
    --- name registered twice keeps the newer query, and the replaced one
    --- holds its subscriptions for the life of the world.
    ---
    --- @param world The world owns the query registry.
    --- @param name Empty raises. Registering it again re-tests every playback
    ---     already parked on the name, against the new query, at the next
    ---     fixed step.
    --- @param descriptor The function copies this descriptor and wraps its
    ---     `onEntitiesAdded` and `onEntitiesRemoved` callbacks. It marks the name
    ---     before calling the supplied callbacks. A non-table raises.
    registerQuery: function(world: World, name: string, descriptor: types.Query.Descriptor)

    --- Returns whether this world has registered a query name.
    ---
    --- @param world The world owns the query registry.
    --- @param name The caller supplies the query name to find.
    --- @return false for a name this world never registered, including one
    ---     another world has: queries are per world.
    hasQuery: function(world: World, name: string): boolean

    --- Raises a signal whenever an event emits at address zero.
    ---
    --- An ECS event is an edge, like a signal, so this wires one to the
    --- other rather than adding a separate kind of wait. Delivery follows
    --- the ordinary signal rule: waiters wake on the next fixed step.
    ---
    --- @param world The world owns the event observer and signal state.
    --- @param name The signal to raise, once per emission. An empty one
    ---     raises.
    --- @param event Observed at address 0, and only there. The observer lasts
    ---     for the life of the world; wiring the same pair twice observes it
    ---     twice, and there is nothing that unwires one.
    signalOnEvent: function<T is ecs.Event>(world: World, name: string, event: T)

    --- Raises a named signal and wakes every playback blocked on it.
    ---
    --- Delivery happens on the next fixed step. Raising a signal nothing is
    --- waiting on is not an error and is not remembered: a playback that
    --- reaches `waitSignal` afterwards keeps waiting.
    ---
    --- @param world The world owns the signal state.
    --- @param name Any string, registered nowhere. An empty one raises.
    --- @return Returns the number of playbacks waiting on the name now. The next
    ---     fixed step wakes the set waiting then, which may differ.
    signal: function(world: World, name: string): integer

    --- Returns how many playbacks currently wait on a signal name.
    ---
    --- @param world The world owns the waiting playbacks.
    --- @param name The caller supplies the signal name to count.
    --- @return 0 for a name nothing waits on, including one never signaled.
    ---     Counts current waiters. A signal raised during this step remains in
    ---     the count until the next step delivers it.
    waitingOn: function(world: World, name: string): integer

    ---------------------------------------------------------------------------
    -- Playback
    ---------------------------------------------------------------------------

    --- Starts a program. The first instruction runs on the next tick of the
    --- program's own clock, never inside this call.
    ---
    --- @param world The world owns the new playback.
    --- @param program A value from `define` or `timeline`, not a name. The
    ---     playback runs this version for its whole life, even if another
    ---     `define` replaces the name. Anything other than a compiled program
    ---     raises.
    --- @param options Omitted, the playback has no owner, no bindings, no
    ---     params, no channel, and the world's instruction budget. Taking a
    ---     channel another playback on the same owner holds cancels that one
    ---     first, reporting `replaced` to anything waiting on it.
    --- @return A handle to the new playback, valid until it ends. A handle
    ---     carries a generation, so one whose playback has ended never names a
    ---     later playback that took the same slot.
    play: function(world: World, program: Program, options?: PlayOptions): Handle

    --- Stops a playback and releases its cursor. This remains safe on a
    --- finished handle.
    ---
    --- It takes the branches it forked with it, and a playback parked in a
    --- `waitTween` on the one canceled is told `canceled` and resumes. What
    --- a `playTween` started is a playback in its own right and is not
    --- canceled with the one that started it, unlike a pause, which cascades
    --- to it: stop it through its owner with `cancelOwnedBy`.
    ---
    --- @param world The world owns the playback.
    --- @param handle Read against this world's cursor arena, so one issued by
    ---     another world is meaningless here rather than reliably ignored.
    --- @return false when the handle names nothing running, whether it already
    ---     finished or was already canceled.
    cancel: function(world: World, handle: Handle): boolean

    --- Suspends a playback, its branches, and anything it started.
    ---
    --- Pause is holder counted: two systems can hold the same playback for
    --- unrelated reasons, and it runs again only when the last one lets go,
    --- so whichever resumes first cannot undo the other. `holder` names who
    --- is holding it and defaults to `"user"`.
    ---
    --- Its wait, if any, resumes from where it paused. What it is waiting on
    --- stops with it when the awaitable provider knows how.
    ---
    --- @param world The world owns the playback.
    --- @param handle The caller supplies the playback to pause.
    --- @param holder Any string, and a set rather than a count: two pauses
    ---     under the same holder are one hold, and one `resume` under it
    ---     releases both. Two callers that both leave it at the default
    ---     therefore share a single hold.
    --- @return Whether the playback stopped. A second holder taking a hold on
    ---     one that is already paused registers the hold and returns false,
    ---     because nothing observable changed. So does a handle that names
    ---     nothing running.
    pause: function(world: World, handle: Handle, holder?: string): boolean

    --- Releases one holder's claim.
    ---
    --- @param world The world owns the playback.
    --- @param handle The caller supplies the paused playback.
    --- @param holder Must be the string that took the hold; releasing one that
    ---     never held it changes nothing. Defaults to `"user"`, as `pause`'s
    ---     does.
    --- @return Whether the playback started running again, which is only
    ---     true for the last holder to let go. A wake time that passed while
    ---     it was held runs it on the next tick rather than immediately.
    resume: function(world: World, handle: Handle, holder?: string): boolean

    --- Returns playback status, or nil for a handle this world never issued.
    ---
    --- @param world The world owns the playback.
    --- @param handle Read against this world's cursor arena, as `cancel`'s is.
    --- @return A fresh table each call, which the caller owns. A finished
    ---     playback still answers, with `state` saying how it ended, until its
    ---     a later `play` takes its slot. The runtime fills waiting fields only
    ---     while the playback lives, so a finished
    ---     playback reports its program, the `pc` it stopped at, how it ended
    ---     and its last tween outcome, with the rest nil.
    status: function(world: World, handle: Handle): Status

    --- Cancels every playback owned by an entity.
    ---
    --- `reason` is what anything waiting on one of them is told. The owner
    --- despawning reports `targetLost`, which lets a waiter distinguish
    --- cancellation from target loss.
    ---
    --- @param world The world owns the playbacks.
    --- @param owner An entity id. A playback started without an owner is
    ---     nothing owns a playback started without an owner, rather than
    ---     entity 0, so no argument reaches
    ---     one and only `cancel` on its handle stops it.
    --- @param reason What a playback parked in a `waitTween` on one of these
    ---     is told, and what its `status` reports afterwards as
    ---     `tweenOutcome`. Omitted, a waiter is told `canceled`.
    --- @return Returns the number of canceled playbacks, or zero when the
    ---     entity owns none. The call reaches branches through their inherited
    ---     owner and counts each cursor once.
    cancelOwnedBy: function(world: World, owner: integer, reason?: TweenOutcome): integer

    --- Returns the number of live playbacks for tests and diagnostics.
    ---
    --- @param world The world owns the playbacks.
    --- @return Branches counted individually, since a branch is a playback of
    ---     its own, and so are the playbacks a `playTween` started.
    activeCount: function(world: World): integer

    --- Returns handles for every live playback, branches included, in a stable
    --- order. For diagnostics and the debugger, not for hot paths.
    ---
    --- @param world The world owns the playbacks.
    --- @return Returns a fresh table ordered by cursor slot. Slot order remains
    ---     stable within a run but differs from creation order because new
    ---     playbacks reuse free slots. The table also includes playbacks started
    ---     by `playTween`.
    playbacks: function(world: World): {Handle}

    ---------------------------------------------------------------------------
    -- Configuration and tooling
    ---------------------------------------------------------------------------

    --- Sets the per-step instruction budget for playbacks without their own.
    ---
    --- @param world The world applies the budget to new playbacks.
    --- @param instructions Must be at least 1. It caps how many instructions
    ---     one playback runs per tick, and exceeding it faults the playback
    ---     with `budgetExceeded` rather than deferring the rest, so it is a
    ---     guard against a `loop` with no wait in it, not a scheduler. Applies
    ---     to playbacks started after this call; a running one keeps the
    ---     budget it started with.
    setInstructionBudget: function(world: World, instructions: integer)

    --- Returns a clock's current tick as counted by the sequencer. It defaults to the
    --- fixed clock.
    ---
    --- @param world The world owns the clock counters.
    --- @param clock Which of the three counters to read. Omitted, `"fixed"`.
    --- @return Ticks of that one clock, rising by one each time the sequencer
    ---     advances it and by nothing else. It counts from when this world's
    ---     the world created its sequencer state, not when the process started.
    ---     A
    ---     snapshot load puts back the count the snapshot carried. Comparable
    ---     only against another reading of the same clock.
    currentStep: function(world: World, clock?: ClockId): integer

    --- Returns the actions a playback will certainly perform next and their
    --- timing.
    ---
    --- Walks the straight-line run ahead of where it sits, accumulating
    --- waits, and stops at the first instruction whose successor requires
    --- execution. It counts ticks in the playback's own
    --- clock, from now.
    ---
    --- @param world The world owns the playback.
    --- @param handle The caller supplies the playback to inspect.
    --- @param withinTicks Report only what is due within this many ticks.
    ---     Counted in the playback's own clock, from now. Omit for everything
    ---     the walk can reach.
    --- @return A fresh table each call, holding the calls and emits ahead in
    ---     order. Empty for a handle that names nothing running, and also for
    ---     one parked on a signal, a query, a join, a tween or an evaluator,
    ---     since none of those has a predictable start. A wait written in
    ---     seconds also ends the walk, because converting it needs a clock the
    ---     program does not carry. Each step's `args` is the program's own
    ---     constant list rather than a copy of it, so read it and do not write
    ---     to it. A paused playback still answers, counted as though it were
    ---     running.
    upcoming: function(world: World, handle: Handle, withinTicks?: integer): {Step}

    --- Describes one step a playback will reach without branching.
    type Step = seqprogram.Step

    --- Renders a program as readable instructions.
    ---
    --- @param program A value from `define` or `timeline`; anything else
    ---     raises.
    --- @param pc Mark this instruction, as a playback's `status` reports it.
    ---     Omit for an unmarked listing. One past the end, or any other
    ---     address the program does not hold, marks nothing.
    --- @return A header naming the program and its version, then one line per
    ---     instruction, newline separated. For reading and not for parsing:
    ---     the format is free to change.
    disassemble: function(program: Program, pc?: integer): string

    --- Installs the sequencer. `tecs.newApplication` installs it automatically,
    --- and it remains safe
    --- to call again: a second install on the same world does nothing.
    ---
    --- @param world The world receives sequencer state and systems.
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

function sequence.waitQuery(name: string, condition: sequence.QueryCondition): sequence.Node
    if type(name) ~= "string" or name == "" then
        error("sequence.waitQuery requires a non-empty query name", 2)
    end
    if condition ~= "any" and condition ~= "empty" then
        error("sequence.waitQuery condition must be 'any' or 'empty'", 2)
    end
    return {kind = "waitQuery", text = name, count = condition == "any" and 1 or 0} as sequence.Node
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

function sequence.playTween(timeline: string, target: sequence.EntityRef, params?: {string: any}): sequence.Node
    if type(timeline) ~= "string" or timeline == "" then
        error("sequence.playTween requires a non-empty timeline name", 2)
    end
    if not seqprogram.isEntityRef(target) then
        error("sequence.playTween requires a sequence.bind(name) target", 2)
    end
    return {kind = "playTween", text = timeline, args = {target, params}} as sequence.Node
end

function sequence.eval(evaluator: string, data?: any): sequence.Node
    if type(evaluator) ~= "string" or evaluator == "" then
        error("sequence.eval requires a non-empty evaluator name", 2)
    end
    return {kind = "eval", text = evaluator, args = data as {any}} as sequence.Node
end

function sequence.await(provider: string, target: sequence.EntityRef, key?: string): sequence.Node
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

function sequence.define(name: string, nodes: {sequence.Node}, options?: sequence.DefineOptions): sequence.Program
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

function sequence.defineData(name: string, rows: {any}, options?: sequence.DefineOptions): sequence.Program, string
    local nodes, err = seqjson.decode(sequence as seqjson.Builders, rows)
    if not nodes then
        return nil, err
    end
    return sequence.define(name, nodes, options)
end

function sequence.dataOps(): {string}
    return seqjson.ops()
end

function sequence.timeline(
    name: string, spec: sequence.TimelineSpec, options?: sequence.TimelineOptions
): sequence.Program
    local clock: seqtypes.ClockId = options and options.clock or "presentation"
    if clock ~= "fixed" and clock ~= "presentation" then
        error("sequence.timeline clock must be 'fixed' or 'presentation'", 2)
    end
    local compiled <const> = tweeneval.compile(spec)
    -- The serialized form is what the const pool carries; the evaluator
    -- resolves it back once, when the first playback of it starts.
    return sequence.define(
        name,
        {
            sequence.eval(seqtweenrun.EVALUATOR, tweeneval.serializeTimeline(compiled)),
        },
        {clock = clock}
    )
end

function sequence.program(name: string, version?: integer): sequence.Program
    if version then
        return seqregistry.version(name, version)
    end
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

function sequence.registerQuery(world: World, name: string, descriptor: types.Query.Descriptor)
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
    local spec: types.Query.Descriptor = {}
    for key, value in pairs(descriptor as {string: any}) do
        (spec as {string: any})[key] = value
    end
    spec.onEntitiesAdded = function(archetype: ecs.Archetype, firstRow: integer, lastRow: integer, count: integer)
        state.dirtyQueries[name] = true
        if userAdded then
            userAdded(archetype, firstRow, lastRow, count)
        end
    end
    spec.onEntitiesRemoved = function(archetype: ecs.Archetype, firstRow: integer, lastRow: integer, count: integer)
        state.dirtyQueries[name] = true
        if userRemoved then
            userRemoved(archetype, firstRow, lastRow, count)
        end
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
    world:observe(0, event, function() sequence.signal(world, name) end)
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
    if not blocked then
        return 0
    end
    local count = 0
    for _ in pairs(blocked) do
        count = count + 1
    end
    -- Delivery is deferred to the next step so a signal raised from inside a
    -- running cursor cannot cascade within the same step.
    state.pendingSignals[#state.pendingSignals + 1] = name
    return count
end

function sequence.waitingOn(world: World, name: string): integer
    local blocked = seqcursors.stateFor(world).channels[name]
    if not blocked then
        return 0
    end
    local count = 0
    for _ in pairs(blocked) do
        count = count + 1
    end
    return count
end

function sequence.play(world: World, program: sequence.Program, options?: sequence.PlayOptions): sequence.Handle
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
        if options.budget then
            cursor.budget = options.budget
        end
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
    if not cursor or not cursor.alive then
        return false
    end
    seqcursors.retire(state, cursor, "canceled")
    return true
end

function sequence.pause(world: World, handle: sequence.Handle, holder?: string): boolean
    local state = seqcursors.stateFor(world)
    local cursor = seqcursors.resolve(state, handle)
    if not cursor or not cursor.alive then
        return false
    end
    return seqcursors.pauseTree(state, cursor, holder or DEFAULT_HOLDER)
end

function sequence.resume(world: World, handle: sequence.Handle, holder?: string): boolean
    local state = seqcursors.stateFor(world)
    local cursor = seqcursors.resolve(state, handle)
    if not cursor or not cursor.alive then
        return false
    end
    return seqcursors.resumeTree(state, cursor, holder or DEFAULT_HOLDER)
end

function sequence.status(world: World, handle: sequence.Handle): sequence.Status
    local state = seqcursors.stateFor(world)
    local cursor = seqcursors.resolve(state, handle)
    if not cursor then
        return nil
    end
    local branches = 0
    local children = cursor.children
    if children then
        for _ in pairs(children) do
            branches = branches + 1
        end
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
        waitingCondition = cursor.alive and cursor.waitQuery and (cursor.waitCondition == 1 and "any" or "empty")
            or nil,
        branches = branches,
        joining = cursor.joining or false,
        fault = cursor.fault,
        faultMessage = cursor.faultMessage,
    }
    return status
end

function sequence.cancelOwnedBy(world: World, owner: integer, reason?: sequence.TweenOutcome): integer
    local state = seqcursors.stateFor(world)
    local owned = state.ownerIndex[owner]
    if not owned then
        return 0
    end
    local slots: {integer} = {}
    for slot in pairs(owned) do
        slots[#slots + 1] = slot
    end
    table.sort(slots)
    local canceled = 0
    for i = 1, #slots do
        local cursor = state.cursors[slots[i]]
        if cursor and cursor.alive then
            seqcursors.retire(state, cursor, "canceled", reason)
            canceled = canceled + 1
        end
    end
    return canceled
end

function sequence.activeCount(world: World): integer
    local state = seqcursors.stateFor(world)
    local count = 0
    for _, cursor in pairs(state.cursors) do
        if cursor.alive then
            count = count + 1
        end
    end
    return count
end

function sequence.playbacks(world: World): {sequence.Handle}
    local state = seqcursors.stateFor(world)
    local slots: {integer} = {}
    for slot, cursor in pairs(state.cursors) do
        if cursor.alive then
            slots[#slots + 1] = slot
        end
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

function sequence.upcoming(world: World, handle: sequence.Handle, withinTicks?: integer): {sequence.Step}
    local state = seqcursors.stateFor(world)
    local cursor = seqcursors.resolve(state, handle)
    if not cursor or not cursor.alive then
        return {}
    end
    -- A scheduled cursor is already some ticks out; one parked on a signal,
    -- a query, a join, or a tween has no predictable start at all.
    if not cursor.wakeAt then
        return {}
    end
    local offset <const> = cursor.wakeAt - seqcursors.clockOf(state, cursor).step
    return seqprogram.ahead(cursor.program, cursor.pc, offset > 0 and offset or 0, withinTicks)
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
local installed: {World: boolean} = setmetatable({}, {__mode = "k"} as metatable<{World: boolean}>)

function sequence.plugin(world: World)
    if installed[world] then
        return
    end
    installed[world] = true
    local state = seqcursors.stateFor(world)

    -- Evaluators are global, so this registers once however many worlds
    -- install the sequencer.
    seqtweenrun.install()

    world:addSystem(
        {
            name = "sequence.Advance",
            phase = ecs.phases.FixedFirst,
            run = function(dt: number) seqvm.tick(world, state, "fixed", dt) end,
        }
    )

    -- phases.First is the earliest gameplay phase, ahead of the fixed group,
    -- so a frame-clock program has run before anything reads what it did. That
    -- is what scripted input needs and what the fixed clock cannot give it: a
    -- frame runs the fixed phases zero times or several, and a program driving
    -- input has to advance exactly once per frame either way.
    world:addSystem(
        {
            name = "sequence.AdvanceFrame",
            phase = ecs.phases.First,
            run = function(dt: number) seqvm.tick(world, state, "frame", dt) end,
        }
    )

    -- Presentation runs in Update with the frame's real dt: what it carries
    -- has to move at the display's rate, not the simulation's.
    world:addSystem(
        {
            name = "sequence.AdvancePresentation",
            phase = ecs.phases.Update,
            run = function(dt: number) seqvm.tick(world, state, "presentation", dt) end,
        }
    )

    world:addSnapshotHandler(
        {
            name = "tecs.sequence",
            save = function(w: World): any return seqsnapshot.save(w) end,
            load = function(w: World, value: any) seqsnapshot.load(w, value) end,
        }
    )

    -- Owner lifetime: a despawned owner cancels the playbacks it governs.
    world:observe(
        0,
        ecs.OnDespawn,
        function(event: ecs.OnDespawn)
            if state.ownerIndex[event.entity] then
                sequence.cancelOwnedBy(world, event.entity, "targetLost")
            end
        end
    )
end

return sequence
