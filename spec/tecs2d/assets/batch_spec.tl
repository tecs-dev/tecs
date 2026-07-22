require("busted")

local love2d_mock <const> = require("spec.love2d.love2d_mock")
rawset(_G, "love", love2d_mock)

local assets <const> = require("tecs2d.assets")
local workers <const> = require("tecs2d.workers")
local luassert <const> = require("luassert")

describe("tecs2d.assets.LoadBatch", function()
    local manager: assets.AssetManager
    local queue: workers.Queue
    local results: love.thread.Channel

    before_each(function()
        queue = workers.new()
        manager = assets.new("assets", queue)
        results = ((queue as {string: any})._pullChannel) as love.thread.Channel
    end)

    after_each(function()
        if assets.manager == manager then assets.manager = nil end
        manager:shutdown()
        queue:shutdown()
    end)

    it("completes a sealed empty batch", function()
        local batch = manager:newBatch()
        batch:seal()
        luassert.is_true(batch.isComplete)
        luassert.is_true(batch.isSuccessful)
        luassert.equals(1, batch.progress)
    end)

    it("tracks progress and waits for every handle", function()
        local batch = manager:newBatch()
        local first = batch:track(manager:loadFile("first.txt"))
        batch:track(manager:loadFile("second.txt"))
        luassert.equals(first, batch:track(first))
        batch:seal()

        luassert.equals(2, batch.totalCount)
    end)

    it("settles successes and failures without failing fast", function()
        local batch = manager:newBatch()
        batch:track(manager:loadFile("good.txt"))
        batch:track(manager:loadFile("bad.txt"))
        batch:seal()

        results:push({1, "good", nil})
        queue:update()
        luassert.equals(1, batch.completedCount)
        luassert.equals(0.5, batch.progress)
        luassert.is_false(batch.isComplete)

        results:push({2, nil, "missing"})
        queue:update()
        luassert.is_true(batch.isComplete)
        luassert.is_false(batch.isSuccessful)
        luassert.equals(1, batch.failedCount)
        luassert.equals("missing", batch.errors[1])
    end)

    it("counts cached completed handles immediately and deduplicates them", function()
        local handle = manager:loadFile("cached.txt")
        results:push({1, "cached", nil})
        queue:update()

        local batch = manager:newBatch()
        batch:track(handle)
        batch:track(manager:loadFile("cached.txt"))
        batch:seal()

        luassert.equals(1, batch.totalCount)
        luassert.equals(1, batch.completedCount)
        luassert.is_true(batch.isComplete)
    end)

    it("notifies once, immediately after completion, and isolates observers", function()
        local batch = manager:newBatch()
        batch:track(manager:loadFile("file.txt"))
        local calls = 0
        batch:observe(function(_batch: assets.LoadBatch)
            error("observer failure")
        end)
        batch:observe(function(_batch: assets.LoadBatch)
            calls = calls + 1
        end)
        batch:seal()
        results:push({1, "ok", nil})
        queue:update()
        batch:observe(function(_batch: assets.LoadBatch)
            calls = calls + 1
        end)
        luassert.equals(2, calls)
    end)

    it("rejects handles added after sealing", function()
        local batch = manager:newBatch()
        batch:seal()
        luassert.has_error(function()
            batch:track(manager:loadFile("late.txt"))
        end, "cannot track an asset handle after sealing its batch")
    end)

    it("uses a directly assignable global manager and records asset metadata", function()
        assets.manager = manager
        local handle = assets.loadFile("global.txt")
        local descriptor = assets.describe(handle)
        luassert.equals("loadFile", descriptor.action)
        luassert.equals("global.txt", descriptor.inputPath)
        luassert.equals(handle, assets.pin(handle))
        luassert.equals(1, assets.getStats().pinnedAssetCount)

        results:push({1, "global", nil})
        queue:update()
        luassert.equals("global", handle.value)
    end)
end)
