--- Love2D bench harness: measures steady-state frame cost of a scenario.
---
--- The plugin installs a system in the First phase whose inter-invocation
--- wall-clock delta is one full frame (update + render + present; vsync is
--- off and TECS_BENCHMARK=1 skips the frame sleep). Measurement runs in
--- three stages:
---   1. warmup frames (JIT warmup, asset upload, steady state)
---   2. timing frames with the GC running normally (realistic frame times)
---   3. alloc frames with the GC stopped (exact Lua bytes allocated/frame)
--- then prints one "TECS_BENCH_RESULT {json}" line, writes the same JSON
--- to TECS_BENCH_OUT if set, and quits.

local tecs = require("tecs")
local tecs2d = require("tecs2d")
local json = require("tecs.utils.json")

local harness = {}

local function percentile(sorted, p)
    local idx = math.max(1, math.ceil(#sorted * p))
    return sorted[idx]
end

--- opts:
---   scenario   (string) scenario name for the report
---   warmup     (integer, default 120) frames before measurement
---   frames     (integer, default 300) timed frames
---   allocFrames(integer, default 60) GC-stopped allocation frames
---   phase      (tecs.Phase|nil) frame-probe phase (default First)
---   tick       (function(world, frame)|nil) per-frame scenario callback
---   meta       (table|nil) extra fields merged into the report
function harness.plugin(opts)
    return function(world)
        local warmup = tonumber(os.getenv("TECS_BENCH_WARMUP")) or opts.warmup or 120
        local timingFrames = tonumber(os.getenv("TECS_BENCH_FRAMES")) or opts.frames or 300
        local allocFrames = tonumber(os.getenv("TECS_BENCH_ALLOC_FRAMES")) or opts.allocFrames or 60

        local getTime = love.timer.getTime
        local frame = 0
        local lastTime = nil
        local deltas = {}
        local cpuDeltas = {}
        local frameStart = nil
        local allocStartKb = nil
        local allocStartFrame = nil
        local done = false

        -- CPU span: First-phase start to just before present. Excludes the
        -- present/GPU-flush block, so CPU-side work is visible even when
        -- the frame time is GPU-bound.
        world:addSystem({
            name = "bench.CpuProbe",
            phase = tecs.phases.RenderLast,
            before = {"love.Present"},
            run = function()
                if done or not frameStart then return end
                if frame > warmup and frame <= warmup + timingFrames then
                    cpuDeltas[#cpuDeltas + 1] = (getTime() - frameStart) * 1000.0
                end
                -- Diagnostic: dump which components are dirty on this
                -- steady-state frame (TECS_BENCH_DUMP_DIRTY=1).
                if os.getenv("TECS_BENCH_DUMP_DIRTY") and frame == warmup + 50 then
                    for arch in world:dirtyArchetypes() do
                        local dirtyNames = {}
                        local allNames = {}
                        for _, comp in ipairs(arch.componentList) do
                            allNames[#allNames + 1] = tostring(comp.componentName)
                        end
                        for comp in arch:dirtyComponents() do
                            dirtyNames[#dirtyNames + 1] = tostring(comp.componentName)
                        end
                        table.sort(allNames)
                        table.sort(dirtyNames)
                        print("DIRTY_ARCH dirty=[" .. table.concat(dirtyNames, ",")
                            .. "] all=[" .. table.concat(allNames, ",") .. "]")
                    end
                end
            end,
        })

        world:addSystem({
            name = "bench.FrameProbe",
            phase = opts.phase or tecs.phases.First,
            run = function()
                if done then return end
                frame = frame + 1
                if opts.tick then opts.tick(world, frame) end

                local now = getTime()
                frameStart = now
                if frame > warmup and frame <= warmup + timingFrames then
                    if lastTime then
                        deltas[#deltas + 1] = (now - lastTime) * 1000.0
                    end
                elseif frame == warmup + timingFrames + 1 then
                    -- Timing done; set up the GC-stopped allocation stage.
                    collectgarbage("collect")
                    collectgarbage("stop")
                    allocStartKb = collectgarbage("count")
                    allocStartFrame = frame
                elseif allocStartFrame and frame >= allocStartFrame + allocFrames then
                    local allocKb = (collectgarbage("count") - allocStartKb) / allocFrames
                    collectgarbage("restart")
                    done = true

                    table.sort(deltas)
                    table.sort(cpuDeltas)
                    local sum = 0
                    for i = 1, #deltas do sum = sum + deltas[i] end
                    local report = {
                        scenario = opts.scenario,
                        warmup = warmup,
                        frames = #deltas,
                        frameMs = {
                            mean = sum / math.max(1, #deltas),
                            p50 = percentile(deltas, 0.50),
                            p95 = percentile(deltas, 0.95),
                            max = deltas[#deltas],
                        },
                        cpuMs = {
                            p50 = percentile(cpuDeltas, 0.50),
                            p95 = percentile(cpuDeltas, 0.95),
                        },
                        allocKbPerFrame = allocKb,
                    }
                    if opts.meta then
                        for k, v in pairs(opts.meta) do report[k] = v end
                    end
                    local encoded = json.serialize(report)
                    print("TECS_BENCH_RESULT " .. encoded)
                    local outPath = os.getenv("TECS_BENCH_OUT")
                    if outPath and #outPath > 0 then
                        local f = io.open(outPath, "w")
                        if f then
                            f:write(encoded, "\n")
                            f:close()
                        end
                    end
                    tecs2d.quit(0)
                end
                lastTime = now
            end,
        })
    end
end

return harness
