require("busted")
local WorldImpl <const> = require("tecs.internal.world")
local phases <const> = require("tecs.internal.phases")
local luassert <const> = require("luassert")
local spy <const> = require("luassert.spy")
local TestHelpers <const> = require("spec.tecs.test_helpers")
local tecs <const> = require("tecs")

describe("WorldImpl", function()
    local w: WorldImpl
    local testId = 0
    local provider: TestHelpers.ComponentProvider
    local PosComponent: TestHelpers.Pos
    local VelComponent: TestHelpers.Vel
    local DeadComponent: TestHelpers.Dead

    before_each(function()
        w = WorldImpl.new() as WorldImpl
        testId = testId + 1

        -- Use the test helper provider
        provider = TestHelpers.createComponentProvider("WorldTest", testId)
        PosComponent = provider.PosComponent
        VelComponent = provider.VelComponent
        DeadComponent = provider.DeadComponent
    end)

    describe("basic world functionality", function()
        it("creates a world", function()
            local w2 = tecs.newWorld()

            luassert.is_not_nil(w2, "World should be created successfully")
            luassert.is_table(w2, "World should be a table")
            luassert.is_function(w2.update, "World should have an update method")
        end)

        it("creates a world with a custom pipeline", function()
            local spyRun = spy.new(function() end)
            local w2 = tecs.newWorld({pipelineFactory = function(): tecs.Pipeline
                return {
                    -- builtin-plugins add systems. Don't assert on this though since more may be added in the future.
                    addSystem = spy.new(function() end),
                    run = spyRun
                } as tecs.Pipeline
            end})

            luassert.is_not_nil(w2, "World should be created with custom pipeline")
            w2:startup()

            luassert.spy(spyRun).was_called(1)
        end)

        it("returns stats about the world", function()
            local w2 = tecs.newWorld()
            local stats = w2:getStats()

            luassert.is_table(stats, "Stats should be a table")
            luassert.is_number(stats.entities, "Stats should include entity count")
            luassert.is_number(stats.archetypes, "Stats should include archetype count")
            luassert.is_number(stats.components, "Stats should include component count")
            luassert.is_number(stats.systems, "Stats should include system count")
        end)
    end)

    describe("entity management", function()
        it("should spawn entities", function()
            local entity = w:spawn(PosComponent())
            w.db:commit() -- Need to commit for entity to be alive
            luassert.is_not_nil(entity)
            luassert.is_true(w:isAlive(entity))
        end)

        it("should despawn entities", function()
            local entity = w:spawn(tecs.builtins.Emitter())
            w.db:commit()
            luassert.is_true(w:isAlive(entity))

            w:despawn(entity)
            w.db:commit()
            luassert.is_false(w:isAlive(entity))
        end)

        it("immediately despawned entities never existed anyway", function()
            local w2 = tecs.newWorld()

            -- Create entity with an emitter
            local emitter = tecs.builtins.Emitter()
            local entity = w2:spawn(emitter)

            -- Add an observer for the OnDespawn event. This won't be fired because the spawn is
            -- immediately canceled out before it's even committed.
            local despawnEventEmitted = false
            emitter:observe(tecs.builtins.OnDespawn, function(e: tecs.builtins.OnDespawn)
                despawnEventEmitted = true
                luassert.equals(entity, e.entity, "OnDespawn event should contain correct entity ID")
            end)

            -- Despawn the entity
            w2:despawn(entity)

            -- Force the world to update so batched changes are applied.
            w2:update(1 / 60)

            luassert.is_false(despawnEventEmitted, "OnDespawn event should not be emitted")
            luassert.is_false(w2:isAlive(entity), "Entity should not be alive after despawning")
        end)

        it("despawns entities and emits event", function()
            local w2 = tecs.newWorld()

            -- Create entity with an emitter
            local emitter = tecs.builtins.Emitter()
            local entity = w2:spawn(emitter)

            -- Add an observer for the OnDespawn event
            local despawnEventEmitted = false
            emitter:observe(tecs.builtins.OnDespawn, function(e: tecs.builtins.OnDespawn)
                despawnEventEmitted = true
                luassert.equals(entity, e.entity, "OnDespawn event should contain correct entity ID")
            end)

            -- Force the world to update so batched changes are applied.
            w2:update(1 / 60)

            -- Despawn the entity
            w2:despawn(entity)

            -- Force the world to update so batched changes are applied.
            w2:update(1 / 60)

            luassert.is_true(despawnEventEmitted, "OnDespawn event should be emitted")
            luassert.is_false(w2:isAlive(entity), "Entity should not be alive after despawning")
        end)
    end)

    describe("component management", function()
        it("should get and set components", function()
            local entity = w:spawn(PosComponent(10, 20))
            w.db:commit()

            local pos = w:get(entity, PosComponent) as TestHelpers.Pos
            luassert.is_not_nil(pos)
            luassert.equals(10, pos.x)
            luassert.equals(20, pos.y)

            w:set(entity, PosComponent(30, 40))
            w.db:commit()
            pos = w:get(entity, PosComponent) as TestHelpers.Pos
            luassert.equals(30, pos.x)
            luassert.equals(40, pos.y)
        end)

        it("adds components using public API", function()
            local w2 = tecs.newWorld()

            local entity = w2:spawn()
            w2:set(entity, tecs.builtins.Name("TestEntity"))

            -- Force the world to update so batched changes are applied.
            w2:update(1 / 60)

            local component = w2:get(entity, tecs.builtins.Name)
            luassert.is_not_nil(component, "Component should be added to entity")
            luassert.equals("TestEntity", component.value, "Component should have the correct value")

            -- Get a non-existent component
            luassert.is_nil(w2:get(entity, tecs.builtins.Transform), "Non-existent component should return nil")
        end)

        it("fails when adding component to unknown entity", function()
            local w2 = tecs.newWorld()

            luassert.error_matches(function()
                w2:set(12345, tecs.builtins.Name("TestEntity"))
            end, "Entity ID 12345 not found in any archetype", "Should fail when adding component to an unknown entity")
        end)

        it("should remove components", function()
            local entity = w:spawn(PosComponent(), VelComponent())
            w.db:commit()

            luassert.is_not_nil(w:get(entity, PosComponent))
            luassert.is_not_nil(w:get(entity, VelComponent))

            w:remove(entity, VelComponent)
            w.db:commit()

            luassert.is_not_nil(w:get(entity, PosComponent))
            luassert.is_nil(w:get(entity, VelComponent))
        end)

        it("removes components using public API", function()
            local w2 = tecs.newWorld()
            local entity = w2:spawn()
            w2:set(entity, tecs.builtins.Name("TestEntity"))

            -- Force the world to update so batched changes are applied.
            w2:update(1 / 60)

            -- Verify component was added
            luassert.is_not_nil(w2:get(entity, tecs.builtins.Name), "Component should be added initially")

            -- Remove the component
            w2:remove(entity, tecs.builtins.Name)

            -- Force the world to update so batched changes are applied.
            w2:update(1 / 60)

            -- Verify component was removed
            luassert.is_nil(w2:get(entity, tecs.builtins.Name), "Component should be removed from entity")
        end)

        it("gets entity emitter for already spawned entity that has an emitter", function()
            local w2 = tecs.newWorld()
            local entity = w2:spawn(tecs.builtins.Emitter())

            -- force the world to update so batched changes are applied.
            w2:update(1 / 60)

            luassert.is_not_nil(w2:getEntityEmitter(entity), "Entity emitter should be returned")
        end)

        it("gets and creates an entity emitter for already spawned entity", function()
            local w2 = tecs.newWorld()
            local entity = w2:spawn()

            -- force the world to update so batched changes are applied.
            w2:update(1 / 60)

            luassert.is_not_nil(w2:getEntityEmitter(entity), "Entity emitter should be returned")
        end)

        it("gets entity emitter for entity currently being created", function()
            local w2 = tecs.newWorld()
            local entity = w2:spawn()

            luassert.is_not_nil(w2:getEntityEmitter(entity), "Entity emitter should be returned")
        end)
    end)

    describe("query system", function()
        it("should create queries", function()
            w:spawn(PosComponent())
            w:spawn(PosComponent(), VelComponent())
            w:spawn(VelComponent())
            w.db:commit()

            local query = w:query({
                include = {PosComponent}
            })

            luassert.is_not_nil(query)

            local count = 0
            for _archetype, len, _entities in query() do
                for _row = 1, len do
                    count = count + 1
                end
            end
            luassert.equals(2, count) -- Two entities have Pos
        end)

        it("should support exclude in queries", function()
            w:spawn(PosComponent())
            w:spawn(PosComponent(), DeadComponent())
            w:spawn(PosComponent())
            w.db:commit()

            local query = w:query({
                include = {PosComponent},
                exclude = {DeadComponent}
            })

            local count = 0
            for _archetype, len, _entities in query() do
                for _row = 1, len do
                    count = count + 1
                end
            end
            luassert.equals(2, count) -- Two entities have Pos but not Dead
        end)
    end)

    describe("resources", function()
        it("puts resources", function()
            local w2 = tecs.newWorld()
            local k: tecs.Context.Key<string> = tecs.Context.newKey()
            local v = "test"
            w2.resources[k] = v

            luassert.is_not_nil(w2.resources[k], "Resource should be stored in the world")
            luassert.equals(w2.resources[k], v, "Retrieved resource should be the same as the stored one")
        end)
    end)

    describe("systems", function()
        it("should add systems", function()
            local systemRan = false

            local function testSystem(_dt: number, _w: WorldImpl)
                systemRan = true
            end

            w:addSystem({
                phase = phases.Update,
                run = testSystem
            })

            w:update(0.016)

            luassert.is_true(systemRan)
        end)

        it("adds systems using public API", function()
            local w2 = tecs.newWorld()
            local systemCalled = false
            local testSystem = function(_dt, _w)
                systemCalled = true
            end

            w2:addSystem({
                phase = tecs.phases.Update,
                name = "TestSystem",
                run = testSystem
            })

            w2:update(1 / 60)

            luassert.is_true(systemCalled, "System should be called during world update")
        end)

        it("should remove systems", function()
            local runCount = 0

            local function testSystem(_dt: number, _w: WorldImpl)
                runCount = runCount + 1
            end

            w:addSystem({
                phase = phases.Update,
                run = testSystem,
                name = "TestSystem"
            })

            w:update(0.016)
            luassert.equals(1, runCount)

            w:removeSystem(phases.Update, "TestSystem")

            w:update(0.016)
            luassert.equals(1, runCount) -- Should not run again
        end)

        it("removes systems using public API", function()
            local w2 = tecs.newWorld()
            local callCount = 0
            local testSystem = function(_dt, _w)
                callCount = callCount + 1
            end

            w2:addSystem({
                phase = tecs.phases.Update,
                name = "TestSystem",
                run = testSystem
            })

            w2:update(1 / 60)
            luassert.equals(1, callCount, "System should be called once")

            -- Remove the system
            w2:removeSystem(tecs.phases.Update, testSystem)

            -- Run update again
            w2:update(1 / 60)
            luassert.equals(1, callCount, "System should not be called after removal")
        end)
    end)

    describe("phases", function()
        it("has startup phase", function()
            local w2 = tecs.newWorld()
            local startupCalled = false
            w2:addSystem({
                phase = tecs.phases.Startup,
                name = "StartupSystem",
                run = function()
                    startupCalled = true
                end
            })

            w2:startup()

            luassert.is_true(startupCalled, "Startup system should be called during world startup")
        end)

        it("has shutdown phase", function()
            local w2 = tecs.newWorld()
            local shutdownCalled = false
            w2:addSystem({
                phase = tecs.phases.Shutdown,
                name = "ShutdownSystem",
                run = function(_dt, _w)
                    shutdownCalled = true
                end
            })

            w2:shutdown()

            luassert.is_true(shutdownCalled, "Shutdown system should be called during world shutdown")
        end)

        it("enables and disables phases", function()
            local w2 = tecs.newWorld()
            local updateCalled = false
            w2:addSystem({
                phase = tecs.phases.Update,
                name = "UpdateSystem",
                run = function(_dt, _w)
                    updateCalled = true
                end
            })

            -- Disable the update phase
            w2:disablePhase(tecs.phases.Update)

            -- Run update
            w2:update(1 / 60)
            luassert.is_false(updateCalled, "Update system should not be called when phase is disabled")

            -- Re-enable the update phase
            w2:enablePhase(tecs.phases.Update)

            -- Run update again
            w2:update(1 / 60)
            luassert.is_true(updateCalled, "Update system should be called when phase is enabled")
        end)
    end)

    describe("commands", function()
        it("should execute commands immediately when not frozen", function()
            local entity = w:spawn(tecs.builtins.Emitter())

            -- ECS is not frozen right after spawn (new system doesn't have frozen state)
            -- w.ecs.frozen = false

            local commandExecuted = false
            w:command(function()
                commandExecuted = true
                w:set(entity, PosComponent())
            end)

            luassert.is_true(commandExecuted)
            luassert.is_not_nil(w:get(entity, PosComponent))
        end)

        it("runs commands immediately if not frozen using public API", function()
            local w2 = tecs.newWorld()
            local commandCalled = false

            w2:command(function()
                commandCalled = true
                -- Commands now access world through closure instead of parameter
            end)

            luassert.is_true(commandCalled, "Command should be called immediately when world is not frozen")
        end)

        it("should defer commands when frozen", function()
            local entity = w:spawn(tecs.builtins.Emitter())

            -- Freeze the DB to simulate system execution
            w.db:setFrozen(true)

            local commandExecuted = false
            w:command(function()
                commandExecuted = true
                w:set(entity, PosComponent())
            end)

            luassert.is_false(commandExecuted)
            luassert.equals(1, #w.commands)

            -- Unfreeze for cleanup
            w.db:setFrozen(false)
        end)

        it("runs commands later when frozen using public API", function()
            local w2 = tecs.newWorld()
            local commandCalled = false

            -- Add a system to test deferred commands
            w2:addSystem({
                phase = tecs.phases.Update,
                name = "TestSystem",
                run = function()
                    -- World is frozen during system execution
                    w2:command(function()
                        commandCalled = true
                    end)

                    luassert.is_false(commandCalled, "Command should not be called immediately when world is frozen")
                end
            })

            w2:update(1 / 60)

            luassert.is_true(commandCalled, "Command should be called after system completes")
        end)
    end)

    describe("plugins", function()
        it("should add plugins", function()
            local pluginRan = false

            local function testPlugin(_w: WorldImpl)
                pluginRan = true
            end

            w:addPlugin(testPlugin)

            luassert.is_true(pluginRan)
        end)

        it("adds plugins using public API", function()
            local w2 = tecs.newWorld()
            local pluginCalled = false

            local testPlugin = function(ww: tecs.World)
                pluginCalled = true
                luassert.is_not_nil(ww, "Plugin should receive the correct world instance")
                luassert.is_equal(w2, ww, "Plugin should receive the correct world instance")
            end

            w2:addPlugin(testPlugin)

            luassert.is_true(pluginCalled, "Plugin should be called when added")
        end)
    end)

    describe("update cycle", function()
        it("should run fixed timestep updates", function()
            local updateCount = 0
            local totalDt: number = 0

            -- Create world with fixed timestep
            local w2 = WorldImpl.new({
                timestep = 0.01 -- 10ms fixed timestep
            }) as WorldImpl

            w2:addSystem({
                phase = phases.FixedUpdate,
                run = function(dt: number, _world: WorldImpl)
                    updateCount = updateCount + 1
                    totalDt = totalDt + dt
                end
            })

            -- Update with 25ms - should run 2 fixed updates
            w2:update(0.025)

            luassert.equals(2, updateCount)
            luassert.is_near(0.02, totalDt, 0.001)
        end)

        it("should freeze ECS during system execution", function()
            local wasFrozen = false

            w:addSystem({
                phase = phases.Update,
                run = function(_dt: number, world: WorldImpl)
                    wasFrozen = (world as WorldImpl).db.frozen
                end
            })

            w:update(0.016)

            luassert.is_true(wasFrozen)
        end)
    end)

    describe("isAlive during despawn", function()
        it("should return false during OnDespawn event", function()
            local entityIdInEvent: integer = nil
            local wasAliveInEvent: boolean = nil

            local entity = w:spawn(tecs.builtins.Emitter())
            w:update(0)

            w:getEntityEmitter(entity):observe(tecs.builtins.OnDespawn, function(event: tecs.builtins.OnDespawn)
                entityIdInEvent = event.entity
                wasAliveInEvent = w:isAlive(event.entity)
            end)

            luassert.is_true(w:isAlive(entity), "Entity should be alive before despawn")
            w:despawn(entity)
            w:update(0)

            luassert.equals(entity, entityIdInEvent, "OnDespawn should have been emitted")
            luassert.is_false(wasAliveInEvent, "Entity should NOT be alive during OnDespawn event")
            luassert.is_false(w:isAlive(entity), "Entity should not be alive after despawn")
        end)

        it("should return false during relationship cleanup hooks", function()
            local parentAliveInHook: boolean = nil
            local childAliveInHook: boolean = nil

            local ChildOf = tecs.newRelationship({
                name = "ChildOfAliveTest",
                exclusive = true,
                onRemove = function(self: tecs.Relationship, world: tecs.World, entityId: integer, _changes: tecs.ChangeView)
                    local rel = self
                    parentAliveInHook = world:isAlive(rel.target)
                    childAliveInHook = world:isAlive(entityId)
                end
            })

            local parent = w:spawn(tecs.builtins.Emitter())
            local child = w:spawn(ChildOf(parent) as tecs.Component, tecs.builtins.Emitter())
            w:update(0)

            luassert.is_true(w:isAlive(parent), "Parent should be alive before despawn")
            luassert.is_true(w:isAlive(child), "Child should be alive before despawn")

            w:despawn(parent)
            w:update(0)

            luassert.is_not_nil(parentAliveInHook, "Hook should have been called")
            luassert.is_false(parentAliveInHook, "Parent should NOT be alive during relationship cleanup")
            luassert.is_true(childAliveInHook, "Child should still be alive during its own hook")
            luassert.is_false(w:isAlive(parent), "Parent should not be alive after despawn")
        end)

        it("should allow component access even when isAlive is false", function()
            local record TestComponentType is tecs.Component
                value: number
            end

            local TestComponent = tecs.newComponent({
                name = "TestComponentAlive",
                container = TestComponentType,
                constructor = function(value: number): tecs.Component
                    return {value = value or 42} as tecs.Component
                end
            })

            local componentValue: number = nil
            local wasAlive: boolean = nil

            local entity = w:spawn(tecs.builtins.Emitter(), TestComponent(100))
            w:update(0)

            w:getEntityEmitter(entity):observe(tecs.builtins.OnDespawn, function(event: tecs.builtins.OnDespawn)
                wasAlive = w:isAlive(event.entity)
                local comp = w:get(event.entity, TestComponent)
                if comp then
                    componentValue = (comp as TestComponentType).value
                end
            end)

            w:despawn(entity)
            w:update(0)

            luassert.is_false(wasAlive, "isAlive should return false during OnDespawn")
            luassert.equals(100, componentValue, "Should still be able to access components even when isAlive is false")
        end)
    end)
end)