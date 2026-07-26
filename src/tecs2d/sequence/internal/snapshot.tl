--- Saving and restoring a world's playbacks.
---
--- A snapshot payload is versioned: a save written by a build whose
--- cursor layout this one does not understand is refused rather than
--- restored field by field into a half-cursor.
---
--- A snapshot carries the exact program versions its live cursors are
--- running, so a load resumes the instructions each playback started with
--- even when the code has since been redefined. Programs restored this way
--- register under their original (name, version), leaving the newest version
--- untouched for later `play` calls.

local tecs <const> = require("tecs")
local logging <const> = require("tecs.utils.logging")
local seqclock <const> = require("tecs2d.sequence.internal.clock")
local seqcursors <const> = require("tecs2d.sequence.internal.cursors")
local seqevaluators <const> = require("tecs2d.sequence.internal.evaluators")
local seqprogram <const> = require("tecs2d.sequence.internal.program")
local seqregistry <const> = require("tecs2d.sequence.internal.registry")
local seqtypes <const> = require("tecs2d.sequence.internal.types")

local type World = tecs.World
local type Cursor = seqtypes.Cursor
local type ProgramImpl = seqtypes.ProgramImpl
local type PlaybackState = seqtypes.PlaybackState
local type TweenOutcome = seqtypes.TweenOutcome

local LOGGER <const> = logging.getLogger("tecs2d.sequence")

local floor <const> = math.floor

local DEFAULT_BUDGET <const> = seqcursors.DEFAULT_BUDGET

-- Layout version of this module's snapshot payload. Bumped whenever a cursor
-- gains state an older reader would silently ignore, so a save written by a
-- newer build is rejected rather than restored as a half-cursor.
--   1: cursor, program, and signal state
--   2: branch tree (parent link and join state)
--   3: query waits
--   4: tween playback waits
--   5: named clocks
--   6: evaluator working state
--   7: awaitable waits
local SNAPSHOT_VERSION <const> = 7

local record snapshot
    --- The payload layout this build writes and accepts.
    VERSION: integer

    --- Everything this world's live playbacks need to come back, or nil when
    --- the world has none.
    save: function(world: World): any

    --- Replace this world's playbacks with the payload's. Raises rather than
    --- restoring a payload whose layout this build does not know.
    load: function(world: World, value: any)
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

-- Each clock's counters travel separately: a cursor resumes on the clock its
-- program declared, and the two do not advance together.
local function clockCounters(state: seqtypes.WorldState): {string: {string: integer}}
    local out: {string: {string: integer}} = {}
    for id, c in pairs(state.clocks) do
        out[id as string] = {step = c.step, seq = c.seq}
    end
    return out
end

local function restoreClockCounters(
    state: seqtypes.WorldState,
    saved: {string: {string: integer}}
)
    if not saved then return end
    for id, counters in pairs(saved) do
        local c = state.clocks[id as seqtypes.ClockId]
        if c then
            c.step = counters.step or 0
            c.seq = counters.seq or 0
        end
    end
end

