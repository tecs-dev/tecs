-- Worker threads and channels.
--
-- Each worker is a real OS thread running its own lua_State. LuaJIT has no
-- shared mutable heap across threads, so nothing crosses except serialized
-- bytes, and these tests exist mostly to pin that boundary: what survives the
-- trip, what order it arrives in, and that a blocked worker can be stopped.

-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local workers = require("tecs.workers")
local tecs = require("tecs")
local runtime = require("tecs.internal.runtime")
local sdl = require("tecs.ffi.sdl3")

local C = sdl.C

-- Every worker resolves modules the same way the spec does.
local PRELUDE = 'package.path = "build/?.lua;build/?/init.lua;" .. package.path\n'

local ECHO = PRELUDE
    .. [[
local workers = require("tecs.workers")
local self = workers.current()
while true do
    local task = self:receive()
    if task == nil then break end
    self:send(task)
end
]]

-- Collects `count` results, or fewer if the worker goes quiet.
local function drain(worker, count, timeoutMs)
    local got = {}
    for _ = 1, count do
        local value = worker:receive(timeoutMs or 2000)
        if value == nil then
            break
        end
        got[#got + 1] = value
    end
    return got
end

describe("workers", function()
    it("loads its native library", function()
        assert.is_string(workers.path)
        assert.is_function(workers.newChannel)
    end)

    it("round trips a table through another state", function()
        local worker = workers.spawn({ source = ECHO })
        worker:send({ id = 7, name = "task", nested = { 1, 2, 3 } })

        local results = drain(worker, 1)
        assert.are.equal(1, #results)
        assert.are.equal(7, results[1].id)
        assert.are.equal("task", results[1].name)
        assert.are.same({ 1, 2, 3 }, results[1].nested)

        assert.are.equal(0, worker:stop())
    end)

    it("preserves order", function()
        local worker = workers.spawn({ source = ECHO })
        for index = 1, 20 do
            worker:send({ index = index })
        end

        local results = drain(worker, 20)
        assert.are.equal(20, #results)
        for index = 1, 20 do
            assert.are.equal(index, results[index].index, "a channel is a queue, not a bag")
        end
        worker:stop()
    end)

    it("actually computes on the other thread", function()
        local worker = workers.spawn({
            source = PRELUDE .. [[
local workers = require("tecs.workers")
local self = workers.current()
while true do
    local task = self:receive()
    if task == nil then break end
    local total = 0
    for i = 1, task.upTo do total = total + i end
    self:send({ total = total })
end
]],
        })
        worker:send({ upTo = 1000 })
        local results = drain(worker, 1)
        assert.are.equal(500500, results[1].total)
        worker:stop()
    end)

    it("runs several workers at once", function()
        local pool = {}
        for index = 1, 4 do
            pool[index] = workers.spawn({ source = ECHO })
            pool[index]:send({ from = index })
        end

        local seen = {}
        for index = 1, 4 do
            local value = pool[index]:receive(2000)
            assert.is_not_nil(value, "every worker should answer")
            seen[value.from] = true
        end

        for index = 1, 4 do
            assert.is_true(seen[index], "worker " .. index .. " went missing")
            pool[index]:stop()
        end
    end)

    it("stops a worker that is blocked waiting for work", function()
        -- The worker is parked in a blocking receive. Closing its inbox is
        -- what lets it observe the shutdown and leave its loop; without that
        -- the join below would never return.
        local worker = workers.spawn({ source = ECHO })
        assert.are.equal(0, worker:stop())
        assert.are.equal(0, worker:stop(), "stopping twice is harmless")
    end)

    it("reports queue depth on both sides", function()
        local worker = workers.spawn({
            source = PRELUDE .. [[
local workers = require("tecs.workers")
local self = workers.current()
while true do
    local task = self:receive()
    if task == nil then break end
    self:send(task)
end
]],
        })
        worker:send({ a = 1 })
        drain(worker, 1)
        assert.are.equal(0, worker:available(), "a taken result is no longer waiting")
        worker:stop()
    end)

    it("watches its own traces when asked, and stops either way", function()
        -- A worker cannot be told anything at spawn but its source, so the
        -- switch is an environment variable and the environment is the
        -- process's. Set around the spawn and cleared after it, so no other
        -- spec inherits it.
        local ffi = require("ffi")
        ffi.cdef([[
            int tecsSpecSetenv(const char *, const char *, int) asm("setenv");
            int tecsSpecUnsetenv(const char *) asm("unsetenv");
        ]])

        ffi.C.tecsSpecSetenv("TECS_TRACEPROF", "1", 1)
        local watched = workers.spawn({ source = ECHO })
        watched:send({ id = 1 })

        -- An answer means the worker has read the variable, so clearing it
        -- here cannot race the read it is meant to be seen by.
        assert.are.equal(1, #drain(watched, 1), "watching must not change what a worker does")
        ffi.C.tecsSpecUnsetenv("TECS_TRACEPROF")

        -- Reporting happens where the inbox closes, and closing it is what
        -- `stop` does. A worker whose report raised would join non-zero.
        assert.are.equal(0, watched:stop())

        local plain = workers.spawn({ source = ECHO })
        plain:send({ id = 2 })
        assert.are.equal(1, #drain(plain, 1))
        assert.are.equal(0, plain:stop())
    end)

    it("does not read a poll that came up empty as a closed inbox", function()
        -- A worker that polls sees nil whenever its queue is empty, which says
        -- nothing about whether it has been asked to stop. Only a wait with no
        -- timeout does.
        local worker = workers.spawn({
            source = PRELUDE .. [[
local workers = require("tecs.workers")
local self = workers.current()
local empty = 0
local task = self:receive(0)
while task == nil and empty < 200000 do
    empty = empty + 1
    task = self:receive(0)
end
self:send({ empty = empty, arrived = task ~= nil })
while self:receive() ~= nil do end
]],
        })
        worker:send({ go = true })
        local results = drain(worker, 1)
        assert.are.equal(1, #results)
        assert.is_true(results[1].arrived, "a polling worker keeps its loop through empty polls")
        assert.are.equal(0, worker:stop())
    end)

    it("rejects values it cannot serialize", function()
        -- Tested on a bare channel rather than through a worker: what is
        -- under test is the encoder rejecting a function, and a live thread
        -- has nothing to do with that.
        --
        local channel = workers.newChannel()

        -- Functions cannot cross: the other state shares neither heap nor
        -- upvalues with this one, so it could not run them. The rejection
        -- names the path, which the encoder's own message does not.
        local ok, err = pcall(function()
            channel:send({ nested = { callback = function() end } })
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("value.nested.callback is a function"))

        -- Non-string, non-number keys cannot cross either.
        assert.is_false(pcall(function()
            channel:send({ [{}] = 1 })
        end))

        channel:send({ fine = 1, nested = { "ok" } })
        assert.are.equal(1, channel:count())
        assert.are.equal(1, channel:receive(0).fine)
        channel:destroy()
    end)

    it("reports a closed channel apart from an empty one", function()
        local channel = workers.newChannel()
        assert.is_false(channel:isClosed())

        channel:send({ last = true })
        channel:close()

        -- Closed is not drained: what was queued before the close still
        -- arrives, and only then does the reader see nil for good.
        assert.is_true(channel:isClosed())
        assert.are.equal(1, channel:count())
        assert.is_true(channel:receive(0).last)
        assert.is_nil(channel:receive(0))

        channel:destroy()
        assert.is_true(channel:isClosed(), "a destroyed channel can never answer again")
    end)
end)

-- Suspending receives. These drive a world rather than the channel API,
-- because what is under test is that a system waiting on a worker releases the
-- SDL thread instead of blocking it.

-- Waits for one message and then ends, so the spawner is parked on a result
-- that will never come.
local SILENT = PRELUDE .. [[
local workers = require("tecs.workers")
local self = workers.current()
self:receive()
]]

-- Drives the process pump the way the Application does, once per iteration.
local function pumpUntil(satisfied, what)
    local deadline = C.SDL_GetTicks() + 2000
    repeat
        runtime.poll()
        if satisfied() then
            return
        end
        C.SDL_Delay(1)
    until C.SDL_GetTicks() >= deadline
    error(what)
end

local function unparked()
    return workers.parked() == 0
end

describe("suspending worker receives", function()
    setup(function()
        assert(C.SDL_Init(0))
    end)

    teardown(function()
        C.SDL_Quit()
    end)

    before_each(function()
        assert.are.equal(0, workers.parked(), "a previous test left a receiver parked")
        assert.is_false(runtime.registered("workers"), "a previous test left the source registered")
    end)

    it("parks the calling system and resumes at the receive", function()
        local worker = workers.spawn({ source = ECHO })
        local world = tecs.ecs.newWorld()
        local order = {}
        local answer

        world:addSystem({
            name = "WorkerReceive",
            phase = tecs.ecs.phases.Update,
            run = function()
                order[#order + 1] = "receive"
                answer = worker:receive(-1)
                order[#order + 1] = "resumed"
            end,
        })
        world:addSystem({
            name = "AfterWorkerReceive",
            phase = tecs.ecs.phases.Last,
            run = function()
                order[#order + 1] = "after"
            end,
        })

        -- Nothing has been sent, so the receive has nothing to take and the
        -- update suspends rather than blocking the thread inside the C pop.
        assert.is_false(world:update(1 / 60))
        assert.is_true(world._updateStalled)
        assert.are.equal(1, workers.parked())
        assert.is_true(runtime.registered("workers"), "a parked receiver holds the runtime source")
        assert.are.same({ "receive" }, order)

        worker:send({ id = 11 })
        pumpUntil(unparked, "the worker result did not reach the pump")

        assert.is_true(world:update(1 / 60))
        assert.is_false(world._updateStalled)
        assert.are.equal(11, answer.id)
        assert.are.same({ "receive", "resumed", "after" }, order)
        assert.are.equal(0, workers.parked())
        assert.is_false(runtime.registered("workers"), "an idle facility releases the source")

        world:shutdown()
        assert.are.equal(0, worker:stop())
    end)

    it("takes a ready result inline without parking", function()
        local worker = workers.spawn({ source = ECHO })
        local world = tecs.ecs.newWorld()
        local answer

        worker:send({ id = 3 })
        pumpUntil(function()
            return worker:available() > 0
        end, "the worker did not answer")

        world:addSystem({
            name = "InlineWorkerReceive",
            phase = tecs.ecs.phases.Update,
            run = function()
                answer = worker:receive(-1)
            end,
        })

        assert.is_true(world:update(1 / 60))
        assert.is_false(world._updateStalled)
        assert.are.equal(3, answer.id)
        assert.are.equal(0, workers.parked())
        assert.is_false(runtime.registered("workers"), "an inline result registers nothing")

        world:shutdown()
        assert.are.equal(0, worker:stop())
    end)

    it("gives up a timed receive when its deadline passes", function()
        local worker = workers.spawn({ source = ECHO })
        local world = tecs.ecs.newWorld()
        local answer = "unset"

        world:addSystem({
            name = "TimedWorkerReceive",
            phase = tecs.ecs.phases.Update,
            run = function()
                answer = worker:receive(5)
            end,
        })

        assert.is_false(world:update(1 / 60))
        assert.are.equal(1, workers.parked())

        C.SDL_Delay(10)
        pumpUntil(unparked, "the expired receive was never released")

        assert.is_true(world:update(1 / 60))
        assert.is_nil(answer)
        assert.are.equal(0, workers.parked())

        world:shutdown()
        assert.are.equal(0, worker:stop())
    end)

    it("unwinds a resource scope when shutdown cancels a parked receive", function()
        local worker = workers.spawn({ source = ECHO })
        local world = tecs.ecs.newWorld()
        local closed = 0

        world:addSystem({
            name = "CanceledWorkerReceive",
            phase = tecs.ecs.phases.Update,
            run = function()
                tecs.scoped("canceled worker receive", function(scope)
                    scope:own({
                        close = function()
                            closed = closed + 1
                            return true
                        end,
                    })
                    worker:receive(-1)
                end)
            end,
        })

        assert.is_false(world:update(1 / 60))
        assert.are.equal(0, closed)
        assert.are.equal(1, workers.parked())

        -- Cancellation reaches the park through the gate it subscribed with,
        -- so the receiver unsubscribes rather than being left behind.
        world:shutdown()
        assert.are.equal(1, closed)
        assert.are.equal(0, workers.parked())
        assert.is_false(runtime.registered("workers"), "shutdown leaves no producer registered")

        assert.are.equal(0, worker:stop())
    end)

    it("releases a parked receive when the worker ends without answering", function()
        local worker = workers.spawn({ source = SILENT })
        local world = tecs.ecs.newWorld()
        local answer = "unset"

        world:addSystem({
            name = "OrphanedWorkerReceive",
            phase = tecs.ecs.phases.Update,
            run = function()
                answer = worker:receive(-1)
            end,
        })

        assert.is_false(world:update(1 / 60))
        assert.are.equal(1, workers.parked())

        -- The worker takes this one message and its source ends, which closes
        -- the outbox. That close is the only signal that no result is coming.
        worker:send({ go = true })
        pumpUntil(unparked, "the ended worker never released its receiver")

        assert.is_true(world:update(1 / 60))
        assert.is_nil(answer)
        assert.are.equal(0, workers.parked())
        assert.is_false(runtime.registered("workers"))

        world:shutdown()
        assert.are.equal(0, worker:stop())
    end)

    it("releases a parked receive when the worker is stopped", function()
        local worker = workers.spawn({ source = ECHO })
        local world = tecs.ecs.newWorld()
        local answer = "unset"

        world:addSystem({
            name = "StoppedWorkerReceive",
            phase = tecs.ecs.phases.Update,
            run = function()
                answer = worker:receive(-1)
            end,
        })

        assert.is_false(world:update(1 / 60))
        assert.are.equal(1, workers.parked())

        assert.are.equal(0, worker:stop())
        assert.are.equal(0, workers.parked(), "stop releases before it destroys the channels")
        assert.is_false(runtime.registered("workers"))

        assert.is_true(world:update(1 / 60))
        assert.is_nil(answer)
        assert.is_nil(worker:receive(-1), "a stopped worker answers nil without waiting")

        world:shutdown()
    end)

    it("blocks its own caller outside a system", function()
        local worker = workers.spawn({ source = ECHO })
        worker:send({ id = 5 })

        -- No task is running, so there is no frame to release and the native
        -- wait is both correct and free of the pump's latency.
        local answer = worker:receive(-1)
        assert.are.equal(5, answer.id)
        assert.are.equal(0, workers.parked())
        assert.is_false(runtime.registered("workers"), "a blocking wait registers nothing")

        assert.are.equal(0, worker:stop())
    end)

    it("rejects a timeout that is not a number", function()
        local worker = workers.spawn({ source = ECHO })
        local ok, err = pcall(function()
            worker:receive("soon")
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("must be a number of milliseconds", 1, true))
        assert.are.equal(0, worker:stop())
    end)
end)
