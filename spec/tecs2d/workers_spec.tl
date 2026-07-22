require("busted")

local love2d_mock <const> = require("spec.love2d.love2d_mock")
rawset(_G, "love", love2d_mock)

local workers <const> = require("tecs2d.workers")
local luassert <const> = require("luassert")

describe("tecs2d.workers", function()
    local queue: workers.Queue
    local results: love.thread.Channel
    local job: workers.Job<string, string>

    before_each(function()
        queue = workers.new({threadCount = 1})
        results = ((queue as {string: any})._pullChannel) as love.thread.Channel
        job = workers.newJob("spec.jobs.echo") as workers.Job<string, string>
    end)

    after_each(function()
        if workers.queue == queue then workers.queue = nil end
        queue:shutdown()
    end)

    it("settles jobs and runs main-thread transforms", function()
        local transformed = queue:submit(job, "hello"):map(function(value: string): string
            return value .. " world"
        end)
        results:push({1, "hello", nil})
        queue:update()
        luassert.is_true(transformed.isComplete)
        luassert.equals("hello world", transformed.value)
    end)

    it("propagates job errors and supports recovery", function()
        local recovered = queue:submit(job, "bad"):handle(function(value: string, err: any): string
            if err then return "recovered: " .. tostring(err) end
            return value
        end)
        results:push({1, nil, "boom"})
        queue:update()
        luassert.equals("recovered: boom", recovered.value)
    end)

    it("flat maps only within the owning queue", function()
        local chained = queue:submit(job, "first"):flatMap(function(value: string): workers.Handle<string>
            return queue:submit(job, value .. " second")
        end)
        results:push({1, "first", nil})
        queue:update()
        results:push({3, "second", nil})
        queue:update()
        luassert.equals("second", chained.value)

        local other = workers.new({threadCount = 1})
        local invalid = queue:submit(job, "cross"):flatMap(function(_value: string): workers.Handle<string>
            return other:submit(job, "other")
        end)
        results:push({4, "cross", nil})
        queue:update()
        luassert.matches("same worker queue", invalid.err)
        other:shutdown()
    end)

    it("waits for all handles and preserves input order", function()
        local first = queue:submit(job, "first")
        local second = queue:submit(job, "second")
        local combined = queue:all({first, second})
        results:push({2, "two", nil})
        results:push({1, "one", nil})
        queue:update()
        luassert.same({"one", "two"}, combined.value)
    end)

    it("exposes a directly assignable global queue without lifecycle side effects", function()
        workers.queue = queue
        local handle = workers.submit(job, "global")
        results:push({1, "global", nil})
        workers.update()
        luassert.equals("global", handle.value)
    end)

    it("settles pending jobs on idempotent shutdown", function()
        local handle = queue:submit(job, "pending")
        queue:shutdown()
        queue:shutdown()
        luassert.is_true(handle.isComplete)
        luassert.matches("shut down", handle.err)
    end)
end)
