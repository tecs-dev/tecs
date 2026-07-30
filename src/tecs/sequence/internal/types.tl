--[=[
Shared record types for the sequencer.

A leaf module in the shape of `debug/internal/cmdtypes`: the internal
modules read these without requiring the public surface back, which would
be a cycle. `tecs.sequence` re-exports every one of them.
]=]

local ecs <const> = require("tecs.ecs")
local type types = require("tecs.types")
local seqclock <const> = require("tecs.sequence.internal.clock")

local type World = types.World

--- Why a cursor stopped running.
local enum FaultReason
    --- A `call` named an action that is not registered on this world.
    "unregisteredAction"
    --- A registered action raised.
    "actionError"
    --- The cursor exceeded its per-step instruction budget.
    "budgetExceeded"
    --- A branch this cursor forked faulted.
    "branchFaulted"
    --- A `waitQuery` named a query that is not registered on this world.
    "unregisteredQuery"
    --- An `eval` named an evaluator that is not registered.
    "unregisteredEvaluator"
    --- An `await` named a provider that is not registered on this build.
    "unregisteredAwaitable"
    --- A `playTween` named a preset that is not registered on this world.
    "unregisteredTween"
end

--- How the playback a `waitTween` step was waiting on ended.
local enum TweenOutcome
    --- It played to the end.
    "completed"
    --- Something canceled it.
    "canceled"
    --- Another playback took over its channel.
    "replaced"
    --- Its entity died, or was never bound in the first place.
    "targetLost"
end

--- What a `waitQuery` step is waiting for.
local enum QueryCondition
    --- At least one entity matches the query.
    "any"
    --- No entity matches the query.
    "empty"
end

--- Which clock a program is scheduled against.
---
--- A clock's unit is its own business: `fixed` counts fixed steps and
--- `frame` counts gameplay frames rather than fixed steps, so a program on it
--- advances exactly once per frame however many fixed steps that frame runs.
--- That is what scripted input needs: one decision per frame, taken before
--- anything reads it.
local enum ClockId
    --- Advances in FixedFirst, one per fixed step. Gameplay logic.
    "fixed"
    --- Advances in First, one per gameplay frame. Scripted input.
    "frame"
    --- Advances in Update, once per frame, carrying the frame's dt.
    --- Continuous evaluation: interpolation that has to look smooth at the
    --- display's rate rather than the simulation's.
    "presentation"
end

--- Something a cursor evaluates every tick rather than sleeping through.
---
--- A playback parked on a wait costs one comparison per tick. One that is
--- interpolating has work to do on every one of them, so it lives in a dense
--- array the tick walks and never touches the wake heap. This is what lets
--- one runtime serve both without either paying for the other.
local record Evaluator
    --- Turn the constants an `eval` step carries into whatever form is
    --- cheapest to read every tick: functions bound, names resolved.
    ---
    --- Called once per program constant and the result shared by every
    --- playback of it, so this is where work that does not depend on the
    --- playback belongs. Omit it to hand the constants over as authored.
    resolve: function(data: any): any

    --- Per-cursor working state, or nil when it needs none. `data` is what
    --- the `eval` step carried, resolved; the cursor is there for what
    --- belongs to the playback rather than the program, chiefly its `owner`
    --- and its `params`.
    newState: function(prog: ProgramImpl, data: any, cursor: Cursor): any

    --- Advance one cursor by `dt`. Returns true when it is finished and the
    --- cursor should move on to the next instruction.
    step: function(world: World, cursor: Cursor, dt: number): boolean

    --- Turn working state into something a snapshot can carry, and back.
    --- Without both, an evaluating playback comes back at the start of its
    --- state rather than where it was.
    save: function(state: any): any
    load: function(prog: ProgramImpl, data: any, saved: any): any
end

--- The lifecycle state of one playback.
local enum PlaybackState
    "running"
    "paused"
    "completed"
    "canceled"
    "faulted"
end

