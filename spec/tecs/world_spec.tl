require("busted")
local ffi <const> = require("ffi")
local WorldImpl <const> = require("tecs.internal.world")
local luassert <const> = require("luassert")
local spy <const> = require("luassert.spy")
local TestHelpers <const> = require("spec.tecs.test_helpers")
local tecs <const> = require("tecs")
local phases <const> = tecs.phases

describe("WorldImpl", function()
    local w: WorldImpl
    local testId = 0
    local provider: TestHelpers.ComponentProvider
    local PosComponent: TestHelpers.Pos
    local VelComponent: TestHelpers.Vel
    local DeadComponent: TestHelpers.Dead

    local function expectContiguous(firstId: integer | nil, ids: {integer} | nil): integer
        luassert.is_not_nil(firstId)
        luassert.is_nil(ids)
        return firstId as integer
    end

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
            w:commit() -- Need to commit for entity to be alive
            luassert.is_not_nil(entity)
            luassert.is_true(w:isAlive(entity))
        end)

        it("should despawn entities", function()
            local entity = w:spawn()
            w:commit()
            luassert.is_true(w:isAlive(entity))

            w:despawn(entity)
            w:commit()
            luassert.is_false(w:isAlive(entity))
        end)

        it("rejects stale handles after slot reuse", function()
            local parentRel = tecs.newRelationship({
                name = "WorldStaleParent_" .. tostring(testId),
                exclusive = true,
            })

            local stale = w:spawn(PosComponent(1, 2), parentRel(123) as tecs.Component)
            w:commit()
            w:despawn(stale)
            w:commit()

            local fresh = w:spawn(PosComponent(9, 9), parentRel(456) as tecs.Component)
            w:commit()

            luassert.is_false(w:isAlive(stale))
            luassert.is_true(w:isAlive(fresh))
            luassert.not_equals(stale, fresh)
            luassert.is_nil(w:get(stale, PosComponent))
            luassert.is_false(w:has(stale, PosComponent))
            luassert.is_nil(w:getFirstRelationship(stale, parentRel))
        end)

        it("spawn-then-despawn in the same frame still fires OnDespawn", function()
            local w2 = tecs.newWorld()

            -- Spawn-then-despawn in the same frame still fires the despawn
            -- event. Hooks are immediate now, so the spawn's hooks have
            -- already run by the time despawn() is called; pretending the
            -- entity never existed by suppressing OnDespawn would be
            -- inconsistent with that.
            local entity = w2:spawn()

            local despawnEventEmitted = false
            w2:observe(entity, tecs.builtins.OnDespawn, function(e: tecs.builtins.OnDespawn)
                despawnEventEmitted = true
                luassert.equals(entity, e.entity, "OnDespawn event should contain correct entity ID")
            end)

            w2:despawn(entity)
            w2:update(1 / 60)

            luassert.is_true(despawnEventEmitted, "OnDespawn event should be emitted")
            luassert.is_false(w2:isAlive(entity), "Entity should not be alive after despawning")
        end)

        it("emits OnSpawn for a top-level spawn", function()
            local w2 = tecs.newWorld()
            local fired = 0
            local aliveDuring: boolean = true
            local eventId: integer = 0
            w2:observe(0, tecs.builtins.OnSpawn, function(e: tecs.builtins.OnSpawn)
                fired = fired + 1
                eventId = e.entity
                aliveDuring = w2:isAlive(e.entity)
                w2:set(e.entity, VelComponent(9, 8))
            end)

            local id = w2:spawn(PosComponent(1, 2))

            luassert.equals(1, fired, "OnSpawn fires once per spawn")
            luassert.equals(id, eventId, "OnSpawn carries the spawned id")
            luassert.is_false(aliveDuring, "entity is staged during the event")
            luassert.is_true(w2:isAlive(id), "spawn returns a committed entity")
            luassert.equals(1, (w2:get(id, PosComponent) as TestHelpers.Pos).x)
            luassert.equals(9, (w2:get(id, VelComponent) as TestHelpers.Vel).x,
                "observer mutation staged during OnSpawn survives the drain")
        end)

        it("keeps observer mutations staged during a deferred OnSpawn", function()
            local w2 = tecs.newWorld()
            w2:observe(0, tecs.builtins.OnSpawn, function(e: tecs.builtins.OnSpawn)
                w2:set(e.entity, VelComponent(7, 6))
            end)

            w2:defer()
            local id = w2:spawn(PosComponent(3, 4))
            luassert.is_false(w2:isAlive(id))
            w2:commit()

            luassert.is_true(w2:isAlive(id))
            luassert.equals(3, (w2:get(id, PosComponent) as TestHelpers.Pos).x)
            luassert.equals(7, (w2:get(id, VelComponent) as TestHelpers.Vel).x,
                "observer component must not be clobbered by spawn staging")
        end)

        it("does not emit OnDespawn for an already-dead id", function()
            local w2 = tecs.newWorld()
            local id = w2:spawn(PosComponent(1, 1))
            w2:commit()

            local fired = 0
            w2:observe(0, tecs.builtins.OnDespawn, function(_e: tecs.builtins.OnDespawn)
                fired = fired + 1
            end)

            w2:despawn(id)
            w2:commit()
            luassert.equals(1, fired)

            w2:despawn(id)
            w2:commit()
            luassert.equals(1, fired, "a dead id despawn is a no-op, not a second event")
        end)

        it("carries high-generation packed ids intact in OnSpawn/OnDespawn", function()
            local w2 = tecs.newWorld()

            -- Recycle one slot until its generation pushes the packed id
            -- past int32 range (generation lives above bit 22).
            local churn: integer
            for _ = 1, 520 do
                churn = w2:spawn()
                w2:despawn(churn)
            end

            local spawnSeen: number = 0
            local despawnSeen: number = 0
            w2:observe(0, tecs.builtins.OnSpawn, function(e: tecs.builtins.OnSpawn)
                spawnSeen = e.entity
            end)
            w2:observe(0, tecs.builtins.OnDespawn, function(e: tecs.builtins.OnDespawn)
                despawnSeen = e.entity
            end)

            local id = w2:spawn()
            luassert.is_true(id > 2147483647, "setup must drive the id past int32")
            luassert.equals(id, spawnSeen, "OnSpawn payload must not truncate the id")

            w2:despawn(id)
            w2:commit()
            luassert.equals(id, despawnSeen, "OnDespawn payload must not truncate the id")
        end)

        it("rejects mutations through stale handles", function()
            local w2 = tecs.newWorld()
            local stale = w2:spawn(PosComponent(1, 1))
            w2:commit()
            w2:despawn(stale)
            w2:commit()

            -- Recycles the slot under a new generation.
            local fresh = w2:spawn(PosComponent(5, 5))
            w2:commit()
            luassert.not_equals(stale, fresh)

            luassert.has_error(function()
                w2:set(stale, PosComponent(9, 9))
            end, "Entity ID not found: " .. stale)
            luassert.equals(5, (w2:get(fresh, PosComponent) as TestHelpers.Pos).x,
                "stale set must not mutate the slot's new entity")

            w2:remove(stale, PosComponent)
            w2:commit()
            luassert.is_not_nil(w2:get(fresh, PosComponent),
                "stale remove must be a no-op")

            w2:despawn(stale)
            w2:commit()
            luassert.is_true(w2:isAlive(fresh),
                "stale despawn must not destroy the slot's new entity")
        end)

        it("spawnAt removes the revived slot from the free stack", function()
            local w2 = tecs.newWorld()
            local a = w2:spawn(PosComponent(1, 1))
            w2:commit()
            w2:despawn(a)
            w2:commit()

            -- Revive the exact handle; its slot must leave the free stack
            -- or the next spawn aliases it.
            w2:spawnAt(a, PosComponent(9, 9))
            w2:commit()

            local b = w2:spawn(PosComponent(2, 2))
            w2:commit()

            luassert.not_equals(a % 2 ^ 22, b % 2 ^ 22,
                "spawn must not hand out the revived slot")
            luassert.is_true(w2:isAlive(a))
            luassert.is_true(w2:isAlive(b))
            luassert.equals(9, (w2:get(a, PosComponent) as TestHelpers.Pos).x)
            luassert.equals(2, (w2:get(b, PosComponent) as TestHelpers.Pos).x)
        end)

        it("batchSpawnAt removes revived slots from the free stack", function()
            local w2 = tecs.newWorld()
            local a = w2:spawn(PosComponent(1, 1))
            w2:commit()
            w2:despawn(a)
            w2:commit()

            w2:batchSpawnAt({a}, {PosComponent},
                function(arch: tecs.Archetype, startRow: integer, lastRow: integer, _n: integer)
                    local ps = arch:getMut(PosComponent)
                    for i = startRow, lastRow do
                        ps[i] = PosComponent(9, 9)
                    end
                end)
            w2:commit()

            local b = w2:spawn(PosComponent(2, 2))
            w2:commit()

            luassert.not_equals(a % 2 ^ 22, b % 2 ^ 22,
                "spawn must not hand out the revived slot")
            luassert.is_true(w2:isAlive(a))
            luassert.is_true(w2:isAlive(b))
            luassert.equals(9, (w2:get(a, PosComponent) as TestHelpers.Pos).x)
            luassert.equals(2, (w2:get(b, PosComponent) as TestHelpers.Pos).x)
        end)

        it("despawns entities and emits event", function()
            local w2 = tecs.newWorld()

            -- Create entity
            local entity = w2:spawn()

            -- Force the world to update so batched changes are applied.
            w2:update(1 / 60)

            -- Add an observer for the OnDespawn event
            local despawnEventEmitted = false
            w2:observe(entity, tecs.builtins.OnDespawn, function(e: tecs.builtins.OnDespawn)
                despawnEventEmitted = true
                luassert.equals(entity, e.entity, "OnDespawn event should contain correct entity ID")
            end)

            -- Despawn the entity
            w2:despawn(entity)

            -- Force the world to update so batched changes are applied.
            w2:update(1 / 60)

            luassert.is_true(despawnEventEmitted, "OnDespawn event should be emitted")
            luassert.is_false(w2:isAlive(entity), "Entity should not be alive after despawning")
        end)
    end)

    describe("has", function()
        -- These specs pin the single-flag `:has` path: exactly one branch
        -- on `component.isSparseInstance`, everything else resolved via
        -- archetype membership. Exercises plain components, tag components,
        -- dense relationship containers/instances, sparse relationship
        -- containers/instances, and target-specificity for sparse.

        it("returns false for an unknown entity id", function()
            luassert.is_false(w:has(999999, PosComponent))
        end)

        it("returns true/false for a plain component", function()
            local e = w:spawn(PosComponent(1, 2))
            w:commit()
            luassert.is_true(w:has(e, PosComponent))
            luassert.is_false(w:has(e, VelComponent))
        end)

        it("returns true/false for a tag component", function()
            local Tag = tecs.newTagComponent({name = "HasSpecTag"})
            local e1 = w:spawn(Tag)
            local e2 = w:spawn()
            w:commit()
            luassert.is_true(w:has(e1, Tag))
            luassert.is_false(w:has(e2, Tag))
        end)

        it("returns true for a dense relationship container and instance", function()
            local Follows = tecs.newRelationship({name = "HasSpecDenseFollows"})
            local leader = w:spawn()
            local other = w:spawn()
            local follower = w:spawn(Follows(leader) as tecs.Component)
            w:commit()

            -- Dense instance: archetype column presence check.
            luassert.is_true(w:has(follower, Follows(leader) as tecs.Component))
            -- Dense container (wildcard): attached via addComponentStaged,
            -- so the arch membership check returns true for any follower.
            luassert.is_true(w:has(follower, Follows as tecs.Component))
            -- Non-follower has neither.
            luassert.is_false(w:has(other, Follows as tecs.Component))
            luassert.is_false(w:has(other, Follows(leader) as tecs.Component))
        end)

        it("distinguishes dense-relationship instances by target", function()
            local Follows = tecs.newRelationship({name = "HasSpecDenseFollowsTarget"})
            local a = w:spawn()
            local b = w:spawn()
            local f = w:spawn(Follows(a) as tecs.Component)
            w:commit()

            luassert.is_true(w:has(f, Follows(a) as tecs.Component))
            luassert.is_false(w:has(f, Follows(b) as tecs.Component),
                "dense instance to a different target must not match")
        end)

        it("returns true/false for a sparse relationship container", function()
            local ChildOf = tecs.newRelationship({
                name = "HasSpecSparseChildOf",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })
            local parent = w:spawn()
            local kid = w:spawn(ChildOf(parent) as tecs.Component)
            local orphan = w:spawn()
            w:commit()

            -- Sparse container lives in the archetype as a wildcard, so
            -- the dense-arch path resolves it.
            luassert.is_true(w:has(kid, ChildOf as tecs.Component))
            luassert.is_false(w:has(orphan, ChildOf as tecs.Component))
        end)

        it("routes sparse-instance checks through the relationship store", function()
            local ChildOf = tecs.newRelationship({
                name = "HasSpecSparseChildOfInstance",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })
            local parent1 = w:spawn()
            local parent2 = w:spawn()
            local kid = w:spawn(ChildOf(parent1) as tecs.Component)
            w:commit()

            -- Specific-target: matches only the live target, not siblings.
            luassert.is_true(w:has(kid, ChildOf(parent1) as tecs.Component))
            luassert.is_false(w:has(kid, ChildOf(parent2) as tecs.Component),
                "sparse instance for a different target must not match")
        end)

        it("reflects removal of a dense relationship", function()
            local Follows = tecs.newRelationship({name = "HasSpecDenseFollowsRemove"})
            local leader = w:spawn()
            local f = w:spawn(Follows(leader) as tecs.Component)
            w:commit()

            luassert.is_true(w:has(f, Follows(leader) as tecs.Component))
            w:remove(f, Follows(leader) as tecs.Component)
            w:commit()
            luassert.is_false(w:has(f, Follows(leader) as tecs.Component))
        end)

        it("reflects removal of a sparse relationship", function()
            local ChildOf = tecs.newRelationship({
                name = "HasSpecSparseChildOfRemove",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })
            local parent = w:spawn()
            local kid = w:spawn(ChildOf(parent) as tecs.Component)
            w:commit()

            luassert.is_true(w:has(kid, ChildOf(parent) as tecs.Component))
            luassert.is_true(w:has(kid, ChildOf as tecs.Component))
            w:remove(kid, ChildOf(parent) as tecs.Component)
            w:commit()
            luassert.is_false(w:has(kid, ChildOf(parent) as tecs.Component))
            luassert.is_false(w:has(kid, ChildOf as tecs.Component))
        end)

        it("sets isSparseInstance only on sparse relationship instances", function()
            -- Canonical flag invariant: single source of truth for the
            -- `:has` branch. Pin it so accidental propagation (e.g. to
            -- dense instances or containers) is caught early.
            local DenseRel = tecs.newRelationship({name = "HasSpecFlagDense"})
            local SparseRel = tecs.newRelationship({
                name = "HasSpecFlagSparse",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })
            local t = w:spawn()

            luassert.is_nil((PosComponent as {string:any}).isSparseInstance,
                "plain component container must not be flagged")
            luassert.is_nil((DenseRel as {string:any}).isSparseInstance,
                "dense relationship container must not be flagged")
            luassert.is_nil(((DenseRel(t) as tecs.Component) as {string:any}).isSparseInstance,
                "dense relationship instance must not be flagged")
            luassert.is_nil((SparseRel as {string:any}).isSparseInstance,
                "sparse relationship container must not be flagged")
            luassert.is_true(((SparseRel(t) as tecs.Component) as {string:any}).isSparseInstance,
                "sparse relationship instance must be flagged")
        end)
    end)

    describe("component management", function()
        it("should get and set components", function()
            local entity = w:spawn(PosComponent(10, 20))
            w:commit()

            local pos = w:get(entity, PosComponent) as TestHelpers.Pos
            luassert.is_not_nil(pos)
            luassert.equals(10, pos.x)
            luassert.equals(20, pos.y)

            w:set(entity, PosComponent(30, 40))
            w:commit()
            pos = w:get(entity, PosComponent) as TestHelpers.Pos
            luassert.equals(30, pos.x)
            luassert.equals(40, pos.y)
        end)

        it("adds components using public API", function()
            local w2 = tecs.newWorld()

            local entity = w2:spawn(tecs.builtins.Name("TestEntity"))

            -- Force the world to update so batched changes are applied.
            w2:update(1 / 60)

            local component = w2:get(entity, tecs.builtins.Name)
            luassert.is_not_nil(component, "Component should be added to entity")
            luassert.equals("TestEntity", component, "Component should have the correct value")

            -- Get a non-existent component
            luassert.is_nil(w2:get(entity, tecs.builtins.Transform), "Non-existent component should return nil")
        end)

        it("fails when adding component to unknown entity", function()
            local w2 = tecs.newWorld()

            luassert.error_matches(function()
                w2:set(12345, tecs.builtins.Name("TestEntity"))
            end, "Entity ID not found: 12345", "Should fail when adding component to an unknown entity")
        end)

        it("should remove components", function()
            local entity = w:spawn(PosComponent(), VelComponent())
            w:commit()

            luassert.is_not_nil(w:get(entity, PosComponent))
            luassert.is_not_nil(w:get(entity, VelComponent))

            w:remove(entity, VelComponent)
            w:commit()

            luassert.is_not_nil(w:get(entity, PosComponent))
            luassert.is_nil(w:get(entity, VelComponent))
        end)

        it("removes components using public API", function()
            local w2 = tecs.newWorld()
            local entity = w2:spawn(tecs.builtins.Name("TestEntity"))

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

        it("can observe events at entity address", function()
            local w2 = tecs.newWorld()
            local entity = w2:spawn()

            -- force the world to update so batched changes are applied.
            w2:update(1 / 60)

            local eventReceived = false
            w2:observe(entity, tecs.builtins.OnDespawn, function(_e: tecs.builtins.OnDespawn)
                eventReceived = true
            end)

            w2:despawn(entity)
            w2:update(1 / 60)

            luassert.is_true(eventReceived, "Event should be received")
        end)

        it("can check for observers at entity address", function()
            local w2 = tecs.newWorld()
            local entity = w2:spawn()
            w2:update(1 / 60)

            luassert.is_false(w2:hasObservers(entity, tecs.builtins.OnDespawn), "No observers initially")

            w2:observe(entity, tecs.builtins.OnDespawn, function(_e: tecs.builtins.OnDespawn) end)

            luassert.is_true(w2:hasObservers(entity, tecs.builtins.OnDespawn), "Should have observers after registering")
        end)

        it("clears observers when entity is despawned", function()
            local w2 = tecs.newWorld()
            local entity = w2:spawn()
            w2:update(1 / 60)

            w2:observe(entity, tecs.builtins.OnDespawn, function(_e: tecs.builtins.OnDespawn) end)
            luassert.is_true(w2:hasObservers(entity, tecs.builtins.OnDespawn), "Should have observers")

            w2:despawn(entity)
            w2:update(1 / 60)

            luassert.is_false(w2:hasObservers(entity, tecs.builtins.OnDespawn), "Observers should be cleared")
        end)
    end)

    describe("query system", function()
        it("should create queries", function()
            w:spawn(PosComponent())
            w:spawn(PosComponent(), VelComponent())
            w:spawn(VelComponent())
            w:commit()

            local query = w:query({
                include = {PosComponent}
            })

            luassert.is_not_nil(query)

            local count = 0
            for _archetype, len, _entities in query:iter() do
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
            w:commit()

            local query = w:query({
                include = {PosComponent},
                exclude = {DeadComponent}
            })

            local count = 0
            for _archetype, len, _entities in query:iter() do
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
            local k: tecs.Key<string> = tecs.newKey("spec.world.res")
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

            w:removeSystem("TestSystem")

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

            -- Remove the system by name
            w2:removeSystem("TestSystem")

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

        it("releases its ffi event slice on shutdown", function()
            local w2 = tecs.newWorld() as WorldImpl
            local sliceId = w2._ffiSliceId

            w2:shutdown()

            local w3 = tecs.newWorld() as WorldImpl
            luassert.is_equal(sliceId, w3._ffiSliceId)
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
        it("returns fixed timing for interpolation", function()
            local w2: tecs.World = tecs.newWorld({timestep = 0.1})

            local timestep, accumulator, alpha = w2:getFixedTiming()
            luassert.is_near(0.1, timestep, 1e-9)
            luassert.is_near(0, accumulator, 1e-9)
            luassert.is_near(0, alpha, 1e-9)

            w2:update(0.05)
            timestep, accumulator, alpha = w2:getFixedTiming()
            luassert.is_near(0.1, timestep, 1e-9)
            luassert.is_near(0.05, accumulator, 1e-9)
            luassert.is_near(0.5, alpha, 1e-9)

            w2:update(0.2)
            timestep, accumulator, alpha = w2:getFixedTiming()
            luassert.is_near(0.1, timestep, 1e-9)
            luassert.is_near(0.05, accumulator, 1e-9)
            luassert.is_near(0.5, alpha, 1e-9)
        end)

        it("leaves under a step owing after dropping the catch-up it could not run", function()
            -- Twenty steps owed, ten allowed, and the rest abandoned by the
            -- default policy. What is left is the part of a step that had not
            -- elapsed, so the alpha an interpolator reads carries on from
            -- where it was rather than jumping.
            local w2 = tecs.newWorld({timestep = 0.1})

            w2:update(2)

            local timestep, accumulator, alpha = w2:getFixedTiming()
            luassert.is_near(0.1, timestep, 1e-9)
            luassert.is_true(accumulator < timestep,
                "nothing whole is still owing: " .. tostring(accumulator))
            luassert.is_true(alpha >= 0 and alpha <= 1)
            luassert.is_true(w2:getStats().fixedTimeDropped > 0,
                "and the seconds that went are counted rather than swallowed")
        end)

        it("clamps fixed interpolation alpha while a backlog is being worked off", function()
            -- The accumulate policy abandons nothing, so the accumulator can
            -- hold whole steps between updates and the alpha has to stay in
            -- range regardless.
            local w2 = tecs.newWorld({timestep = 0.1, fixedOverload = "accumulate"})

            w2:update(2)

            local _, accumulator, alpha = w2:getFixedTiming()
            luassert.is_true(accumulator >= 0.1, "the rest is still owed")
            luassert.is_near(1, alpha, 1e-9)
            luassert.equals(0, w2:getStats().fixedTimeDropped)
        end)

        it("advances fixed timing while fixed phases are disabled", function()
            local w2 = tecs.newWorld({timestep = 0.1})
            w2:disablePhase(phases.FixedUpdateGroup)

            w2:update(0.15)

            local _, accumulator, alpha = w2:getFixedTiming()
            luassert.is_near(0.05, accumulator, 1e-9)
            luassert.is_near(0.5, alpha, 1e-9)
        end)

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

    end)

    describe("isAlive during despawn", function()
        it("should return true during OnDespawn event and false after commit", function()
            local entityIdInEvent: integer = nil
            local wasAliveInEvent: boolean = nil

            local entity = w:spawn()
            w:update(0)

            w:observe(entity, tecs.builtins.OnDespawn, function(event: tecs.builtins.OnDespawn)
                entityIdInEvent = event.entity
                wasAliveInEvent = w:isAlive(event.entity)
            end)

            luassert.is_true(w:isAlive(entity), "Entity should be alive before despawn")
            w:despawn(entity)
            w:update(0)

            luassert.equals(entity, entityIdInEvent, "OnDespawn should have been emitted")
            luassert.is_true(wasAliveInEvent, "Entity still in entityIndex during OnDespawn")
            luassert.is_false(w:isAlive(entity), "Entity should not be alive after commit")
        end)

        it("should cascade delete children when parent with cascadeDelete relationship is despawned", function()
            local ChildOf = tecs.newRelationship({
                name = "ChildOfAliveTest",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
                cascadeDelete = true,
            })

            local parent = w:spawn()
            local child = w:spawn(ChildOf(parent) as tecs.Component)
            w:update(0)

            luassert.is_true(w:isAlive(parent), "Parent should be alive before despawn")
            luassert.is_true(w:isAlive(child), "Child should be alive before despawn")

            w:despawn(parent)
            w:update(0)

            luassert.is_false(w:isAlive(parent), "Parent should not be alive after despawn")
            luassert.is_false(w:isAlive(child), "Child should be cascade deleted")
        end)

        it("should allow component access during OnDespawn", function()
            local record TestComponentType is tecs.Component
                value: number
            end

            local TestComponent = tecs.newComponent({
                name = "TestComponentAlive",
                container = TestComponentType,
                fields = {"value"},
                init = function(instance: TestComponentType, value: number)
                    instance.value = value or 42
                end
            })

            local componentValue: number = nil
            local wasAlive: boolean = nil

            local entity = w:spawn(TestComponent(100))
            w:update(0)

            w:observe(entity, tecs.builtins.OnDespawn, function(event: tecs.builtins.OnDespawn)
                wasAlive = w:isAlive(event.entity)
                local comp = w:get(event.entity, TestComponent)
                if comp then
                    componentValue = (comp as TestComponentType).value
                end
            end)

            w:despawn(entity)
            w:update(0)

            luassert.is_true(wasAlive, "Entity still in entityIndex during OnDespawn")
            luassert.equals(100, componentValue, "Should access components during OnDespawn")
        end)
    end)

    describe("batchSpawn", function()
        it("should spawn entities with correct data", function()
            local count = 100
            local firstIdMaybe, ids = w:batchSpawn(count, {PosComponent, VelComponent},
                function(arch: tecs.Archetype, startRow: integer, lastRow: integer, n: integer)
                    local positions = arch:getMut(PosComponent)
                    local velocities = arch:getMut(VelComponent)
                    for i = startRow, lastRow do
                        positions[i] = PosComponent(i * 10, i * 20)
                        velocities[i] = VelComponent(1, 2)
                    end
                end)
            local firstId = expectContiguous(firstIdMaybe, ids)
            w:commit()

            luassert.equals(count, firstId + count - 1 - firstId + 1)
            for i = firstId, firstId + count - 1 do
                luassert.is_true(w:isAlive(i))
                local p = w:get(i, PosComponent) as TestHelpers.Pos
                luassert.is_not_nil(p)
            end

            -- Check first and last entity data
            local p1 = w:get(firstId, PosComponent) as TestHelpers.Pos
            luassert.equals(10, p1.x)
            luassert.equals(20, p1.y)
        end)

        it("should return contiguous entity IDs", function()
            local firstIdMaybe, ids = w:batchSpawn(5, {PosComponent},
                function(arch: tecs.Archetype, startRow: integer, lastRow: integer, n: integer)
                    local positions = arch:getMut(PosComponent)
                    for i = startRow, lastRow do
                        positions[i] = PosComponent(i, i)
                    end
                end)
            local firstId = expectContiguous(firstIdMaybe, ids)
            w:commit()

            for i = 0, 4 do
                luassert.is_true(w:isAlive(firstId + i))
            end
        end)

        it("falls back to explicit IDs when a contiguous range is unavailable", function()
            local small = WorldImpl.new({maxEntities = 6}) as WorldImpl
            local spawned: {integer} = {}
            for i = 1, 5 do
                spawned[i] = small:spawn()
            end
            small:commit()

            small:despawn(spawned[2])
            small:despawn(spawned[4])
            small:commit()

            local firstId, ids = small:batchSpawn(2, {PosComponent},
                function(arch: tecs.Archetype, startRow: integer, lastRow: integer, n: integer)
                    local positions = arch:getMut(PosComponent)
                    for row = startRow, lastRow do
                        positions[row] = PosComponent(row, row)
                    end
                end)
            luassert.is_nil(firstId)
            luassert.is_not_nil(ids)
            local list = ids as {integer}
            luassert.equals(2, #list)

            small:commit()
            for i = 1, #list do
                luassert.is_true(small:isAlive(list[i]))
                luassert.is_not_nil(small:get(list[i], PosComponent))
            end
        end)

        it("should be queryable after commit", function()
            w:batchSpawn(50, {PosComponent},
                function(arch: tecs.Archetype, startRow: integer, lastRow: integer, n: integer)
                    local positions = arch:getMut(PosComponent)
                    for i = startRow, lastRow do
                        positions[i] = PosComponent(i, i)
                    end
                end)
            w:commit()

            local q = w:query({include = {PosComponent}})
            local totalEntities = 0
            for _, len in q:iter() do
                totalEntities = totalEntities + len
            end
            luassert.equals(50, totalEntities)
        end)

        it("should notify query observers", function()
            local matchCount = 0
            w:query({
                include = {PosComponent},
                onEntitiesAdded = function(_archetype: tecs.Archetype, _firstRow: integer, _lastRow: integer, count: integer)
                    matchCount = matchCount + count
                end,
            })

            w:batchSpawn(20, {PosComponent},
                function(arch: tecs.Archetype, startRow: integer, lastRow: integer, n: integer)
                    local positions = arch:getMut(PosComponent)
                    for i = startRow, lastRow do
                        positions[i] = PosComponent(i, i)
                    end
                end)
            w:commit()

            luassert.equals(20, matchCount, "onEntitiesAdded should cover all batch-spawned entities")
        end)


        it("supports sparse relationship components in the signature", function()
            local SparseRel = tecs.newRelationship({
                name = "BatchSparse" .. testId,
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })
            local parent = w:spawn(PosComponent(0, 0))
            w:commit()

            local firstIdMaybe, ids = w:batchSpawn(5, {PosComponent, SparseRel as tecs.Component},
                function(arch: tecs.Archetype, startRow: integer, lastRow: integer, n: integer)
                    local positions = arch:getMut(PosComponent)
                    for i = startRow, lastRow do
                        positions[i] = PosComponent(i, i)
                    end
                end)
            local firstId = expectContiguous(firstIdMaybe, ids)
            -- Attach per-entity sparse targets before commit. The staged
            -- sparse sets drain after the batchSpawn placement but before
            -- the ledger walker, so targets land in the RelationshipStore
            -- alongside the fresh entities.
            for i = 0, 4 do
                w:set(firstId + i, (SparseRel as function(integer): tecs.Component)(parent))
            end
            w:commit()

            -- All five entities should appear as children of the parent.
            local seen: {integer: boolean} = {}
            w:targets(parent, SparseRel, function(childId: integer)
                seen[childId] = true
            end)
            for i = 0, 4 do
                luassert.is_true(seen[firstId + i],
                    "expected sparse target for batch-spawned id " .. (firstId + i))
            end
        end)

        it("should work with multiple batch spawns into same archetype", function()
            w:batchSpawn(10, {PosComponent},
                function(arch: tecs.Archetype, startRow: integer, lastRow: integer, n: integer)
                    local positions = arch:getMut(PosComponent)
                    for i = startRow, lastRow do
                        positions[i] = PosComponent(i, i)
                    end
                end)

            w:batchSpawn(10, {PosComponent},
                function(arch: tecs.Archetype, startRow: integer, lastRow: integer, n: integer)
                    local positions = arch:getMut(PosComponent)
                    for i = startRow, lastRow do
                        positions[i] = PosComponent(i + 100, i + 100)
                    end
                end)
            w:commit()

            local q = w:query({include = {PosComponent}})
            local totalEntities = 0
            for _, len in q:iter() do
                totalEntities = totalEntities + len
            end
            luassert.equals(20, totalEntities)
        end)

        it("allows mid-frame world:set on a batch-spawned id", function()
            local Tag = tecs.newTagComponent({name = "BatchMidSet" .. testId})
            local firstIdMaybe, ids = w:batchSpawn(3, {PosComponent},
                function(arch: tecs.Archetype, startRow: integer, lastRow: integer, n: integer)
                    local positions = arch:getMut(PosComponent)
                    for i = startRow, lastRow do
                        positions[i] = PosComponent(i, i)
                    end
                end)
            local firstId = expectContiguous(firstIdMaybe, ids)
            -- Mutate before commit. This transitions the entities into a
            -- new archetype via the ledger path (entityPendingArch is the
            -- starting point).
            w:set(firstId, Tag)
            w:commit()

            luassert.is_not_nil(w:get(firstId, Tag), "set before commit should land on the entity")
            luassert.is_nil(w:get(firstId + 1, Tag), "unrelated ids should not be affected")
            luassert.is_not_nil(w:get(firstId, PosComponent), "original batch component should survive")
        end)

        it("allows mid-frame world:despawn on a batch-spawned id", function()
            local firstIdMaybe, ids = w:batchSpawn(3, {PosComponent},
                function(arch: tecs.Archetype, startRow: integer, lastRow: integer, n: integer)
                    local positions = arch:getMut(PosComponent)
                    for i = startRow, lastRow do
                        positions[i] = PosComponent(i, i)
                    end
                end)
            local firstId = expectContiguous(firstIdMaybe, ids)
            w:despawn(firstId + 1)  -- despawn middle id before commit
            w:commit()

            luassert.is_true(w:isAlive(firstId))
            luassert.is_false(w:isAlive(firstId + 1))
            luassert.is_true(w:isAlive(firstId + 2))
        end)
    end)

    describe("batchDespawn", function()
        it("despawns all entities matching a query", function()
            for _ = 1, 5 do w:spawn(PosComponent(0, 0), VelComponent(0, 0)) end
            for _ = 1, 3 do w:spawn(PosComponent(0, 0)) end  -- only Pos
            w:commit()

            local q = w:query({include = {PosComponent, VelComponent}})
            w:batchDespawn(q)
            w:commit()

            -- Pos-only survivors should still be alive
            local remaining = 0
            for _, len in w:query({include = {PosComponent}}):iter() do
                remaining = remaining + len
            end
            luassert.equals(3, remaining)
        end)

        it("respects query include/exclude", function()
            local Tag = tecs.newTagComponent({name = "BatchDespawnTag" .. testId})
            for _ = 1, 4 do w:spawn(PosComponent(0, 0), Tag) end
            for _ = 1, 6 do w:spawn(PosComponent(0, 0)) end  -- no tag
            w:commit()

            local q = w:query({include = {PosComponent}, exclude = {Tag}})
            w:batchDespawn(q)
            w:commit()

            local remaining = 0
            for _, len in w:query({include = {PosComponent}}):iter() do
                remaining = remaining + len
            end
            luassert.equals(4, remaining, "tagged entities survive")
        end)

        it("marks despawned entities as not alive after commit", function()
            local ids: {integer} = {}
            for i = 1, 5 do ids[i] = w:spawn(PosComponent(i, i)) end

            local q = w:query({include = {PosComponent}})
            -- Wrap in a defer scope to observe the deferred contract:
            -- staged until commit. In eager (default) mode the
            -- batchDespawn would apply synchronously.
            w:defer()
            w:batchDespawn(q)
            for i = 1, 5 do
                luassert.is_true(w:isAlive(ids[i]))
            end
            w:commit()

            for i = 1, 5 do
                luassert.is_false(w:isAlive(ids[i]))
            end
        end)

        it("applies batchDespawn immediately in eager mode", function()
            local ids: {integer} = {}
            for i = 1, 5 do ids[i] = w:spawn(PosComponent(i, i)) end

            local q = w:query({include = {PosComponent}})
            w:batchDespawn(q)
            for i = 1, 5 do
                luassert.is_false(w:isAlive(ids[i]))
            end
        end)

        it("emits global OnDespawn for every entity on the fast path", function()
            local observed: {integer} = {}
            w:observe(0, tecs.builtins.OnDespawn, function(ev)
                observed[#observed + 1] = ev.entity
            end)

            local ids: {integer} = {}
            for i = 1, 5 do ids[i] = w:spawn(PosComponent(i, i)) end
            w:commit()

            local q = w:query({include = {PosComponent}})
            w:batchDespawn(q)
            w:commit()

            luassert.equals(5, #observed)
            -- Every spawned id should show up in the observed list.
            local seen: {integer: boolean} = {}
            for _, id in ipairs(observed) do seen[id] = true end
            for _, id in ipairs(ids) do
                luassert.is_true(seen[id], "expected global OnDespawn for id " .. id)
            end
        end)

        it("emits per-entity OnDespawn and clears the entity's observers", function()
            local id = w:spawn(PosComponent(1, 2))
            w:commit()

            local perEntityFires = 0
            w:observe(id, tecs.builtins.OnDespawn, function(_ev)
                perEntityFires = perEntityFires + 1
            end)

            local q = w:query({include = {PosComponent}})
            w:batchDespawn(q)
            w:commit()

            luassert.equals(1, perEntityFires, "per-entity OnDespawn should fire once")
            luassert.is_false(w:hasObservers(id, tecs.builtins.OnDespawn),
                "per-entity observers should be cleared after despawn")
        end)

        it("cascades sparse relationships via the slow path", function()
            local SparseRel = tecs.newRelationship({
                name = "BatchDespawnRel" .. testId,
                exclusive = true,
                sparse = true,
                reverseIndex = true,
                cascadeDelete = true,
            })

            local parent2 = w:spawn(PosComponent(0, 0))
            local kid1 = w:spawn(PosComponent(1, 1), SparseRel(parent2))
            local kid2 = w:spawn(PosComponent(2, 2), SparseRel(parent2))
            w:commit()

            -- Despawn parent explicitly through despawn; children cascade.
            w:despawn(parent2)
            w:commit()
            luassert.is_false(w:isAlive(parent2))
            luassert.is_false(w:isAlive(kid1), "child should cascade-delete with parent")
            luassert.is_false(w:isAlive(kid2))
        end)

        it("indexes builtin Key and rejects duplicate live keys", function()
            local a = w:spawn(tecs.builtins.Key("player"), PosComponent(1, 2))
            w:commit()

            luassert.equals(a, w:byKey("player"))
            luassert.equals(a, w:requireKey("player"))

            local ok = pcall(function()
                w:spawn(tecs.builtins.Key("player"), PosComponent(3, 4))
            end)
            luassert.is_false(ok)
        end)

        it("reaps builtin Key when an entity despawns", function()
            local a = w:spawn(tecs.builtins.Key("player"), PosComponent(1, 2))
            w:commit()

            w:despawn(a)
            w:commit()

            luassert.is_nil(w:byKey("player"))
            local b = w:spawn(tecs.builtins.Key("player"), PosComponent(3, 4))
            w:commit()
            luassert.equals(b, w:byKey("player"))
        end)

        it("updates builtin Key when set or removed", function()
            local a = w:spawn(PosComponent(1, 2))
            w:commit()

            w:set(a, tecs.builtins.Key("first"))
            w:commit()
            luassert.equals(a, w:byKey("first"))

            w:set(a, tecs.builtins.Key("second"))
            w:commit()
            luassert.is_nil(w:byKey("first"))
            luassert.equals(a, w:byKey("second"))

            w:remove(a, tecs.builtins.Key)
            w:commit()
            luassert.is_nil(w:byKey("second"))
        end)

        it("keeps the Key index correct through batch set and remove", function()
            local a = w:spawn(PosComponent(1, 2))
            w:commit()

            local q = w:query({include = {PosComponent}})
            w:batchSet(q, tecs.builtins.Key("player"))
            w:commit()
            luassert.equals(a, w:byKey("player"))

            w:batchRemove(q, tecs.builtins.Key)
            w:commit()
            luassert.is_nil(w:byKey("player"))

            local b = w:spawn(tecs.builtins.Key("player"), PosComponent(3, 4))
            w:commit()
            luassert.equals(b, w:byKey("player"))
        end)

        it("rejects duplicate keys through batch set", function()
            w:spawn(PosComponent(1, 2))
            w:spawn(PosComponent(3, 4))
            w:commit()

            local q = w:query({include = {PosComponent}})
            local ok = pcall(function()
                w:batchSet(q, tecs.builtins.Key("player"))
            end)
            luassert.is_false(ok)
        end)

        it("rejects batch spawning entities with builtin Key", function()
            local ok = pcall(function()
                w:batchSpawn(2, {tecs.builtins.Key}, function(_arch, _first, _last, _count) end)
            end)
            luassert.is_false(ok)
        end)

        it("rebuilds the Key index after raw batch spawn", function()
            local ids = ffi.new("uint32_t[1]", 1001)
            local wImpl = w as WorldImpl
            wImpl:batchSpawnAtRaw(ids, 1, {tecs.builtins.Key, PosComponent}, function(arch, rowStart, _rowEnd, _count)
                (arch.columns[tecs.builtins.Key] as {string})[rowStart] = "player"
                (arch.columns[PosComponent] as {PosComponent})[rowStart] = PosComponent(1, 2)
            end)
            luassert.equals(1001, w:byKey("player"))
        end)
    end)

    describe("save/load primitives", function()
        it("spawnAt uses the provided handle", function()
            -- Encoding matches IdAllocator.encodeId: slot + generation * 2^22.
            local encoded = (1 * 2^22) + 42  -- (gen=1, slot=42)
            w:spawnAt(encoded, PosComponent(1, 2))
            w:commit()
            luassert.is_true(w:isAlive(encoded))
            luassert.is_not_nil(w:get(encoded, PosComponent))
            -- Next normal spawn should still use the next auto-slot
            local next = w:spawn(PosComponent(3, 4))
            luassert.is_not_equal(encoded, next)
        end)

        it("forEachArchetype visits all archetypes", function()
            w:spawn(PosComponent(1, 1))
            w:spawn(PosComponent(2, 2), VelComponent(1, 1))
            w:commit()

            local count = 0
            w:forEachArchetype(function(_arch: tecs.Archetype)
                count = count + 1
            end)
            -- At least the 2 populated archetypes + the empty sentinel
            luassert.is_true(count >= 2, "should visit at least 2 archetypes, got " .. count)
        end)
    end)

    describe("clearEntities", function()
        local function queryCount(q: tecs.Query): integer
            local total = 0
            for _, len in q:iter() do total = total + len end
            return total
        end

        it("keeps queries matching archetypes created after the clear", function()
            local q = w:query({include = {PosComponent}})
            w:spawn(PosComponent(1, 1))
            w:spawn(PosComponent(2, 2))
            luassert.equals(2, queryCount(q))

            w:clearEntities()
            luassert.equals(0, queryCount(q))

            -- A (Pos, Vel) archetype that did not exist before the clear. The
            -- query's global ArchetypeCreated subscription must survive
            -- clearEntities, or new archetypes are silently missed until the
            -- query is rebuilt.
            w:spawn(PosComponent(3, 3), VelComponent() as tecs.Component)
            w:spawn(PosComponent(4, 4), VelComponent() as tecs.Component)
            luassert.equals(2, queryCount(q),
                "query must match a new archetype after clearEntities")

            -- The pre-existing Pos-only archetype keeps working too.
            w:spawn(PosComponent(5, 5))
            luassert.equals(3, queryCount(q))
        end)
    end)
end)
