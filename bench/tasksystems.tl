--- Benchmarks the unified resumable world-update path.

local getenv <const> = os.getenv
local root = getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local ecs <const> = require("tecs.ecs")
local phases <const> = require("tecs.internal.phases")
local task <const> = require("tecs.internal.taskruntime")
local clock <const> = os.clock

local record PipelineView
    update: function(self: PipelineView, dt: number, world: any)
end

local record WorldView
    _commit: function(self: WorldView)
end

local ITERATIONS <const> = tonumber(getenv("BENCH_ITERATIONS")) or 100000
local ONLY <const> = getenv("BENCH_CASE")

local function measure(label: string, run: function()): number
    if ONLY ~= nil and ONLY ~= label then
        return 0
    end
    collectgarbage("collect")
    for _ = 1, 10000 do
        run()
    end
    collectgarbage("collect")
    collectgarbage("stop")
    local beforeKb <const> = collectgarbage("count")
    local started <const> = clock()
    for _ = 1, ITERATIONS do
        run()
    end
    local elapsed <const> = clock() - started
    local bytesPerUpdate <const> = (collectgarbage("count") - beforeKb) * 1024 / ITERATIONS
    collectgarbage("restart")
    io.write(
        ("%-28s %8.1f ns/update %8.3f B/update\n"):format(label, elapsed * 1000000000 / ITERATIONS, bytesPerUpdate)
    )
    return elapsed
end

-- This calls the synchronous dispatch boundary directly. The worlds in these
-- comparisons do not mutate, so dirty-bit cleanup is empty in both cases. The
-- commit is retained because every deferred-only world update now owns that
-- scheduler boundary. This isolates the reusable coroutine wrapper from the
-- work it contains.
local directEmptyWorld <const> = ecs.newWorld()
local directEmptyPipeline <const> = (directEmptyWorld as {string: any}).pipeline as PipelineView
local directEmptyView <const> = directEmptyWorld as WorldView
measure(
    "direct empty pipeline",
    function() directEmptyView:_commit(); directEmptyPipeline:update(1 / 60, directEmptyWorld) end
)

local emptyWorld <const> = ecs.newWorld()
measure("empty world", function() emptyWorld:update(1 / 60) end)

local directSystemWorld <const> = ecs.newWorld()
local directCalls = 0
directSystemWorld:addSystem({
    name = "bench.DirectSystem",
    phase = phases.Update,
    run = function() directCalls = directCalls + 1 end,
})
local directSystemPipeline <const> = (directSystemWorld as {string: any}).pipeline as PipelineView
local directSystemView <const> = directSystemWorld as WorldView
measure(
    "direct one system",
    function() directSystemView:_commit(); directSystemPipeline:update(1 / 60, directSystemWorld) end
)

local systemWorld <const> = ecs.newWorld()
local calls = 0
systemWorld:addSystem({
    name = "bench.UnifiedSystem",
    phase = phases.Update,
    run = function() calls = calls + 1 end,
})
measure("one synchronous system", function() systemWorld:update(1 / 60) end)

local readyGate <const> = task.newGate()
readyGate:complete(true)
local readyWorld <const> = ecs.newWorld()
readyWorld:addSystem({
    name = "bench.ReadyAwait",
    phase = phases.Update,
    run = function() readyGate:wait() end,
})
measure(
    "one already-ready await", function() readyGate:reset(); readyGate:complete(true); readyWorld:update(1 / 60) end
)

local waitingGate <const> = task.newGate()
local waitingWorld <const> = ecs.newWorld()
waitingWorld:addSystem({
    name = "bench.SuspendResume",
    phase = phases.Update,
    run = function() waitingGate:wait() end,
})
measure(
    "one suspend + resume",
    function()
        waitingGate:reset()
        waitingWorld:update(1 / 60)
        waitingGate:complete(true)
        waitingWorld:update(1 / 60)
    end
)

if ONLY == nil and (calls == 0 or directCalls == 0) then
    error("bench: system calls were not observed", 0)
end
