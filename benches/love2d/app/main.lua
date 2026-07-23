--- Generic bench app: loads the scenario named by TECS_BENCH_SCENARIO from
--- scenarios/<name>.lua, installs the harness frame probe, and runs the
--- real tecs2d loop. See harness.lua for the measurement protocol.

local tecs2d = require("tecs2d")
local harness = require("harness")

local name = os.getenv("TECS_BENCH_SCENARIO")
if not name or #name == 0 then
    error("TECS_BENCH_SCENARIO is required (a module under scenarios/)")
end
local scenario = require("scenarios." .. name)

love.run = tecs2d.run({
    fps = 60,
    game = function(world)
        harness.plugin({
            scenario = name,
            warmup = scenario.warmup,
            frames = scenario.frames,
            allocFrames = scenario.allocFrames,
            phase = scenario.probePhase,
            tick = scenario.tick,
            meta = scenario.meta,
        })(world)
        scenario.setup(world)
    end,
    render = scenario.render or {},
})
