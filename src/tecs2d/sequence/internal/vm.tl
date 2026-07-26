--- The instruction loop, and the per-tick driver that feeds it.
---
--- One cursor runs until it waits, finishes, or faults; the driver decides
--- which cursors run at all. Delivery of the waits that are not times --
--- signals, query conditions, tween endings -- happens at the top of a tick,
--- before anything advances, so a cursor woken by one runs in the same tick
--- rather than a tick later.

local tecs <const> = require("tecs")
local logging <const> = require("tecs.utils.logging")
local tween <const> = require("tecs2d.tween")
local frameclock <const> = require("tecs2d.internal.frameclock")
local seqclock <const> = require("tecs2d.sequence.internal.clock")
local seqevaluators <const> = require("tecs2d.sequence.internal.evaluators")
local seqregistry <const> = require("tecs2d.sequence.internal.registry")
local seqcursors <const> = require("tecs2d.sequence.internal.cursors")
local seqprogram <const> = require("tecs2d.sequence.internal.program")
local seqtypes <const> = require("tecs2d.sequence.internal.types")

local type World = tecs.World
local type Cursor = seqtypes.Cursor
local type WorldState = seqtypes.WorldState

local LOGGER <const> = logging.getLogger("tecs2d.sequence")

local SLOT_LIMIT <const> = seqcursors.SLOT_LIMIT

local record vm
    --- Run one cursor, arming its per-step budget on its first run in a step.
    advance: function(world: World, state: WorldState, cursor: Cursor)

    --- One tick of a world's fixed clock: deliver what is due, then drain
    --- every cursor scheduled at or before the new step.
    tick: function(world: World, state: WorldState, clockId: seqtypes.ClockId, dt?: number)
end

local function contextEntity(self: seqtypes.ActionContext, name: string): integer
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
local function contextBind(self: seqtypes.ActionContext, name: string, entity: integer)
    local cursor = self._cursor as Cursor
    local bindings = cursor.bindings
    if not bindings then
        bindings = {}
        cursor.bindings = bindings
    end
    bindings[name] = entity
end

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
            local name = (value as seqtypes.EntityRef).bindName
            local id = cursor.bindings and cursor.bindings[name]
            out[i] = (id and world:isAlive(id)) and id or nil
        else
            out[i] = value
        end
    end
    for i = #out, count + 1, -1 do out[i] = nil end
    return out
end

-- Seconds are authored; a clock counts ticks. The fixed clock converts with
-- the world's timestep, the frame clock with the run loop's nominal frame dt,
-- so the same program waits the same wall-clock time on either.
local function secondsToSteps(world: World, clock: seqtypes.ClockId, seconds: number): integer
    if seconds <= 0 then return 0 end
    local timestep = clock == "frame"
        and (frameclock.nominal > 0 and frameclock.nominal or 1 / 60)
        or world:getFixedTiming()
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
            seqcursors.fault(state, cursor, "budgetExceeded",
                "exceeded " .. tostring(cursor.budget)
                .. " instructions in one step without waiting")
            return budget
        end

        local base = cursor.pc * seqprogram.STRIDE
        local op = code[base + 1]
        local a = code[base + 2]
        local b = code[base + 3]

        if op == seqprogram.END then
            seqcursors.retire(state, cursor, "completed")
            return budget

        elseif op == seqprogram.WAIT then
            local steps = a >= 0 and secondsToSteps(world, cursor.clock, consts[a] as number) or b
            cursor.pc = cursor.pc + 1
            seqcursors.schedule(state, cursor,
                seqcursors.clockOf(state, cursor).step + (steps > 0 and steps or 1))
            return budget

        elseif op == seqprogram.WAIT_SIGNAL then
            local channel = consts[a] as string
            cursor.pc = cursor.pc + 1
            cursor.waitChannel = channel
            cursor.wakeAt = nil
            seqcursors.park(state.channels, channel, cursor.slot)
            return budget

        elseif op == seqprogram.WAIT_QUERY then
            local name = consts[a] as string
            if not state.queries[name] then
                seqcursors.fault(state, cursor, "unregisteredQuery",
                    "query '" .. name .. "' is not registered on this world")
                return budget
            end
            cursor.pc = cursor.pc + 1
            cursor.waitQuery = name
            cursor.waitCondition = b
            cursor.wakeAt = nil
            seqcursors.park(state.queryWaiters, name, cursor.slot)
            -- Test at the next step rather than here: a spawn or despawn
            -- from this step is still staged, so the query cannot answer
            -- for the world this cursor has already asked for.
            state.dirtyQueries[name] = true
            return budget

        elseif op == seqprogram.PLAY_TWEEN then
            local preset = consts[a] as string
            local spec = consts[b] as {any}
            local ref = spec[1] as seqtypes.EntityRef
            local id = cursor.bindings and cursor.bindings[ref.bindName]
            seqcursors.releaseTween(state, cursor)
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
                    seqcursors.fault(state, cursor, "unregisteredTween",
                        "tween preset '" .. preset .. "': " .. tostring(result))
                    return budget
                end
                cursor.tweenEntity = id
                cursor.tweenPlayback = result as integer
                state.tweenOwners[cursor.tweenPlayback] = cursor.slot
            end
            cursor.pc = cursor.pc + 1

        elseif op == seqprogram.EVAL then
            local name <const> = consts[a] as string
            local evaluator <const> = seqevaluators.get(name)
            if not evaluator then
                seqcursors.fault(state, cursor, "unregisteredEvaluator",
                    "evaluator '" .. name .. "' is not registered")
                return budget
            end
            -- The cursor leaves the heap and joins the active set: from here
            -- the evaluator decides when it is done, not a wake time.
            cursor.pc = cursor.pc + 1
            cursor.evaluator = name
            cursor.evalState = evaluator.newState and evaluator.newState(prog) or nil
            cursor.wakeAt = nil
            seqclock.activate(seqcursors.clockOf(state, cursor), cursor.slot)
            return budget

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
                seqcursors.fault(state, cursor, "unregisteredAction",
                    "action '" .. name .. "' is not registered on this world")
                return budget
            end
            local ctx = state.context
            if not ctx then
                ctx = {world = world, entity = contextEntity, bind = contextBind}
                    as seqtypes.ActionContext
                state.context = ctx
            end
            ctx.handle = seqcursors.packHandle(cursor.slot, cursor.generation)
            ctx.owner = cursor.owner
            ctx.args = resolveArgs(world, state, cursor, b)
            ctx._cursor = cursor

            local ok, err = pcall(action, world, ctx) as (boolean, any)
            if not ok then
                seqcursors.fault(state, cursor, "actionError", tostring(err))
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
                seqcursors.packHandle(cursor.slot, cursor.generation))
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
            local child = seqcursors.alloc(state)
            child.program = prog
            -- A branch runs the same program, so it runs on the same clock.
            child.clock = cursor.clock
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

            seqcursors.linkOwner(state, child)
            seqcursors.schedule(state, child,
                seqcursors.clockOf(state, child).step)
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
            seqcursors.fault(state, cursor, "actionError",
                "unknown opcode " .. tostring(op))
            return budget
        end
    end