-------------------------------------------------------------------------------
-- Public surface
-------------------------------------------------------------------------------

--- A compiled, immutable program. Produced by `define`, shared by every
--- playback of it, and reference counted.
---
--- Redefining a name compiles a new version. Playbacks already running
--- keep the version they started with, so a hot reload continues rather
--- than resuming against changed instructions. Later `play` calls use the
--- newest version, and a superseded version is released once its last
--- playback finishes.
local interface Program
    --- Read-only. The name passed to `define`.
    name: string

    --- Read-only. Monotonic version, starting at 1. Incremented per
    --- redefinition.
    version: integer
end

--- One authored step. Produced by the node constructors below; treat the
--- returned value as opaque and do not reuse a node across programs.
local interface Node
end

--- A reference to an entity supplied at `play` time. Resolved when the
--- instruction that uses it runs, not when the program is defined.
local record EntityRef
    --- Read-only. Name of the binding this reference resolves.
    bindName: string
    --- Read-only. Marker distinguishing a reference from an ordinary table
    --- argument.
    isBinding: boolean
end

--- A generation-checked reference to one playback. Remains meaningful
--- across a snapshot load: a handle refers to the same playback before
--- and after a restore. A handle whose playback the snapshot did not
--- carry reports no status at all, the same as a handle this world
--- never issued.
local type Handle = integer

--- Constants a `call` passes to its action: numbers, strings, booleans,
--- and arrays or maps composed of those, plus `bind(name)` references,
--- which resolve to entity ids when the instruction runs. Anything else
--- (functions, cdata, entities) is rejected by `define`, because a
--- program has to survive a snapshot.
local type Argument = any

--- Options for `play`.
local record PlayOptions
    --- Caller-writable. Entity whose lifetime governs the playback. When it
    --- despawns, the playback is canceled. Omit for a world-scoped sequence.
    owner: integer

    --- Caller-writable. Entities the program acts on, addressed by
    --- `sequence.bind(name)`.
    bindings: {string: integer}

    --- Caller-writable. Constants this playback runs with, readable by its
    --- actions and its evaluators. A program is shared by every playback of
    --- it, so anything that differs between two of them belongs here rather
    --- than in the program. Plain data, for the same reason a `call`
    --- argument is: it travels with a snapshot.
    params: {string: any}

    --- Caller-writable. Per-step instruction budget for this playback.
    --- Defaults to the world's configured budget. See
    --- `setInstructionBudget`.
    budget: integer

    --- Caller-writable. Names a slot this playback occupies on its owner.
    --- Starting another playback on the same owner and channel cancels this
    --- one, which is how a second fade replaces the first rather than
    --- fighting it.
    channel: string
end

--- What a registered action receives.
---
--- The context and its `args` belong to the sequencer and are reused by
--- the next call. Read them; do not keep or modify them.
local record ActionContext
    --- Read-only. The world this playback belongs to.
    world: World

    --- Read-only. The playback, for `status` or `cancel` from inside an
    --- action.
    handle: Handle

    --- Read-only. The `owner` supplied at `play`, or 0 for a world-scoped
    --- sequence.
    owner: integer

    --- Read-only. Constants supplied by the `call` node, with any `bind`
    --- references already resolved to entity ids.
    args: {any}

    --- Read-only. The `params` supplied at `play`, or nil. Unlike `args`,
    --- this is the playback's own table rather than borrowed scratch, and it
    --- is the same one every step of the playback sees.
    params: {string: any}

    --- Resolve a named binding. Returns nil when the binding was not
    --- supplied or its entity is no longer alive.
    entity: function(self: ActionContext, name: string): integer

    --- Name an entity for the steps that follow, so an action that creates
    --- one can hand it on. Bindings travel with the playback and survive a
    --- snapshot; passing nil forgets the name.
    bind: function(self: ActionContext, name: string, entity: integer)

    --- Internal cursor reference. Not part of the supported surface.
    _cursor: any
end

