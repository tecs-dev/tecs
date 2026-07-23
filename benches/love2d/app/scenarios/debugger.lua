--- Steady-state debugger overhead with an otherwise empty render world.
--- Set TECS_BENCH_DEBUG_OPEN=1 to render the overlay; omitted measures the
--- installed-but-closed baseline in the same process configuration.

local debug = require("tecs2d.debug")
local context = require("tecs2d.debug.context")
local tecs = require("tecs")
local tecs2d = require("tecs2d")

local OPEN = os.getenv("TECS_BENCH_DEBUG_OPEN") ~= nil
local PROFILE = os.getenv("TECS_BENCH_PROFILE") ~= nil

local function installProfiler(world)
    if not PROFILE then return end

    local profile = require("tecs.utils.profile")
    local getTime = love.timer.getTime
    local warmupStarted = getTime()
    local session = nil
    local sampleStarted = nil
    local sampleFrames = 0
    local seconds = tonumber(os.getenv("TECS_BENCH_PROFILE_SECONDS")) or 5
    local output = os.getenv("TECS_BENCH_PROFILE_OUT")
        or "/tmp/tecs-debugger-open.collapsed"

    world:addSystem({
        name = "bench.DebugProfiler",
        phase = tecs.phases.RenderFirst,
        run = function()
            local now = getTime()
            if not session then
                if now - warmupStarted < 1 then return end
                session = profile.sample({intervalMs = 1, stackDepth = 32})
                sampleStarted = now
                return
            end

            sampleFrames = sampleFrames + 1
            if now - sampleStarted < seconds then return end

            local elapsed = now - sampleStarted
            session:stop(output)
            print(string.format(
                "TECS_BENCH_PROFILE frames=%d seconds=%.3f fps=%.1f output=%s",
                sampleFrames, elapsed, sampleFrames / elapsed, output))
            tecs2d.quit(0)
        end,
    })
end

return {
    -- Profiling owns the process lifetime; keep the ordinary frame harness
    -- from reaching its allocation stage and quitting first.
    frames = PROFILE and 1000000000 or nil,
    -- The debugger suspends gameplay phases while open, so its frame clock
    -- must live in the render lane that remains active while frozen.
    probePhase = tecs.phases.RenderFirst,
    render = {
        lightingMode = "none",
        lerpingEnabled = false,
    },
    meta = {debugOpen = OPEN},
    setup = function(world)
        world:addPlugin(debug.new())
        world.resources[context.KEY].open = OPEN
        installProfiler(world)
    end,
}
