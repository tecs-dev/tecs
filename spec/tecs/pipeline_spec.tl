require("busted")
local tecs <const> = require("tecs")
local pipeline <const> = require("tecs.internal.pipeline")
local luassert = require("luassert")

local CommitRequestTag <const> = tecs.ecs.newTagComponent({
    name = "PipelineSpecCommitRequestTag",
    container = {},
})

local record Test
    world: tecs.World
    pipeline: tecs.ecs.Pipeline
    counter: integer
    fixedCounter: integer
    updateCounter: integer
    beforeCounter: integer
    afterCounter: integer
end

-- Create a test function to increment the counter
local function createCounterSystem(test: Test, counterType: string): tecs.System
    return function(_dt: number, _world: tecs.World)
        if counterType == "fixed" then
            test.fixedCounter = test.fixedCounter + 1
        elseif counterType == "update" then
            test.updateCounter = test.updateCounter + 1
        elseif counterType == "before" then
            test.beforeCounter = test.beforeCounter + 1
        elseif counterType == "after" then
            test.afterCounter = test.afterCounter + 1
        end
        test.counter = test.counter + 1
    end
end

-- Create a conditional system that only runs when counter is even
local function createConditionalSystem(test: Test): tecs.System, function(number, tecs.World): boolean
    local function runIf(_dt: number, _world: tecs.World): boolean
        return test.counter % 2 == 0
    end

    return function(_dt: number, _world: tecs.World) test.counter = test.counter + 100 end, runIf
end

-- Dummy world stub. The pipeline calls the internal barrier at phase boundaries,
-- so the dummy needs that method; tests that care about commit semantics
-- override it locally.
local function makeDummyWorld(): tecs.World
    return {_commit = function(_self: tecs.World) end} as tecs.World
end

local FPS <const> = 1 / 60