--- A registered effect. Runs synchronously and must return before the
--- cursor advances; it may not yield.
---
--- Raising faults the playback with `actionError`. Mutations the action
--- already made are kept: the sequencer does not roll them back.
local type Action = function(world: World, ctx: ActionContext)

--- Emitted by an `emit` step, at address 0.
local record Event is ecs.Event
    --- Name supplied to `sequence.emit`.
    name: string
    --- Arguments supplied to `sequence.emit`, with bindings resolved.
    --- Unlike an action's `ctx.args`, this list is the observer's to
    --- keep: it is built per emit.
    args: {any}
    --- The playback that emitted it.
    handle: Handle

    init: function(self: Event, name: string, args: {any}, handle: Handle)
end

--- A playback's current state.
local record Status
    --- Read-only.
    state: PlaybackState

    --- Read-only. Program name this playback is running.
    program: string

    --- Read-only. Program version this playback is running.
    version: integer

    --- Read-only. Instruction index, for disassembly and debugging.
    pc: integer

    --- Read-only. Fixed step this playback next runs on. Nil when it is
    --- blocked on a signal rather than a time.
    wakeAt: integer

    --- Read-only. Signal name this playback is blocked on, when it is.
    waitingFor: string

    --- Read-only. Query name this playback is blocked on, when it is, and the
    --- condition it is waiting for.
    waitingQuery: string

    --- Read-only. Query condition this playback is waiting for.
    waitingCondition: QueryCondition

    --- Read-only. Awaitable provider this playback is blocked on, when it is,
    --- and the entity it is waiting on.
    waitingAwaitable: string

    --- Read-only. Entity this playback's awaitable is waiting on.
    waitingAwaitableEntity: integer

    --- Read-only. Tween playback token this playback is blocked on, when it
    --- is.
    waitingTween: integer

    --- Read-only. How the last tween it waited on ended.
    tweenOutcome: TweenOutcome

    --- Read-only. Live branches this playback forked and has not joined.
    branches: integer

    --- Read-only. Whether it is parked at a `join` waiting for those
    --- branches.
    joining: boolean

    --- Read-only. Set when `state` is `"faulted"`.
    fault: FaultReason

    --- Read-only. Error message set when `state` is `"faulted"`.
    faultMessage: string
end

function Event.init(e: Event, name: string, args: {any}, handle: Handle)
    e.name = name
    e.args = args
    e.handle = handle
end

ecs.newEvent(Event)

-------------------------------------------------------------------------------
-- Runtime representations
-------------------------------------------------------------------------------

local record ProgramImpl is Program
    name: string
    version: integer
    clock: ClockId
    code: {integer}
    consts: {any}
    loopCounts: {integer: integer}
    -- Const indexes whose argument list holds a `bind` reference, so a call
    -- with plain constants hands its arguments over without copying them.
    bindingArgs: {integer: boolean}

    -- Resolved `eval` payloads, keyed by const index. Runtime only, and
    -- derived from the consts like bindingArgs: a restored program rebuilds
    -- the same thing on first use.
    evalResolved: {integer: any}
end

local record NodeImpl is Node
    kind: string
    text: string
    number: number
    args: {any}
    nodes: {Node}
    blocks: {{Node}}
    count: integer
end

