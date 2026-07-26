--- Frame timing, with an injectable source.
---
--- Nondeterminism enters the engine through this module and `events`. Both
--- take their input from a provider that defaults to the real thing, which is
--- what makes recorded replay possible: frames are the coordinate system, dt
--- is data. Reading the performance counter directly from the run loop would
--- make deterministic replay unimplementable rather than merely unimplemented.

local sdl <const> = require("tecs2d.ffi.sdl3")

local C <const> = sdl.C

local record clock
    --- Installed by a replay driver. Consulted once per frame with the
    --- measured dt; returning a number replaces it, nil keeps the measurement.
    provider: function(realDt: number): number

    --- The loop's nominal frame dt, set at boot from the target frame rate.
    --- Stepped frames use it so a step advances identically on every machine.
    nominal: number

    --- Longest dt handed to the world. A frame that stalls (a breakpoint, a
    --- window drag) must not integrate as one enormous step.
    maxDelta: number
end

clock.nominal = 1.0 / 60.0
clock.maxDelta = 0.25

local frequency: number = 0.0
local last: number = 0.0

--- Reads the monotonic counter in seconds. Not affected by the provider.
function clock.now(): number
    if frequency == 0.0 then
        frequency = tonumber(C.SDL_GetPerformanceFrequency()) as number
    end
    return (tonumber(C.SDL_GetPerformanceCounter()) as number) / frequency
end

--- Resets the baseline so the next `step` measures from now. Called after
--- startup so the first frame's dt excludes load time.
function clock.reset()
    last = clock.now()
end

--- Advances one frame and returns the dt the world should receive.
---
--- Clamps to `maxDelta`, then offers the value to `provider`.
function clock.step(): number
    local now = clock.now()
    if last == 0.0 then last = now end
    local dt = now - last
    last = now

    if dt > clock.maxDelta then dt = clock.maxDelta end

    local p = clock.provider
    if p ~= nil then
        local override = p(dt)
        if override ~= nil then return override end
    end
    return dt
end

return clock
