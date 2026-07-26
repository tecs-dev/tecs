--- Cursor lifetime: the arena, the wait indexes, and the branch tree.
---
--- These belong together because they are mutually recursive. Retiring a
--- cursor cancels its branches and may fault its parent, and faulting one
--- retires it; splitting them would need an indirection through a table in
--- the middle of the hot path to say the same thing.
---
--- A finished cursor frees its slot immediately, so the arena is bounded by
--- peak concurrency rather than by every playback ever started. Its record
--- survives until the slot is handed out again, which is what lets `status`
--- report a final state; once reused, the generation check makes the old
--- handle report nothing rather than another playback's state.

local tecs <const> = require("tecs")
local logging <const> = require("tecs.utils.logging")
local seqclock <const> = require("tecs2d.sequence.internal.clock")
local seqregistry <const> = require("tecs2d.sequence.internal.registry")
local seqtypes <const> = require("tecs2d.sequence.internal.types")

local type World = tecs.World
local type Cursor = seqtypes.Cursor
local type WorldState = seqtypes.WorldState
local type FaultReason = seqtypes.FaultReason
local type PlaybackState = seqtypes.PlaybackState

local LOGGER <const> = logging.getLogger("tecs2d.sequence")

-- Handle packing. A handle is slot + generation * SLOT_LIMIT, so it stays a
-- plain integer that survives snapshots and compares by value.
local SLOT_LIMIT <const> = 1048576

local DEFAULT_BUDGET <const> = 512

local record cursors
    SLOT_LIMIT: integer
    DEFAULT_BUDGET: integer

    stateFor: function(world: World): WorldState
    packHandle: function(slot: integer, generation: integer): seqtypes.Handle
    resolve: function(state: WorldState, handle: seqtypes.Handle): Cursor
    alloc: function(state: WorldState): Cursor
    schedule: function(state: WorldState, cursor: Cursor, wakeAt: integer)

    park: function(index: {string: {integer: boolean}}, key: string, slot: integer)
    unpark: function(index: {string: {integer: boolean}}, key: string, slot: integer)
    unlinkWaits: function(state: WorldState, cursor: Cursor)
    releaseTween: function(state: WorldState, cursor: Cursor)
    linkOwner: function(state: WorldState, cursor: Cursor)
    childSlots: function(cursor: Cursor): {integer}

    retire: function(state: WorldState, cursor: Cursor, finalState: PlaybackState)
    fault: function(state: WorldState, cursor: Cursor, reason: FaultReason, message: string)

    pauseTree: function(state: WorldState, cursor: Cursor): boolean
    resumeTree: function(state: WorldState, cursor: Cursor): boolean
end

local states: {World: WorldState} =
    setmetatable({}, {__mode = "k"} as metatable<{World: WorldState}>)

