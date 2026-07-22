require("busted")

-- Set up Love2D mock before requiring anything else
local love2d_mock <const> = require("spec.love2d.love2d_mock")
rawset(_G, "love", love2d_mock)

local assets <const> = require("tecs2d.assets")
local workers <const> = require("tecs2d.workers")
local luassert <const> = require("luassert")

describe("asset handles", function()
    local manager: assets.AssetManager
    local queue: workers.Queue
    -- Each worker queue owns a uniquely named result channel, so independent
    -- queues cannot steal each other's results.
    local resultChannel: love.thread.Channel

    before_each(function()
        queue = workers.new()
        manager = assets.new("assets", queue)
        resultChannel = ((queue as {string: any})._pullChannel) as love.thread.Channel
    end)

    after_each(function()
        if manager then
            manager:shutdown()
        end
        if queue then queue:shutdown() end
    end)

    describe("handle", function()
        it("calls callback with value on success", function()
            -- Create a simple handle that succeeds immediately
            local imageHandle = manager:loadImage("test.png")

            -- Simulate completion by pushing result to the channel
            resultChannel:push({1, {getDimensions = function() return 64, 64 end}, nil})
            queue:update()

            local handledResult: {string: any} = nil
            local handled = imageHandle:handle(function(value: any, err: any): {string: any}
                return { gotValue = value ~= nil, gotErr = err }
            end)

            -- The handle callback should have run
            queue:update()
            luassert.is_true(handled.isComplete)
            handledResult = handled.value
            luassert.is_true(handledResult.gotValue)
            luassert.is_nil(handledResult.gotErr)
        end)

        it("calls callback with error on failure", function()
            local imageHandle = manager:loadImage("missing.png")

            -- Simulate failure
            resultChannel:push({1, nil, "File not found"})
            queue:update()

            local handled = imageHandle:handle(function(value: any, err: any): {string: any}
                return { gotValue = value, gotErr = err }
            end)

            queue:update()
            luassert.is_true(handled.isComplete)
            local result = handled.value
            luassert.is_nil(result.gotValue)
            luassert.equals("File not found", result.gotErr)
        end)

        it("can recover from errors", function()
            local imageHandle = manager:loadImage("missing.png")

            -- Simulate failure
            resultChannel:push({1, nil, "File not found"})
            queue:update()

            local handled = imageHandle:handle(function(_value: any, err: any): string
                if err then
                    return "default"
                end
                return "loaded"
            end)

            queue:update()
            luassert.is_true(handled.isComplete)
            luassert.equals("default", handled.value)
        end)
    end)

    describe("workers.all", function()
        it("transforms empty handles", function()
            local result = queue:all({} as {workers.Handle<string>}):map(function(_values: {string}): string
                return "empty"
            end)
            luassert.is_true(result.isComplete)
            luassert.equals("empty", result.value)
        end)

        it("waits for all handles to complete", function()
            local handle1 = manager:loadFile("a.txt")
            local handle2 = manager:loadFile("b.txt")
            local handle3 = manager:loadFile("c.txt")

            local result = queue:all({handle1, handle2, handle3}):map(function(values: {string}): integer
                return #values
            end)

            -- Not complete yet
            luassert.is_false(result.isComplete)

            -- Complete first handle
            resultChannel:push({1, "a", nil})
            queue:update()
            luassert.is_false(result.isComplete)

            -- Complete second handle
            resultChannel:push({2, "b", nil})
            queue:update()
            luassert.is_false(result.isComplete)

            -- Complete third handle
            resultChannel:push({3, "c", nil})
            queue:update()

            -- Now should be complete
            luassert.is_true(result.isComplete)
            luassert.equals(3, result.value)
        end)

        it("fails if any handle fails", function()
            local handle1 = manager:loadFile("good.txt")
            local handle2 = manager:loadFile("bad.txt")

            local result = queue:all({handle1, handle2}):map(function(values: {string}): string
                return table.concat(values, ",")
            end)

            -- First succeeds
            resultChannel:push({1, "good", nil})
            -- Second fails
            resultChannel:push({2, nil, "File not found"})
            queue:update()
            queue:update()

            luassert.is_true(result.isComplete)
            luassert.equals("File not found", result.err)
        end)

        it("preserves order of results", function()
            local handle1 = manager:loadFile("first.txt")
            local handle2 = manager:loadFile("second.txt")
            local handle3 = manager:loadFile("third.txt")

            local result = queue:all({handle1, handle2, handle3}):map(function(values: {string}): string
                return values[1] .. "," .. values[2] .. "," .. values[3]
            end)

            -- Complete out of order: 3, 1, 2
            resultChannel:push({3, "third", nil})
            queue:update()
            resultChannel:push({1, "first", nil})
            queue:update()
            resultChannel:push({2, "second", nil})
            queue:update()

            luassert.is_true(result.isComplete)
            luassert.equals("first,second,third", result.value)
        end)

        it("transforms values into new type", function()
            local handle1 = manager:loadFile("a.txt")
            local handle2 = manager:loadFile("b.txt")

            local result = queue:all({handle1, handle2}):map(function(values: {string}): {string: string}
                return { first = values[1], second = values[2] }
            end)

            resultChannel:push({1, "alpha", nil})
            resultChannel:push({2, "beta", nil})
            queue:update()
            queue:update()

            luassert.is_true(result.isComplete)
            luassert.equals("alpha", result.value.first)
            luassert.equals("beta", result.value.second)
        end)
    end)

    describe("map", function()
        it("only calls transform on success", function()
            local imageHandle = manager:loadImage("test.png")

            local transformCalled = false
            local mapped = imageHandle:map(function(_value: any): string
                transformCalled = true
                return "transformed"
            end)

            -- Simulate failure
            resultChannel:push({1, nil, "File not found"})
            queue:update()

            luassert.is_true(mapped.isComplete)
            luassert.is_false(transformCalled)
            luassert.equals("File not found", mapped.err)
        end)

        it("propagates errors without calling transform", function()
            local imageHandle = manager:loadImage("test.png")

            local mapped = imageHandle:map(function(_value: any): string
                return "should not be called"
            end)

            resultChannel:push({1, nil, "Some error"})
            queue:update()

            luassert.is_true(mapped.isComplete)
            luassert.equals("Some error", mapped.err)
        end)
    end)
end)
