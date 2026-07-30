--[=[
The one place in the engine that resumes a coroutine.

A system registered with `coroutine` instead of `run` is a body that keeps its own
place across frames. The pipeline still dispatches it in phase order, in its
slot, behind its `runIf`; what changes is that reaching the end of the slot
suspends the body rather than returning from it, so the next frame carries on
from the same line with its locals intact.

Everything the body would otherwise have to keep in a table is a local: the
stage it reached, the index it stopped at, the value it is waiting for. That is
the whole of what this buys, and it is why the mechanism is confined to one
module and one config field rather than offered as a general facility.

## The wrapper

A coroutine system is turned into an ordinary `run` closure once, at registration.
The pipeline's dispatch loop is untouched and still calls `runs[i](dt, world)`
through a flat array, so a world with no coroutine systems in it pays nothing at all
and a world with them pays one closure call plus the resume.

## Clocks

Waits are counted in the `dt` the body's own phase receives rather than against
a monotonic clock. A wait of half a second is half a second of the time the
game is actually running, so it stops when the game stops, and the module needs
no platform clock. `runIf` gating a coroutine system off freezes its waits along with
it, because a system that is not being dispatched is not waiting, it is off.

## Death

A body that returns has finished, and the system unregisters itself. A body
that raises is unregistered too, and then the raise carries on outward with the
coroutine's own traceback attached, so it stops the frame and reaches the
application's crash guard exactly as a `run` system's failure does. Neither is
restarted: re-running a body that already had effects is worse than stopping.
]=]

local types <const> = require("tecs.types")

local type World = types.World
local type System = types.System

-- What `Future` looks like from here.
--
-- Declared rather than imported, because `tecs.Future` sits above the ECS and
-- naming it here would point the graph back the way it came. Only `Future`
-- reaches `parkOn`, and it hands itself over as one of these.
local record Settling
    status: string
    onSettle: function(self: Settling, listener: function(Settling)): Settling
end

-- The one field of a world this module reads, named here for the same reason.
local record ScopeHolder
    _scopeDepth: integer
end

-- What a parked body is waiting for.
local WAKE_FRAME <const> = 1
local WAKE_TIME <const> = 2
local WAKE_SETTLING <const> = 3

-- Seconds close enough to zero that a wait counted down to them is over.
--
-- A wait is aged by subtracting each frame's dt from it, and a float does not
-- reach zero that way: half a second less five tenths leaves 2.8e-17 rather
-- than 0, which is positive, so every wait that divides evenly into the frame
-- rate would sleep one whole frame longer than it asked for. Larger than any
-- residue a run of subtractions can leave, and smaller than any wait worth
-- distinguishing.
local TIME_EPSILON <const> = 1e-9

-- Seconds a body may stay parked before the first stall report. Doubling from
-- there, on the same reasoning as the pipeline's dropped-step report: a body
-- parked forever is the failure this cannot otherwise be seen through, and one
-- that is merely slow must not fill a log with it.
local STALL_SECONDS <const> = 5

-- A logger name is what `SDL_SetLogPriority` filters on, so it is configuration
-- a developer types into a shell rather than an identifier this tree renames.
local LOGGER_NAME <const> = "tecs.coroutines"

local record State
    name: string
    co: thread

    -- False until the first dispatch, which passes the world rather than a dt.
    started: boolean
    dead: boolean

    wake: integer
    -- Seconds left of a WAKE_TIME park.
    wakeIn: number
    -- What a WAKE_SETTLING park is watching, and whether it has settled.
    settling: Settling
    settled: boolean

    -- Seconds left before this park times out, or nil for no timeout.
    timeoutLeft: number
    -- Set by the scheduler so the resumed `yield` raises rather than returning.
    timedOut: boolean

    -- Seconds this park has lasted, and the next total worth reporting.
    parkedFor: number
    nextStallReport: number

    -- The dt of the frame currently resuming this body, so a park that turns
    -- out not to need to park has something to answer with.
    dt: number

    -- One listener per system, allocated here and reused by every await.
    onSettle: function(Settling)
end

