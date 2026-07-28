--- Timelines as programs: the evaluator a compiled timeline runs under.
---
--- A tween playback is a cursor that never sleeps. It joins its clock's
--- active set at the `eval` step and is walked from there every tick, holding
--- a direct reference to its timeline and one contiguous state buffer.
---
--- That is the whole point of the merge. The shipping tween runtime reached a
--- playback through a query, an archetype, a component, a cursor list, and a
--- registry lookup before it could touch a number, and paid that per playback
--- per frame. Here the walk is the dense array and the timeline is a field.

local type types = require("tecs.types")
local seqcursors <const> = require("tecs.sequence.internal.cursors")
local seqtypes <const> = require("tecs.sequence.internal.types")
local tweeneval <const> = require("tecs.sequence.internal.tweeneval")

local floor <const> = math.floor

local type World = types.World
local type Cursor = seqtypes.Cursor
local type PlaybackMode = tweeneval.PlaybackMode
local type RunSlot = tweeneval.RunSlot
local type TimelineImpl = tweeneval.TimelineImpl
local type TweenSlotState = tweeneval.TweenSlotState

local evaluateSlots <const> = tweeneval.evaluateSlots

--- The name a compiled timeline's `eval` step carries.
local EVALUATOR <const> = "tecs.tween"

--- One playback's working state: where it is in its timeline, and the slot
--- state the evaluation loop writes through.
---
--- The same record serves a nested `run`, which is a playback of the child
--- timeline driven by its parent's clock rather than by dt.
local record Playback
    timeline: TimelineImpl
    state: {TweenSlotState}
    children: {Playback}
    elapsed: number
    direction: integer
    mode: PlaybackMode
    remainingPasses: integer
    nextEmit: integer
    rate: number
    delay: number
    completed: boolean
    lastCycleIndex: integer
end

local record tweenrun
    --- The evaluator name a compiled timeline names.
    EVALUATOR: string

    type Playback = Playback

    --- Register the evaluator. Idempotent, and called when the sequencer's
    --- plugin installs.
    install: function()

    --- The playback options a timeline reads out of `params`, validated.
    --- Raises on a combination a timeline cannot run.
    resolveOptions: function(params: {string: any}, totalDuration: number): PlaybackMode, integer, number, number
end

-------------------------------------------------------------------------------
-- Construction
-------------------------------------------------------------------------------

function tweenrun.resolveOptions(params: {string: any}, totalDuration: number): PlaybackMode, integer, number, number
    local mode, passCount = tweeneval.playbackMode(
        params and params.mode as PlaybackMode, params and params.count as integer
    )
    local speed <const> = (params and params.speed as number) or 1
    local delay <const> = (params and params.delay as number) or 0
    if speed <= 0 then
        error("Tween speed must be greater than 0")
    end
    if delay < 0 then
        error("Tween delay must be at least 0")
    end
    if passCount ~= 1 and totalDuration <= 0 then
        error("Repeating tween timelines must have a duration")
    end
    return mode, passCount, speed, delay
end

local function newPlayback(
    tl: TimelineImpl, mode: PlaybackMode, passCount: integer, rate: number, delay: number
): Playback
    local children: {Playback} = nil
    if tl.runs then
        children = {}
        for i = 1, #tl.runs do
            local run <const> = tl.runs[i]
            children[i] = newPlayback(run.timeline, run.mode, run.passCount, 1, 0)
        end
    end
    return {
        timeline = tl,
        state = tweeneval.newState(tl.stateSize),
        children = children,
        elapsed = 0,
        direction = 1,
        mode = mode,
        remainingPasses = passCount,
        nextEmit = 1,
        rate = rate,
        delay = delay,
        completed = false,
        lastCycleIndex = 0,
    }
end

-------------------------------------------------------------------------------
-- Evaluation
-------------------------------------------------------------------------------

-- The handle is packed here rather than passed down, so a timeline with no
-- emits -- which is nearly all of them -- pays nothing for the possibility.
local function fireEmits(p: Playback, world: World, target: integer, cursor: Cursor)
    local emits <const> = p.timeline.emits
    if not emits then
        return
    end
    while p.nextEmit <= #emits do
        local evDef <const> = emits[p.nextEmit]
        if p.elapsed >= evDef.time then
            p.nextEmit = p.nextEmit + 1
            -- An authored emit is an ordinary sequence event: the name it was
            -- given, and the entity it played on.
            world:emit(0, seqtypes.Event, evDef.name, {target}, seqcursors.packHandle(cursor.slot, cursor.generation))
        else
            break
        end
    end
end

local evaluate: function(Playback, World, integer, Cursor)
local resetCycle: function(Playback)