-- A program can name another: `playTween` carries a timeline's name in its
-- const pool. The named one is not running when the save is written -- the
-- playback has not reached that step yet -- so collecting only what live
-- cursors run would leave the restored playback to fault the moment it got
-- there. Referenced programs travel too, transitively.
local function collectReferenced(prog: ProgramImpl, out: {ProgramImpl}, seen: {string: boolean})
    local code <const> = prog.code
    local stride <const> = seqprogram.STRIDE
    for at = 0, floor(#code / stride) - 1 do
        local base <const> = at * stride
        if code[base + 1] == seqprogram.PLAY_TWEEN then
            local name <const> = prog.consts[code[base + 2]] as string
            local referenced = name and seqregistry.newest(name)
            if referenced then
                local key <const> = referenced.name .. "@" .. tostring(referenced.version)
                if not seen[key] then
                    seen[key] = true
                    out[#out + 1] = referenced
                    collectReferenced(referenced, out, seen)
                end
            end
        end
    end
end

local function serializeProgram(prog: ProgramImpl): {string: any}
    return {
        name = prog.name,
        version = prog.version,
        code = prog.code,
        consts = prog.consts,
        clock = prog.clock,
        loopCounts = prog.loopCounts,
    }
end

function snapshot.save(world: World): any
    local state = seqcursors.stateFor(world)

    local programs: {{string: any}} = {}
    local seenPrograms: {string: boolean} = {}
    local referenced: {ProgramImpl} = {}
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
                collectReferenced(prog, referenced, seenPrograms)
            end
            -- Only the evaluator says what of its working state is data;
            -- one that does not say carries nothing and comes back at the
            -- start of whatever it was evaluating.
            local evalState: any = nil
            if cursor.evaluator then
                local evaluator = seqevaluators.get(cursor.evaluator)
                if evaluator and evaluator.save then
                    evalState = evaluator.save(cursor.evalState)
                end
            end

            cursors[#cursors + 1] = {
                slot = cursor.slot,
                generation = cursor.generation,
                evaluator = cursor.evaluator,
                evalIndex = cursor.evalIndex,
                evalState = evalState,
                program = prog.name,
                version = prog.version,
                pc = cursor.pc,
                state = cursor.state,
                clock = cursor.clock,
                owner = cursor.owner,
                bindings = cursor.bindings,
                params = cursor.params,
                pauseHolders = cursor.pauseHolders,
                budget = cursor.budget,
                wakeAt = cursor.wakeAt,
                seq = cursor.seq,
                loopRegs = cursor.loopRegs,
                waitChannel = cursor.waitChannel,
                waitQuery = cursor.waitQuery,
                waitCondition = cursor.waitCondition,
                tweenPlayback = cursor.tweenPlayback,
                tweenOutcome = cursor.tweenOutcome,
                waitingTween = cursor.waitingTween,
                awaitedBy = cursor.awaitedBy,
                channel = cursor.channel,
                awaitProvider = cursor.awaitProvider,
                awaitEntity = cursor.awaitEntity,
                awaitKey = cursor.awaitKey,
                parentSlot = cursor.parentSlot,
                parentGeneration = cursor.parentGeneration,
                joining = cursor.joining,
            }
        end
    end

    for i = 1, #referenced do
        programs[#programs + 1] = serializeProgram(referenced[i])
    end

    return {
        version = SNAPSHOT_VERSION,
        clocks = clockCounters(state),
        budget = state.budget,
        nextSlot = state.nextSlot,
        generations = state.generations,
        programs = programs,
        cursors = cursors,
        pendingSignals = state.pendingSignals,
    }
end

-- An evaluating playback rejoins its clock's active set rather than the heap:
-- it has no wake time, only work to do every tick. An evaluator this build no
-- longer registers is not fatal; the playback gives up its working state and
-- carries on at the instruction after its eval.
local function restoreEvaluator(
    state: seqtypes.WorldState,
    cursor: Cursor,
    prog: ProgramImpl,
    saved: any
)
    local evaluator <const> = seqevaluators.get(cursor.evaluator)
    if not evaluator then
        LOGGER:warn("%s v%d: evaluator '%s' is gone; resuming past it",
            prog.name, prog.version, cursor.evaluator)
        cursor.evaluator = nil
        cursor.evalIndex = nil
        seqcursors.schedule(state, cursor, seqcursors.clockOf(state, cursor).step + 1)
        return
    end
    if cursor.evalIndex then
        cursor.evalData = seqevaluators.resolve(prog, evaluator, cursor.evalIndex)
    end
    cursor.evalState = evaluator.load
        and evaluator.load(prog, cursor.evalData, saved)
        or (evaluator.newState
            and evaluator.newState(prog, cursor.evalData, cursor) or nil)
    cursor.evalImpl = evaluator
    seqcursors.activate(state, cursor)
end

function snapshot.load(world: World, value: any)
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

    local state = seqcursors.stateFor(world)
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
    
    state.channels = {}
    state.pendingSignals = {}
    -- Registered queries are code, kept like actions; only the parked
    -- cursors are data.
    state.queryWaiters = {}
    state.dirtyQueries = {}
    state.channelled = {}
    state.awaitWaiters = {}
    -- The call scratch points at cursors that are about to be replaced.
    state.context = nil
    state.argScratch = {}
    state.nextSlot = 1
    state.generations = {}
    for _, c in pairs(state.clocks) do seqclock.clear(c) end

    local data = value as {string: any}
    if not data then return end

    restoreClockCounters(state, data.clocks as {string: {string: integer}})
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
                clock = (row.clock as seqtypes.ClockId) or "fixed",
                owner = (row.owner as integer) or 0,
                bindings = row.bindings as {string: integer},
                params = row.params as {string: any},
                pauseHolders = row.pauseHolders as {string: boolean},
                budget = (row.budget as integer) or state.budget,
                wakeAt = row.wakeAt as integer,
                seq = row.seq as integer,
                loopRegs = row.loopRegs as {integer: integer},
                waitChannel = row.waitChannel as string,
                waitQuery = row.waitQuery as string,
                waitCondition = row.waitCondition as integer,
                tweenPlayback = row.tweenPlayback as integer,
                tweenOutcome = row.tweenOutcome as TweenOutcome,
                waitingTween = row.waitingTween as boolean,
                awaitedBy = row.awaitedBy as integer,
                channel = row.channel as string,
                awaitProvider = row.awaitProvider as string,
                awaitEntity = row.awaitEntity as integer,
                awaitKey = row.awaitKey as string,
                parentSlot = row.parentSlot as integer,
                parentGeneration = row.parentGeneration as integer,
                joining = row.joining as boolean,
                evaluator = row.evaluator as string,
                evalIndex = row.evalIndex as integer,
            }
            seqregistry.retain(prog)
            state.cursors[cursor.slot] = cursor
            seqcursors.linkOwner(state, cursor)
            if cursor.channel then
                state.channelled[tostring(cursor.owner) .. "\0" .. cursor.channel] =
                    cursor.slot
            end

            -- Rebuild the wake indexes rather than serializing them. A
            -- cursor blocked on a signal or a query has no wake time and
            -- belongs in its wait index instead of the heap; one evaluating
            -- belongs in its clock's active set; one parked at a join belongs
            -- in none of them and is woken by its last branch.
            if cursor.waitChannel then
                seqcursors.park(state.channels, cursor.waitChannel, cursor.slot)
            elseif cursor.evaluator then
                restoreEvaluator(state, cursor, prog, row.evalState)
            elseif cursor.waitQuery then
                seqcursors.park(state.queryWaiters, cursor.waitQuery, cursor.slot)
                -- The world this cursor parked against is gone, so its
                -- condition is re-tested against the restored one.
                state.dirtyQueries[cursor.waitQuery] = true
            elseif cursor.awaitProvider then
                -- Re-tested at the next step against the restored world,
                -- which is the only thing that can answer for it.
                state.awaitWaiters[cursor.slot] = true
            elseif cursor.waitingTween then
                -- Nothing to rebuild: the playback it waits on carries the
                -- back reference and wakes it when it ends.
            elseif not cursor.joining then
                seqclock.requeue(seqcursors.clockOf(state, cursor), cursor.wakeAt, cursor.seq,
                    seqcursors.packHandle(cursor.slot, cursor.generation))
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
            seqcursors.schedule(state, cursor, seqcursors.clockOf(state, cursor).step + 1)
        end
    end

    -- Slots the snapshot did not fill are free again.
    for slot = 1, state.nextSlot - 1 do
        if not state.cursors[slot] then
            state.freeSlots[#state.freeSlots + 1] = slot
        end
    end
end

snapshot.VERSION = SNAPSHOT_VERSION

return snapshot
