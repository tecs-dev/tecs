-- Unified resumable system execution.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local ecs = require("tecs.ecs")
local phases = require("tecs.internal.phases")
local task = require("tecs.internal.taskruntime")

describe("resumable run systems", function()
    local serial = 0

    local function fixture(config)
        serial = serial + 1
        local world = ecs.newWorld(config)
        local Value = ecs.newComponent({
            name = "UnifiedSystemValue" .. serial,
            container = {},
            fields = { "value" },
            defaults = { 0 },
        })
        local entity = world:spawn(Value(0))
        return world, Value, entity
    end

    it("runs an ordinary system synchronously through the reusable update fiber", function()
        local world, Value, entity = fixture()
        world:addSystem({
            name = "SynchronousUnifiedSystem",
            phase = phases.Update,
            run = function(_, runWorld)
                runWorld:set(entity, Value, Value(3))
            end,
        })
        assert.is_true(world:update(1 / 60))
        assert.is_false(world._updateStalled)
        assert.are.equal(3, world:get(entity, Value).value)
    end)

    it("automatically suspends a run system only when an operation waits", function()
        local world, Value, entity = fixture()
        local gate = task.newGate()
        local entered = 0
        world:addSystem({
            name = "TransparentWait",
            phase = phases.Update,
            run = function(_, runWorld)
                entered = entered + 1
                gate:wait()
                runWorld:set(entity, Value, Value(7))
            end,
        })
        assert.is_false(world:update(1 / 60))
        assert.is_true(world._updateStalled)
        assert.are.equal(1, entered)
        assert.are.equal(0, world:get(entity, Value).value)
        gate:complete(true)
        assert.is_true(world:update(99))
        assert.is_false(world._updateStalled)
        assert.are.equal(1, entered)
        assert.are.equal(7, world:get(entity, Value).value)
    end)

    it("does not stall for an operation that is already ready", function()
        local world = fixture()
        local gate = task.newGate()
        gate:complete(true)
        world:addSystem({
            name = "InlineReadyWait",
            phase = phases.Update,
            run = function()
                assert.is_true(gate:wait())
            end,
        })
        assert.is_true(world:update(1 / 60))
        assert.is_false(world._updateStalled)
    end)

    it("preserves exact system and phase order across suspension", function()
        local world = fixture()
        local gate = task.newGate()
        local order = {}
        world:addSystem({
            name = "BeforeSuspension",
            phase = phases.Update,
            run = function()
                order[#order + 1] = "before"
            end,
        })
        world:addSystem({
            name = "SuspendingSystem",
            phase = phases.Update,
            run = function()
                order[#order + 1] = "enter"
                gate:wait()
                order[#order + 1] = "resume"
            end,
        })
        world:addSystem({
            name = "AfterSuspension",
            phase = phases.Last,
            run = function()
                order[#order + 1] = "after"
            end,
        })
        world:update(1 / 60)
        world:update(12)
        assert.are.same({ "before", "enter" }, order)
        gate:complete(true)
        world:update(12)
        assert.are.same({ "before", "enter", "resume", "after" }, order)
    end)

    it("keeps a query iterator valid while a nested spawn waits for an asset", function()
        local world, Value = fixture()
        local gate = task.newGate()
        local query = world:newQuery({ include = { Value } })
        local spawned
        world:addSystem({
            name = "SpawnFromSuspendedQuery",
            phase = phases.Update,
            run = function(_, runWorld)
                for archetype, length in query:iter() do
                    local values = archetype:get(Value)
                    for row = 1, length do
                        gate:wait()
                        spawned = runWorld:spawn(Value(values[row].value + 1))
                    end
                end
            end,
        })
        world:update(1 / 60)
        assert.is_true(world._updateStalled)
        gate:complete(true)
        world:update(1 / 60)
        assert.is_false(world._updateStalled)
        assert.are.equal(1, world:get(spawned, Value).value)
    end)

    it("continues a fixed step at the exact suspension point", function()
        local world = fixture({ timestep = 0.1 })
        local gate = task.newGate()
        local calls = 0
        world:addSystem({
            name = "SuspendingFixedSystem",
            phase = phases.FixedUpdate,
            run = function()
                calls = calls + 1
                gate:wait()
            end,
        })
        world:update(0.1)
        assert.is_true(world._updateStalled)
        assert.are.equal(1, calls)
        assert.are.equal(1, world:fixedStepCount())
        gate:complete(true)
        world:update(10)
        assert.is_false(world._updateStalled)
        assert.are.equal(1, calls)
        assert.are.equal(1, world:fixedStepCount())
    end)

    it("keeps runIf, ordering, and removal on the one system path", function()
        local world = fixture()
        local order = {}
        world:addSystem({
            name = "Second",
            phase = phases.Update,
            after = { "First" },
            run = function()
                order[#order + 1] = "second"
            end,
        })
        world:addSystem({
            name = "First",
            phase = phases.Update,
            before = { "Second" },
            run = function()
                order[#order + 1] = "first"
            end,
        })
        world:addSystem({
            name = "Skipped",
            phase = phases.Update,
            runIf = function()
                return false
            end,
            run = function()
                order[#order + 1] = "skipped"
            end,
        })
        world:update(1 / 60)
        world:removeSystem("First")
        world:update(1 / 60)
        assert.are.same({ "first", "second", "second" }, order)
    end)

    it("reports a resumed failure and starts the next update cleanly", function()
        local world = fixture()
        local gate = task.newGate()
        local attempts = 0
        world:addSystem({
            name = "FailAfterWaitOnce",
            phase = phases.Update,
            run = function()
                attempts = attempts + 1
                if attempts == 1 then
                    gate:wait()
                    error("unified boom")
                end
            end,
        })
        world:update(1 / 60)
        gate:complete(true)
        local ok, reason = pcall(function()
            world:update(1 / 60)
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("unified boom", 1, true))
        assert.has_no.errors(function()
            world:update(1 / 60)
        end)
        assert.are.equal(2, attempts)
    end)

    it("cancels a suspended update during shutdown", function()
        local world = fixture()
        local gate = task.newGate()
        world:addSystem({
            name = "WaitUntilShutdown",
            phase = phases.Update,
            run = function()
                gate:wait()
            end,
        })
        world:update(1 / 60)
        assert.is_true(world._updateStalled)
        assert.has_no.errors(function()
            world:shutdown()
        end)
        assert.is_false(world._updateStalled)
    end)

    it("isolates failure bookkeeping for concurrently stalled worlds", function()
        local first = fixture()
        local second, Value, entity = fixture()
        local firstGate = task.newGate()
        local secondGate = task.newGate()

        first:addSystem({
            name = "FirstWorldFailsAfterWait",
            phase = phases.Update,
            run = function()
                firstGate:wait()
                error("first world resumed failure")
            end,
        })
        second:addSystem({
            name = "SecondWorldCommitsAfterWait",
            phase = phases.Update,
            run = function(_, runWorld)
                secondGate:wait()
                runWorld:set(entity, Value, Value(11))
            end,
        })

        assert.is_false(first:update(0))
        assert.is_false(second:update(0))
        assert.is_true(first._runningSystem)
        assert.is_true(second._runningSystem)

        firstGate:complete(true)
        local ok, reason = pcall(first.update, first, 0)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("first world resumed failure", 1, true))
        assert.is_true(second._runningSystem)

        secondGate:complete(true)
        assert.is_true(second:update(0))
        assert.are.equal(11, second:get(entity, Value).value)
    end)

    it("rejects direct phase dispatch while an update is suspended", function()
        local world = fixture()
        local gate = task.newGate()
        world:addSystem({
            name = "WaitAcrossDirectPhaseAttempt",
            phase = phases.Update,
            run = function()
                world:spawn()
                gate:wait()
            end,
        })

        assert.is_false(world:update(0))
        assert.has_error(function()
            world:runPhase(phases.Last, 0)
        end)
        assert.has_error(function()
            world:startup()
        end)

        gate:complete(true)
        assert.is_true(world:update(0))
    end)

    it("clears commit bookkeeping when an observer raises", function()
        local world, Value = fixture()
        local fail = true
        world:observe(0, ecs.OnSpawn, function()
            if fail then
                fail = false
                error("observer rejected commit")
            end
        end)
        local ok, reason = pcall(world.spawn, world, Value(1))
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("observer rejected commit", 1, true))
        assert.is_false(world._committing)

        world:spawn(Value(2))
        assert.has_no.errors(function()
            world:update(0)
        end)
        assert.is_false(world._committing)
    end)
end)
