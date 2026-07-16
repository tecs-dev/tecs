--- Deterministic dt override for the run loop. When a provider is installed
--- (the debugger's rewind replay), it is consulted once per frame with the
--- scaled dt the world is about to receive; returning a number replaces it,
--- returning nil keeps the measured value. This is the seam that lets a
--- recorded run replay with its original per-frame dt instead of live
--- wall-clock jitter: frames are the coordinate system, dt is data.

local record frameclock
    --- Installed by the replay driver; nil when no replay is active.
    provider: function(realDt: number): number

    --- Called by the run loop with the frame's scaled dt.
    apply: function(realDt: number): number
end

function frameclock.apply(realDt: number): number
    local p = frameclock.provider
    if p == nil then return realDt end
    local override = p(realDt)
    if override == nil then return realDt end
    return override
end

return frameclock