function cursors.stateFor(world: World): WorldState
    local state = states[world]
    if state then return state end
    state = {
        cursors = {},
        freeSlots = {},
        nextSlot = 1,
        generations = {},
        actions = {},
        budget = DEFAULT_BUDGET,
        fixed = seqclock.new(),
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

function cursors.packHandle(slot: integer, generation: integer): seqtypes.Handle
    return slot + generation * SLOT_LIMIT
end

function cursors.schedule(state: WorldState, cursor: Cursor, wakeAt: integer)
    cursor.wakeAt = wakeAt
    cursor.seq = seqclock.schedule(state.fixed, wakeAt,
        cursors.packHandle(cursor.slot, cursor.generation))
end

function cursors.resolve(state: WorldState, handle: seqtypes.Handle): Cursor
    if type(handle) ~= "number" then return nil end
    local slot = handle % SLOT_LIMIT
    local generation = (handle - slot) / SLOT_LIMIT
    local cursor = state.cursors[slot]
    if not cursor or cursor.generation ~= generation then return nil end
    return cursor
end

function cursors.alloc(state: WorldState): Cursor
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

function cursors.park(
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

function cursors.unpark(
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
function cursors.unlinkWaits(state: WorldState, cursor: Cursor)
    local channel = cursor.waitChannel
    if channel then
        cursor.waitChannel = nil
        cursors.unpark(state.channels, channel, cursor.slot)
    end
    local queryName = cursor.waitQuery
    if queryName then
        cursor.waitQuery = nil
        cursor.waitCondition = nil
        cursors.unpark(state.queryWaiters, queryName, cursor.slot)
    end
    if cursor.waitingTween then
        cursor.waitingTween = false
        state.tweenWaiters[cursor.slot] = nil
    end
end

-- Drop the cursor's claim on a tween token, so an end event for a playback
-- nothing is following no longer finds an owner.
function cursors.releaseTween(state: WorldState, cursor: Cursor)
    local token = cursor.tweenPlayback
    if not token then return end
    if state.tweenOwners[token] == cursor.slot then
        state.tweenOwners[token] = nil
    end
    cursor.tweenPlayback = nil
    cursor.tweenEntity = nil
end

function cursors.linkOwner(state: WorldState, cursor: Cursor)
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
function cursors.childSlots(cursor: Cursor): {integer}
    local slots: {integer} = {}
    local children = cursor.children
    if not children then return slots end
    for slot in pairs(children) do slots[#slots + 1] = slot end
    table.sort(slots)
    return slots
end

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
        cursors.fault(state, parent, "branchFaulted",
            "branch at pc=" .. tostring(cursor.pc) .. " faulted: "
            .. tostring(cursor.faultMessage))
        return
    end

    if parent.joining and (not children or next(children) == nil) then
        parent.joining = false
        cursors.schedule(state, parent, state.fixed.step)
    end
end

-- A finished cursor frees its slot immediately, so the arena is bounded by
-- peak concurrency rather than by every sequence ever played. Its record
-- stays until the slot is handed out again, which lets `status` report the
-- final state; once reused, the generation check makes the old handle report
-- nil instead of another playback's state.
function cursors.retire(state: WorldState, cursor: Cursor, finalState: PlaybackState)
    if not cursor.alive then return end
    cursor.state = finalState
    cursor.alive = false
    cursor.joining = false
    cursors.unlinkWaits(state, cursor)
    cursors.releaseTween(state, cursor)
    unlinkOwner(state, cursor)
    seqregistry.release(cursor.program)

    -- A subtree dies from the root down: branches are cancelled first, so
    -- each one finds a parent already gone and reports nothing back up.
    local children = cursor.children
    if children and next(children) ~= nil then
        local slots = cursors.childSlots(cursor)
        for i = 1, #slots do
            local child = state.cursors[slots[i]]
            if child and child.alive then cursors.retire(state, child, "cancelled") end
        end
    end
    cursor.children = nil

    detachFromParent(state, cursor, finalState)
    state.freeSlots[#state.freeSlots + 1] = cursor.slot
end

function cursors.fault(
    state: WorldState,
    cursor: Cursor,
    reason: FaultReason,
    message: string
)
    cursor.fault = reason
    cursor.faultMessage = message
    LOGGER:error("%s v%d pc=%d: %s (%s)",
        cursor.program.name, cursor.program.version, cursor.pc, message, reason)
    cursors.retire(state, cursor, "faulted")
end

-- Pause and resume apply to the whole branch tree, so suspending a cutscene
-- suspends everything it started.
function cursors.pauseTree(state: WorldState, cursor: Cursor): boolean
    local slots = cursors.childSlots(cursor)
    for i = 1, #slots do
        local child = state.cursors[slots[i]]
        if child and child.alive then cursors.pauseTree(state, child) end
    end
    if cursor.state ~= "running" then return false end
    cursor.state = "paused"
    return true
end

function cursors.resumeTree(state: WorldState, cursor: Cursor): boolean
    local slots = cursors.childSlots(cursor)
    for i = 1, #slots do
        local child = state.cursors[slots[i]]
        if child and child.alive then cursors.resumeTree(state, child) end
    end
    if cursor.state ~= "paused" then return false end
    cursor.state = "running"
    -- A cursor blocked on a signal or parked at a join has no wake time and
    -- stays where it is. Otherwise it keeps its heap entry, and if its wake
    -- time passed while it was paused it runs on the next step rather than
    -- immediately.
    if cursor.wakeAt and cursor.wakeAt <= state.fixed.step then
        cursors.schedule(state, cursor, state.fixed.step + 1)
    end
    return true
end

cursors.SLOT_LIMIT = SLOT_LIMIT
cursors.DEFAULT_BUDGET = DEFAULT_BUDGET

return cursors
