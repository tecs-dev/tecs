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
local logging <const> = require("tecs.utils.logging")

local type World = tecs.World

local LOGGER <const> = logging.getLogger("tecs2d.sequence")

local floor <const> = math.floor

-- Handle packing. A handle is slot + generation * SLOT_LIMIT, so it stays a
-- plain integer that survives snapshots and compares by value.
local SLOT_LIMIT <const> = 1048576

local DEFAULT_BUDGET <const> = 512

-- Layout version of this module's snapshot payload. Bumped whenever a cursor
-- gains state an older reader would silently ignore, so a save written by a
-- newer build is rejected rather than restored as a half-cursor.
local SNAPSHOT_VERSION <const> = 1

-- Instruction opcodes. Code is a flat array with stride 3: (op, a, b).
local OP_WAIT <const> = 1     -- a = const index holding seconds, or -1
                              -- b = literal step count when a is -1
local OP_CALL <const> = 2     -- a = const index of action name
                              -- b = const index of args array
local OP_EMIT <const> = 3     -- a = const index of event name
                              -- b = const index of args array
local OP_JUMP <const> = 4     -- a = target pc
                              -- b = loop register, or -1 for unconditional
local OP_END <const> = 5
local OP_WAIT_SIGNAL <const> = 6  -- a = const index of signal name

local STRIDE <const> = 3

--- Why a cursor stopped running.
local enum FaultReason
    --- A `call` named an action that is not registered on this world.
    "unregisteredAction"
    --- A registered action raised.
    "actionError"
    --- The cursor exceeded its per-step instruction budget.
    "budgetExceeded"
end

--- The lifecycle state of one playback.
local enum PlaybackState
    "running"
    "paused"
    "completed"
    "cancelled"
    "faulted"
end

local record sequence
    ---------------------------------------------------------------------------
    -- Types
    ---------------------------------------------------------------------------

    --- Why a cursor stopped running.
    type FaultReason = FaultReason

    --- The lifecycle state of one playback.
    type PlaybackState = PlaybackState

    --- A compiled, immutable program. Produced by `define`, shared by every
    --- playback of it, and reference counted.
    ---
    --- Redefining a name compiles a new version. Playbacks already running
    --- keep the version they started with, so a hot reload continues rather
    --- than resuming against changed instructions. Later `play` calls use the
    --- newest version, and a superseded version is released once its last
    --- playback finishes.
    interface Program
        --- The name passed to `define`.
        name: string

        --- Monotonic version, starting at 1. Incremented per redefinition.
        version: integer
    end

    --- One authored step. Produced by the node constructors below; treat the
    --- returned value as opaque and do not reuse a node across programs.
    interface Node end

    --- A reference to an entity supplied at `play` time. Resolved when the
    --- instruction that uses it runs, not when the program is defined.
    record EntityRef
        --- Name of the binding this reference resolves.
        bindName: string
        --- Marker distinguishing a reference from an ordinary table argument.
        isBinding: boolean
    end

    --- A generation-checked reference to one playback. Remains meaningful
    --- across a snapshot load: a handle refers to the same playback before
    --- and after a restore. A handle whose playback the snapshot did not
    --- carry reports no status at all, the same as a handle this world
    --- never issued.
    type Handle = integer

    --- Constants a `call` passes to its action: numbers, strings, booleans,
    --- and arrays or maps composed of those, plus `bind(name)` references,
    --- which resolve to entity ids when the instruction runs. Anything else
    --- (functions, cdata, entities) is rejected by `define`, because a
    --- program has to survive a snapshot.
    type Argument = any

    --- Options for `play`.
    record PlayOptions
        --- Entity whose lifetime governs the playback. When it despawns, the
        --- playback is cancelled. Omit for a world-scoped sequence.
        owner: integer

        --- Entities the program acts on, addressed by `sequence.bind(name)`.
        bindings: {string: integer}

        --- Per-step instruction budget for this playback. Defaults to the
        --- world's configured budget. See `setInstructionBudget`.
        budget: integer
    end

    --- What a registered action receives.
    record ActionContext
        --- The world this playback belongs to.
        world: World

        --- The playback, for `status` or `cancel` from inside an action.
        handle: Handle

        --- The `owner` supplied at `play`, or 0 for a world-scoped sequence.
        owner: integer

        --- Constants supplied by the `call` node, with any `bind` references
        --- already resolved to entity ids.
        args: {any}

        --- Resolve a named binding. Returns nil when the binding was not
        --- supplied or its entity is no longer alive.
        entity: function(self: ActionContext, name: string): integer

        --- Internal cursor reference. Not part of the supported surface.
        _cursor: any
    end

    --- A registered effect. Runs synchronously and must return before the
    --- cursor advances; it may not yield.
    ---
    --- Raising faults the playback with `actionError`. Mutations the action
    --- already made are kept: the sequencer does not roll them back.
    type Action = function(world: World, ctx: ActionContext)

    --- Emitted by an `emit` step, at address 0.
    record Event is tecs.Event
        --- Name supplied to `sequence.emit`.
        name: string
        --- Arguments supplied to `sequence.emit`, with bindings resolved.
        args: {any}
        --- The playback that emitted it.
        handle: Handle

        init: function(self: Event, name: string, args: {any}, handle: Handle)
    end

    --- A playback's current state.
    record Status
        state: PlaybackState

        --- Program name and version this playback is running.
        program: string
        version: integer

        --- Instruction index, for disassembly and debugging.
        pc: integer

        --- Fixed step this playback next runs on. Nil when it is blocked on
        --- a signal rather than a time.
        wakeAt: integer

        --- Signal name this playback is blocked on, when it is.
        waitingFor: string

        --- Set when `state` is `"faulted"`.
        fault: FaultReason
        faultMessage: string
    end

    ---------------------------------------------------------------------------
    -- Authoring
    ---------------------------------------------------------------------------

    --- Compile a program under a stable symbolic name.
    define: function(name: string, nodes: {Node}): Program

    --- Look up the newest version of a defined program.
    program: function(name: string): Program

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

    ---------------------------------------------------------------------------
    -- Configuration and tooling
    ---------------------------------------------------------------------------

    --- Per-step instruction budget for playbacks that do not set their own.
    setInstructionBudget: function(world: World, instructions: integer)

    --- The world's current fixed step, as counted by the sequencer.
    currentStep: function(world: World): integer

    --- Render a program as readable instructions.
    disassemble: function(program: Program): string

    --- Install the sequencer. Auto-installed by `tecs2d.run`.
    plugin: function(world: World)