end

--- Run one cursor, arming its budget the first time it runs in a step.
function vm.advance(world: World, state: WorldState, cursor: Cursor)
    local step <const> = seqcursors.clockOf(state, cursor).step
    if cursor.budgetStep ~= step then
        cursor.budgetStep = step
        cursor.budgetLeft = cursor.budget
    end
    cursor.budgetLeft = run(world, state, cursor, cursor.budgetLeft)
end

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
                    seqcursors.unlinkWaits(state, cursor)
                    seqcursors.schedule(state, cursor, seqcursors.clockOf(state, cursor).step)
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
                    seqcursors.unlinkWaits(state, cursor)
                    seqcursors.schedule(state, cursor, seqcursors.clockOf(state, cursor).step)
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
                seqcursors.unlinkWaits(state, cursor)
                seqcursors.releaseTween(state, cursor)
                seqcursors.schedule(state, cursor, seqcursors.clockOf(state, cursor).step)
            end
        end
    end
end

-- Everything evaluating on this clock, stepped once. Finished cursors leave
-- the set and carry on at the instruction after their eval; the walk is
-- backwards so removing one does not skip its neighbour.
local function stepActive(world: World, state: WorldState, clock: seqclock.Clock, dt: number)
    local active <const> = clock.active
    for i = #active, 1, -1 do
        local cursor = state.cursors[active[i]]
        if not cursor or not cursor.alive then
            seqclock.deactivate(clock, active[i])
        elseif cursor.state == "running" then
            local evaluator <const> = seqevaluators.get(cursor.evaluator)
            local done: boolean
            if evaluator then
                local ok, result = pcall(evaluator.step, world, cursor, dt) as (boolean, any)
                if not ok then
                    seqcursors.fault(state, cursor, "actionError", tostring(result))
                    done = false
                else
                    done = result as boolean
                end
            else
                done = true
            end
            if done and cursor.alive then
                seqclock.deactivate(clock, cursor.slot)
                cursor.evaluator = nil
                cursor.evalState = nil
                seqcursors.schedule(state, cursor, clock.step)
            end
        end
    end
end

function vm.tick(world: World, state: WorldState, clockId: seqtypes.ClockId, dt?: number)
    local clock <const> = state.clocks[clockId]
    clock.step = clock.step + 1
    local step = clock.step

    -- Waits that are not times are delivered on the fixed clock, which is the
    -- one gameplay runs on. A frame-clock program waits on ticks alone.
    if clockId == "fixed" then
        deliverSignals(state)
        deliverQueryWaits(state)
        deliverTweenWaits(world, state)
    end

    stepActive(world, state, clock, dt or 0)

    local fixed <const> = clock
    while true do
        local due <const> = seqclock.next(fixed)
        if not due or due > step then break end
        local seq, packed = seqclock.take(fixed)
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
                vm.advance(world, state, cursor)
            end
        end
    end
end

return vm
