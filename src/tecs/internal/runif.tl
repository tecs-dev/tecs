--- runIf.tl - Scheduling and timer helpers for system execution
local types <const> = require("tecs.types")

local random <const> = math.random

local type World = types.World

--- A runIf predicate function that determines if a system should run.
local type RunIfFn = function(dt: number, world: World, systemName: string): boolean

local record runIf
    --- Create a runIf predicate that fires once after a delay, then removes the system.
    ---
    --- The system will not run until the specified delay has elapsed.
    --- After firing once, the system is automatically removed from the pipeline.
    ---
    --- @param delay The delay in seconds before the system fires.
    --- @return A runIf predicate function.
    after: function(delay: number): RunIfFn

    --- Create a runIf predicate that fires repeatedly at regular intervals.
    ---
    --- The system will fire every `interval` seconds (approximately).
    --- Optional jitter can be added to desynchronize multiple systems
    --- using the same interval.
    ---
    --- @param interval The interval in seconds between fires.
    --- @param jitter Optional random variance (±jitter seconds) added to each interval.
    --- @return A runIf predicate function.
    every: function(interval: number, jitter?: number): RunIfFn

    --- Create a runIf predicate that fires immediately, then suppresses for a cooldown period.
    ---
    --- The first call will fire immediately. Subsequent calls are suppressed
    --- until the cooldown duration has elapsed since the last fire.
    ---
    --- @param duration The cooldown duration in seconds.
    --- @return A runIf predicate function.
    cooldown: function(duration: number): RunIfFn

    --- Create a runIf predicate that fires when the given state is on top of the state stack.
    ---
    --- @param name The state name to check.
    --- @return A runIf predicate function.
    inState: function(name: string): RunIfFn

    --- Create a runIf predicate that combines two predicates with logical AND.
    ---
    --- The combined predicate returns true only if both input predicates return true.
    ---
    --- @param lhs The first runIf predicate.
    --- @param rhs The second runIf predicate.
    --- @return A runIf predicate function.
    both: function(lhs: RunIfFn, rhs: RunIfFn): RunIfFn

    --- Create a runIf predicate that combines two predicates with logical OR.
    ---
    --- The combined predicate returns true if either input predicate returns true.
    ---
    --- @param lhs The first runIf predicate.
    --- @param rhs The second runIf predicate.
    --- @return A runIf predicate function.
    either: function(lhs: RunIfFn, rhs: RunIfFn): RunIfFn

    --- Create a runIf predicate that inverts another runIf predicate.
    ---
    --- @param predicate The runIf predicate to invert.
    --- @return A runIf predicate function that returns the opposite of the input predicate.
    negate: function(predicate: RunIfFn): RunIfFn
end

function runIf.after(delay: number): RunIfFn
    local elapsed: number = 0
    local hasFired = false

    return function(dt: number, world: World, systemName: string): boolean
        if hasFired then
            return false
        end

        elapsed = elapsed + dt
        if elapsed >= delay then
            hasFired = true
            -- Remove system immediately (this is safe because we use pre-flattened arrays)
            world:removeSystem(systemName)
            return true
        end

        return false
    end
end

function runIf.every(interval: number, jitter?: number): RunIfFn
    local elapsed: number = 0
    local currentInterval = interval
    jitter = jitter or 0

    -- Return a simplified function if no jitter is specified
    if jitter == 0 then
        return function(dt: number, _world: World, _systemName: string): boolean
            elapsed = elapsed + dt
            if elapsed >= interval then
                elapsed = elapsed - interval
                return true
            end
            return false
        end
    end

    return function(dt: number, _world: World, _systemName: string): boolean
        elapsed = elapsed + dt
        if elapsed >= currentInterval then
            elapsed = elapsed - currentInterval
            -- Apply jitter for next interval. Clamp so jitter >= interval
            -- cannot roll a zero or negative interval that fires every
            -- frame until the next roll.
            local variance = (random() * 2 - 1) * jitter
            currentInterval = interval + variance
            if currentInterval < interval * 0.01 then
                currentInterval = interval * 0.01
            end
            return true
        end
        return false
    end
end

function runIf.cooldown(duration: number): RunIfFn
    local elapsed: number = duration  -- Start ready to fire

    return function(dt: number, _world: World, _systemName: string): boolean
        elapsed = elapsed + dt

        if elapsed >= duration then
            elapsed = 0
            return true
        end

        return false
    end
end

function runIf.inState(name: string): RunIfFn
    return function(_dt: number, world: World, _systemName: string): boolean
        return world:peekState() == name
    end
end

-- Both combinators short-circuit, so operand ORDER is part of the API
-- for stateful predicates (`every`, `cooldown`): the rhs receives dt
-- only on ticks where the lhs lets evaluation reach it.
--
--   both(inState("menu"), every(1))  -- timer FROZEN outside the menu;
--                                    -- resumes where it left off
--   both(every(1), inState("menu"))  -- timer keeps running; fires that
--                                    -- land outside the menu are spent
--
-- Put the gate first to pause a timer with the gate, the timer first to
-- keep its cadence independent of the gate.
function runIf.both(lhs: RunIfFn, rhs: RunIfFn): RunIfFn
    return function(dt: number, world: World, systemName: string): boolean
        return lhs(dt, world, systemName) and rhs(dt, world, systemName)
    end
end

function runIf.either(lhs: RunIfFn, rhs: RunIfFn): RunIfFn
    return function(dt: number, world: World, systemName: string): boolean
        return lhs(dt, world, systemName) or rhs(dt, world, systemName)
    end
end

function runIf.negate(predicate: RunIfFn): RunIfFn
    return function(dt: number, world: World, systemName: string): boolean
        return not predicate(dt, world, systemName)
    end
end

return runIf
