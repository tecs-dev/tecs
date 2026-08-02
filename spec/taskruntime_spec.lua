-- Phase-zero proof for direct-style coroutine I/O. The runtime is internal on
-- purpose: these cases hold the semantics still under discussion without
-- publishing names that converted I/O would then have to preserve.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local task = require("tecs.internal.taskruntime")
local Future = require("tecs.internal.completion")

local function stackDepth()
    local depth = 0
    while debug.getinfo(depth + 2, "") do
        depth = depth + 1
    end
    return depth
end

describe("internal task runtime prototype", function()
    it("preserves direct control flow and locals across an I/O wait", function()
        local gate = task.newGate()
        local result = task.run(function(scope)
            scope:spawn(function()
                task.yield()
                gate:complete(41)
            end)

            local before = 1
            local value = assert(gate:wait())
            local after = 2
            return before + value + after
        end)

        assert.are.equal(44, result)
    end)

    it("starts concurrent children before join", function()
        local order = {}
        task.run(function(scope)
            local first = scope:spawn(function()
                order[#order + 1] = "first start"
                task.yield()
                order[#order + 1] = "first end"
                return 10
            end)
            local second = scope:spawn(function()
                order[#order + 1] = "second start"
                task.yield()
                order[#order + 1] = "second end"
                return 20
            end)

            assert.are.equal(10, first:join())
            assert.are.equal(20, second:join())
        end)

        assert.are.same({ "first start", "second start", "first end", "second end" }, order)
    end)

    it("can be advanced by an application one bounded turn at a time", function()
        local scheduler = task.newScheduler()
        local gate = task.newGate()
        local rootTask = scheduler:spawn(function()
            return assert(gate:wait())
        end)

        assert.are.equal(1, scheduler:step())
        assert.are.equal("pending", rootTask.status)
        assert.are.equal(0, scheduler:step())

        gate:complete("from reactor")
        assert.are.equal(1, scheduler:step())
        assert.are.equal("ready", rootTask.status)
        assert.are.equal("from reactor", rootTask.value)
    end)

    it("does not let cooperative yield monopolize one scheduler turn", function()
        local scheduler = task.newScheduler()
        local turns = 0
        local rootTask = scheduler:spawn(function()
            for _ = 1, 3 do
                turns = turns + 1
                task.yield()
            end
        end)

        scheduler:step()
        assert.are.equal(1, turns)
        scheduler:step()
        assert.are.equal(2, turns)
        scheduler:step()
        assert.are.equal(3, turns)
        scheduler:step()
        assert.are.equal("ready", rootTask.status)
    end)

    it("runs an immediate root synchronously until its first suspension", function()
        local scheduler = task.newScheduler()
        local gate = task.newGate()
        local entered = false
        local rootTask = scheduler:spawnImmediate(function()
            entered = true
            return assert(gate:wait())
        end)

        assert.is_true(entered)
        assert.are.equal("pending", rootTask.status)
        assert.are.equal(0, scheduler:step())
        gate:complete(17)
        assert.are.equal(1, scheduler:step())
        assert.are.equal("ready", rootTask.status)
        assert.are.equal(17, rootTask.value)
    end)

    it("does not enqueue an immediate root that completes synchronously", function()
        local scheduler = task.newScheduler()
        local rootTask = scheduler:spawnImmediate(function()
            return 23
        end)

        assert.are.equal("ready", rootTask.status)
        assert.are.equal(23, rootTask.value)
        assert.are.equal(0, scheduler:step())
    end)

    it("reuses one coroutine across synchronous root invocations", function()
        local scheduler = task.newScheduler()
        local value = 0
        local rootTask = scheduler:spawnReusableImmediate(function()
            value = value + 1
            return value
        end)
        local thread = rootTask.thread

        assert.are.equal("ready", rootTask.status)
        assert.are.equal(1, rootTask.value)
        scheduler:restartImmediate(rootTask)
        assert.are.equal(thread, rootTask.thread)
        assert.are.equal("ready", rootTask.status)
        assert.are.equal(2, rootTask.value)
        assert.are.equal(0, scheduler:step())
    end)

    it("reuses one coroutine after it parks and resumes", function()
        local scheduler = task.newScheduler()
        local gate = task.newGate()
        local rootTask = scheduler:spawnReusableImmediate(function()
            return assert(gate:wait())
        end)
        local thread = rootTask.thread

        assert.are.equal("pending", rootTask.status)
        gate:complete(11)
        scheduler:step()
        assert.are.equal("ready", rootTask.status)
        assert.are.equal(11, rootTask.value)

        scheduler:restartImmediate(rootTask)
        assert.are.equal(thread, rootTask.thread)
        assert.are.equal("pending", rootTask.status)
        gate:complete(12)
        scheduler:step()
        assert.are.equal("ready", rootTask.status)
        assert.are.equal(12, rootTask.value)
    end)

    it("reuses one coroutine after an invocation fails", function()
        local scheduler = task.newScheduler()
        local fail = true
        local rootTask = scheduler:spawnReusableImmediate(function()
            if fail then
                error("cycle boom")
            end
            return 19
        end)
        local thread = rootTask.thread

        assert.are.equal("failed", rootTask.status)
        assert.is_truthy(rootTask.error:find("cycle boom", 1, true))
        fail = false
        scheduler:restartImmediate(rootTask)
        assert.are.equal(thread, rootTask.thread)
        assert.are.equal("ready", rootTask.status)
        assert.are.equal(19, rootTask.value)
    end)

    it("requires task context even when a completion is already ready", function()
        local gate = task.newGate()
        gate:complete(7)

        local ok, reason = pcall(function()
            gate:wait()
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("needs a task", 1, true))
        assert.are.equal(
            7,
            task.run(function()
                return assert(gate:wait())
            end)
        )
    end)

    it("checks suspension barriers before the ready fast path", function()
        local gate = task.newGate()
        gate:complete(7)

        task.run(function()
            task.enterBarrier("query iteration")
            local ok, reason = pcall(function()
                gate:wait()
            end)
            assert.is_false(ok)
            assert.is_truthy(tostring(reason):find("query iteration is active", 1, true))
            task.leaveBarrier()
            assert.are.equal(7, gate:wait())
        end)
    end)

    it("returns operational failure through the direct call shape", function()
        local gate = task.newGate()
        gate:fail("connection reset")

        task.run(function()
            local value, reason = gate:wait()
            assert.is_nil(value)
            assert.are.equal("connection reset", reason)
        end)
    end)

    it("awaits a current Future without polling it", function()
        local future = Future.pending()
        local scheduler = task.newScheduler()
        local rootTask = scheduler:spawn(function()
            return task.awaitFuture(future)
        end)

        assert.are.equal(1, scheduler:step())
        assert.are.equal("pending", rootTask.status)
        future:complete("decoded")
        assert.are.equal(1, scheduler:step())
        assert.are.equal("ready", rootTask.status)
        assert.are.equal("decoded", rootTask.value)
    end)

    it("can inspect an operational Future failure without failing the Task", function()
        local future = Future.pending()
        local scheduler = task.newScheduler()
        local rootTask = scheduler:spawn(function()
            local settled = task.awaitFutureSettlement(future)
            return settled.status .. ": " .. settled.error
        end)

        scheduler:step()
        future:fail("decode failed")
        scheduler:step()
        assert.are.equal("ready", rootTask.status)
        assert.are.equal("failed: decode failed", rootTask.value)
    end)

    it("cancels the awaited Future when its Task is canceled", function()
        local future = Future.pending()
        local scheduler = task.newScheduler()
        local rootTask = scheduler:spawn(function()
            return task.awaitFuture(future)
        end)

        scheduler:step()
        rootTask:cancel("entity despawned")
        assert.are.equal("canceled", future.status)
        scheduler:step()
        assert.are.equal("canceled", rootTask.status)
    end)

    it("awaits a callback subscription without creating a Future", function()
        local resume
        local canceled = 0
        local scheduler = task.newScheduler()
        local rootTask = scheduler:spawn(function()
            return task.awaitCallback(function(complete)
                resume = complete
                return function()
                    canceled = canceled + 1
                end
            end)
        end)

        assert.are.equal(1, scheduler:step())
        assert.are.equal("pending", rootTask.status)
        resume("decoded")
        assert.are.equal(1, scheduler:step())
        assert.are.equal("ready", rootTask.status)
        assert.are.equal("decoded", rootTask.value)
        assert.are.equal(0, canceled)
    end)

    it("cancels a callback subscription when its Task is canceled", function()
        local canceled = 0
        local scheduler = task.newScheduler()
        local rootTask = scheduler:spawn(function()
            return task.awaitCallback(function(_complete)
                return function()
                    canceled = canceled + 1
                end
            end)
        end)

        scheduler:step()
        rootTask:cancel("entity despawned")
        assert.are.equal(1, canceled)
        scheduler:step()
        assert.are.equal("canceled", rootTask.status)
    end)

    it("detaches an internal completion listener when its consumer cancels", function()
        local root = Future.pending()
        root._watchers = 0
        local called = false
        local cancel = Future._subscribe(root, function()
            called = true
        end)

        assert.is_not_nil(root._listeners[1])
        cancel()
        assert.is_nil(root._listeners[1])
        assert.are.equal("canceled", root.status)
        root:complete("too late")
        assert.is_false(called)
    end)

    it("reports a child failure at join", function()
        local ok, reason = pcall(function()
            task.run(function(scope)
                local child = scope:spawn(function()
                    error("decode failed")
                end)
                child:join()
            end)
        end)

        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("decode failed", 1, true))
    end)

    it("cancels and drains an unfinished child when its scope ends", function()
        local gate = task.newGate()
        local unwound = false
        local child

        task.run(function(scope)
            child = scope:spawn(function()
                local ok = pcall(function()
                    gate:wait()
                end)
                unwound = not ok
            end)
            task.yield()
        end)

        assert.is_true(unwound)
        assert.are.equal("canceled", child.status)
        assert.are.equal("owner scope ended", child.error)
    end)

    it("does not grow the Lua stack across repeated suspension", function()
        local low = math.huge
        local high = 0
        task.run(function()
            for _ = 1, 2000 do
                local depth = stackDepth()
                low = math.min(low, depth)
                high = math.max(high, depth)
                task.yield()
            end
        end)
        assert.are.equal(low, high)
    end)

    it("reuses one readiness gate for a long stream", function()
        local gate = task.newGate()
        local count = 20000
        local sum = task.run(function(scope)
            scope:spawn(function()
                for value = 1, count do
                    gate:complete(value)
                    task.yield()
                end
            end)

            local total = 0
            for _ = 1, count do
                total = total + assert(gate:wait())
            end
            return total
        end)

        assert.are.equal(count * (count + 1) / 2, sum)
    end)

    it("detects a headless deadlock instead of blocking the process", function()
        local gate = task.newGate()
        local ok, reason = pcall(function()
            task.run(function()
                gate:wait()
            end)
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("deadlocked", 1, true))
    end)

    it("rejects a nested scheduler instead of losing the current task", function()
        task.run(function()
            local nested = task.newScheduler()
            nested:spawn(function()
                return true
            end)
            local ok, reason = pcall(function()
                nested:step()
            end)
            assert.is_false(ok)
            assert.is_truthy(tostring(reason):find("cannot drive another", 1, true))

            -- The outer scheduler remains current after the rejected call.
            task.yield()
        end)
    end)
end)
