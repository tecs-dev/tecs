--- Deterministic, snapshot-safe gameplay sequencing.
---
--- A sequence is a compiled program of scheduled steps that advances on the
--- fixed step. Cutscenes, ability chains, spawn waves, and tutorials are
--- normally written as coroutines, whose suspended state lives in the Lua
--- stack and cannot be serialized. A sequence keeps its position as data, so
--- it survives snapshots, rewind, and hot reload.
---
--- Usage:
---   local sequence = require("tecs2d.sequence")
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

local tecs <const> = require("tecs")
local seqtypes <const> = require("tecs2d.sequence.internal.types")
local seqprogram <const> = require("tecs2d.sequence.internal.program")
local seqregistry <const> = require("tecs2d.sequence.internal.registry")
local logging <const> = require("tecs.utils.logging")
local tween <const> = require("tecs2d.tween")
local wakeheap <const> = require("tecs2d.internal.wakeheap")

local type World = tecs.World

local LOGGER <const> = logging.getLogger("tecs2d.sequence")


-- The runtime records live in the leaf types module; bind them so the body
-- below reads the same as when they were declared here.
local type FaultReason = seqtypes.FaultReason
local type PlaybackState = seqtypes.PlaybackState
local type TweenOutcome = seqtypes.TweenOutcome
local type ProgramImpl = seqtypes.ProgramImpl
local type Cursor = seqtypes.Cursor
local type WorldState = seqtypes.WorldState

-- Handle packing. A handle is slot + generation * SLOT_LIMIT, so it stays a
-- plain integer that survives snapshots and compares by value.
local SLOT_LIMIT <const> = 1048576

local DEFAULT_BUDGET <const> = 512

-- Layout version of this module's snapshot payload. Bumped whenever a cursor
-- gains state an older reader would silently ignore, so a save written by a
-- newer build is rejected rather than restored as a half-cursor.
--   1: cursor, program, and signal state
--   2: branch tree (parent link and join state)
--   3: query waits
--   4: tween playback waits
local SNAPSHOT_VERSION <const> = 4


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

    --- Compile a program under a stable symbolic name.
    define: function(name: string, nodes: {Node}): Program

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
    --- Needs the tween plugin, which `tecs2d.run` installs. A binding that
    --- is missing or dead is not a fault: nothing plays, and a following
    --- `waitTween` resumes at once reporting `targetLost`.
    playTween: function(preset: string, target: EntityRef, options?: tween.PlaybackOptions): Node

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

    --- Register an effect a `call` node can name.
    ---
    --- Actions must obey the deterministic-action contract to keep replay and
    --- rewind meaningful: no wall-clock reads, no file or network access, and
    --- randomness only through `love.math`, whose state travels with
    --- snapshots.
    registerAction: function(world: World, name: string, action: Action)

    --- Whether an action name is registered on this world.
    hasAction: function(world: World, name: string): boolean

    --- Register a query a `waitQuery` step can name.
    ---
    --- The query subscribes to archetype transitions, so a wait on it stays
    --- event driven rather than polling. Registration is startup work: a
    --- name registered twice keeps the newer query, and the replaced one
    --- holds its subscriptions for the life of the world.
    registerQuery: function(world: World, name: string, descriptor: tecs.Query.Descriptor)

    --- Whether a query name is registered on this world.
    hasQuery: function(world: World, name: string): boolean

    --- Raise a signal every time an event is emitted at address 0.
    ---
    --- An ECS event is an edge, like a signal, so this wires one to the
    --- other rather than adding a separate kind of wait. Delivery follows
    --- the ordinary signal rule: waiters wake on the next fixed step.
    signalOnEvent: function<T is tecs.Event>(world: World, name: string, event: T)

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

    --- Suspend a playback. Its wait, if any, resumes from where it paused.
    pause: function(world: World, handle: Handle): boolean

    --- Resume a paused playback.
    resume: function(world: World, handle: Handle): boolean

    --- Inspect a playback. Returns nil for a handle this world never issued.
    status: function(world: World, handle: Handle): Status

    --- Cancel every playback owned by an entity.
    cancelOwnedBy: function(world: World, owner: integer): integer

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

    --- The world's current fixed step, as counted by the sequencer.
    currentStep: function(world: World): integer

    --- Render a program as readable instructions.
    --- @param pc Mark this instruction, as a playback's `status` reports it.
    disassemble: function(program: Program, pc?: integer): string

    --- Install the sequencer. Auto-installed by `tecs2d.run`.
    plugin: function(world: World)
end

-------------------------------------------------------------------------------
-- Program representation
-------------------------------------------------------------------------------


-- The event record lives in the leaf types module so the VM can emit it
-- without requiring this one back; re-exported here as the public handle.
sequence.Event = seqtypes.Event


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
    preset: string,
    target: sequence.EntityRef,
    options?: tween.PlaybackOptions
): sequence.Node
    if type(preset) ~= "string" or preset == "" then
        error("sequence.playTween requires a non-empty preset name", 2)
    end
    if not seqprogram.isEntityRef(target) then
        error("sequence.playTween requires a sequence.bind(name) target", 2)
    end
    return {kind = "playTween", text = preset, args = {target, options}}
        as sequence.Node
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


