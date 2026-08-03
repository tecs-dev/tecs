-- Several cooperative waits at one call site.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local ecs = require("tecs.ecs")
local phases = require("tecs.internal.phases")
local task = require("tecs.internal.taskruntime")

describe("tecs.batch", function()
    -- One driver stands in for the frame loop: gates complete on the frame
    -- they are due, which is what a producer settling between updates does.
    local function newDriver()
        local driver = { frame = 0, pending = {} }

        function driver.wait(label, frames)
            local gate = task.newGate()
            driver.pending[#driver.pending + 1] = {
                gate = gate,
                due = driver.frame + frames,
                label = label,
            }
            return gate:wait()
        end

        function driver.run(world, limit)
            local guard = 0
            repeat
                driver.frame = driver.frame + 1
                guard = guard + 1
                for index = #driver.pending, 1, -1 do
                    local entry = driver.pending[index]
                    if driver.frame >= entry.due then
                        table.remove(driver.pending, index)
                        entry.gate:complete(entry.label)
                    end
                end
            until world:update(1 / 60) or guard > (limit or 200)
            return guard
        end

        return driver
    end

    local function worldRunning(body)
        local world = ecs.newWorld()
        local done = false
        world:addSystem({
            name = "BatchSpecSystem",
            phase = phases.Update,
            run = function()
                if done then
                    return
                end
                done = true
                body()
            end,
        })
        return world
    end

    it("returns every result at its own index", function()
        local driver = newDriver()
        local results
        local world = worldRunning(function()
            results = tecs.batch({
                function()
                    return driver.wait("slow", 5)
                end,
                function()
                    return driver.wait("fast", 1)
                end,
                function()
                    return driver.wait("middle", 3)
                end,
            })
        end)

        driver.run(world)

        assert.are.same({ "slow", "fast", "middle" }, results)
    end)

    it("waits about as long as the slowest callback rather than all of them", function()
        local batched = newDriver()
        local batchedWorld = worldRunning(function()
            local bodies = {}
            for index = 1, 5 do
                bodies[index] = function()
                    return batched.wait("op" .. index, 3)
                end
            end
            tecs.batch(bodies)
        end)
        local batchedFrames = batched.run(batchedWorld)

        local serial = newDriver()
        local serialWorld = worldRunning(function()
            for index = 1, 5 do
                serial.wait("op" .. index, 3)
            end
        end)
        local serialFrames = serial.run(serialWorld)

        assert.is_true(batchedFrames < serialFrames)
        -- Five three-frame waits overlap into one three-frame wait.
        assert.are.equal(4, batchedFrames)
        assert.are.equal(16, serialFrames)
    end)

    it("costs a system no extra frame when it batches one callback", function()
        local batched = newDriver()
        local batchedWorld = worldRunning(function()
            tecs.batch({
                function()
                    return batched.wait("only", 3)
                end,
            })
        end)

        local direct = newDriver()
        local directWorld = worldRunning(function()
            direct.wait("only", 3)
        end)

        assert.are.equal(direct.run(directWorld), batched.run(batchedWorld))
    end)

    it("raises the first failure and cancels the callbacks still running", function()
        local driver = newDriver()
        local failure, siblingFinished
        local world = worldRunning(function()
            local ok, reason = pcall(tecs.batch, {
                function()
                    error("batch spec failure", 0)
                end,
                function()
                    driver.wait("sibling", 5)
                    siblingFinished = true
                end,
            })
            failure = not ok and tostring(reason) or nil
        end)

        driver.run(world)

        assert.is_string(failure)
        assert.is_truthy(failure:find("batch spec failure", 1, true))
        assert.is_nil(siblingFinished)
    end)

    it("reports a callback that failed while another was still waiting, once", function()
        local driver = newDriver()
        local failure, results
        local world = worldRunning(function()
            local ok, reason = pcall(tecs.batch, {
                function()
                    return driver.wait("slow", 4)
                end,
                function()
                    -- Fails while the caller is parked on the first callback's
                    -- join, which is the park the runtime leaves alone.
                    error("late callback failure", 0)
                end,
            })
            failure = not ok and tostring(reason) or nil
            results = ok and reason or nil
        end)

        driver.run(world)

        assert.is_nil(results)
        assert.is_string(failure)
        assert.is_truthy(failure:find("late callback failure", 1, true))
        assert.is_nil(failure:find("a task started by this one failed", 1, true))
    end)

    it("closes a scope a canceled callback owns", function()
        local driver = newDriver()
        local closed = false
        local resource = {
            close = function()
                closed = true
                return true
            end,
        }

        local world = worldRunning(function()
            pcall(tecs.batch, {
                function()
                    error("batch spec failure", 0)
                end,
                function()
                    tecs.scoped("batch spec callback", function(scope)
                        scope:own(resource)
                        driver.wait("sibling", 5)
                    end)
                end,
            })
        end)

        driver.run(world)

        assert.is_true(closed)
    end)

    it("nests without either level losing a result", function()
        local driver = newDriver()
        local results
        local world = worldRunning(function()
            results = tecs.batch({
                function()
                    local inner = tecs.batch({
                        function()
                            return driver.wait("a", 2)
                        end,
                        function()
                            return driver.wait("b", 2)
                        end,
                    })
                    return inner[1] .. inner[2]
                end,
                function()
                    return driver.wait("c", 3)
                end,
            })
        end)

        driver.run(world)

        assert.are.same({ "ab", "c" }, results)
    end)

    it("unwinds a callback when world shutdown cancels the parked system", function()
        local driver = newDriver()
        local reached = false
        local world = worldRunning(function()
            tecs.batch({
                function()
                    return driver.wait("never", 1000)
                end,
            })
            reached = true
        end)

        assert.is_false(world:update(1 / 60))
        world:shutdown()

        assert.is_false(reached)
    end)

    it("returns an empty array without waiting", function()
        local results
        local world = worldRunning(function()
            results = tecs.batch({})
        end)

        assert.is_true(world:update(1 / 60))
        assert.are.same({}, results)
    end)

    it("raises for anything that is not an array of functions", function()
        local outcomes
        local world = worldRunning(function()
            outcomes = {
                notATable = select(1, pcall(tecs.batch, "callbacks")),
                notAFunction = select(1, pcall(tecs.batch, { function() end, 5 })),
            }
        end)

        assert.is_true(world:update(1 / 60))
        assert.is_false(outcomes.notATable)
        assert.is_false(outcomes.notAFunction)
    end)

    it("runs callbacks outside a system by driving their producers", function()
        local scheduler = task.newScheduler()
        local gate = task.newGate()
        -- A producer that settles on its own the first time it is asked.
        local settled = false
        local results = nil

        local worker = scheduler:spawn(function()
            results = tecs.batch({
                function()
                    return "immediate"
                end,
                function()
                    if not settled then
                        settled = true
                        gate:complete("settled")
                    end
                    return gate:wait()
                end,
            })
        end)

        while worker.status == "pending" do
            assert.is_true(scheduler:step() > 0)
        end

        assert.are.equal("ready", worker.status)
        assert.are.same({ "immediate", "settled" }, results)
    end)
end)
