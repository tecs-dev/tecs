-- Update-wide primary coroutine with spill runners at blocking systems.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local task = require("tecs.internal.taskruntime")
local update = require("tecs.internal.updaterunner")

describe("update-wide coroutine runners", function()
    it("crosses one coroutine boundary for every synchronous phase", function()
        local pool = update.new()
        local order = {}
        local counts = {2, 0, 2}

        local complete = pool:start(#counts, counts, function(phaseIndex, systemIndex)
            order[#order + 1] = ("%d.%d"):format(phaseIndex, systemIndex)
            assert.are.equal(phaseIndex, update.currentPhase())
            assert.are.equal(systemIndex, update.currentSystem())
        end, function(phaseIndex)
            order[#order + 1] = "commit " .. phaseIndex
        end)

        assert.is_true(complete)
        assert.are.same({"1.1", "1.2", "commit 1", "commit 2", "3.1", "3.2", "commit 3"}, order)
        assert.are.equal(1, pool.createdCount)
        assert.are.equal(1, pool.peakActive)
    end)

    it("continues the current phase but holds later phases at the barrier", function()
        local pool = update.new()
        local gate = task.newGate()
        local order = {}
        local counts = {3, 1}

        assert.is_false(pool:start(#counts, counts, function(phaseIndex, systemIndex)
            if phaseIndex == 1 and systemIndex == 2 then
                order[#order + 1] = "wait entered"
                gate:wait()
                order[#order + 1] = "wait resumed"
            else
                order[#order + 1] = ("%d.%d"):format(phaseIndex, systemIndex)
            end
        end, function(phaseIndex)
            order[#order + 1] = "commit " .. phaseIndex
        end))

        assert.are.same({"1.1", "wait entered", "1.3"}, order)
        assert.are.equal(2, pool.createdCount)
        gate:complete(true)
        assert.is_true(pool:poll())
        assert.are.same({
            "1.1", "wait entered", "1.3", "wait resumed", "commit 1", "2.1", "commit 2",
        }, order)
    end)

    it("resumes systems in readiness order and commits only after all settle", function()
        local pool = update.new()
        local first = task.newGate()
        local third = task.newGate()
        local order = {}
        local counts = {4, 1}

        pool:start(#counts, counts, function(phaseIndex, systemIndex)
            if phaseIndex == 1 and systemIndex == 1 then
                order[#order + 1] = "first entered"
                first:wait()
                order[#order + 1] = "first resumed"
            elseif phaseIndex == 1 and systemIndex == 3 then
                order[#order + 1] = "third entered"
                third:wait()
                order[#order + 1] = "third resumed"
            else
                order[#order + 1] = ("%d.%d"):format(phaseIndex, systemIndex)
            end
        end, function(phaseIndex)
            order[#order + 1] = "commit " .. phaseIndex
        end)

        assert.are.same({"first entered", "1.2", "third entered", "1.4"}, order)
        assert.are.equal(3, pool.createdCount)

        third:complete(true)
        assert.is_false(pool:poll())
        assert.are.same({"first entered", "1.2", "third entered", "1.4", "third resumed"}, order)

        first:complete(true)
        assert.is_true(pool:poll())
        assert.are.same({
            "first entered", "1.2", "third entered", "1.4", "third resumed", "first resumed",
            "commit 1", "2.1", "commit 2",
        }, order)
    end)

    it("keeps a coordinator when the final system is the one that waits", function()
        local pool = update.new()
        local gate = task.newGate()
        local order = {}
        local counts = {1, 1}

        assert.is_false(pool:start(#counts, counts, function(phaseIndex)
            if phaseIndex == 1 then
                order[#order + 1] = "last entered"
                gate:wait()
                order[#order + 1] = "last resumed"
            else
                order[#order + 1] = "next phase"
            end
        end, function(phaseIndex)
            order[#order + 1] = "commit " .. phaseIndex
        end))
        assert.are.same({"last entered"}, order)
        assert.are.equal(2, pool.createdCount)

        gate:complete(true)
        assert.is_true(pool:poll())
        assert.are.same({"last entered", "last resumed", "commit 1", "next phase", "commit 2"}, order)
    end)

    it("preserves phase and system context across a suspension", function()
        local pool = update.new()
        local gate = task.newGate()
        local contexts = {}
        local counts = {1}

        pool:start(#counts, counts, function()
            contexts[#contexts + 1] = {update.currentPhase(), update.currentSystem()}
            gate:wait()
            contexts[#contexts + 1] = {update.currentPhase(), update.currentSystem()}
        end, function() end)
        gate:complete(true)
        assert.is_true(pool:poll())
        assert.are.same({{1, 1}, {1, 1}}, contexts)
        assert.are.equal(0, update.currentPhase())
        assert.are.equal(0, update.currentSystem())
    end)

    it("reuses spill runners on later updates", function()
        local pool = update.new()
        local first = task.newGate()
        local second = task.newGate()
        local counts = {2}
        pool:start(#counts, counts, function(_, systemIndex)
            if systemIndex == 1 then first:wait() else second:wait() end
        end, function() end)
        first:complete(true)
        second:complete(true)
        assert.is_true(pool:poll())
        assert.are.equal(3, pool.createdCount)

        local synchronousCounts = {10, 10, 10}
        assert.is_true(pool:start(#synchronousCounts, synchronousCounts, function() end, function() end))
        assert.are.equal(3, pool.createdCount)
        assert.are.equal(3, pool.idleCount)
    end)

    it("cancels every continuation when a resumed system fails", function()
        local failGate = task.newGate()
        local otherCanceled = false
        local otherGate = task.newGate(function() otherCanceled = true end)
        local pool = update.new()
        local counts = {2}

        pool:start(#counts, counts, function(_, systemIndex)
            if systemIndex == 1 then
                failGate:wait()
                error("update runner boom")
            else
                otherGate:wait()
            end
        end, function() end)
        failGate:complete(true)
        local ok, reason = pcall(function() pool:poll() end)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("update runner boom", 1, true))
        assert.is_true(otherCanceled)
        assert.is_false(pool.running)
        assert.are.equal(0, pool.activeCount)
    end)

    it("rejects overlapping updates and cancels a pending one", function()
        local pool = update.new()
        local gate = task.newGate()
        local counts = {1}
        pool:start(#counts, counts, function() gate:wait() end, function() end)
        assert.has_error(function()
            pool:start(#counts, counts, function() end, function() end)
        end)
        pool:cancel("test ended")
        assert.is_false(pool.running)
        assert.are.equal(0, pool.activeCount)
        assert.is_true(pool:poll())
    end)
end)