function sequence.define(name: string, nodes: {sequence.Node}): sequence.Program
    if type(name) ~= "string" or name == "" then
        error("sequence.define requires a non-empty program name", 2)
    end
    if type(nodes) ~= "table" then
        error("sequence.define requires an array of nodes", 2)
    end

    local prog = seqprogram.compile(name, seqregistry.nextVersion(name), nodes)
    seqregistry.publish(prog)
    return prog
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



local states: {World: WorldState} =
    setmetatable({}, {__mode = "k"} as metatable<{World: WorldState}>)

local function stateFor(world: World): WorldState
    local state = states[world]
    if state then return state end
    state = {
        cursors = {},
        freeSlots = {},
        nextSlot = 1,
        generations = {},
        actions = {},
        step = 0,
        seq = 0,
        budget = DEFAULT_BUDGET,
        heap = wakeheap.new(),
        channels = {},
        pendingSignals = {},
        queries = {},
        queryWaiters = {},
        dirtyQueries = {},
        tweenOwners = {},
        tweenWaiters = {},
        argScratch = {},
        ownerIndex = {},
    }
    states[world] = state
    return state
end

local function packHandle(slot: integer, generation: integer): sequence.Handle
    return slot + generation * SLOT_LIMIT
end

-------------------------------------------------------------------------------
-- Scheduling
-------------------------------------------------------------------------------

local function schedule(state: WorldState, cursor: Cursor, wakeAt: integer)
    state.seq = state.seq + 1
    cursor.wakeAt = wakeAt
    cursor.seq = state.seq
    wakeheap.push(state.heap, wakeAt, cursor.seq,
        packHandle(cursor.slot, cursor.generation))
end

-------------------------------------------------------------------------------
-- Arena
-------------------------------------------------------------------------------

local function resolve(state: WorldState, handle: sequence.Handle): Cursor
    if type(handle) ~= "number" then return nil end
    local slot = handle % SLOT_LIMIT
    local generation = (handle - slot) / SLOT_LIMIT
    local cursor = state.cursors[slot]
    if not cursor or cursor.generation ~= generation then return nil end
    return cursor
end

local function allocCursor(state: WorldState): Cursor
    local slot: integer
    local freeCount = #state.freeSlots
    if freeCount > 0 then
        slot = state.freeSlots[freeCount]
        state.freeSlots[freeCount] = nil
    else
        slot = state.nextSlot
        state.nextSlot = slot + 1
        if slot >= SLOT_LIMIT then
            error("sequence: cursor arena exhausted")
        end
    end
    local generation = (state.generations[slot] or 0) + 1
    state.generations[slot] = generation
    local cursor: Cursor = {
        slot = slot,
        generation = generation,
        alive = true,
        pc = 0,
        state = "running",
        owner = 0,
        budget = state.budget,
        wakeAt = 0,
        seq = 0,
        loopRegs = nil,
    }
    state.cursors[slot] = cursor
    return cursor
end

local function park(
    index: {string: {integer: boolean}},
    key: string,
    slot: integer
)
    local blocked = index[key]
    if not blocked then
        blocked = {}
        index[key] = blocked
    end
    blocked[slot] = true
end

local function unpark(
    index: {string: {integer: boolean}},
    key: string,
    slot: integer
)
    local blocked = index[key]
    if not blocked then return end
    blocked[slot] = nil
    if next(blocked) == nil then index[key] = nil end
end

-- Drop a cursor from whichever wait index holds it. Every wait that is not
-- a time lives in one of these, so every exit path goes through here.
local function unlinkWaits(state: WorldState, cursor: Cursor)
    local channel = cursor.waitChannel
    if channel then
        cursor.waitChannel = nil
        unpark(state.channels, channel, cursor.slot)
    end
    local queryName = cursor.waitQuery
    if queryName then
        cursor.waitQuery = nil
        cursor.waitCondition = nil
        unpark(state.queryWaiters, queryName, cursor.slot)
    end
    if cursor.waitingTween then
        cursor.waitingTween = false
        state.tweenWaiters[cursor.slot] = nil
    end
end

-- Drop the cursor's claim on a tween token, so an end event for a playback
-- nothing is following no longer finds an owner.
local function releaseTween(state: WorldState, cursor: Cursor)
    local token = cursor.tweenPlayback
    if not token then return end
    if state.tweenOwners[token] == cursor.slot then
        state.tweenOwners[token] = nil
    end
    cursor.tweenPlayback = nil
    cursor.tweenEntity = nil
end

local function linkOwner(state: WorldState, cursor: Cursor)
    if cursor.owner == 0 then return end
    local owned = state.ownerIndex[cursor.owner]
    if not owned then
        owned = {}
        state.ownerIndex[cursor.owner] = owned
    end
    owned[cursor.slot] = true
end

local function unlinkOwner(state: WorldState, cursor: Cursor)
    if cursor.owner == 0 then return end
    local owned = state.ownerIndex[cursor.owner]
    if owned then
        owned[cursor.slot] = nil
        if next(owned) == nil then state.ownerIndex[cursor.owner] = nil end
    end
end

