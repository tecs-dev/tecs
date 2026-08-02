--- Benchmarks the pooled phase runner's fast path and wait path.

local getenv <const> = os.getenv
local root = getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local phase <const> = require("tecs.internal.phaserunner")
local task <const> = require("tecs.internal.taskruntime")
local clock <const> = os.clock

local ITERATIONS <const> = tonumber(getenv("BENCH_ITERATIONS")) or 100000
local ONLY <const> = getenv("BENCH_CASE")

local function measure(label: string, iterations: number, run: function()): number
    if ONLY ~= nil and ONLY ~= label then
        return 0
    end
    collectgarbage("collect")
    for _ = 1, math.min(iterations, 10000) do
        run()
    end
    collectgarbage("collect")
    collectgarbage("stop")
    local beforeKb <const> = collectgarbage("count")
    local started <const> = clock()
    for _ = 1, iterations do
        run()
    end
    local elapsed <const> = clock() - started
    local bytesPerPhase <const> = (collectgarbage("count") - beforeKb) * 1024 / iterations
    collectgarbage("restart")
    io.write(("%-31s %9.1f ns/phase %8.3f B/phase\n"):format(label, elapsed * 1000000000 / iterations, bytesPerPhase))
    return elapsed
end

local sink = 0
local function synchronousSystem(index: integer)
    sink = sink + index
end

measure("direct one synchronous system", ITERATIONS, function() synchronousSystem(1) end)

local onePool <const> = phase.new()
measure("pooled one synchronous system", ITERATIONS, function() onePool:start(1, synchronousSystem) end)

measure("direct 100 synchronous systems", ITERATIONS, function() for index = 1, 100 do synchronousSystem(index) end end)

local hundredPool <const> = phase.new()
measure("pooled 100 synchronous systems", ITERATIONS, function() hundredPool:start(100, synchronousSystem) end)

-- This is the allocation-free version of the tempting alternative: keep one
-- permanent reusable coroutine per system and cross its boundary every phase.
-- It gives that design its best case without task construction in the sample.
local perSystemScheduler <const> = task.newScheduler()
local perSystemTasks: {task.Task<boolean>} = {}
for index = 1, 100 do
    local systemIndex <const> = index
    perSystemTasks[index] = perSystemScheduler:spawnReusableImmediate(function(): boolean
        synchronousSystem(systemIndex)
        return true
    end)
end
measure(
    "100 permanent system coroutines",
    ITERATIONS,
    function() for index = 1, 100 do perSystemScheduler:restartImmediate(perSystemTasks[index]) end end
)

local cacheIterations <const> = math.max(1000, math.floor(ITERATIONS / 100))
local function tenThousandCacheHits(_index: integer)
    for entity = 1, 10000 do
        sink = sink + entity
    end
end

measure("direct 10k hits in one system", cacheIterations, function() tenThousandCacheHits(1) end)

local cachePool <const> = phase.new()
measure("pooled 10k hits in one system", cacheIterations, function() cachePool:start(1, tenThousandCacheHits) end)

local oneGate <const> = task.newGate()
local oneMissPool <const> = phase.new()
local function oneMissSystem(index: integer)
    if index == 50 then
        oneGate:wait()
    end
    sink = sink + index
end
measure(
    "100 systems, one wait",
    ITERATIONS,
    function() oneGate:reset(); oneMissPool:start(100, oneMissSystem); oneGate:complete(true); oneMissPool:poll() end
)

local gates: {task.Gate} = {}
for index = 1, 10 do
    gates[index] = task.newGate()
end
local tenMissPool <const> = phase.new()
local function tenMissSystem(index: integer)
    if index <= 10 then
        gates[index]:wait()
    end
    sink = sink + index
end
measure(
    "100 systems, ten waits",
    ITERATIONS,
    function()
        for index = 1, 10 do
            gates[index]:reset()
        end
        tenMissPool:start(100, tenMissSystem)
        for index = 1, 10 do
            gates[index]:complete(true)
        end
        tenMissPool:poll()
    end
)

if ONLY == nil then
    io.write(
        ("runners: sync=%d one-wait=%d ten-wait=%d sink=%d\n"):format(
            hundredPool.createdCount, oneMissPool.createdCount, tenMissPool.createdCount, sink
        )
    )
end