describe(
    "Pipeline",
    function()
        local test: Test

        before_each(function()
            test = {
                world = makeDummyWorld(),
                pipeline = nil,
                counter = 0,
                fixedCounter = 0,
                updateCounter = 0,
                beforeCounter = 0,
                afterCounter = 0,
            }
            test.pipeline = pipeline.new(FPS)
        end)

        it(
            "exposes concrete phase positions through the public Phase type",
            function()
                local update: tecs.ecs.Phase = tecs.ecs.phases.Update
                luassert.is_true(update.position > 0)
                luassert.equals("Update", update.name)
            end
        )

        it(
            "should add and run systems in the correct phases",
            function()
                -- Add systems to different phases
                test.pipeline:addSystem({
                    phase = tecs.ecs.phases.PreUpdate,
                    run = createCounterSystem(test, "before"),
                    name = "before_system",
                })

                test.pipeline:addSystem({
                    phase = tecs.ecs.phases.FixedUpdate,
                    run = createCounterSystem(test, "fixed"),
                    name = "fixed_system",
                })

                test.pipeline:addSystem({
                    phase = tecs.ecs.phases.Update, run = createCounterSystem(test, "update"), name = "update_system"
                })

                test.pipeline:addSystem({
                    phase = tecs.ecs.phases.PostUpdate,
                    run = createCounterSystem(test, "after"),
                    name = "after_system",
                })

                test.pipeline:update(FPS, test.world)

                luassert.equals(4, test.counter, "All four systems should have run once")
                luassert.equals(1, test.beforeCounter, "Before system should have run once")
                luassert.equals(1, test.fixedCounter, "Fixed system should have run once")
                luassert.equals(1, test.updateCounter, "Update system should have run once")
                luassert.equals(1, test.afterCounter, "After system should have run once")
            end
        )

        it(
            "should respect topological ordering with before/after dependencies",
            function()
                local orderTracker = {}

                local systemA = function(_dt: number, _world: tecs.World) table.insert(orderTracker, "A") end

                local systemB = function(_dt: number, _world: tecs.World) table.insert(orderTracker, "B") end

                local systemC = function(_dt: number, _world: tecs.World) table.insert(orderTracker, "C") end

                -- Add systems with explicit dependencies
                -- C should run before A, and B should run after A
                test.pipeline:addSystem({
                    phase = tecs.ecs.phases.Update,
                    run = systemA,
                    name = "systemA",
                    before = {"systemB"},
                    after = {"systemC"},
                })

                test.pipeline:addSystem({phase = tecs.ecs.phases.Update, run = systemB, name = "systemB"})

                test.pipeline:addSystem({phase = tecs.ecs.phases.Update, run = systemC, name = "systemC"})

                test.pipeline:update(FPS, test.world)

                luassert.equals("C", orderTracker[1], "System C should run first")
                luassert.equals("A", orderTracker[2], "System A should run second")
                luassert.equals("B", orderTracker[3], "System B should run last")
            end
        )

        it(
            "should detect cycles in system dependencies",
            function()
                local systemA = function(_dt: number, _world: tecs.World) end
                local systemB = function(_dt: number, _world: tecs.World) end

                -- Create a circular dependency: A before B, B before A
                test.pipeline:addSystem({
                    phase = tecs.ecs.phases.Update, run = systemA, name = "systemA", before = {"systemB"}
                })

                test.pipeline:addSystem({
                    phase = tecs.ecs.phases.Update, run = systemB, name = "systemB", before = {"systemA"}
                })

                luassert.error_matches(
                    function() test.pipeline:update(FPS, test.world) end,
                    "Cycle detected in system dependencies",
                    "Should detect cycles in system dependencies"
                )
            end
        )

        it(
            "should run fixed update systems with appropriate accumulation",
            function()
                local fixedTimestep = 1 / 10
                test.pipeline = pipeline.new(fixedTimestep)

                test.pipeline:addSystem({
                    phase = tecs.ecs.phases.FixedUpdate,
                    run = createCounterSystem(test, "fixed"),
                    name = "fixed_system",
                })

                -- Run with dt less than fixed timestep
                test.pipeline:update(fixedTimestep / 2, test.world)
                luassert.equals(0, test.fixedCounter, "Fixed system should not run when dt < fixedTimestep")

                -- Run with dt equal to fixed timestep
                test.pipeline:update(fixedTimestep / 2, test.world)
                luassert.equals(
                    1, test.fixedCounter, "Fixed system should run once when accumulated dt = fixedTimestep"
                )

                -- Run with dt equal to 2.5x fixed timestep
                test.pipeline:update(fixedTimestep * 2.5, test.world)
                luassert.equals(3, test.fixedCounter, "Fixed system should run twice more with dt = 2.5x fixedTimestep")
            end
        )

        it(
            "should respect the default catch-up limit for fixed updates",
            function()
                local fixedTimestep = 1 / 10
                test.pipeline = pipeline.new(fixedTimestep)

                test.pipeline:addSystem({
                    phase = tecs.ecs.phases.FixedUpdate,
                    run = createCounterSystem(test, "fixed"),
                    name = "fixed_system",
                })

                -- Run with a very large dt, which the default fixedMaxSteps bounds.
                test.pipeline:update(fixedTimestep * 20, test.world)
                luassert.equals(10, test.fixedCounter, "Fixed system should be limited to fixedMaxSteps runs")
                luassert.equals(10, test.pipeline.fixedMaxSteps)
            end
        )

        it(
            "should respect the runIf condition for systems",
            function()
                local system, runIf = createConditionalSystem(test)

                test.pipeline:addSystem({
                    phase = tecs.ecs.phases.Update, run = system, runIf = runIf, name = "conditional_system"
                })

                -- First run with counter = 0 (even, should run)
                test.pipeline:update(FPS, test.world)
                luassert.equals(100, test.counter, "Conditional system should run when counter is even")

                -- Second run with counter = 100 (even, should run)
                test.pipeline:update(FPS, test.world)
                luassert.equals(200, test.counter, "Conditional system should run when counter is even")

                -- Manually set to odd
                test.counter = 201

                -- Third run with counter = 201 (odd, should not run)
                test.pipeline:update(FPS, test.world)
                luassert.equals(201, test.counter, "Conditional system should not run when counter is odd")
            end
        )

        it(
            "should enable and disable phases correctly",
            function()
                test.pipeline:addSystem({
                    phase = tecs.ecs.phases.Update, run = createCounterSystem(test, "update"), name = "update_system"
                })

                -- Run once with all phases enabled
                test.pipeline:update(FPS, test.world)
                luassert.equals(1, test.counter, "System should run with phase enabled")

                -- Disable the Update phase
                test.pipeline:disablePhase(tecs.ecs.phases.Update)

                -- Run again with update phase disabled
                test.pipeline:update(FPS, test.world)
                luassert.equals(1, test.counter, "System should not run with phase disabled")

                -- Re-enable the Update phase
                test.pipeline:enablePhase(tecs.ecs.phases.Update)

                -- Run again with update phase re-enabled
                test.pipeline:update(FPS, test.world)
                luassert.equals(2, test.counter, "System should run again after phase is re-enabled")
            end
        )

        it(
            "should correctly remove systems",
            function()
                local system = createCounterSystem(test, "update")

                test.pipeline:addSystem({phase = tecs.ecs.phases.Update, run = system, name = "update_system"})

                -- Run once
                test.pipeline:update(FPS, test.world)
                luassert.equals(1, test.counter, "System should run before removal")

                -- Remove the system by name
                test.pipeline:removeSystem("update_system")

                -- Run again
                test.pipeline:update(FPS, test.world)
                luassert.equals(1, test.counter, "System should not run after removal")
            end
        )

        it(
            "keeps count accurate before rebuilds",
            function()
                local systemA = createCounterSystem(test, "update")
                local systemB = createCounterSystem(test, "before")

                luassert.equals(0, test.pipeline.count, "fresh pipeline should start empty")

                test.pipeline:addSystem({phase = tecs.ecs.phases.Update, run = systemA, name = "update_system"})
                luassert.equals(1, test.pipeline.count, "count should update immediately after add")

                test.pipeline:addSystem({phase = tecs.ecs.phases.PreUpdate, run = systemB, name = "before_system"})
                luassert.equals(2, test.pipeline.count, "count should include multiple added systems before update")

                test.pipeline:removeSystem("update_system")
                luassert.equals(1, test.pipeline.count, "count should decrement immediately after removal")
            end
        )

        it(
            "should handle children",
            function()
                -- Add system to FixedUpdate phase
                test.pipeline:addSystem({
                    phase = tecs.ecs.phases.FixedUpdate,
                    run = createCounterSystem(test, "fixed"),
                    name = "fixed_system",
                })

                -- Run with all phases enabled
                test.pipeline:update(FPS, test.world)
                luassert.equals(1, test.fixedCounter, "System should run with parent phase enabled")

                -- Disable the FixedUpdateGroup phase (parent of FixedUpdate)
                test.pipeline:disablePhase(tecs.ecs.phases.FixedUpdateGroup)

                -- Run again
                test.pipeline:update(FPS, test.world)
                luassert.equals(1, test.fixedCounter, "System should not run when parent phase is disabled")

                -- Re-enable just the child phase
                test.pipeline:enablePhase(tecs.ecs.phases.FixedUpdate)

                -- Run again
                test.pipeline:update(FPS, test.world)
                luassert.equals(2, test.fixedCounter, "System should run again after child phase is re-enabled")
            end
        )

        it(
            "commits at phase boundaries and declared system barriers",
            function()
                local commitCount = 0
                test.world = {
                    _commit = function(_self: tecs.World) commitCount = commitCount + 1 end,
                } as tecs.World

                test.pipeline:addSystem({
                    phase = tecs.ecs.phases.PreUpdate,
                    run = createCounterSystem(test, "before"),
                    name = "before_system",
                })

                test.pipeline:addSystem({
                    phase = tecs.ecs.phases.Update,
                    run = createCounterSystem(test, "update"),
                    name = "update_system",
                    commitBefore = true,
                    commitAfter = true,
                })

                test.pipeline:update(FPS, test.world)

                luassert.equals(4, commitCount, "two phase ends plus the declared before/after barriers")
            end
        )

        it(
            "honors a system commit request before the next system",
            function()
                local world = tecs.ecs.newWorld()
                local query = world:newQuery({include = {CommitRequestTag}})
                local visibleToProducer = -1
                local visibleToConsumer = -1

                test.pipeline:addSystem({
                    phase = tecs.ecs.phases.Update,
                    name = "commit_request_producer",
                    run = function(_dt: number, w: tecs.World)
                        w:spawn(CommitRequestTag)
                        w:enqueueCommit()
                        w:enqueueCommit()
                        visibleToProducer = query:count()
                    end,
                })
                test.pipeline:addSystem({
                    phase = tecs.ecs.phases.Update,
                    name = "commit_request_consumer",
                    run = function(_dt: number, _w: tecs.World) visibleToConsumer = query:count() end,
                })

                test.pipeline:update(FPS, world)

                luassert.equals(0, visibleToProducer, "the requesting system must retain its stable view")
                luassert.equals(1, visibleToConsumer, "the next system must observe the requested barrier")
            end
        )

        it(
            "honors a commit request immediately outside system dispatch",
            function()
                local world = tecs.ecs.newWorld()
                local entity = world:spawn(CommitRequestTag)

                luassert.is_false(world:isAlive(entity))
                world:enqueueCommit()
                luassert.is_true(world:isAlive(entity))
            end
        )

        it(
            "does not call commit when all phase groups are empty",
            function()
                local commitCount = 0
                test.world = {
                    _commit = function(_self: tecs.World) commitCount = commitCount + 1 end,
                } as tecs.World

                test.pipeline:update(FPS, test.world)

                luassert.equals(0, commitCount, "idle update() should not commit")
            end
        )

        describe(
            "dependency sort",
            function()
                it(
                    "honors before when the target system registered first",
                    function()
                        local order: {string} = {}
                        test.pipeline:addSystem({
                            phase = tecs.ecs.phases.Update,
                            name = "beforeTargetB",
                            run = function(_dt: number, _world: tecs.World) order[#order + 1] = "B" end,
                        })
                        test.pipeline:addSystem({
                            phase = tecs.ecs.phases.Update,
                            name = "beforeSourceA",
                            run = function(_dt: number, _world: tecs.World) order[#order + 1] = "A" end,
                            before = {"beforeTargetB"},
                        })

                        test.pipeline:update(FPS, test.world)

                        luassert.same({"A", "B"}, order, "before constraint must hold regardless of registration order")
                    end
                )

                it(
                    "accepts a redundant consistent constraint pair",
                    function()
                        local order: {string} = {}
                        test.pipeline:addSystem({
                            phase = tecs.ecs.phases.Update,
                            name = "redundantA",
                            run = function(_dt: number, _world: tecs.World) order[#order + 1] = "A" end,
                            before = {"redundantB"},
                        })
                        test.pipeline:addSystem({
                            phase = tecs.ecs.phases.Update,
                            name = "redundantB",
                            run = function(_dt: number, _world: tecs.World) order[#order + 1] = "B" end,
                            after = {"redundantA"},
                        })

                        test.pipeline:update(FPS, test.world)

                        luassert.same({"A", "B"}, order, "A before B plus B after A describe one edge, not a cycle")
                    end
                )

                it(
                    "runs two systems sharing one run function",
                    function()
                        local runs = 0
                        local shared = function(_dt: number, _world: tecs.World) runs = runs + 1 end
                        test.pipeline:addSystem({
                            phase = tecs.ecs.phases.Update,
                            name = "sharedFn1",
                            run = shared,
                        })
                        test.pipeline:addSystem({
                            phase = tecs.ecs.phases.Update,
                            name = "sharedFn2",
                            run = shared,
                        })

                        test.pipeline:update(FPS, test.world)

                        luassert.equals(2, runs, "both registrations must execute")
                    end
                )
            end
        )

        it(
            "run() on a disabled leaf phase executes nothing",
            function()
                local ran = 0
                test.pipeline:addSystem({
                    phase = tecs.ecs.phases.Update,
                    name = "disabledLeafProbe",
                    run = function(_dt: number, _world: tecs.World) ran = ran + 1 end,
                })

                test.pipeline:disablePhase(tecs.ecs.phases.Update)
                test.pipeline:run(tecs.ecs.phases.Update, FPS, test.world)
                luassert.equals(0, ran, "disabled leaf phase must not run directly")

                test.pipeline:enablePhase(tecs.ecs.phases.Update)
                test.pipeline:run(tecs.ecs.phases.Update, FPS, test.world)
                luassert.equals(1, ran, "re-enabled phase runs again")
            end
        )

        it(
            "a phase registered on another pipeline does not break this one",
            function()
                local ran = 0
                test.pipeline:addSystem({
                    phase = tecs.ecs.phases.Update,
                    name = "crossPipelineProbe",
                    run = function(_dt: number, _world: tecs.World) ran = ran + 1 end,
                })

                local other = pipeline.new(FPS)
                local custom = {name = "CrossPipelineCustom"} as tecs.ecs.Phase
                other:registerPhase(custom)
                other:addSystem({
                    phase = custom,
                    name = "crossPipelineCustomSystem",
                    run = function(_dt: number, _world: tecs.World) end,
                })

                -- Rebuild iterates the shared phase index; the position registered
                -- only on `other` must be tolerated.
                test.pipeline:update(FPS, test.world)
                luassert.equals(1, ran)
            end
        )
    end
)

-- A frame that owes more fixed steps than it is allowed to run has to do
-- something with the rest, and the thing it must not do is nothing. These use
-- a timestep of 1/8, which is exact in binary, so the assertions are about the
-- policy rather than about floating-point drift. The invariant that has to
-- hold at any timestep is asserted separately, with a tolerance.
describe(
    "Pipeline fixed-step overload",
    function()
        local world: tecs.World
        local steps: integer

        local function makeDummyWorld(): tecs.World
            return {_commit = function(_self: tecs.World) end} as tecs.World
        end

        local function counting(p: tecs.ecs.Pipeline): tecs.ecs.Pipeline
            p:addSystem({
                phase = tecs.ecs.phases.FixedUpdate,
                name = "overloadStep",
                run = function(_dt: number, _world: tecs.World) steps = steps + 1 end,
            })
            return p
        end

        local EXACT <const> = 1 / 8

        before_each(function() world = makeDummyWorld(); steps = 0 end)

        it(
            "reports the simulated time it drops rather than swallowing it",
            function()
                local p = counting(pipeline.new(EXACT))

                -- Twenty steps owed, ten allowed.
                p:update(EXACT * 20, world)

                luassert.equals(10, steps, "the frame runs what it is allowed")
                luassert.equals(10, p.fixedStepsDropped, "and says how many it did not")
                luassert.is_true(math.abs(p.fixedTimeDropped - EXACT * 10) < 1e-12, "in seconds as well as in steps")
                luassert.is_true(p.fixedAccumulator < EXACT, "with nothing left owing, so the next frame starts level")
            end
        )

        it(
            "drops nothing on a frame that keeps up",
            function()
                local p = counting(pipeline.new(EXACT))

                p:update(EXACT * 3, world)

                luassert.equals(3, steps)
                luassert.equals(0, p.fixedStepsDropped)
                luassert.equals(0, p.fixedTimeDropped)
            end
        )

        it(
            "keeps the sub-step remainder, so the interpolation alpha does not jump",
            function()
                local p = counting(pipeline.new(EXACT))

                -- Twenty whole steps plus a sixteenth, which is half a step.
                p:update(EXACT * 20 + EXACT / 2, world)

                luassert.equals(10, p.fixedStepsDropped, "whole steps only")
                luassert.is_true(
                    math.abs(p.fixedAccumulator - EXACT / 2) < 1e-12,
                    "the part of a step that had not elapsed is not a step to drop"
                )
            end
        )

        it(
            "takes a catch-up limit of its own",
            function()
                local p = counting(pipeline.new(EXACT, 3))

                p:update(EXACT * 20, world)

                luassert.equals(3, p.fixedMaxSteps)
                luassert.equals(3, steps, "three is the budget it was given")
                luassert.equals(17, p.fixedStepsDropped, "and the other seventeen are counted")
            end
        )

        it(
            "keeps every second under the accumulate policy",
            function()
                local p = counting(pipeline.new(EXACT, 10, "accumulate"))

                p:update(EXACT * 20, world)
                luassert.equals(10, steps, "a frame is still bounded")
                luassert.equals(0, p.fixedStepsDropped, "but nothing is abandoned")
                luassert.equals(0, p.fixedTimeDropped)
                luassert.is_true(p.fixedAccumulator >= EXACT * 10, "the debt is still owed")

                -- The frames after it work the debt off.
                p:update(0, world)
                luassert.equals(20, steps, "and the simulation catches up exactly")
                luassert.equals(0, p.fixedStepsDropped)
            end
        )

        it(
            "conserves time at a timestep that is not exact in binary",
            function()
                local p = counting(pipeline.new(1 / 60))
                local total = 1.0

                p:update(total, world)

                -- Every second handed in is either simulated, dropped and
                -- counted, or still owed. There is no fourth destination.
                local accounted = steps * (1 / 60) + p.fixedTimeDropped + p.fixedAccumulator
                luassert.is_true(
                    math.abs(accounted - total) < 1e-9, "time went somewhere unaccounted: " .. tostring(accounted)
                )
                luassert.is_true(p.fixedStepsDropped > 0, "and this frame did drop some")
            end
        )

        it(
            "rejects a configuration that cannot work",
            function()
                luassert.is_false(
                    pcall(function() pipeline.new(0) end), "a zero timestep is an infinite loop, not a fast one"
                )
                luassert.is_false(pcall(function() pipeline.new(-1 / 60) end))
                luassert.is_false(
                    pcall(function() pipeline.new(1 / 60, 0) end), "a frame that may run no steps never advances"
                )
                luassert.is_false(pcall(function() pipeline.new(1 / 60, 2.5 as integer) end))
                luassert.is_false(pcall(function() pipeline.new(1 / 60, 10, "clamp" as tecs.ecs.FixedOverload) end))
            end
        )
    end
)

describe(
    "World fixed-step configuration",
    function()
        it(
            "passes the policy through newWorld and reports the loss in getStats",
            function()
                local world <const> = tecs.ecs.newWorld({timestep = 1 / 8, fixedMaxSteps = 2})
                local steps = 0
                world:addSystem({
                    phase = tecs.ecs.phases.FixedUpdate,
                    name = "worldOverloadStep",
                    run = function(_dt: number, _world: tecs.World) steps = steps + 1 end,
                })

                world:update(1.0)

                luassert.equals(2, steps, "the world's own limit is the one that applied")
                local stats <const> = world:getStats()
                luassert.equals(6, stats.fixedStepsDropped, "eight steps were owed, two ran")
                luassert.is_true(stats.fixedTimeDropped > 0, "and getStats is where a game or a tool finds that out")
            end
        )

        it(
            "drops nothing on a world that is keeping up",
            function()
                local world <const> = tecs.ecs.newWorld()
                world:update(1 / 60)
                luassert.equals(0, world:getStats().fixedStepsDropped)
                luassert.equals(0, world:getStats().fixedTimeDropped)
            end
        )
    end
)
