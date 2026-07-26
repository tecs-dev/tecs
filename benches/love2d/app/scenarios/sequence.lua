--- Sequence scheduler load: N playbacks that all wake on the fixed step and
--- run a call before waiting again. Measures the scheduler and the VM, not
--- rendering: the scene is empty.
---
--- TECS_BENCH_CURSORS   playbacks to run (default 1000)
--- TECS_BENCH_SEQ_WAIT  steps each playback sleeps between calls (default 1,
---                      so every playback runs on every step)
--- TECS_BENCH_SEQ_STAGGER=1 spreads their wake steps instead of leaving them
---                      in lockstep, which is the friendlier case for a heap
---                      keyed on (wakeAt, seq).

local sequence = require("tecs2d.sequence")

local CURSORS = tonumber(os.getenv("TECS_BENCH_CURSORS")) or 1000
local WAIT = tonumber(os.getenv("TECS_BENCH_SEQ_WAIT")) or 1
local STAGGER = os.getenv("TECS_BENCH_SEQ_STAGGER") == "1"

return {
    render = {
        lightingMode = "forward",
        lerpingEnabled = false,
    },
    meta = {
        cursors = CURSORS,
        waitSteps = WAIT,
        staggered = STAGGER,
    },
    setup = function(world)
        local ticks = 0
        sequence.registerAction(world, "bench.tick", function()
            ticks = ticks + 1
        end)

        local program = sequence.define("bench.loop", {
            sequence.loop(nil, {
                sequence.call("bench.tick"),
                sequence.waitSteps(WAIT),
            }),
        })

        -- A staggered playback opens with a one-off wait, so the population
        -- spreads across WAIT distinct wake steps.
        local staggered = {}
        for offset = 0, WAIT - 1 do
            staggered[offset] = sequence.define("bench.loop.offset" .. offset, {
                sequence.waitSteps(offset),
                sequence.loop(nil, {
                    sequence.call("bench.tick"),
                    sequence.waitSteps(WAIT),
                }),
            })
        end

        for i = 1, CURSORS do
            if STAGGER then
                sequence.play(world, staggered[i % WAIT])
            else
                sequence.play(world, program)
            end
        end
    end,
}
