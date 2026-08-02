--- Measures the reusable coroutine primitives behind world updates.

local getenv <const> = os.getenv
local clock <const> = os.clock
local format <const> = string.format

local root = getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local type tasks = require("tecs.internal.taskruntime")
local task <const> = require("tecs.internal.taskruntime")

local OPERATIONS <const> = tonumber(getenv("BENCH_TASK_OPERATIONS")) as integer or 1000000

local function measure(name: string, body: function(): integer)
    for _ = 1, 5 do
        body()
    end
    local started <const> = clock()
    local answer = 0
    for _ = 1, OPERATIONS do
        answer = answer + body()
    end
    local elapsed <const> = clock() - started
    if answer == 0 then
        error("bench: no coroutine work completed", 0)
    end
    print(format("async %-24s %.1f ns/op", name, elapsed * 1000000000 / OPERATIONS))
end

local scheduler <const> = task.newScheduler()
local cycles = 0
local function reusableBody(_scope: tasks.Scope): integer
    cycles = cycles + 1
    return cycles
end
local reusable = scheduler:spawnReusableImmediate(reusableBody)

measure(
    "reusable coroutine",
    function(): integer scheduler:restartImmediate(reusable); return reusable.status == "ready" and 1 or 0 end
)

local readyGate <const> = task.newGate()
readyGate:complete(true)
local schedulerReady <const> = task.newScheduler()
local inline = schedulerReady:spawnReusableImmediate(function(): integer readyGate:wait(); return 1 end)

measure(
    "already-ready await",
    function(): integer
        readyGate:reset()
        readyGate:complete(true)
        schedulerReady:restartImmediate(inline)
        return inline.status == "ready" and 1 or 0
    end
)
