-- Production coverage for direct-style coroutine I/O. The runtime stays
-- internal because games use ordinary systems and direct engine calls.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local task = require("tecs.internal.taskruntime")
local Completion = require("tecs.internal.completion")

local function stackDepth()
    local depth = 0
    while debug.getinfo(depth + 2, "") do
        depth = depth + 1
    end
    return depth
end

describe("internal task runtime", function()
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

    it("remains usable after a settlement observer raises", function()
        local scheduler = task.newScheduler()
        local rootTask = scheduler:spawn(function()
            return 7
        end)
        task.onSettle(rootTask, function()
            error("observer failed")
        end)

        local ok, reason = pcall(function()
            scheduler:step()
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("observer failed", 1, true))
        assert.are.equal("ready", rootTask.status)
        assert.are.equal(0, scheduler:step())
        assert.are.equal("ready", scheduler:spawnImmediate(function() end).status)
    end)

    it("queues cancellation before invoking a failing cancellation hook", function()
        local scheduler = task.newScheduler()
        local gate = task.newGate(function()
            error("cancel hook failed")
        end)
        local rootTask = scheduler:spawn(function()
            gate:wait()
        end)
        scheduler:step()

        local ok, reason = pcall(function()
            rootTask:cancel("test cancellation")
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("cancel hook failed", 1, true))
        scheduler:step()
        assert.are.equal("canceled", rootTask.status)
        assert.are.equal("test cancellation", rootTask.error)
        assert.are.equal("ready", scheduler:spawnImmediate(function() end).status)
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

    it("ends a suspension barrier the body left by raising", function()
        local scheduler = task.newScheduler()
        local gate = task.newGate()
        gate:complete(3)
        local raise = true
        local reusable = scheduler:spawnReusableImmediate(function()
            if raise then
                task.enterBarrier("query iteration")
                error("raised inside the barrier")
            end
            return gate:wait()
        end)
        assert.are.equal("failed", reusable.status)

        -- The scope outlives the invocation, so a barrier left behind would
        -- reject every wait in every later one.
        raise = false
        scheduler:restartImmediate(reusable)
        assert.are.equal("ready", reusable.status)
        assert.are.equal(3, reusable.value)
    end)

    it("ends a suspension barrier the body returned inside", function()
        local scheduler = task.newScheduler()
        local gate = task.newGate()
        gate:complete(5)
        local hold = true
        local reusable = scheduler:spawnReusableImmediate(function()
            if hold then
                task.enterBarrier("snapshot restore")
                return 1
            end
            return gate:wait()
        end)
        assert.are.equal("ready", reusable.status)

        hold = false
        scheduler:restartImmediate(reusable)
        assert.are.equal("ready", reusable.status)
        assert.are.equal(5, reusable.value)
    end)

    it("keeps one traceback on a failure that already carries one", function()
        local scheduler = task.newScheduler()
        local rootTask = scheduler:spawnImmediate(function()
            local ok, failure = xpcall(function()
                error("inner boom")
            end, debug.traceback)
            assert.is_false(ok)
            error(failure, 0)
        end)

        assert.are.equal("failed", rootTask.status)
        assert.is_truthy(rootTask.error:find("inner boom", 1, true))
        local _, tracebacks = rootTask.error:gsub("stack traceback:", "")
        assert.are.equal(1, tracebacks)
    end)

    it("names the operation a parked task is in, and drops the name with it", function()
        local scheduler = task.newScheduler()
        local named = task.newGate()
        local unnamed = task.newGate()
        local rootTask = scheduler:spawn(function()
            task.checkWait("spec operation")
            named:wait()
            return unnamed:wait()
        end)

        scheduler:step()
        assert.are.equal("spec operation", task.describeWait(rootTask))

        -- The next park has no name of its own, so it must not inherit one
        -- from the operation that already finished.
        named:complete(1)
        scheduler:step()
        assert.are.equal("gate", task.describeWait(rootTask))

        unnamed:complete(2)
        scheduler:step()
        assert.are.equal("ready", rootTask.status)
        assert.is_nil(task.describeWait(rootTask))
    end)

    it("cancels the producer it abandons at its wait budget", function()
        local canceled = false
        local completion = Completion.pending({
            sliceMs = 1,
            defaultWaitMs = 4,
            poll = function()
                return 0
            end,
            advance = function()
                return 0
            end,
            cancel = function()
                canceled = true
            end,
        })

        local ok, reason = pcall(task.awaitCompletion, completion, "decode")

        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("wait budget", 1, true))
        assert.is_true(canceled, "the abandoned producer was told to stop")
        assert.are.equal("canceled", completion.status)
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

    it("awaits an internal completion without polling it", function()
        local completion = Completion.pending()
        local scheduler = task.newScheduler()
        local rootTask = scheduler:spawn(function()
            return task.awaitCompletion(completion, "decode")
        end)

        assert.are.equal(1, scheduler:step())
        assert.are.equal("pending", rootTask.status)
        completion:complete("decoded")
        assert.are.equal(1, scheduler:step())
        assert.are.equal("ready", rootTask.status)
        assert.are.equal("decoded", rootTask.value)
    end)

    it("turns an internal completion failure into an operation error", function()
        local completion = Completion.pending()
        local scheduler = task.newScheduler()
        local rootTask = scheduler:spawn(function()
            return task.awaitCompletion(completion, "decode")
        end)

        scheduler:step()
        completion:fail("bad pixels")
        scheduler:step()
        assert.are.equal("failed", rootTask.status)
        assert.matches("tecs: decode failed: bad pixels", rootTask.error, 1, true)
    end)

    it("cancels the awaited completion when its Task is canceled", function()
        local completion = Completion.pending()
        local scheduler = task.newScheduler()
        local rootTask = scheduler:spawn(function()
            return task.awaitCompletion(completion, "decode")
        end)

        scheduler:step()
        rootTask:cancel("entity despawned")
        assert.are.equal("canceled", completion.status)
        scheduler:step()
        assert.are.equal("canceled", rootTask.status)
    end)

    it("leaves a retained completion to its other consumer when one is canceled", function()
        -- A producer that keeps its completion for a resource lifetime, which
        -- is what a process does with its exit.
        local shared = Completion.pending()
        shared:retain()
        local scheduler = task.newScheduler()
        local first = scheduler:spawn(function()
            return task.awaitCompletion(shared, "exit")
        end)
        local second = scheduler:spawn(function()
            return task.awaitCompletion(shared, "exit")
        end)

        scheduler:step()
        scheduler:step()
        assert.are.equal("pending", first.status)
        assert.are.equal("pending", second.status)

        first:cancel("entity despawned")
        assert.are.equal("pending", shared.status)
        scheduler:step()
        assert.are.equal("canceled", first.status)

        shared:complete("exit 0")
        scheduler:step()
        assert.are.equal("ready", second.status)
        assert.are.equal("exit 0", second.value)
    end)

    it("keeps a retained completion pending after every consumer gives up", function()
        local shared = Completion.pending()
        shared:retain()
        local scheduler = task.newScheduler()
        local waiter = scheduler:spawn(function()
            return task.awaitCompletion(shared, "exit")
        end)

        scheduler:step()
        waiter:cancel("entity despawned")
        scheduler:step()

        assert.are.equal("canceled", waiter.status)
        assert.are.equal("pending", shared.status)
        shared:complete("exit 0")
        assert.are.equal("ready", shared.status)
        assert.are.equal("exit 0", shared.value)
    end)

    it("releases only its own hold when its wait budget expires", function()
        local canceled = 0
        local shared = Completion.pending({
            sliceMs = 1,
            defaultWaitMs = 4,
            poll = function()
                return 0
            end,
            advance = function()
                return 0
            end,
            cancel = function()
                canceled = canceled + 1
            end,
        })
        local delivered
        shared:subscribe(function(settled)
            delivered = settled.value
        end)

        local ok, reason = pcall(task.awaitCompletion, shared, "decode")

        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("wait budget", 1, true))
        assert.are.equal("pending", shared.status)
        assert.are.equal(0, canceled, "the consumer that stayed keeps the producer working")

        shared:complete("decoded")
        assert.are.equal("decoded", delivered)
    end)

    it("settles and frees a single-consumer completion", function()
        local canceled = 0
        local completion = Completion.pending({
            sliceMs = 1,
            defaultWaitMs = 4,
            poll = function()
                return 0
            end,
            advance = function()
                return 0
            end,
            cancel = function()
                canceled = canceled + 1
            end,
        })
        local scheduler = task.newScheduler()
        local rootTask = scheduler:spawn(function()
            return task.awaitCompletion(completion, "decode")
        end)

        scheduler:step()
        assert.are.equal(1, completion._watchers, "the wait holds the completion alone")

        completion:complete("decoded")
        scheduler:step()

        assert.are.equal("ready", rootTask.status)
        assert.are.equal("decoded", rootTask.value)
        assert.are.equal(0, canceled)
        assert.is_nil(completion._listeners, "settlement frees the suspended closure")
    end)

    it("awaits a callback subscription without creating a completion", function()
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
        local root = Completion.pending()
        local called = false
        local cancel = root:subscribe(function()
            called = true
        end)

        assert.is_not_nil(root._listeners[1])
        cancel()
        assert.is_nil(root._listeners)
        assert.are.equal("canceled", root.status)
        root:complete("too late")
        assert.is_false(called)
    end)

    it("keeps shared completion work until its last consumer cancels", function()
        local root = Completion.pending()
        local cancelFirst = root:subscribe(function() end)
        local cancelSecond = root:subscribe(function() end)

        cancelFirst()
        assert.are.equal("pending", root.status)
        cancelSecond()
        assert.are.equal("canceled", root.status)
    end)

    it("drains reentrant completion listeners without retaining them", function()
        local root = Completion.pending()
        local calls = {}
        root:onSettle(function(settled)
            calls[#calls + 1] = "first"
            settled:onSettle(function()
                calls[#calls + 1] = "second"
            end)
        end)

        root:complete("ready")
        assert.are.same({ "first", "second" }, calls)
        assert.is_nil(root._listeners)
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

    it("raises a child failure at an owner parked on an unrelated wait", function()
        local scheduler = task.newScheduler()
        -- Nothing else ever completes this gate. The child was what would
        -- have, which is why its failure has to reach the owner here rather
        -- than at a join the owner never gets to.
        local unrelated = task.newGate()
        local rootTask = scheduler:spawn(function(scope)
            scope:spawn(function()
                task.yield()
                error("writer failed", 0)
            end)
            return unrelated:wait()
        end)

        while rootTask.status == "pending" and scheduler:step() > 0 do
        end

        assert.are.equal("failed", rootTask.status)
        assert.is_truthy(rootTask.error:find("writer failed", 1, true))
        assert.is_nil(unrelated.waiter, "the abandoned wait released its gate")
    end)

    it("keeps a sibling failure for the join while the owner collects children", function()
        local scheduler = task.newScheduler()
        local slowGate = task.newGate()
        local order = {}
        local failing
        local rootTask = scheduler:spawn(function(scope)
            local slow = scope:spawn(function()
                return slowGate:wait()
            end)
            failing = scope:spawn(function()
                task.yield()
                error("sibling failed", 0)
            end)
            order[#order + 1] = "join slow"
            order[#order + 1] = slow:join()
            order[#order + 1] = "join failing"
            return failing:join()
        end)

        -- The sibling fails here, while the owner is parked on another join.
        local turns = 0
        while (failing == nil or failing.status == "pending") and turns < 20 do
            turns = turns + 1
            scheduler:step()
        end

        assert.are.equal("failed", failing.status)
        assert.are.equal("pending", rootTask.status)
        assert.are.same({ "join slow" }, order)

        slowGate:complete("slow value")
        while rootTask.status == "pending" and scheduler:step() > 0 do
        end

        assert.are.equal("failed", rootTask.status)
        assert.are.same({ "join slow", "slow value", "join failing" }, order)
        assert.is_truthy(rootTask.error:find("sibling failed", 1, true))
        -- Read once, at the join, rather than also delivered to the park.
        assert.is_nil(rootTask.error:find("a task started by this one failed", 1, true))
    end)

    it("reports a joined child failure once rather than also at the park", function()
        local scheduler = task.newScheduler()
        local rootTask = scheduler:spawn(function(scope)
            local child = scope:spawn(function()
                task.yield()
                error("decode failed", 0)
            end)
            return child:join()
        end)

        while rootTask.status == "pending" and scheduler:step() > 0 do
        end

        assert.are.equal("failed", rootTask.status)
        assert.is_nil(rootTask.error:find("a task started by this one failed", 1, true))
        local _, tracebacks = rootTask.error:gsub("stack traceback:", "")
        assert.are.equal(1, tracebacks)
    end)

    it("keeps the first value a task body returns and discards the rest", function()
        local scheduler = task.newScheduler()
        local rootTask = scheduler:spawnImmediate(function()
            return "first", "second"
        end)

        assert.are.equal("ready", rootTask.status)
        assert.are.equal("first", rootTask.value)
        assert.are.equal(
            "first",
            task.run(function()
                return "first", "second"
            end)
        )
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

    it("lets cleanup wrappers preserve the private cancellation unwind", function()
        local scheduler = task.newScheduler()
        local gate = task.newGate()
        local running = scheduler:spawnImmediate(function()
            local ok, reason = pcall(function()
                gate:wait()
            end)
            if not ok then
                task.rethrowCancellation(reason)
            end
            return "cancellation was swallowed"
        end)
        assert.are.equal("pending", running.status)

        running:cancel("stop wrapped I/O")
        scheduler:step()
        assert.are.equal("canceled", running.status)
        assert.are.equal("stop wrapped I/O", running.error)
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

describe("a draining step", function()
    it("runs a task spawned during the step in that same step", function()
        local scheduler = task.newScheduler()
        local order = {}

        local root = scheduler:spawn(function(scope)
            order[#order + 1] = "root"
            local child = scope:spawn(function()
                order[#order + 1] = "child"
                return "done"
            end)
            return child:join()
        end)

        -- One step covers the root, the child it spawned, and the join.
        local turns = scheduler:step()

        assert.are.equal("ready", root.status)
        assert.are.equal("done", root.value)
        assert.are.same({ "root", "child" }, order)
        assert.is_true(turns >= 3)
    end)

    it("hands a yielding task the next step rather than the rest of this one", function()
        local scheduler = task.newScheduler()
        local turns = 0

        local root = scheduler:spawn(function()
            for _ = 1, 3 do
                turns = turns + 1
                task.yield()
            end
            return turns
        end)

        -- Each step resumes the yielding task once, so a cooperative yield
        -- cannot spin the draining loop against its own round budget.
        scheduler:step()
        assert.are.equal(1, turns)
        scheduler:step()
        assert.are.equal(2, turns)
        scheduler:step()
        assert.are.equal(3, turns)
        scheduler:step()
        assert.are.equal("ready", root.status)
    end)

    it("stops draining at its round cap and keeps the remainder for later", function()
        local scheduler = task.newScheduler()
        local depth = 0

        -- Every generation joins the next, so each one stays parked while its
        -- child runs and the chain needs far more rounds than one step allows.
        local function chain(scope)
            depth = depth + 1
            if depth < 200 then
                return scope:spawn(chain):join()
            end
            return depth
        end

        local root = scheduler:spawn(chain)
        scheduler:step()

        assert.are.equal("pending", root.status)
        assert.is_true(depth < 200)

        repeat
            local turns = scheduler:step()
            assert.is_true(turns > 0)
        until root.status ~= "pending"

        assert.are.equal("ready", root.status)
        assert.are.equal(200, depth)
    end)
end)
