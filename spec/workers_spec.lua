-- Worker threads and channels.
--
-- Each worker is a real OS thread running its own lua_State. LuaJIT has no
-- shared mutable heap across threads, so nothing crosses except serialized
-- bytes, and these tests exist mostly to pin that boundary: what survives the
-- trip, what order it arrives in, and that a blocked worker can be stopped.

package.path = "build/?.lua;build/?/init.lua;"
    .. "../tecs/build/?.lua;../tecs/build/?/init.lua;" .. package.path

local workers = require("tecs2d.workers")

-- Every worker resolves modules the same way the spec does.
local PRELUDE = 'package.path = "build/?.lua;build/?/init.lua;" .. package.path\n'

local ECHO = PRELUDE .. [[
local workers = require("tecs2d.workers")
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
        if value == nil then break end
        got[#got + 1] = value
    end
    return got
end

describe("workers", function()
    it("loads its native library", function()
        assert.is_string(workers.path)
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
        for index = 1, 20 do worker:send({ index = index }) end

        local results = drain(worker, 20)
        assert.are.equal(20, #results)
        for index = 1, 20 do
            assert.are.equal(index, results[index].index,
                "a channel is a queue, not a bag")
        end
        worker:stop()
    end)

    it("actually computes on the other thread", function()
        local worker = workers.spawn({ source = PRELUDE .. [[
local workers = require("tecs2d.workers")
local self = workers.current()
while true do
    local task = self:receive()
    if task == nil then break end
    local total = 0
    for i = 1, task.upTo do total = total + i end
    self:send({ total = total })
end
]] })
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
        local worker = workers.spawn({ source = PRELUDE .. [[
local workers = require("tecs2d.workers")
local self = workers.current()
while true do
    local task = self:receive()
    if task == nil then break end
    self:send(task)
end
]] })
        worker:send({ a = 1 })
        drain(worker, 1)
        assert.are.equal(0, worker:available(),
            "a taken result is no longer waiting")
        worker:stop()
    end)

    it("rejects values it cannot serialize", function()
        local worker = workers.spawn({ source = ECHO })
        -- Functions cannot cross: the other state could not run them, since
        -- it shares no heap and no upvalues with this one.
        assert.is_false(pcall(function()
            worker:send({ callback = function() end })
        end))
        worker:stop()
    end)
end)
