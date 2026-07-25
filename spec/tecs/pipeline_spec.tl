require("busted")
local tecs <const> = require("tecs")
local pipeline <const> = require("tecs.internal.pipeline")
local luassert = require("luassert")

local record Test
    world: tecs.World
    pipeline: tecs.Pipeline
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

    return function(_dt: number, _world: tecs.World)
        test.counter = test.counter + 100
    end, runIf
end

-- Dummy world stub. The pipeline calls world:commit() at phase boundaries,
-- so the dummy needs a commit method; tests that care about commit semantics
-- override it locally.
local function makeDummyWorld(): tecs.World
    return { commit = function(_self: tecs.World) end } as tecs.World
end

local FPS <const> = 1 / 60

describe("Pipeline", function()
    local test: Test

    before_each(function()
        test = {
            world = makeDummyWorld(),
            pipeline = nil,
            counter = 0,
            fixedCounter = 0,
            updateCounter = 0,
            beforeCounter = 0,
            afterCounter = 0
        }
        test.pipeline = pipeline.new(FPS)
    end)

    it("exposes concrete phase positions through the public Phase type", function()
        local update: tecs.Phase = tecs.phases.Update
        luassert.is_true(update.position > 0)
        luassert.equals("Update", update.name)
    end)

    it("should add and run systems in the correct phases", function()
        -- Add systems to different phases
        test.pipeline:addSystem({
            phase = tecs.phases.PreUpdate,
            run = createCounterSystem(test, "before"),
            name = "before_system"
        })

        test.pipeline:addSystem({
            phase = tecs.phases.FixedUpdate,
            run = createCounterSystem(test, "fixed"),
            name = "fixed_system"
        })

        test.pipeline:addSystem({
            phase = tecs.phases.Update,
            run = createCounterSystem(test, "update"),
            name = "update_system"
        })

        test.pipeline:addSystem({
            phase = tecs.phases.PostUpdate,
            run = createCounterSystem(test, "after"),
            name = "after_system"
        })

        test.pipeline:update(FPS, test.world)

        luassert.equals(4, test.counter, "All four systems should have run once")
        luassert.equals(1, test.beforeCounter, "Before system should have run once")
        luassert.equals(1, test.fixedCounter, "Fixed system should have run once")
        luassert.equals(1, test.updateCounter, "Update system should have run once")
        luassert.equals(1, test.afterCounter, "After system should have run once")
    end)

    it("should respect topological ordering with before/after dependencies", function()
        local orderTracker = {}

        local systemA = function(_dt: number, _world: tecs.World)
            table.insert(orderTracker, "A")
        end

        local systemB = function(_dt: number, _world: tecs.World)
            table.insert(orderTracker, "B")
        end

        local systemC = function(_dt: number, _world: tecs.World)
            table.insert(orderTracker, "C")
        end

        -- Add systems with explicit dependencies
        -- C should run before A, and B should run after A
        test.pipeline:addSystem({
            phase = tecs.phases.Update,
            run = systemA,
            name = "systemA",
            before = {"systemB"},
            after = {"systemC"}
        })

        test.pipeline:addSystem({
            phase = tecs.phases.Update,
            run = systemB,
            name = "systemB"
        })

        test.pipeline:addSystem({
            phase = tecs.phases.Update,
            run = systemC,
            name = "systemC"
        })

        test.pipeline:update(FPS, test.world)

        luassert.equals("C", orderTracker[1], "System C should run first")
        luassert.equals("A", orderTracker[2], "System A should run second")
        luassert.equals("B", orderTracker[3], "System B should run last")
    end)

    it("should detect cycles in system dependencies", function()
        local systemA = function(_dt: number, _world: tecs.World) end
        local systemB = function(_dt: number, _world: tecs.World) end

        -- Create a circular dependency: A before B, B before A
        test.pipeline:addSystem({
            phase = tecs.phases.Update,
            run = systemA,
            name = "systemA",
            before = {"systemB"}
        })

        test.pipeline:addSystem({
            phase = tecs.phases.Update,
            run = systemB,
            name = "systemB",
            before = {"systemA"}
        })

        luassert.error_matches(function()
            test.pipeline:update(FPS, test.world)
        end, "Cycle detected in system dependencies", "Should detect cycles in system dependencies")
    end)

    it("should run fixed update systems with appropriate accumulation", function()
        local fixedTimestep = 1 / 10
        test.pipeline = pipeline.new(fixedTimestep)

        test.pipeline:addSystem({
            phase = tecs.phases.FixedUpdate,
            run = createCounterSystem(test, "fixed"),
            name = "fixed_system"
        })

        -- Run with dt less than fixed timestep
        test.pipeline:update(fixedTimestep / 2, test.world)
        luassert.equals(0, test.fixedCounter, "Fixed system should not run when dt < fixedTimestep")

        -- Run with dt equal to fixed timestep
        test.pipeline:update(fixedTimestep / 2, test.world)
        luassert.equals(1, test.fixedCounter, "Fixed system should run once when accumulated dt = fixedTimestep")

        -- Run with dt equal to 2.5x fixed timestep
        test.pipeline:update(fixedTimestep * 2.5, test.world)
        luassert.equals(3, test.fixedCounter, "Fixed system should run twice more with dt = 2.5x fixedTimestep")
    end)

    it("should respect the MAX_ITERATIONS limit for fixed updates", function()
        local fixedTimestep = 1 / 10
        test.pipeline = pipeline.new(fixedTimestep)

        test.pipeline:addSystem({
            phase = tecs.phases.FixedUpdate,
            run = createCounterSystem(test, "fixed"),
            name = "fixed_system"
        })

        -- Run with a very large dt (should be limited to MAX_ITERATIONS)
        test.pipeline:update(fixedTimestep * 20, test.world)
        luassert.equals(10, test.fixedCounter, "Fixed system should be limited to MAX_ITERATIONS runs")
    end)

    it("should respect the runIf condition for systems", function()
        local system, runIf = createConditionalSystem(test)

        test.pipeline:addSystem({
            phase = tecs.phases.Update,
            run = system,
            runIf = runIf,
            name = "conditional_system"
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
    end)

    it("should enable and disable phases correctly", function()
        test.pipeline:addSystem({
            phase = tecs.phases.Update,
            run = createCounterSystem(test, "update"),
            name = "update_system"
        })

        -- Run once with all phases enabled
        test.pipeline:update(FPS, test.world)
        luassert.equals(1, test.counter, "System should run with phase enabled")

        -- Disable the Update phase
        test.pipeline:disablePhase(tecs.phases.Update)

        -- Run again with update phase disabled
        test.pipeline:update(FPS, test.world)
        luassert.equals(1, test.counter, "System should not run with phase disabled")

        -- Re-enable the Update phase
        test.pipeline:enablePhase(tecs.phases.Update)

        -- Run again with update phase re-enabled
        test.pipeline:update(FPS, test.world)
        luassert.equals(2, test.counter, "System should run again after phase is re-enabled")
    end)

    it("should correctly remove systems", function()
        local system = createCounterSystem(test, "update")

        test.pipeline:addSystem({
            phase = tecs.phases.Update,
            run = system,
            name = "update_system"
        })

        -- Run once
        test.pipeline:update(FPS, test.world)
        luassert.equals(1, test.counter, "System should run before removal")

        -- Remove the system by name
        test.pipeline:removeSystem("update_system")

        -- Run again
        test.pipeline:update(FPS, test.world)
        luassert.equals(1, test.counter, "System should not run after removal")
    end)

    it("keeps count accurate before rebuilds", function()
        local systemA = createCounterSystem(test, "update")
        local systemB = createCounterSystem(test, "before")

        luassert.equals(0, test.pipeline.count, "fresh pipeline should start empty")

        test.pipeline:addSystem({
            phase = tecs.phases.Update,
            run = systemA,
            name = "update_system"
        })
        luassert.equals(1, test.pipeline.count, "count should update immediately after add")

        test.pipeline:addSystem({
            phase = tecs.phases.PreUpdate,
            run = systemB,
            name = "before_system"
        })
        luassert.equals(2, test.pipeline.count, "count should include multiple added systems before update")

        test.pipeline:removeSystem("update_system")
        luassert.equals(1, test.pipeline.count, "count should decrement immediately after removal")
    end)

    it("should handle children", function()
        -- Add system to FixedUpdate phase
        test.pipeline:addSystem({
            phase = tecs.phases.FixedUpdate,
            run = createCounterSystem(test, "fixed"),
            name = "fixed_system"
        })

        -- Run with all phases enabled
        test.pipeline:update(FPS, test.world)
        luassert.equals(1, test.fixedCounter, "System should run with parent phase enabled")

        -- Disable the FixedUpdateGroup phase (parent of FixedUpdate)
        test.pipeline:disablePhase(tecs.phases.FixedUpdateGroup)

        -- Run again
        test.pipeline:update(FPS, test.world)
        luassert.equals(1, test.fixedCounter, "System should not run when parent phase is disabled")

        -- Re-enable just the child phase
        test.pipeline:enablePhase(tecs.phases.FixedUpdate)

        -- Run again
        test.pipeline:update(FPS, test.world)
        luassert.equals(2, test.fixedCounter, "System should run again after child phase is re-enabled")
    end)

    it("does not call commit at phase-group boundaries (eager mode)", function()
        -- With eager-by-default mutation semantics, each world:set /
        -- despawn / etc. flushes as it happens (or on query-iteration
        -- exit via auto-defer). The pipeline no longer calls
        -- world:commit at phase-group boundaries -- that would be a
        -- redundant no-op fast-bail.
        local commitCount = 0
        test.world = {
            commit = function(_self: tecs.World) commitCount = commitCount + 1 end,
        } as tecs.World

        test.pipeline:addSystem({
            phase = tecs.phases.PreUpdate,
            run = createCounterSystem(test, "before"),
            name = "before_system"
        })

        test.pipeline:addSystem({
            phase = tecs.phases.Update,
            run = createCounterSystem(test, "update"),
            name = "update_system"
        })

        test.pipeline:update(FPS, test.world)

        luassert.equals(0, commitCount,
            "pipeline should not call world:commit under eager semantics")
    end)

    it("does not call commit when all phase groups are empty", function()
        local commitCount = 0
        test.world = {
            commit = function(_self: tecs.World) commitCount = commitCount + 1 end,
        } as tecs.World

        test.pipeline:update(FPS, test.world)

        luassert.equals(0, commitCount,
            "idle update() should not commit")
    end)

    describe("dependency sort", function()
        it("honors before when the target system registered first", function()
            local order: {string} = {}
            test.pipeline:addSystem({
                phase = tecs.phases.Update,
                name = "beforeTargetB",
                run = function(_dt: number, _world: tecs.World) order[#order + 1] = "B" end,
            })
            test.pipeline:addSystem({
                phase = tecs.phases.Update,
                name = "beforeSourceA",
                run = function(_dt: number, _world: tecs.World) order[#order + 1] = "A" end,
                before = {"beforeTargetB"},
            })

            test.pipeline:update(FPS, test.world)

            luassert.same({"A", "B"}, order,
                "before constraint must hold regardless of registration order")
        end)

        it("accepts a redundant consistent constraint pair", function()
            local order: {string} = {}
            test.pipeline:addSystem({
                phase = tecs.phases.Update,
                name = "redundantA",
                run = function(_dt: number, _world: tecs.World) order[#order + 1] = "A" end,
                before = {"redundantB"},
            })
            test.pipeline:addSystem({
                phase = tecs.phases.Update,
                name = "redundantB",
                run = function(_dt: number, _world: tecs.World) order[#order + 1] = "B" end,
                after = {"redundantA"},
            })

            test.pipeline:update(FPS, test.world)

            luassert.same({"A", "B"}, order,
                "A before B plus B after A describe one edge, not a cycle")
        end)

        it("runs two systems sharing one run function", function()
            local runs = 0
            local shared = function(_dt: number, _world: tecs.World) runs = runs + 1 end
            test.pipeline:addSystem({
                phase = tecs.phases.Update,
                name = "sharedFn1",
                run = shared,
            })
            test.pipeline:addSystem({
                phase = tecs.phases.Update,
                name = "sharedFn2",
                run = shared,
            })

            test.pipeline:update(FPS, test.world)

            luassert.equals(2, runs, "both registrations must execute")
        end)
    end)

    it("run() on a disabled leaf phase executes nothing", function()
        local ran = 0
        test.pipeline:addSystem({
            phase = tecs.phases.Update,
            name = "disabledLeafProbe",
            run = function(_dt: number, _world: tecs.World) ran = ran + 1 end,
        })

        test.pipeline:disablePhase(tecs.phases.Update)
        test.pipeline:run(tecs.phases.Update, FPS, test.world)
        luassert.equals(0, ran, "disabled leaf phase must not run directly")

        test.pipeline:enablePhase(tecs.phases.Update)
        test.pipeline:run(tecs.phases.Update, FPS, test.world)
        luassert.equals(1, ran, "re-enabled phase runs again")
    end)

    it("a phase registered on another pipeline does not break this one", function()
        local ran = 0
        test.pipeline:addSystem({
            phase = tecs.phases.Update,
            name = "crossPipelineProbe",
            run = function(_dt: number, _world: tecs.World) ran = ran + 1 end,
        })

        local other = pipeline.new(FPS)
        local custom = {name = "CrossPipelineCustom"} as tecs.Phase
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
    end)
end)
