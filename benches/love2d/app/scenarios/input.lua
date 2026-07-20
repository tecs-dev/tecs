--- No-listener input flood: dispatches high-frequency mouse motion through
--- the real handler/router path. Measures the observer-count fast path and
--- catches accidental event construction when no routed target is listening.

local handlers = require("tecs2d.internal.handlers")

local EVENTS_PER_FRAME = tonumber(os.getenv("TECS_BENCH_INPUT_EVENTS")) or 10000
local mousemoved = handlers.handlers.mousemoved

return {
    render = {
        lightingMode = "forward",
        lerpingEnabled = false,
    },
    meta = {eventsPerFrame = EVENTS_PER_FRAME, observers = 0},
    setup = function(_world)
    end,
    tick = function(world, frame)
        local x = frame % 320
        local y = frame % 240
        for _ = 1, EVENTS_PER_FRAME do
            mousemoved(world, x, y, 1, 1, false)
        end
    end,
}
