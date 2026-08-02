--- Compares per-phase coroutine pooling with one update-wide primary runner.

local getenv <const> = os.getenv
local root = getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local phase <const> = require("tecs.internal.phaserunner")
local task <const> = require("tecs.internal.taskruntime")
local update <const> = require("tecs.internal.updaterunner")
local clock <const> = os.clock

local ITERATIONS <const> = tonumber(getenv("BENCH_ITERATIONS")) or 500000
local ONLY <const> = getenv("BENCH_CASE")
local PHASE_COUNT <const> = 10
local SYSTEM_COUNT <const> = 10
local counts: {integer} = {}
for phaseIndex = 1, PHASE_COUNT do
    counts[phaseIndex] = SYSTEM_COUNT
end

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
    local bytesPerUpdate <const> = (collectgarbage("count") - beforeKb) * 1024 / iterations
    collectgarbage("restart")
    io.write(
        ("%-32s %9.1f ns/update %8.3f B/update\n"):format(label, elapsed * 1000000000 / iterations, bytesPerUpdate)
    )
    return elapsed
end

local sink = 0
local function runSystem(phaseIndex: integer, systemIndex: integer)
    sink = sink + phaseIndex + systemIndex
end
local function commitPhase(phaseIndex: integer)
    sink = sink + phaseIndex
end

local function runDirectUpdate()
    for phaseIndex = 1, PHASE_COUNT do
        for systemIndex = 1, SYSTEM_COUNT do
            runSystem(phaseIndex, systemIndex)
        end
        commitPhase(phaseIndex)
    end
end

measure("direct 10 phases / 100 systems", ITERATIONS, function() runDirectUpdate() end)

-- This is the current fast shape: one reusable coroutine around the entire
-- update. It cannot spill when a system waits, but establishes the lower bound
-- for the update-wide pool's synchronous path.
local wholeScheduler <const> = task.newScheduler()
local wholeTask <const> = wholeScheduler:spawnReusableImmediate(function(): boolean runDirectUpdate(); return true end)
measure("one non-spilling update coroutine", ITERATIONS, function() wholeScheduler:restartImmediate(wholeTask) end)

local phasePool <const> = phase.new()
local currentPhase = 0
local function runPhaseSystem(systemIndex: integer)
    runSystem(currentPhase, systemIndex)
end
measure(
    "ten independently pooled phases",
    ITERATIONS,
    function()
        for phaseIndex = 1, PHASE_COUNT do
            currentPhase = phaseIndex
            phasePool:start(SYSTEM_COUNT, runPhaseSystem)
            commitPhase(phaseIndex)
        end
    end
)

local updatePool <const> = update.new()
measure(
    "one update-wide primary runner",
    ITERATIONS,
    function() updatePool:start(PHASE_COUNT, counts, runSystem, commitPhase) end
)

local phaseGate <const> = task.newGate()
local waitingPhasePool <const> = phase.new()
local function runWaitingPhaseSystem(systemIndex: integer)
    if currentPhase == 5 and systemIndex == 5 then
        phaseGate:wait()
    end
    runSystem(currentPhase, systemIndex)
end
measure(
    "per-phase pool, one wait",
    ITERATIONS,
    function()
        phaseGate:reset()
        for phaseIndex = 1, PHASE_COUNT do
            currentPhase = phaseIndex
            local complete <const> = waitingPhasePool:start(SYSTEM_COUNT, runWaitingPhaseSystem)
            if not complete then
                phaseGate:complete(true)
                waitingPhasePool:poll()
            end
            commitPhase(phaseIndex)
        end
    end
)

local updateGate <const> = task.newGate()
local waitingUpdatePool <const> = update.new()
local function runWaitingUpdateSystem(phaseIndex: integer, systemIndex: integer)
    if phaseIndex == 5 and systemIndex == 5 then
        updateGate:wait()
    end
    runSystem(phaseIndex, systemIndex)
end
measure(
    "update-wide runner, one wait",
    ITERATIONS,
    function()
        updateGate:reset()
        waitingUpdatePool:start(PHASE_COUNT, counts, runWaitingUpdateSystem, commitPhase)
        updateGate:complete(true)
        waitingUpdatePool:poll()
    end
)

if ONLY == nil then
    io.write(
        ("runners: phase=%d update=%d phase-wait=%d update-wait=%d sink=%d\n"):format(
            phasePool.createdCount,
            updatePool.createdCount,
            waitingPhasePool.createdCount,
            waitingUpdatePool.createdCount,
            sink
        )
    )
end
