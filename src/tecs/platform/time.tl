--[=[
Frame timing, with an injectable source.

The application calls `step` once per iteration and passes the result to the
world. `maxDelta` clamps long stalls before simulation sees them. Game code
may read `now`, but it must not call `step` because that moves the frame
baseline.

Install a provider to replace measured frame deltas during replay:

```teal
local recorded <const>: {number} = {1 / 60, 1 / 60, 1 / 30}
local frame = 0

tecs.time.provider = function(realDt: number): number
    frame = frame + 1
    -- Nil keeps the measurement, so a run past the end of the recording is
    -- live again.
    return recorded[frame]
end
```

Returning nil keeps the measured delta. Pair this provider with
`tecs.events.source` to replay frame timing and platform events together.
`now` always reads the monotonic platform clock and ignores the replay
provider.
]=]

local sdl <const> = require("tecs.ffi.sdl3")

local C <const> = sdl.C

local record time
    --- Caller-writable. Installs a replay hook that receives the measured
    --- frame delta. Returning a number replaces it; returning nil keeps it.
    ---
    --- @param realDt The application supplies the measured frame delta in seconds.
    --- @return A number replaces the measured delta, while nil keeps it.
    provider: function(realDt: number): number

    --- Caller-writable. Sets the nominal frame delta in seconds. The
    --- application initializes it from the target frame rate.
    nominal: number

    --- Caller-writable. Sets the longest frame delta in seconds that `step`
    --- returns.
    maxDelta: number
end

time.nominal = 1.0 / 60.0
time.maxDelta = 0.25

local frequency: number = 0.0
local last: number = 0.0

--- Reads the monotonic counter in seconds. Not affected by the provider.
function time.now(): number
    if frequency == 0.0 then
        frequency = tonumber(C.SDL_GetPerformanceFrequency()) as number
    end
    return (tonumber(C.SDL_GetPerformanceCounter()) as number) / frequency
end

--- Resets the baseline so the next `step` measures from now. Called after
--- startup so the first frame's dt excludes load time.
function time.reset()
    last = time.now()
end

--- Advances one frame and returns the dt the world should receive.
---
--- Clamps to `maxDelta`, then offers the value to `provider`.
function time.step(): number
    local now = time.now()
    if last == 0.0 then
        last = now
    end
    local dt = now - last
    last = now

    if dt > time.maxDelta then
        dt = time.maxDelta
    end

    local p = time.provider
    if p ~= nil then
        local override = p(dt)
        if override ~= nil then
            return override
        end
    end
    return dt
end

return time