local record coroutines
    --- Wraps a coroutine body in the ordinary `run` closure the pipeline dispatches.
    --- @param name The system name, used to unregister it and to name it in a log.
    --- @param body The body to resume, receiving the world and nothing else.
    --- @return A system function the pipeline stores like any other.
    newSystem: function(name: string, body: function(World)): System

    --- Parks for a moment. Implements `World.yield`.
    --- @param world The world whose pipeline is dispatching this body.
    --- @param seconds Nil for the next slot, or a number of seconds to sleep.
    --- @return The delta time of the frame this body resumed on.
    yield: function(world: World, seconds: number): number

    --- Parks until something settles. What `Future.yield` parks in.
    ---
    --- Answers with nothing, because the caller owns the settled object and its
    --- own types: it reads its result and decides what a failure means. That
    --- split is what lets a wait on a future return the future's own value type
    --- without this module knowing anything about futures.
    --- @param world The world whose pipeline is dispatching this body.
    --- @param awaited Something answering `status` and `onSettle`. Anything else raises.
    --- @param timeoutMs Milliseconds before the park raises, or nil to wait forever.
    parkOn: function(world: World, awaited: any, timeoutMs: number)

    --- Names the coroutine system currently being resumed, or nil outside one.
    ---
    --- So a caller raising about a wait of its own can say whose wait it was.
    --- A message naming only the value that failed is the same message from
    --- every system that waited on one.
    --- @return The system name, or nil.
    runningName: function(): string
end

-- The body being resumed, so `yield` knows whose park it is recording. Saved
-- and restored around every resume rather than cleared, because a body may run
-- a phase of its own and reach a second one.
local current: State = nil

-------------------------------------------------------------------------------
-- Parking
-------------------------------------------------------------------------------

-- Whether a parked body's wait is over. Ages the wait as it goes, which is why
-- it runs once per dispatch and not once per query.
local function woken(state: State, dt: number): boolean
    local kind = state.wake
    if kind == WAKE_FRAME then
        return true
    end
    if kind == WAKE_TIME then
        local left = state.wakeIn - dt
        state.wakeIn = left
        return left <= TIME_EPSILON
    end
    -- Settling. The listener answers first; the status is what covers a future
    -- that settled before this body ever registered on it. A park with nothing
    -- to watch resumes rather than waiting forever, because waking a body early
    -- is recoverable and hanging it is not.
    local settling <const> = state.settling
    return state.settled or settling == nil or settling.status ~= "pending"
end

-- Ages a park's timeout, and answers whether it just ran out.
local function expired(state: State, dt: number): boolean
    local left = state.timeoutLeft
    if left == nil then
        return false
    end
    left = left - dt
    state.timeoutLeft = left
    return left <= TIME_EPSILON
end

-- Says out loud that a body has been parked a long time.
--
-- The one failure a coroutine system has that a `run` system cannot: a body waiting
-- on something that never arrives stops running and nothing else changes, so
-- the symptom is a feature quietly not happening. Reported here rather than
-- left to a timeout, because the bodies that need saying are exactly the ones
-- whose author did not think a timeout was necessary.
local function reportStall(state: State, dt: number)
    local parked = state.parkedFor + dt
    state.parkedFor = parked
    if parked < state.nextStallReport then
        return
    end
    while state.nextStallReport <= parked do
        state.nextStallReport = state.nextStallReport * 2
    end

    -- Required here rather than at the top, on the same terms as the
    -- pipeline's own overload report: logging is SDL's, reached through the
    -- FFI, and a tool that only wants worlds and systems should not be made to
    -- find SDL to build one. A stall is a cold path by construction.
    local log <const> = require("tecs.log")
    local waitingOn: string
    if state.wake == WAKE_TIME then
        waitingOn = ("a %.1fs sleep"):format(state.wakeIn)
    elseif state.wake == WAKE_SETTLING then
        waitingOn = "something that has not settled"
    else
        waitingOn = "its next slot"
    end
    log.get(LOGGER_NAME):error(
        "Coroutine system '%s' has been parked on %s for %.1fs. It is not running, "
            .. "and nothing else will report that. Give the yield a timeout, or "
            .. "check that whatever it waits for still happens.",
        state.name,
        waitingOn,
        parked
    )
end

-------------------------------------------------------------------------------
-- Dispatch
-------------------------------------------------------------------------------

local function retire(state: State, world: World)
    state.dead = true
    state.settling = nil
    -- Through the world rather than the pipeline directly, so the name registry
    -- and the flat groups are updated by the one path that knows how.
    --
    -- Tolerant of the name already being gone, which is a body that removed
    -- itself and then returned. `removeSystem` raises on a name it does not
    -- hold, and that raise would replace whatever the body was actually doing.
    pcall(world.removeSystem, world, state.name)
end