end

-------------------------------------------------------------------------------
-- Program representation
-------------------------------------------------------------------------------

local record ProgramImpl is sequence.Program
    name: string
    version: integer
    code: {integer}
    consts: {any}
    loopSlots: integer
    loopCounts: {integer: integer}
end

function sequence.Event.init(
    e: sequence.Event,
    name: string,
    args: {any},
    handle: sequence.Handle
)
    e.name = name
    e.args = args
    e.handle = handle
end

tecs.newEvent(sequence.Event)

-- Programs are process-global and keyed by name. Every version ever compiled
-- stays reachable by (name, version) so a snapshot taken against an older
-- version can restore a cursor that continues to run it.
local programsByName: {string: ProgramImpl} = {}
local programVersions: {string: {integer: ProgramImpl}} = {}

-------------------------------------------------------------------------------
-- Authoring nodes
-------------------------------------------------------------------------------

local record NodeImpl is sequence.Node
    kind: string
    text: string
    number: number
    args: {any}
    nodes: {sequence.Node}
    count: integer
end

function sequence.bind(name: string): sequence.EntityRef
    if type(name) ~= "string" or name == "" then
        error("sequence.bind requires a non-empty binding name", 2)
    end
    return {bindName = name, isBinding = true}
end

local function isEntityRef(value: any): boolean
    if type(value) ~= "table" then return false end
    local ref = value as sequence.EntityRef
    return ref.isBinding == true and type(ref.bindName) == "string"
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

-------------------------------------------------------------------------------
-- Compiler
-------------------------------------------------------------------------------

local record Compiler
    code: {integer}
    consts: {any}
    constIndex: {any: integer}
    loopSlots: integer
    loopCounts: {integer: integer}
end

local function intern(c: Compiler, value: any): integer
    -- Only scalars can be deduplicated by value; tables are appended as-is.
    if type(value) ~= "table" then
        local existing = c.constIndex[value]
        if existing then return existing end
    end
    local index = #c.consts + 1
    c.consts[index] = value
    if type(value) ~= "table" then
        c.constIndex[value] = index
    end
    return index
