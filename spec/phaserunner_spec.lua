-- Pooled coroutine execution for an ordered phase of systems.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local phase = require("tecs.internal.phaserunner")
local task = require("tecs.internal.taskruntime")

describe("pooled phase runners", function()
    it("uses one reusable runner for an entirely synchronous phase", function()
        local pool = phase.new()
        local order = {}
        local complete = pool:start(4, function(index)
            order[#order + 1] = index
            assert.are.equal(index, phase.currentSystem())
        end)

        assert.is_true(complete)
        assert.are.same({1, 2, 3, 4}, order)
        assert.are.equal(1, pool.createdCount)
        assert.are.equal(1, pool.peakActive)
        assert.are.equal(0, pool.activeCount)
    end)

    it("continues later systems and resumes waits in readiness order", function()
        local pool = phase.new()
        local first = task.newGate()
        local third = task.newGate()
        local order = {}
        local systems = {
            function()
                order[#order + 1] = "first entered"
                first:wait()
                order[#order + 1] = "first resumed"
            end,
            function() order[#order + 1] = "second" end,
            function()
                order[#order + 1] = "third entered"
                third:wait()
                order[#order + 1] = "third resumed"
            end,
            function() order[#order + 1] = "fourth" end,
        }

        assert.is_false(pool:start(#systems, function(index) systems[index]() end))
        assert.are.same({"first entered", "second", "third entered", "fourth"}, order)
        assert.are.equal(3, pool.createdCount)
        assert.are.equal(2, pool.activeCount)

        third:complete(true)
        assert.is_false(pool:poll())
        assert.are.same({
            "first entered", "second", "third entered", "fourth", "third resumed",
        }, order)

        first:complete(true)
        assert.is_true(pool:poll())
        assert.are.same({
            "first entered", "second", "third entered", "fourth", "third resumed", "first resumed",
        }, order)
    end)

    it("keeps one pinned continuation through multiple waits", function()
        local pool = phase.new()
        local first = task.newGate()
        local second = task.newGate()
        local order = {}
        local systems = {
            function()
                order[#order + 1] = "enter"
                first:wait()
                order[#order + 1] = "middle"
                second:wait()
                order[#order + 1] = "leave"
            end,
            function() order[#order + 1] = "later system" end,
        }

        assert.is_false(pool:start(#systems, function(index) systems[index]() end))
        assert.are.same({"enter", "later system"}, order)
        assert.are.equal(2, pool.createdCount)

        first:complete(true)
        assert.is_false(pool:poll())
        assert.are.same({"enter", "later system", "middle"}, order)
        assert.are.equal(2, pool.createdCount)

        second:complete(true)
        assert.is_true(pool:poll())
        assert.are.same({"enter", "later system", "middle", "leave"}, order)
    end)

    it("preserves the claimed system ordinal across suspension", function()
        local pool = phase.new()
        local gate = task.newGate()
        local ordinals = {}
        local systems = {
            function()
                ordinals[#ordinals + 1] = phase.currentSystem()
                gate:wait()
                ordinals[#ordinals + 1] = phase.currentSystem()
            end,
            function() ordinals[#ordinals + 1] = phase.currentSystem() end,
        }

        pool:start(#systems, function(index) systems[index]() end)
        assert.are.same({1, 2}, ordinals)
        gate:complete(true)
        assert.is_true(pool:poll())
        assert.are.same({1, 2, 1}, ordinals)
        assert.are.equal(0, phase.currentSystem())
    end)

    it("reuses the pool high-water mark on later phases", function()
        local pool = phase.new()
        local first = task.newGate()
        local third = task.newGate()
        local systems = {
            function() first:wait() end,
            function() end,
            function() third:wait() end,
            function() end,
        }
        pool:start(#systems, function(index) systems[index]() end)
        first:complete(true)
        third:complete(true)
        assert.is_true(pool:poll())
        assert.are.equal(3, pool.createdCount)

        assert.is_true(pool:start(100, function() end))
        assert.are.equal(3, pool.createdCount)
        assert.are.equal(3, pool.idleCount)
    end)

    it("cancels every pinned runner when one system fails", function()
        local canceled = false
        local gate = task.newGate(function() canceled = true end)
        local pool = phase.new()
        local systems = {
            function() gate:wait() end,
            function() error("phase runner boom") end,
        }

        local ok, reason = pcall(function()
            pool:start(#systems, function(index) systems[index]() end)
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("phase runner boom", 1, true))
        assert.is_true(canceled)
        assert.is_false(pool.running)
        assert.are.equal(0, pool.activeCount)
    end)

    it("reports a resumed failure and cancels the other continuations", function()
        local failGate = task.newGate()
        local otherCanceled = false
        local otherGate = task.newGate(function() otherCanceled = true end)
        local pool = phase.new()
        local systems = {
            function()
                failGate:wait()
                error("resumed phase runner boom")
            end,
            function() otherGate:wait() end,
        }

        assert.is_false(pool:start(#systems, function(index) systems[index]() end))
        failGate:complete(true)
        local ok, reason = pcall(function() pool:poll() end)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("resumed phase runner boom", 1, true))
        assert.is_true(otherCanceled)
        assert.is_false(pool.running)
        assert.are.equal(0, pool.activeCount)
    end)

    it("rejects overlapping starts and can cancel a pending phase", function()
        local pool = phase.new()
        local gate = task.newGate()
        assert.is_false(pool:start(1, function() gate:wait() end))
        assert.has_error(function() pool:start(0, function() end) end)
        pool:cancel("test ended")
        assert.is_false(pool.running)
        assert.are.equal(0, pool.activeCount)
        assert.is_true(pool:poll())
    end)
end)