local record Cursor
    -- Arena bookkeeping
    slot: integer
    generation: integer
    alive: boolean

    program: ProgramImpl
    pc: integer
    state: PlaybackState

    --- The clock this cursor is scheduled against, from its program.
    clock: ClockId

    --- Set while the cursor is evaluating rather than waiting: it sits in
    --- its clock's active array and is stepped every tick.
    evaluator: string
    evalState: any

    --- The constants that `eval` step carried: where they sit in the const
    --- pool, and the resolved form the evaluator reads. Only the index is
    --- data; the resolved form is rebuilt from the program on load.
    evalIndex: integer
    evalData: any

    --- The registered evaluator itself, held rather than looked up by name,
    --- and where the cursor sits in its clock's active array. Both exist so
    --- the per-tick walk touches no hash table at all.
    evalImpl: Evaluator
    activeIndex: integer

    owner: integer
    bindings: {string: integer}
    params: {string: any}
    budget: integer

    wakeAt: integer
    seq: integer
    loopRegs: {integer: integer}
    waitChannel: string
    waitQuery: string
    waitCondition: integer

    -- The playback the last playTween started, as a handle, and how it ended
    -- once it has. The cursor it names carries the back reference.
    tweenPlayback: integer
    tweenOutcome: TweenOutcome
    waitingTween: boolean

    --- What an `await` step is parked on: the provider name, the entity it
    --- resolved, and the key it was given.
    awaitProvider: string
    awaitEntity: integer
    awaitKey: string

    --- Slot of the cursor parked on this one finishing, if any, and the
    --- channel this playback occupies on its owner.
    awaitedBy: integer
    channel: string

    -- Branch tree. A child holds its parent by (slot, generation) so a
    -- recycled slot can never be mistaken for the parent that forked it.
    parentSlot: integer
    parentGeneration: integer
    children: {integer: boolean}
    joining: boolean

    --- Who is holding this playback paused. It runs again when the last one
    --- lets go, so two systems pausing it for unrelated reasons cannot undo
    --- each other.
    pauseHolders: {string: boolean}

    -- Instruction budget is spent per fixed step, not per resume, so a
    -- cursor that wakes again within the same step cannot re-arm it.
    budgetStep: integer
    budgetLeft: integer

    fault: FaultReason
    faultMessage: string
end

local record WorldState
    --- The world this state belongs to, for the few paths that have to call
    --- outward: an awaitable provider being told its work is paused.
    world: World

    cursors: {integer: Cursor}
    freeSlots: {integer}
    nextSlot: integer
    generations: {integer: integer}

    actions: {string: Action}
    budget: integer

    -- One clock per ClockId. A cursor is scheduled against the clock its
    -- program declared.
    clocks: {ClockId: seqclock.Clock}

    -- Cursors blocked on a signal are held here rather than in the heap:
    -- they have no wake time until the signal arrives.
    channels: {string: {integer: boolean}}
    pendingSignals: {string}

    -- Query waits work the same way, except a query is a condition rather
    -- than an edge: a name is marked dirty when its query gains or loses
    -- entities, and every cursor parked on it re-tests at the next step.
    queries: {string: types.Query}
    queryWaiters: {string: {integer: boolean}}
    dirtyQueries: {string: boolean}

    -- Occupied channels, keyed by owner and channel name, so starting a
    -- playback on one can cancel whatever held it.
    channelled: {string: integer}

    -- Cursors parked on an awaitable provider, re-tested each fixed step.
    awaitWaiters: {integer: boolean}

    -- Scratch reused across calls: one argument list and one context. Calls
    -- never overlap, since a cursor runs to a wait before any other does.
    argScratch: {any}
    context: ActionContext

    ownerIndex: {integer: {integer: boolean}}
end

--- Every shared type, re-exported for `tecs.sequence` and the internal
--- modules. `Event` is a value field rather than a type alias: it is used in
--- both positions (`world:emit(0, seqtypes.Event, ...)` and `e: Event`), and
--- only a value field works for both.
local record seqtypes
    type FaultReason = FaultReason
    type PlaybackState = PlaybackState
    type QueryCondition = QueryCondition
    type ClockId = ClockId
    type Evaluator = Evaluator
    type TweenOutcome = TweenOutcome

    type Program = Program
    type Node = Node
    type EntityRef = EntityRef
    type Handle = Handle
    type Argument = Argument
    type PlayOptions = PlayOptions
    type ActionContext = ActionContext
    type Action = Action
    type Status = Status

    type ProgramImpl = ProgramImpl
    type NodeImpl = NodeImpl
    type Cursor = Cursor
    type WorldState = WorldState

    Event: Event
end

seqtypes.Event = Event

return seqtypes