local function resume(state: State, dt: number, world: World)
    local previous <const> = current
    current = state
    state.dt = dt

    local ok: boolean
    local err: any
    if state.started then
        ok, err = coroutine.resume(state.co, dt) as (boolean, any)
    else
        state.started = true
        ok, err = coroutine.resume(state.co, world) as (boolean, any)
    end

    current = previous

    if not ok then
        -- Unregistered and then raised onward, rather than caught here. A `run`
        -- system that raises stops the frame and reaches the application's
        -- crash guard, which unwinds the scopes an interrupted body left open;
        -- a coroutine system that vanished from the pipeline while the game carried
        -- on would be the silent failure the stall report below exists to
        -- prevent, and if it raised inside query iteration the frame after it
        -- would stage every mutation instead of applying it.
        --
        -- The traceback is attached here because it is the coroutine's own, and
        -- this is the last point that can reach it: the frames above are the
        -- scheduler's, which are never the answer.
        local traceback <const> = debug.traceback(state.co, tostring(err))
        retire(state, world)
        error("tecs: coroutine system '" .. state.name .. "' raised: " .. traceback, 0)
    end

    if coroutine.status(state.co) == "dead" then
        retire(state, world)
    end
end

function coroutines.newSystem(name: string, body: function(World)): System
    local state: State = {
        name = name,
        co = coroutine.create(body as function(...: any): any...),
        started = false,
        dead = false,
        wake = WAKE_FRAME,
        wakeIn = 0,
        settled = false,
        timedOut = false,
        parkedFor = 0,
        nextStallReport = STALL_SECONDS,
        dt = 0,
    }

    -- Compared against the current park rather than trusted outright: a body
    -- that timed out waiting on one thing and went on to wait for another must
    -- not be woken by the first one settling afterwards.
    state.onSettle = function(settled: Settling)
        if settled == state.settling then
            state.settled = true
        end
    end

    return function(dt: number, world: World)
        if state.dead then
            return
        end

        if state.started and not woken(state, dt) then
            if not expired(state, dt) then
                reportStall(state, dt)
                return
            end
            state.timedOut = true
        end

        resume(state, dt, world)
    end
end

-------------------------------------------------------------------------------
-- Yielding
-------------------------------------------------------------------------------

-- Everything both parks share: the caller must be a body, and it must not be
-- inside query iteration.
--
-- Iteration holds a world-wide scope, and a body suspended inside one leaves
-- every later system's mutations staged instead of applied, for the rest of the
-- frame, silently. Caught here so it costs a compare and names the line.
local function enterPark(world: World, what: string): State
    local state <const> = current
    if state == nil or coroutine.running() ~= state.co then
        error("tecs: " .. what .. " is only callable from inside a coroutine system", 4)
    end
    if (world as ScopeHolder)._scopeDepth > 0 then
        error(
            "tecs: coroutine system '"
                .. state.name
                .. "' cannot yield during query iteration. Finish the loop, or use "
                .. "query:newCursor() and close the cursor before yielding.",
            4
        )
    end

    state.parkedFor = 0
    state.nextStallReport = STALL_SECONDS
    state.settled = false
    state.settling = nil
    state.timeoutLeft = nil
    return state
end

function coroutines.yield(world: World, seconds: number): number
    local state <const> = enterPark(world, "world:yield()")

    if seconds == nil then
        state.wake = WAKE_FRAME
    else
        if seconds ~= seconds or seconds < 0 then
            error("tecs: world:yield() takes nothing or a number of seconds to sleep", 3)
        end
        state.wake = WAKE_TIME
        state.wakeIn = seconds
    end

    return coroutine.yield() as number
end

function coroutines.runningName(): string
    local state <const> = current
    if state == nil or coroutine.running() ~= state.co then
        return nil
    end
    return state.name
end

function coroutines.parkOn(world: World, awaited: any, timeoutMs: number)
    local state <const> = enterPark(world, "yielding on a future")

    local settling <const> = awaited as Settling
    if type(settling) ~= "table" or settling.onSettle == nil or settling.status == nil then
        error("tecs: a coroutine system can only yield on something that settles", 3)
    end
    if timeoutMs ~= nil then
        if timeoutMs <= 0 then
            error("tecs: a yield timeout must be greater than zero", 3)
        end
        state.timeoutLeft = timeoutMs / 1000
    end

    state.wake = WAKE_SETTLING
    state.settling = settling
    settling:onSettle(state.onSettle)

    -- Already settled, so the listener has run and there is nothing to wait for.
    -- Carrying straight on rather than costing a frame is what lets a run of
    -- cached loads finish in the frame that asked for them.
    if state.settled then
        state.settling = nil
        return
    end

    coroutine.yield()
    state.settling = nil

    if state.timedOut then
        state.timedOut = false
        error(
            "tecs: coroutine system '"
                .. state.name
                .. "' timed out after "
                .. tostring(timeoutMs)
                .. "ms waiting here",
            3
        )
    end
end

return coroutines