-- Branch slots in a stable order, so a subtree is torn down the same way on
-- every run regardless of hash iteration order.
local function childSlots(cursor: Cursor): {integer}
    local slots: {integer} = {}
    local children = cursor.children
    if not children then return slots end
    for slot in pairs(children) do slots[#slots + 1] = slot end
    table.sort(slots)
    return slots
end

-- Faulting a parent from a faulting branch retires it, so the two are
-- mutually recursive.
local faultCursor: function(
    state: WorldState,
    cursor: Cursor,
    reason: FaultReason,
    message: string
)

local function detachFromParent(
    state: WorldState,
    cursor: Cursor,
    finalState: PlaybackState
)
    local slot = cursor.parentSlot
    if not slot then return end
    cursor.parentSlot = nil
    local parent = state.cursors[slot]
    if not parent or parent.generation ~= cursor.parentGeneration then return end

    local children = parent.children
    if children then children[cursor.slot] = nil end
    if not parent.alive then return end

    -- A faulted branch is a defect in the program, so it surfaces rather
    -- than leaving a join quietly one branch short. A cancelled branch is
    -- deliberate, and the join simply proceeds without it.
    if finalState == "faulted" then
        faultCursor(state, parent, "branchFaulted",
            "branch at pc=" .. tostring(cursor.pc) .. " faulted: "
            .. tostring(cursor.faultMessage))
        return
    end

    if parent.joining and (not children or next(children) == nil) then
        parent.joining = false
        schedule(state, parent, state.step)
    end
end

-- A finished cursor frees its slot immediately, so the arena is bounded by
-- peak concurrency rather than by every sequence ever played. Its record
-- stays until the slot is handed out again, which lets `status` report the
-- final state; once reused, the generation check makes the old handle report
-- nil instead of another playback's state.
local function retire(state: WorldState, cursor: Cursor, finalState: PlaybackState)
    if not cursor.alive then return end
    cursor.state = finalState
    cursor.alive = false
    cursor.joining = false
    unlinkWaits(state, cursor)
    releaseTween(state, cursor)
    unlinkOwner(state, cursor)
    seqregistry.release(cursor.program)

    -- A subtree dies from the root down: branches are cancelled first, so
    -- each one finds a parent already gone and reports nothing back up.
    local children = cursor.children
    if children and next(children) ~= nil then
        local slots = childSlots(cursor)
        for i = 1, #slots do
            local child = state.cursors[slots[i]]
            if child and child.alive then retire(state, child, "cancelled") end
        end
    end
    cursor.children = nil

    detachFromParent(state, cursor, finalState)
    state.freeSlots[#state.freeSlots + 1] = cursor.slot
end

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
    stateFor(world).actions[name] = action
end

function sequence.hasAction(world: World, name: string): boolean
    return stateFor(world).actions[name] ~= nil
end

function sequence.registerQuery(
    world: World,
    name: string,
    descriptor: tecs.Query.Descriptor
)
    if type(name) ~= "string" or name == "" then
        error("sequence.registerQuery requires a non-empty query name", 2)
    end
    if type(descriptor) ~= "table" then
        error("sequence.registerQuery requires a query descriptor", 2)
    end
    local state = stateFor(world)

    -- The callbacks only mark the name; the condition is tested once per
    -- step for every name that moved, not once per entity.
    local userAdded = descriptor.onEntitiesAdded
    local userRemoved = descriptor.onEntitiesRemoved
    local spec: tecs.Query.Descriptor = {}
    for key, value in pairs(descriptor as {string: any}) do
        (spec as {string: any})[key] = value
    end
    spec.onEntitiesAdded = function(
        archetype: tecs.Archetype,
        firstRow: integer,
        lastRow: integer,
        count: integer
    )
        state.dirtyQueries[name] = true
        if userAdded then userAdded(archetype, firstRow, lastRow, count) end
    end
    spec.onEntitiesRemoved = function(
        archetype: tecs.Archetype,
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
    return stateFor(world).queries[name] ~= nil
end

function sequence.signalOnEvent<T is tecs.Event>(world: World, name: string, event: T)
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

local function contextEntity(self: sequence.ActionContext, name: string): integer
    local cursor = self._cursor as Cursor
    local bindings = cursor.bindings
    if not bindings then return nil end
    local id = bindings[name]
    if not id then return nil end
    if not self.world:isAlive(id) then return nil end
    return id
end

-- Arguments without a binding in them are handed over as the program stored
-- them; the rest are resolved into the world's scratch list. Either way the
-- list belongs to the sequencer, and an action must read it rather than keep
-- or modify it.
local function resolveArgs(
    world: World,
    state: WorldState,
    cursor: Cursor,
    index: integer
): {any}
    local raw = cursor.program.consts[index] as {any}
    if not cursor.program.bindingArgs[index] then return raw end

    local out = state.argScratch
    local count = #raw
    for i = 1, count do
        local value = raw[i]
        if seqprogram.isEntityRef(value) then
            local name = (value as sequence.EntityRef).bindName
            local id = cursor.bindings and cursor.bindings[name]
            out[i] = (id and world:isAlive(id)) and id or nil
        else
            out[i] = value
        end
    end
    for i = #out, count + 1, -1 do out[i] = nil end
    return out
end

faultCursor = function(
    state: WorldState,
    cursor: Cursor,
    reason: FaultReason,
    message: string
)
    cursor.fault = reason
    cursor.faultMessage = message
    LOGGER:error("%s v%d pc=%d: %s (%s)",
        cursor.program.name, cursor.program.version, cursor.pc, message, reason)
    retire(state, cursor, "faulted")
end

local function secondsToSteps(world: World, seconds: number): integer
    if seconds <= 0 then return 0 end
    local timestep = world:getFixedTiming()
    if not timestep or timestep <= 0 then return 1 end
    local steps = math.floor(seconds / timestep + 0.5)
    if steps < 1 then steps = 1 end
    return steps
end

--- Run one cursor until it waits, finishes, or faults, returning the
--- instruction budget it has left for this step.
local function run(
    world: World,
    state: WorldState,
    cursor: Cursor,
    budget: integer
): integer
    local prog = cursor.program
    local code = prog.code
    local consts = prog.consts

    while true do
        budget = budget - 1
        if budget < 0 then
            faultCursor(state, cursor, "budgetExceeded",
                "exceeded " .. tostring(cursor.budget)
                .. " instructions in one step without waiting")
            return budget
        end

        local base = cursor.pc * seqprogram.STRIDE
        local op = code[base + 1]
        local a = code[base + 2]
        local b = code[base + 3]

        if op == seqprogram.END then
            retire(state, cursor, "completed")
            return budget

        elseif op == seqprogram.WAIT then
            local steps = a >= 0 and secondsToSteps(world, consts[a] as number) or b
            cursor.pc = cursor.pc + 1
            schedule(state, cursor, state.step + (steps > 0 and steps or 1))
            return budget

        elseif op == seqprogram.WAIT_SIGNAL then
            local channel = consts[a] as string
            cursor.pc = cursor.pc + 1
            cursor.waitChannel = channel
            cursor.wakeAt = nil
            park(state.channels, channel, cursor.slot)
            return budget

        elseif op == seqprogram.WAIT_QUERY then
            local name = consts[a] as string
            if not state.queries[name] then
                faultCursor(state, cursor, "unregisteredQuery",
                    "query '" .. name .. "' is not registered on this world")
                return budget
            end
            cursor.pc = cursor.pc + 1
            cursor.waitQuery = name
            cursor.waitCondition = b
            cursor.wakeAt = nil
            park(state.queryWaiters, name, cursor.slot)
            -- Test at the next step rather than here: a spawn or despawn
            -- from this step is still staged, so the query cannot answer
            -- for the world this cursor has already asked for.
            state.dirtyQueries[name] = true
            return budget

        elseif op == seqprogram.PLAY_TWEEN then
            local preset = consts[a] as string
            local spec = consts[b] as {any}
            local ref = spec[1] as sequence.EntityRef
            local id = cursor.bindings and cursor.bindings[ref.bindName]
            releaseTween(state, cursor)
            cursor.tweenOutcome = nil
            if not id or not world:isAlive(id) then
                -- A missing or dead actor is a game state, not a defect in
                -- the program. Nothing plays, and a following waitTween has
                -- its answer already.
                cursor.tweenOutcome = "targetLost"
            else
                local ok, result = pcall(tween.play, world, id, preset,
                    spec[2] as tween.PlaybackOptions)
                if not ok then
                    faultCursor(state, cursor, "unregisteredTween",
                        "tween preset '" .. preset .. "': " .. tostring(result))
                    return budget
                end
                cursor.tweenEntity = id
                cursor.tweenPlayback = result as integer
                state.tweenOwners[cursor.tweenPlayback] = cursor.slot
            end
            cursor.pc = cursor.pc + 1

        elseif op == seqprogram.WAIT_TWEEN then
            cursor.pc = cursor.pc + 1
            if cursor.tweenPlayback then
                cursor.waitingTween = true
                cursor.wakeAt = nil
                state.tweenWaiters[cursor.slot] = true
                return budget
            end
            -- Nothing to wait for: either no playTween ran or its target
            -- was already gone, and the outcome says which.

        elseif op == seqprogram.CALL then
            local name = consts[a] as string
            local action = state.actions[name]
            if not action then
                faultCursor(state, cursor, "unregisteredAction",
                    "action '" .. name .. "' is not registered on this world")
                return budget
            end
            local ctx = state.context
            if not ctx then
                ctx = {world = world, entity = contextEntity} as sequence.ActionContext
                state.context = ctx
            end
            ctx.handle = packHandle(cursor.slot, cursor.generation)
            ctx.owner = cursor.owner
            ctx.args = resolveArgs(world, state, cursor, b)
            ctx._cursor = cursor

            local ok, err = pcall(action, world, ctx) as (boolean, any)
            if not ok then
                faultCursor(state, cursor, "actionError", tostring(err))
                return budget
            end
            -- An action may cancel its own playback.
            if not cursor.alive then return budget end
            cursor.pc = cursor.pc + 1

        elseif op == seqprogram.EMIT then
            -- An emitted list is copied rather than borrowed: it leaves with
            -- the event, and an observer is entitled to keep it.
            local resolved = resolveArgs(world, state, cursor, b)
            local args: {any} = {}
            for i = 1, #resolved do args[i] = resolved[i] end
            world:emit(0, seqtypes.Event,
                consts[a] as string, args,
                packHandle(cursor.slot, cursor.generation))
            cursor.pc = cursor.pc + 1

        elseif op == seqprogram.JUMP then
            if b < 0 then
                cursor.pc = a
            else
                local regs = cursor.loopRegs
                if not regs then
                    regs = {}
                    cursor.loopRegs = regs
                end
                local remaining = regs[cursor.pc]
                if remaining == nil then
                    remaining = (prog.loopCounts and prog.loopCounts[cursor.pc]) or 1
                end
                remaining = remaining - 1
                if remaining > 0 then
                    regs[cursor.pc] = remaining
                    cursor.pc = a
                else
                    regs[cursor.pc] = nil
                    cursor.pc = cursor.pc + 1
                end
            end

        elseif op == seqprogram.FORK then
            -- The branch is queued for this same step rather than entered
            -- here: it runs once this cursor yields, which keeps a tree of
            -- branches breadth-first, off the Lua stack, and ordered by the
            -- scheduler like everything else.
            local child = allocCursor(state)
            child.program = prog
            seqregistry.retain(prog)
            child.pc = a
            child.owner = cursor.owner
            child.bindings = cursor.bindings
            child.budget = cursor.budget
            child.parentSlot = cursor.slot
            child.parentGeneration = cursor.generation

            local children = cursor.children
            if not children then
                children = {}
                cursor.children = children
            end
            children[child.slot] = true

            linkOwner(state, child)
            schedule(state, child, state.step)
            cursor.pc = b

        elseif op == seqprogram.JOIN then
            cursor.pc = cursor.pc + 1
            local children = cursor.children
            if children and next(children) ~= nil then
                -- No wake time: the last branch to finish schedules it.
                cursor.joining = true
                cursor.wakeAt = nil
                return budget
            end

        else
            faultCursor(state, cursor, "actionError",
                "unknown opcode " .. tostring(op))
            return budget
        end
    end
end

--- Run one cursor, arming its budget the first time it runs in a step.
local function advance(world: World, state: WorldState, cursor: Cursor)
    if cursor.budgetStep ~= state.step then
        cursor.budgetStep = state.step
        cursor.budgetLeft = cursor.budget
    end
    cursor.budgetLeft = run(world, state, cursor, cursor.budgetLeft)
end

-------------------------------------------------------------------------------
-- Playback API
-------------------------------------------------------------------------------

function sequence.signal(world: World, name: string): integer
    if type(name) ~= "string" or name == "" then
        error("sequence.signal requires a non-empty signal name", 2)
    end
    local state = stateFor(world)
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
    local blocked = stateFor(world).channels[name]
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
    local state = stateFor(world)
    local cursor = allocCursor(state)
    cursor.program = program as ProgramImpl
    cursor.pc = 0
    cursor.state = "running"
    seqregistry.retain(cursor.program)

    if options then
        cursor.owner = options.owner or 0
        cursor.bindings = options.bindings
        if options.budget then cursor.budget = options.budget end
    end

    linkOwner(state, cursor)

    -- The first instruction runs on the next fixed step, never inside play.
    schedule(state, cursor, state.step + 1)
    return packHandle(cursor.slot, cursor.generation)
end

function sequence.cancel(world: World, handle: sequence.Handle): boolean
    local state = stateFor(world)
    local cursor = resolve(state, handle)
    if not cursor or not cursor.alive then return false end
    retire(state, cursor, "cancelled")
    return true
end

-- Pause and resume apply to the whole branch tree, so suspending a cutscene
-- suspends everything it started.
local function pauseTree(state: WorldState, cursor: Cursor): boolean
    local slots = childSlots(cursor)
    for i = 1, #slots do
        local child = state.cursors[slots[i]]
        if child and child.alive then pauseTree(state, child) end
    end
    if cursor.state ~= "running" then return false end
    cursor.state = "paused"
    return true
end

local function resumeTree(state: WorldState, cursor: Cursor): boolean
    local slots = childSlots(cursor)
    for i = 1, #slots do
        local child = state.cursors[slots[i]]
        if child and child.alive then resumeTree(state, child) end
    end
    if cursor.state ~= "paused" then return false end
    cursor.state = "running"
    -- A cursor blocked on a signal or parked at a join has no wake time and
    -- stays where it is. Otherwise it keeps its heap entry, and if its wake
    -- time passed while it was paused it runs on the next step rather than
    -- immediately.
    if cursor.wakeAt and cursor.wakeAt <= state.step then
        schedule(state, cursor, state.step + 1)
    end
    return true
end

function sequence.pause(world: World, handle: sequence.Handle): boolean
    local state = stateFor(world)
    local cursor = resolve(state, handle)
    if not cursor or not cursor.alive then return false end
    return pauseTree(state, cursor)
end

function sequence.resume(world: World, handle: sequence.Handle): boolean
    local state = stateFor(world)
    local cursor = resolve(state, handle)
    if not cursor or not cursor.alive then return false end
    return resumeTree(state, cursor)
end

function sequence.status(world: World, handle: sequence.Handle): sequence.Status
    local state = stateFor(world)
    local cursor = resolve(state, handle)
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

function sequence.cancelOwnedBy(world: World, owner: integer): integer
    local state = stateFor(world)
    local owned = state.ownerIndex[owner]
    if not owned then return 0 end
    local slots: {integer} = {}
    for slot in pairs(owned) do slots[#slots + 1] = slot end
    table.sort(slots)
    local cancelled = 0
    for i = 1, #slots do
        local cursor = state.cursors[slots[i]]
        if cursor and cursor.alive then
            retire(state, cursor, "cancelled")
            cancelled = cancelled + 1
        end
    end
    return cancelled
end

function sequence.activeCount(world: World): integer
    local state = stateFor(world)
    local count = 0
    for _, cursor in pairs(state.cursors) do
        if cursor.alive then count = count + 1 end
    end
    return count
end

function sequence.playbacks(world: World): {sequence.Handle}
    local state = stateFor(world)
    local slots: {integer} = {}
    for slot, cursor in pairs(state.cursors) do
        if cursor.alive then slots[#slots + 1] = slot end
    end
    table.sort(slots)
    local handles: {sequence.Handle} = {}
    for i = 1, #slots do
        local cursor = state.cursors[slots[i]]
        handles[i] = packHandle(cursor.slot, cursor.generation)
    end
    return handles
end

function sequence.setInstructionBudget(world: World, instructions: integer)
    if type(instructions) ~= "number" or instructions < 1 then
        error("sequence.setInstructionBudget requires a positive count", 2)
    end
    stateFor(world).budget = instructions
end

function sequence.currentStep(world: World): integer
    return stateFor(world).step
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
-- Snapshot
--
-- A snapshot carries the exact program versions its live cursors are running,
-- so a load resumes the instructions each playback started with even when the
-- code has since been redefined. Programs restored this way are registered
-- under their original (name, version), leaving the newest version untouched
-- for later `play` calls.
-------------------------------------------------------------------------------

local function serializeProgram(prog: ProgramImpl): {string: any}
    return {
        name = prog.name,
        version = prog.version,
        code = prog.code,
        consts = prog.consts,
        loopSlots = prog.loopSlots,
        loopCounts = prog.loopCounts,
    }
end


local function saveState(world: World): any
    local state = states[world]
    if not state then return nil end

    local programs: {{string: any}} = {}
    local seenPrograms: {string: boolean} = {}
    local cursors: {{string: any}} = {}

    local slots: {integer} = {}
    for slot in pairs(state.cursors) do slots[#slots + 1] = slot end
    table.sort(slots)

    for i = 1, #slots do
        local cursor = state.cursors[slots[i]]
        if cursor.alive then
            local prog = cursor.program
            local key = prog.name .. "@" .. tostring(prog.version)
            if not seenPrograms[key] then
                seenPrograms[key] = true
                programs[#programs + 1] = serializeProgram(prog)
            end
            cursors[#cursors + 1] = {
                slot = cursor.slot,
                generation = cursor.generation,
                program = prog.name,
                version = prog.version,
                pc = cursor.pc,
                state = cursor.state,
                owner = cursor.owner,
                bindings = cursor.bindings,
                budget = cursor.budget,
                wakeAt = cursor.wakeAt,
                seq = cursor.seq,
                loopRegs = cursor.loopRegs,
                waitChannel = cursor.waitChannel,
                waitQuery = cursor.waitQuery,
                waitCondition = cursor.waitCondition,
                tweenEntity = cursor.tweenEntity,
                tweenPlayback = cursor.tweenPlayback,
                tweenOutcome = cursor.tweenOutcome,
                waitingTween = cursor.waitingTween,
                parentSlot = cursor.parentSlot,
                parentGeneration = cursor.parentGeneration,
                joining = cursor.joining,
            }
        end
    end

    return {
        version = SNAPSHOT_VERSION,
        step = state.step,
        seq = state.seq,
        budget = state.budget,
        nextSlot = state.nextSlot,
        generations = state.generations,
        programs = programs,
        cursors = cursors,
        pendingSignals = state.pendingSignals,
    }
end

local function loadState(world: World, value: any)
    -- Validate before touching live state: a rejected snapshot leaves the
    -- world's playbacks exactly as they were rather than half-cleared.
    if value ~= nil then
        if type(value) ~= "table" then
            error("tecs2d.sequence snapshot data must be a table", 2)
        end
        local header = value as {string: any}
        if header.version ~= SNAPSHOT_VERSION then
            error("unsupported tecs2d.sequence snapshot version: "
                .. tostring(header.version), 2)
        end
    end

    local state = stateFor(world)
    -- The playbacks about to be discarded give up their claim on the program
    -- versions they were running, so a version this world was the last user
    -- of goes with them.
    for _, cursor in pairs(state.cursors) do
        if cursor.alive then seqregistry.release(cursor.program) end
    end

    -- Actions stay registered: they are code, rebound by name, not data.
    state.cursors = {}
    state.freeSlots = {}
    state.ownerIndex = {}
    wakeheap.clear(state.heap)
    state.channels = {}
    state.pendingSignals = {}
    -- Registered queries are code, kept like actions; only the parked
    -- cursors are data.
    state.queryWaiters = {}
    state.dirtyQueries = {}
    state.tweenOwners = {}
    state.tweenWaiters = {}
    -- The call scratch points at cursors that are about to be replaced.
    state.context = nil
    state.argScratch = {}
    state.nextSlot = 1
    state.generations = {}
    state.step = 0
    state.seq = 0

    local data = value as {string: any}
    if not data then return end

    state.step = (data.step as integer) or 0
    state.seq = (data.seq as integer) or 0
    state.budget = (data.budget as integer) or DEFAULT_BUDGET
    state.nextSlot = (data.nextSlot as integer) or 1
    state.generations = (data.generations as {integer: integer}) or {}
    state.pendingSignals = (data.pendingSignals as {string}) or {}

    local restored: {string: ProgramImpl} = {}
    local programs = (data.programs as {{string: any}}) or {}
    for i = 1, #programs do
        local prog = seqregistry.restore(programs[i])
        restored[prog.name .. "@" .. tostring(prog.version)] = prog
    end

    local cursors = (data.cursors as {{string: any}}) or {}
    for i = 1, #cursors do
        local row = cursors[i]
        local key = (row.program as string) .. "@" .. tostring(row.version)
        local prog = restored[key]
        if prog then
            local cursor: Cursor = {
                slot = row.slot as integer,
                generation = row.generation as integer,
                alive = true,
                program = prog,
                pc = row.pc as integer,
                state = row.state as PlaybackState,
                owner = (row.owner as integer) or 0,
                bindings = row.bindings as {string: integer},
                budget = (row.budget as integer) or state.budget,
                wakeAt = row.wakeAt as integer,
                seq = row.seq as integer,
                loopRegs = row.loopRegs as {integer: integer},
                waitChannel = row.waitChannel as string,
                waitQuery = row.waitQuery as string,
                waitCondition = row.waitCondition as integer,
                tweenEntity = row.tweenEntity as integer,
                tweenPlayback = row.tweenPlayback as integer,
                tweenOutcome = row.tweenOutcome as TweenOutcome,
                waitingTween = row.waitingTween as boolean,
                parentSlot = row.parentSlot as integer,
                parentGeneration = row.parentGeneration as integer,
                joining = row.joining as boolean,
            }
            seqregistry.retain(prog)
            state.cursors[cursor.slot] = cursor
            linkOwner(state, cursor)
            if cursor.tweenPlayback then
                state.tweenOwners[cursor.tweenPlayback] = cursor.slot
            end
            -- Rebuild the wake indexes rather than serializing them. A
            -- cursor blocked on a signal or a query has no wake time and
            -- belongs in its wait index instead of the heap; one parked at a
            -- join belongs in neither and is woken by its last branch.
            if cursor.waitChannel then
                park(state.channels, cursor.waitChannel, cursor.slot)
            elseif cursor.waitQuery then
                park(state.queryWaiters, cursor.waitQuery, cursor.slot)
                -- The world this cursor parked against is gone, so its
                -- condition is re-tested against the restored one.
                state.dirtyQueries[cursor.waitQuery] = true
            elseif cursor.waitingTween then
                state.tweenWaiters[cursor.slot] = true
            elseif not cursor.joining then
                wakeheap.push(state.heap, cursor.wakeAt, cursor.seq,
                    packHandle(cursor.slot, cursor.generation))
            end
        else
            LOGGER:warn("dropping cursor for missing program %s", key)
        end
    end

    -- Restored slots in a stable order, so relinking and any recovery below
    -- happen the same way on every load.
    local liveSlots: {integer} = {}
    for slot in pairs(state.cursors) do liveSlots[#liveSlots + 1] = slot end
    table.sort(liveSlots)

    -- Relink the branch tree from the parent references the cursors carry.
    for i = 1, #liveSlots do
        local cursor = state.cursors[liveSlots[i]]
        local parentSlot = cursor.parentSlot
        if parentSlot then
            local parent = state.cursors[parentSlot]
            if parent and parent.generation == cursor.parentGeneration then
                local children = parent.children
                if not children then
                    children = {}
                    parent.children = children
                end
                children[cursor.slot] = true
            else
                cursor.parentSlot = nil
                cursor.parentGeneration = nil
            end
        end
    end

    -- A join whose branches all went missing would never wake, so give any
    -- such cursor back to the scheduler rather than stranding it.
    for i = 1, #liveSlots do
        local cursor = state.cursors[liveSlots[i]]
        if cursor.joining and (not cursor.children or next(cursor.children) == nil) then
            LOGGER:warn("%s v%d: join at pc=%d lost its branches; resuming",
                cursor.program.name, cursor.program.version, cursor.pc)
            cursor.joining = false
            schedule(state, cursor, state.step + 1)
        end
    end

    -- Slots the snapshot did not fill are free again.
    for slot = 1, state.nextSlot - 1 do
        if not state.cursors[slot] then
            state.freeSlots[#state.freeSlots + 1] = slot
        end
    end
end

-------------------------------------------------------------------------------
-- Plugin
-------------------------------------------------------------------------------

local function deliverSignals(state: WorldState)
    local pending = state.pendingSignals
    local count = #pending
    if count == 0 then return end
    state.pendingSignals = {}

    for i = 1, count do
        local blocked = state.channels[pending[i]]
        if blocked then
            -- Sort by slot so wake order is reproducible regardless of the
            -- hash iteration order.
            local slots: {integer} = {}
            for slot in pairs(blocked) do slots[#slots + 1] = slot end
            table.sort(slots)
            for j = 1, #slots do
                local cursor = state.cursors[slots[j]]
                if cursor and cursor.alive then
                    unlinkWaits(state, cursor)
                    schedule(state, cursor, state.step)
                end
            end
        end
    end
end

-- Re-test every query name that gained or lost entities since the last step,
-- and wake the cursors parked on it whose condition now holds. Names that
-- did not move are never looked at, so the cost tracks world churn rather
-- than the number of waiters.
local function deliverQueryWaits(state: WorldState)
    local dirty = state.dirtyQueries
    if next(dirty) == nil then return end
    state.dirtyQueries = {}

    local names: {string} = {}
    for name in pairs(dirty) do names[#names + 1] = name end
    table.sort(names)

    for i = 1, #names do
        local name = names[i]
        local waiting = state.queryWaiters[name]
        local query = state.queries[name]
        if waiting and query then
            local matched = query:count() > 0 and 1 or 0
            local slots: {integer} = {}
            for slot in pairs(waiting) do slots[#slots + 1] = slot end
            table.sort(slots)
            for j = 1, #slots do
                local cursor = state.cursors[slots[j]]
                if cursor and cursor.alive and cursor.waitCondition == matched then
                    unlinkWaits(state, cursor)
                    schedule(state, cursor, state.step)
                end
            end
        end
    end
end

-- Release every cursor whose tween has ended. The end events set the
-- outcome; this also asks the tween runtime directly, so a playback that
-- disappears without one still frees its waiter rather than parking it for
-- the life of the world.
local function deliverTweenWaits(world: World, state: WorldState)
    local waiting = state.tweenWaiters
    if next(waiting) == nil then return end

    local slots: {integer} = {}
    for slot in pairs(waiting) do slots[#slots + 1] = slot end
    table.sort(slots)

    for i = 1, #slots do
        local cursor = state.cursors[slots[i]]
        if not cursor or not cursor.alive then
            waiting[slots[i]] = nil
        elseif cursor.state == "running" then
            local outcome = cursor.tweenOutcome
            if not outcome
                and not tween.isPlaying(world, cursor.tweenEntity, cursor.tweenPlayback)
            then
                LOGGER:warn("%s v%d: tween %d ended without an event",
                    cursor.program.name, cursor.program.version, cursor.tweenPlayback)
                outcome = "targetLost"
                cursor.tweenOutcome = outcome
            end
            if outcome then
                unlinkWaits(state, cursor)
                releaseTween(state, cursor)
                schedule(state, cursor, state.step)
            end
        end
    end
end

local function tick(world: World, state: WorldState)
    state.step = state.step + 1
    local step = state.step

    deliverSignals(state)
    deliverQueryWaits(state)
    deliverTweenWaits(world, state)

    local heap <const> = state.heap
    while true do
        local due <const> = wakeheap.peek(heap)
        if not due or due > step then break end
        local _, seq, handle = wakeheap.pop(heap)
        local packed = handle as integer
        local slot = packed % SLOT_LIMIT
        local generation = (packed - slot) / SLOT_LIMIT
        local cursor = state.cursors[slot]
        -- Stale entry: the cursor was cancelled, retired, or rescheduled.
        if cursor
            and cursor.generation == generation
            and cursor.alive
            and cursor.seq == seq
        then
            if cursor.state == "paused" then
                -- Keep a paused cursor out of the heap; resume re-schedules.
                cursor.wakeAt = step
            else
                advance(world, state, cursor)
            end
        end
    end
end

function sequence.plugin(world: World)
    local state = stateFor(world)

    world:addSystem({
        name = "sequence.Advance",
        phase = tecs.phases.FixedFirst,
        run = function()
            tick(world, state)
        end,
    })

    world:addSnapshotHandler({
        name = "tecs2d.sequence",
        save = function(w: World): any
            return saveState(w)
        end,
        load = function(w: World, value: any)
            loadState(w, value)
        end,
    })

    -- Owner lifetime: a despawned owner cancels the playbacks it governs.
    world:observe(0, tecs.builtins.OnDespawn, function(event: tecs.builtins.OnDespawn)
        if state.ownerIndex[event.entity] then
            sequence.cancelOwnedBy(world, event.entity)
        end
    end)

    -- How a tween ended is only knowable from the event that ends it. The
    -- cursor records it and waits for the step boundary, so a waiter never
    -- resumes in the middle of another system's frame.
    local function endTween(slotOwner: integer, playback: integer, outcome: TweenOutcome)
        local cursor = state.cursors[slotOwner]
        if not cursor or not cursor.alive then return end
        if cursor.tweenPlayback ~= playback then return end
        cursor.tweenOutcome = outcome
    end

    world:observe(0, tween.TweenComplete, function(event: tween.TweenComplete)
        local owner = state.tweenOwners[event.playback]
        if owner then endTween(owner, event.playback, "completed") end
    end)

    world:observe(0, tween.TweenCancelled, function(event: tween.TweenCancelled)
        local owner = state.tweenOwners[event.playback]
        if owner then endTween(owner, event.playback, event.reason as TweenOutcome) end
    end)
end

return sequence