end

local function emitOp(c: Compiler, op: integer, a: integer, b: integer): integer
    local pc = floor(#c.code / STRIDE)
    c.code[#c.code + 1] = op
    c.code[#c.code + 1] = a
    c.code[#c.code + 1] = b
    return pc
end

local compileBlock: function(c: Compiler, nodes: {sequence.Node}, depth: integer)

local function compileNode(c: Compiler, node: NodeImpl, depth: integer)
    local kind = node.kind
    if kind == "call" then
        emitOp(c, OP_CALL, intern(c, node.text), intern(c, node.args))
    elseif kind == "emit" then
        emitOp(c, OP_EMIT, intern(c, node.text), intern(c, node.args))
    elseif kind == "wait" then
        emitOp(c, OP_WAIT, intern(c, node.number), -1)
    elseif kind == "waitSignal" then
        emitOp(c, OP_WAIT_SIGNAL, intern(c, node.text), -1)
    elseif kind == "waitSteps" then
        emitOp(c, OP_WAIT, -1, node.number as integer)
    elseif kind == "loop" then
        local slot = depth + 1
        if slot > c.loopSlots then c.loopSlots = slot end
        local top = floor(#c.code / STRIDE)
        compileBlock(c, node.nodes, slot)
        -- A nil count loops forever; the register is unused in that case.
        local jumpPc = emitOp(c, OP_JUMP, top, node.count and slot or -1)
        -- Counts are keyed by the jump's own pc, so a cursor reaching that
        -- jump for the first time knows what to seed its register with.
        if node.count then c.loopCounts[jumpPc] = node.count end
    else
        error("sequence: unknown node kind '" .. tostring(kind) .. "'")
    end
end

compileBlock = function(c: Compiler, nodes: {sequence.Node}, depth: integer)
    for i = 1, #nodes do
        local node = nodes[i] as NodeImpl
        if type(node) ~= "table" or node.kind == nil then
            error("sequence: entry " .. tostring(i) .. " is not a sequence node")
        end
        compileNode(c, node, depth)
    end
end

function sequence.define(name: string, nodes: {sequence.Node}): sequence.Program
    if type(name) ~= "string" or name == "" then
        error("sequence.define requires a non-empty program name", 2)
    end
    if type(nodes) ~= "table" then
        error("sequence.define requires an array of nodes", 2)
    end

    local c: Compiler = {
        code = {},
        consts = {},
        constIndex = {},
        loopSlots = 0,
        loopCounts = {},
    }
    compileBlock(c, nodes, 0)
    emitOp(c, OP_END, -1, -1)

    local previous = programsByName[name]
    local prog: ProgramImpl = {
        name = name,
        version = previous and previous.version + 1 or 1,
        code = c.code,
        consts = c.consts,
        loopSlots = c.loopSlots,
        loopCounts = c.loopCounts,
    }

    programsByName[name] = prog
    local versions = programVersions[name]
    if not versions then
        versions = {}
        programVersions[name] = versions
    end
    versions[prog.version] = prog
    return prog
end

function sequence.program(name: string): sequence.Program
    return programsByName[name]
end

-------------------------------------------------------------------------------
-- Per-world state: cursor arena, action registry, scheduler
-------------------------------------------------------------------------------

local record Cursor
    -- Arena bookkeeping
    slot: integer
    generation: integer
    alive: boolean

    program: ProgramImpl
    pc: integer
    state: PlaybackState

    owner: integer
    bindings: {string: integer}
    budget: integer

    wakeAt: integer
    seq: integer
    loopRegs: {integer: integer}
    waitChannel: string

    fault: FaultReason
    faultMessage: string
end

local record HeapEntry
    wakeAt: integer
    seq: integer
    slot: integer
    generation: integer
end

local record WorldState
    cursors: {integer: Cursor}
    freeSlots: {integer}
    nextSlot: integer
    generations: {integer: integer}

    actions: {string: sequence.Action}
    step: integer
    seq: integer
    budget: integer

    heap: {HeapEntry}
    heapSize: integer

    -- Cursors blocked on a signal are held here rather than in the heap:
    -- they have no wake time until the signal arrives.
    channels: {string: {integer: boolean}}
    pendingSignals: {string}

    ownerIndex: {integer: {integer: boolean}}
end

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
        heap = {},
        heapSize = 0,
        channels = {},
        pendingSignals = {},
        ownerIndex = {},
    }
    states[world] = state
    return state
end

-------------------------------------------------------------------------------
-- Deterministic min-heap keyed on (wakeAt, seq)
-------------------------------------------------------------------------------

local function heapLess(a: HeapEntry, b: HeapEntry): boolean
    if a.wakeAt ~= b.wakeAt then return a.wakeAt < b.wakeAt end
    return a.seq < b.seq
end

local function heapPush(state: WorldState, entry: HeapEntry)
    local heap = state.heap
    local i = state.heapSize + 1
    state.heapSize = i
    heap[i] = entry
    while i > 1 do
        local parent = floor(i / 2)
        if heapLess(heap[i], heap[parent]) then
            heap[i], heap[parent] = heap[parent], heap[i]
            i = parent
        else
            break
        end
    end
end

local function heapPop(state: WorldState): HeapEntry
    local heap = state.heap
    local size = state.heapSize
    if size == 0 then return nil end
    local top = heap[1]
    heap[1] = heap[size]
    heap[size] = nil
    size = size - 1
    state.heapSize = size

    local i = 1
    while true do
        local left = i * 2
        local right = left + 1
        local smallest = i
        if left <= size and heapLess(heap[left], heap[smallest]) then smallest = left end
        if right <= size and heapLess(heap[right], heap[smallest]) then smallest = right end
        if smallest == i then break end
        heap[i], heap[smallest] = heap[smallest], heap[i]
        i = smallest
    end
    return top
end

-------------------------------------------------------------------------------
-- Arena
-------------------------------------------------------------------------------

local function packHandle(slot: integer, generation: integer): sequence.Handle
    return slot + generation * SLOT_LIMIT
end

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

local function unlinkChannel(state: WorldState, cursor: Cursor)
    local channel = cursor.waitChannel
    if not channel then return end
    cursor.waitChannel = nil
    local blocked = state.channels[channel]
    if not blocked then return end
    blocked[cursor.slot] = nil
    if next(blocked) == nil then state.channels[channel] = nil end
end

local function unlinkOwner(state: WorldState, cursor: Cursor)
    if cursor.owner == 0 then return end
    local owned = state.ownerIndex[cursor.owner]
    if owned then
        owned[cursor.slot] = nil
        if next(owned) == nil then state.ownerIndex[cursor.owner] = nil end
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
    unlinkChannel(state, cursor)
    unlinkOwner(state, cursor)
    state.freeSlots[#state.freeSlots + 1] = cursor.slot
end

-------------------------------------------------------------------------------
-- Scheduling
-------------------------------------------------------------------------------

local function schedule(state: WorldState, cursor: Cursor, wakeAt: integer)
    state.seq = state.seq + 1
    cursor.wakeAt = wakeAt
    cursor.seq = state.seq
    heapPush(state, {
        wakeAt = wakeAt,
        seq = cursor.seq,
        slot = cursor.slot,
        generation = cursor.generation,
    })
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

local function resolveArgs(world: World, cursor: Cursor, raw: {any}): {any}
    local out: {any} = {}
    for i = 1, #raw do
        local value = raw[i]
        if isEntityRef(value) then
            local name = (value as sequence.EntityRef).bindName
            local id = cursor.bindings and cursor.bindings[name]
            out[i] = (id and world:isAlive(id)) and id or nil
        else
            out[i] = value
        end
    end
    return out
end

local function faultCursor(
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

--- Run one cursor until it waits, finishes, or faults.
local function advance(world: World, state: WorldState, cursor: Cursor)
    local prog = cursor.program
    local code = prog.code
    local consts = prog.consts
    local budget = cursor.budget

    while true do
        budget = budget - 1
        if budget < 0 then
            faultCursor(state, cursor, "budgetExceeded",
                "exceeded " .. tostring(cursor.budget)
                .. " instructions in one step without waiting")
            return
        end

        local base = cursor.pc * STRIDE
        local op = code[base + 1]
        local a = code[base + 2]
        local b = code[base + 3]

        if op == OP_END then
            retire(state, cursor, "completed")
            return

        elseif op == OP_WAIT then
            local steps = a >= 0 and secondsToSteps(world, consts[a] as number) or b
            cursor.pc = cursor.pc + 1
            schedule(state, cursor, state.step + (steps > 0 and steps or 1))
            return

        elseif op == OP_WAIT_SIGNAL then
            local channel = consts[a] as string
            cursor.pc = cursor.pc + 1
            cursor.waitChannel = channel
            cursor.wakeAt = nil
            local blocked = state.channels[channel]
            if not blocked then
                blocked = {}
                state.channels[channel] = blocked
            end
            blocked[cursor.slot] = true
            return

        elseif op == OP_CALL then
            local name = consts[a] as string
            local action = state.actions[name]
            if not action then
                faultCursor(state, cursor, "unregisteredAction",
                    "action '" .. name .. "' is not registered on this world")
                return
            end
            local ctx: sequence.ActionContext = {
                world = world,
                handle = packHandle(cursor.slot, cursor.generation),
                owner = cursor.owner,
                args = resolveArgs(world, cursor, consts[b] as {any}),
                entity = contextEntity,
                _cursor = cursor,
            }
            local result: {any} = {pcall(action, world, ctx)}
            if not result[1] then
                faultCursor(state, cursor, "actionError", tostring(result[2]))
                return
            end
            -- An action may cancel its own playback.
            if not cursor.alive then return end
            cursor.pc = cursor.pc + 1

        elseif op == OP_EMIT then
            world:emit(0, sequence.Event,
                consts[a] as string,
                resolveArgs(world, cursor, consts[b] as {any}),
                packHandle(cursor.slot, cursor.generation))
            cursor.pc = cursor.pc + 1

        elseif op == OP_JUMP then
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

        else
            faultCursor(state, cursor, "actionError",
                "unknown opcode " .. tostring(op))
            return
        end
    end
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

    if options then
        cursor.owner = options.owner or 0
        cursor.bindings = options.bindings
        if options.budget then cursor.budget = options.budget end
    end

    if cursor.owner ~= 0 then
        local owned = state.ownerIndex[cursor.owner]
        if not owned then
            owned = {}
            state.ownerIndex[cursor.owner] = owned
        end
        owned[cursor.slot] = true
    end

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

function sequence.pause(world: World, handle: sequence.Handle): boolean
    local state = stateFor(world)
    local cursor = resolve(state, handle)
    if not cursor or not cursor.alive or cursor.state ~= "running" then return false end
    cursor.state = "paused"
    return true
end

function sequence.resume(world: World, handle: sequence.Handle): boolean
    local state = stateFor(world)
    local cursor = resolve(state, handle)
    if not cursor or not cursor.alive or cursor.state ~= "paused" then return false end
    cursor.state = "running"
    -- A cursor blocked on a signal has no wake time and stays parked on its
    -- channel. Otherwise it keeps its heap entry, and if its wake time passed
    -- while it was paused it runs on the next step rather than immediately.
    if cursor.wakeAt and cursor.wakeAt <= state.step then
        schedule(state, cursor, state.step + 1)
    end
    return true
end

function sequence.status(world: World, handle: sequence.Handle): sequence.Status
    local state = stateFor(world)
    local cursor = resolve(state, handle)
    if not cursor then return nil end
    local status: sequence.Status = {
        state = cursor.state,
        program = cursor.program.name,
        version = cursor.program.version,
        pc = cursor.pc,
        wakeAt = cursor.alive and cursor.wakeAt or nil,
        waitingFor = cursor.alive and cursor.waitChannel or nil,
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

local function describeArgs(args: {any}): string
    if not args or #args == 0 then return "" end
    local parts: {string} = {}
    for i = 1, #args do
        local value = args[i]
        if isEntityRef(value) then
            parts[#parts + 1] = "bind(" .. (value as sequence.EntityRef).bindName .. ")"
        elseif type(value) == "string" then
            parts[#parts + 1] = string.format("%q", value as string)
        else
            parts[#parts + 1] = tostring(value)
        end
    end
    return ", " .. table.concat(parts, ", ")
end

function sequence.disassemble(program: sequence.Program): string
    local prog = program as ProgramImpl
    if type(prog) ~= "table" or prog.code == nil then
        error("sequence.disassemble requires a program from sequence.define", 2)
    end
    local out: {string} = {
        string.format("%s v%d  (%d instructions)",
            prog.name, prog.version, floor(#prog.code / STRIDE)),
    }
    local counts = prog.loopCounts
    for pc = 0, floor(#prog.code / STRIDE) - 1 do
        local base = pc * STRIDE
        local op = prog.code[base + 1]
        local a = prog.code[base + 2]
        local b = prog.code[base + 3]
        local text: string
        if op == OP_WAIT then
            text = a >= 0
                and string.format("WAIT      %ss", tostring(prog.consts[a]))
                or string.format("WAIT      %d step(s)", b)
        elseif op == OP_WAIT_SIGNAL then
            text = string.format("WAITSIG   %q", prog.consts[a] as string)
        elseif op == OP_CALL then
            text = string.format("CALL      %q%s",
                prog.consts[a] as string, describeArgs(prog.consts[b] as {any}))
        elseif op == OP_EMIT then
            text = string.format("EMIT      %q%s",
                prog.consts[a] as string, describeArgs(prog.consts[b] as {any}))
        elseif op == OP_JUMP then
            local count = counts and counts[pc]
            text = string.format("JUMP      -> %d  (%s)", a,
                b < 0 and "forever" or ("x" .. tostring(count or 1)))
        elseif op == OP_END then
            text = "END"
        else
            text = "?? " .. tostring(op)
        end
        out[#out + 1] = string.format("%4d  %s", pc, text)
    end
    return table.concat(out, "\n")
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

local function restoreProgram(data: {string: any}): ProgramImpl
    local name <const> = data.name as string
    local version <const> = data.version as integer
    local versions = programVersions[name]
    if versions and versions[version] then
        return versions[version]
    end

    local prog: ProgramImpl = {
        name = name,
        version = version,
        code = data.code as {integer},
        consts = data.consts as {any},
        loopSlots = data.loopSlots as integer,
        loopCounts = (data.loopCounts as {integer: integer}) or {},
    }
    if not versions then
        versions = {}
        programVersions[name] = versions
    end
    versions[version] = prog
    -- A restored version never displaces a newer definition.
    local newest = programsByName[name]
    if not newest or newest.version < version then
        programsByName[name] = prog
    end
    return prog
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
    -- Actions stay registered: they are code, rebound by name, not data.
    state.cursors = {}
    state.freeSlots = {}
    state.ownerIndex = {}
    state.heap = {}
    state.heapSize = 0
    state.channels = {}
    state.pendingSignals = {}
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
        local prog = restoreProgram(programs[i])
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
            }
            state.cursors[cursor.slot] = cursor
            if cursor.owner ~= 0 then
                local owned = state.ownerIndex[cursor.owner]
                if not owned then
                    owned = {}
                    state.ownerIndex[cursor.owner] = owned
                end
                owned[cursor.slot] = true
            end
            -- Rebuild the wake indexes rather than serializing them. A
            -- signal-blocked cursor has no wake time and belongs in its
            -- channel instead of the heap.
            if cursor.waitChannel then
                local blocked = state.channels[cursor.waitChannel]
                if not blocked then
                    blocked = {}
                    state.channels[cursor.waitChannel] = blocked
                end
                blocked[cursor.slot] = true
            else
                heapPush(state, {
                    wakeAt = cursor.wakeAt,
                    seq = cursor.seq,
                    slot = cursor.slot,
                    generation = cursor.generation,
                })
            end
        else
            LOGGER:warn("dropping cursor for missing program %s", key)
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
                    unlinkChannel(state, cursor)
                    schedule(state, cursor, state.step)
                end
            end
        end
    end
end

local function tick(world: World, state: WorldState)
    state.step = state.step + 1
    local step = state.step

    deliverSignals(state)

    while state.heapSize > 0 do
        local top = state.heap[1]
        if top.wakeAt > step then break end
        local entry = heapPop(state)
        local cursor = state.cursors[entry.slot]
        -- Stale entry: the cursor was cancelled, retired, or rescheduled.
        if cursor
            and cursor.generation == entry.generation
            and cursor.alive
            and cursor.seq == entry.seq
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
end

return sequence