local function beginRunCycle(p: Playback, runSlot: RunSlot, cycleIndex: integer)
    if runSlot.mode == "loop" or cycleIndex % 2 == 0 then
        resetCycle(p)
    end
    p.direction = runSlot.mode == "pingPong" and cycleIndex % 2 == 1 and -1 or 1
    if p.direction == -1 then
        local emits <const> = p.timeline.emits
        p.nextEmit = (emits and #emits or 0) + 1
    else
        p.nextEmit = 1
    end
    p.lastCycleIndex = cycleIndex
    p.remainingPasses = runSlot.passCount - cycleIndex
end

local function evaluateRun(
    p: Playback, runSlot: RunSlot, localElapsed: number, world: World, target: integer, cursor: Cursor
)
    local cycleDuration <const> = p.timeline.totalDuration
    if cycleDuration <= 0 then
        return
    end

    local atEnd <const> = localElapsed >= runSlot.effectiveDuration
    local cycleIndex = atEnd and (runSlot.passCount - 1) or floor(localElapsed / cycleDuration)
    local cyclePos = atEnd and cycleDuration or (localElapsed % cycleDuration)

    if cycleIndex > p.lastCycleIndex then
        for completedCycle = p.lastCycleIndex, cycleIndex - 1 do
            p.elapsed = runSlot.mode == "pingPong" and completedCycle % 2 == 1 and 0 or cycleDuration
            evaluate(p, world, target, cursor)
            beginRunCycle(p, runSlot, completedCycle + 1)
        end
    elseif cycleIndex < p.lastCycleIndex then
        p.lastCycleIndex = cycleIndex
        p.direction = runSlot.mode == "pingPong" and cycleIndex % 2 == 1 and -1 or 1
    end

    if runSlot.mode == "pingPong" and cycleIndex % 2 == 1 then
        cyclePos = cycleDuration - cyclePos
    end
    p.elapsed = cyclePos
    p.remainingPasses = runSlot.passCount - cycleIndex
    evaluate(p, world, target, cursor)
    p.completed = atEnd
end

evaluate = function(p: Playback, world: World, target: integer, cursor: Cursor)
    local tl <const> = p.timeline
    evaluateSlots(tl.slots, p.state, world, target, p.elapsed)
    fireEmits(p, world, target, cursor)
    local runs <const> = tl.runs
    if runs and p.children then
        for i = 1, #runs do
            local runSlot <const> = runs[i]
            local child <const> = p.children[i]
            local runStart <const> = runSlot.startTime
            local runEnd <const> = runStart + runSlot.effectiveDuration
            if p.elapsed >= runStart and p.elapsed <= runEnd then
                evaluateRun(child, runSlot, p.elapsed - runStart, world, target, cursor)
            elseif p.elapsed > runEnd and not child.completed then
                evaluateRun(child, runSlot, runSlot.effectiveDuration, world, target, cursor)
            end
        end
    end
end

resetCycle = function(p: Playback)
    tweeneval.clearState(p.state, p.timeline.stateSize)
    p.elapsed = 0
    p.direction = 1
    p.nextEmit = 1
    p.completed = false
    p.lastCycleIndex = 0
    if p.children then
        for i = 1, #p.children do
            resetCycle(p.children[i])
        end
    end
end

--- Advance one playback by `dt`, returning true once it is finished.
local function advance(p: Playback, dt: number, world: World, target: integer, cursor: Cursor): boolean
    if p.delay > 0 then
        p.delay = p.delay - dt
        if p.delay > 0 then
            return false
        end
        dt = -p.delay
        p.delay = 0
    end

    local totalDuration <const> = p.timeline.totalDuration
    if totalDuration <= 0 then
        evaluate(p, world, target, cursor)
        return true
    end

    local remainingTime = dt * p.rate
    if remainingTime <= 0 then
        evaluate(p, world, target, cursor)
        return false
    end

    while remainingTime > 0 do
        local distance <const> = p.direction == 1 and (totalDuration - p.elapsed) or p.elapsed
        if remainingTime < distance then
            p.elapsed = p.elapsed + remainingTime * p.direction
            evaluate(p, world, target, cursor)
            return false
        end

        p.elapsed = p.direction == 1 and totalDuration or 0
        evaluate(p, world, target, cursor)
        remainingTime = remainingTime - distance

        if p.remainingPasses == -1 or p.remainingPasses > 1 then
            if p.remainingPasses > 1 then
                p.remainingPasses = p.remainingPasses - 1
            end
            if p.mode == "pingPong" then
                p.direction = -p.direction
                if p.direction == 1 then
                    resetCycle(p)
                end
            else
                resetCycle(p)
            end
        else
            return true
        end
    end

    return false
end

-------------------------------------------------------------------------------
-- Snapshot
-------------------------------------------------------------------------------

local SLOT_FIELDS <const>: {string} = {"init", "applied", "lastT", "s1", "s2", "s3", "s4", "d1", "d2", "d3", "d4"}

local function saveSlotState(state: {TweenSlotState}, count: integer): {{number}}
    local out: {{number}} = {}
    for i = 0, count - 1 do
        local s <const> = state[i]
        out[i + 1] = {s.init, s.applied, s.lastT, s.s1, s.s2, s.s3, s.s4, s.d1, s.d2, s.d3, s.d4}
    end
    return out
end

local function loadSlotState(state: {TweenSlotState}, count: integer, rows: {{number}})
    for i = 0, count - 1 do
        local row <const> = rows and rows[i + 1]
        if not row then
            return
        end
        local s <const> = state[i]
        local slot <const> = s as {string: number}
        for f = 1, #SLOT_FIELDS do
            slot[SLOT_FIELDS[f]] = row[f] or 0
        end
    end
end

local savePlayback: function(p: Playback): {string: any}
savePlayback = function(p: Playback): {string: any}
    local children: {{string: any}} = nil
    if p.children then
        children = {}
        for i = 1, #p.children do
            children[i] = savePlayback(p.children[i])
        end
    end
    return {
        elapsed = p.elapsed,
        direction = p.direction,
        mode = p.mode,
        remainingPasses = p.remainingPasses,
        nextEmit = p.nextEmit,
        rate = p.rate,
        delay = p.delay,
        completed = p.completed,
        lastCycleIndex = p.lastCycleIndex,
        state = saveSlotState(p.state, p.timeline.stateSize),
        children = children,
    }
end

-- The timeline comes back from the program, not the save: a playback restores
-- where it was in instructions this build compiled, never instructions the
-- save carried.
local loadPlayback: function(tl: TimelineImpl, data: {string: any}): Playback
loadPlayback = function(tl: TimelineImpl, data: {string: any}): Playback
    local p <const> = newPlayback(
        tl,
        (data.mode as PlaybackMode) or "once",
        (data.remainingPasses as integer) or 1,
        (data.rate as number) or 1,
        (data.delay as number) or 0
    )
    p.elapsed = (data.elapsed as number) or 0
    p.direction = (data.direction as integer) or 1
    p.nextEmit = (data.nextEmit as integer) or 1
    p.completed = data.completed == true
    p.lastCycleIndex = (data.lastCycleIndex as integer) or 0
    loadSlotState(p.state, tl.stateSize, data.state as {{number}})
    local savedChildren = data.children as {{string: any}}
    if savedChildren and p.children and tl.runs then
        for i = 1, #p.children do
            if savedChildren[i] then
                p.children[i] = loadPlayback(tl.runs[i].timeline, savedChildren[i])
            end
        end
    end
    return p
end

-------------------------------------------------------------------------------
-- The evaluator
-------------------------------------------------------------------------------

local installed = false

function tweenrun.install()
    if installed then
        return
    end
    installed = true

    local seqevaluators <const> = require("tecs.sequence.internal.evaluators")
    seqevaluators.register(
        EVALUATOR,
        {
            -- One resolve per program constant, shared by every playback of it:
            -- easing names become functions and target ids become targets once,
            -- not once per entity.
            resolve = function(data: any): any return tweeneval.deserializeTimeline(data as {string: any}) end,

            newState = function(_prog: seqtypes.ProgramImpl, data: any, cursor: Cursor): any
                local tl <const> = data as TimelineImpl
                local mode, passCount, speed, delay = tweenrun.resolveOptions(cursor.params, tl.totalDuration)
                return newPlayback(tl, mode, passCount, speed, delay)
            end,

            step = function(world: World, cursor: Cursor, dt: number): boolean
                local target <const> = cursor.owner
                -- A timeline animates the playback's owner. Without one there is
                -- nothing to write to, so it is done rather than faulted: the
                -- same answer a despawned target gives.
                if target == 0 then
                    return true
                end
                return advance(cursor.evalState as Playback, dt, world, target, cursor)
            end,

            save = function(state: any): any return savePlayback(state as Playback) end,

            load = function(_prog: seqtypes.ProgramImpl, data: any, saved: any): any
                local tl <const> = data as TimelineImpl
                if not saved then
                    return newPlayback(tl, "once", 1, 1, 0)
                end
                return loadPlayback(tl, saved as {string: any})
            end,
        }
    )
end

tweenrun.EVALUATOR = EVALUATOR

return tweenrun
