require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")
local spy <const> = require("luassert.spy")

local TestHelpers <const> = require("spec.tecs.test_helpers")

-------------------------------------------------------------------------------
-- Start of tests
-------------------------------------------------------------------------------

describe("Queries module tests", function()
    local world: tecs.World
    local Position: TestHelpers.Pos
    local Velocity: TestHelpers.Vel
    local Health: TestHelpers.Health
    local Sprite: TestHelpers.Sprite
    local Transform: TestHelpers.Transform
    local testId = 0

    before_each(function()
        world = tecs.newWorld()
        testId = testId + 1

        -- Create fresh components for each test to avoid conflicts
        local provider = TestHelpers.createComponentProvider("queries_", testId)
        Position = provider.PosComponent
        Velocity = provider.VelComponent
        Health = provider.HealthComponent
        Sprite = provider.SpriteComponent
        Transform = provider.TransformComponent

        -- Verify components are set up correctly
        assert(Position.componentType == Position, "Position componentType should point to itself")
        assert(Position.componentName, "Position should have a name")
        local posInstance = Position(5, 10)
        assert(posInstance, "Position constructor should create an instance")
        assert(posInstance.componentType == Position, "Instance should have componentType via metatable")
    end)

    describe("Query creation and iteration", function()
        it("creates queries that match entities with specified components", function()
            -- Spawn entities with various components
            local e1 = world:spawn(Position(1, 1), Velocity(10, 10))
            local e2 = world:spawn(Position(2, 2), Velocity(20, 20))
            local e3 = world:spawn(Position(3, 3)) -- No velocity

            -- Need to update world to commit changes
            world:update(0)

            -- Verify entities were actually created
            luassert.is_not_nil(world:get(e1, Position), "Entity 1 should have Position")
            luassert.is_not_nil(world:get(e1, Velocity), "Entity 1 should have Velocity")
            luassert.is_not_nil(world:get(e2, Position), "Entity 2 should have Position")
            luassert.is_not_nil(world:get(e2, Velocity), "Entity 2 should have Velocity")
            luassert.is_not_nil(world:get(e3, Position), "Entity 3 should have Position")
            luassert.is_nil(world:get(e3, Velocity), "Entity 3 should not have Velocity")

            local query = world:query({
                include = {Position, Velocity}
            })

            luassert.is_not_nil(query, "Query should be created successfully")

            -- Count matching entities using each
            local count = 0
            for archetype, len in query() do
                local poss = archetype[Position]
                local vels = archetype[Velocity]
                for row = 1, len do
                    local pos = poss[row]
                    local vel = vels[row]
                    count = count + 1
                    luassert.is_not_nil(pos, "Position component should exist")
                    luassert.is_not_nil(vel, "Velocity component should exist")
                end
            end
            luassert.is_equal(2, count, "Query should match 2 entities with both Position and Velocity")
        end)

        it("allows direct archetype component access using table indexing", function()
            -- Spawn entities with various components
            world:spawn(Position(5, 7), Velocity(15, 25))
            world:spawn(Position(10, 20), Velocity(30, 40))
            world:update(0)

            local query = world:query({
                include = {Position, Velocity}
            })

            -- Test direct archetype access
            local count = 0
            local totalX: number = 0
            local totalVx: number = 0
            for archetype, len in query() do
                -- Access component columns directly from archetype
                local positions = archetype[Position]
                local velocities = archetype[Velocity]

                luassert.is_not_nil(positions, "Should be able to access Position column via archetype[Position]")
                luassert.is_not_nil(velocities, "Should be able to access Velocity column via archetype[Velocity]")

                for row = 1, len do
                    local pos = positions[row]
                    local vel = velocities[row]
                    count = count + 1
                    totalX = totalX + pos.x
                    totalVx = totalVx + vel.x
                    luassert.is_not_nil(pos, "Position component should exist")
                    luassert.is_not_nil(vel, "Velocity component should exist")
                end
            end

            luassert.is_equal(2, count, "Should process 2 entities")
            luassert.is_equal(15, totalX, "Sum of x positions should be 15")
            luassert.is_equal(45, totalVx, "Sum of x velocities should be 45")
        end)

        it("handles empty results", function()
            -- Create a query with no matching entities
            local query = world:query({
                include = {Position, Velocity, Health, Sprite, Transform}
            })

            luassert.is_not_nil(query, "Query should be created even with no matches")

            local count = 0
            for _, len in query() do
                for _ = 1, len do
                    count = count + 1
                end
            end
            luassert.is_equal(0, count, "Query should have zero matches")
        end)

        it("handles queries with only include", function()
            world:spawn(Position(1, 1))
            world:spawn(Position(2, 2))
            world:update(0)

            local query = world:query({
                include = {Position}
            })

            luassert.is_not_nil(query, "Query should be created")

            local count = 0
            for archetype, len in query() do
                local poss = archetype[Position]
                for row = 1, len do
                    local pos = poss[row]
                    count = count + 1
                    luassert.is_not_nil(pos, "Position should exist")
                end
            end
            luassert.is_equal(2, count, "Query should match 2 entities")
        end)

        it("registers onMatch callbacks for existing entities", function()
            local matchedEntities = {}
            local onMatchSpy = spy.new(function(id: integer)
                table.insert(matchedEntities, id)
            end)

            -- Spawn entities first
            world:spawn(Position(1, 1))
            world:spawn(Position(2, 2))
            world:spawn(Position(3, 3))
            world:update(0)

            -- Create query with onMatch callback
            world:query({
                include = {Position},
                onMatch = onMatchSpy,
                save = true
            })

            luassert.spy(onMatchSpy).was_called(3)
            luassert.equals(3, #matchedEntities, "Should have matched 3 entities")
        end)

        it("works without callbacks", function()
            world:spawn(Position(1, 1))
            world:spawn(Position(2, 2))
            world:update(0)

            -- This should not error even without callbacks
            local query = world:query({
                include = {Position}
            })

            local count = 0
            for _, len in query() do
                for _ = 1, len do
                    count = count + 1
                end
            end
            luassert.is_equal(2, count, "Query should work without callbacks")
        end)
    end)

    describe("Query filtering", function()
        it("filters with include correctly", function()
            world:spawn(Position(1, 1), Velocity(10, 10))
            world:spawn(Position(2, 2))
            world:spawn(Velocity(30, 30))
            world:update(0)

            local query = world:query({
                include = {Position, Velocity}
            })

            local count = 0
            for archetype, len in query() do
                local poss = archetype[Position]
                local vels = archetype[Velocity]
                for row = 1, len do
                    local pos = poss[row]
                    local vel = vels[row]
                    count = count + 1
                    luassert.is_not_nil(pos, "Position should exist")
                    luassert.is_not_nil(vel, "Velocity should exist")
                end
            end
            luassert.is_equal(1, count, "Should only match 1 entity with both components")
        end)

        it("filters with exclude correctly", function()
            world:spawn(Position(1, 1), Health(100))
            world:spawn(Position(2, 2))
            world:spawn(Position(3, 3), Health(50))
            world:update(0)

            local query = world:query({
                include = {Position},
                exclude = {Health}
            })

            local count = 0
            for archetype, len in query() do
                local poss = archetype[Position]
                for row = 1, len do
                    local pos = poss[row]
                    count = count + 1
                    luassert.is_not_nil(pos, "Position should exist")
                end
            end
            luassert.is_equal(1, count, "Should only match 1 entity without Health")
        end)
    end)

    describe("Dynamic query updates", function()
        it("updates when new matching entities are added", function()
            local query = world:query({
                include = {Position}
            })

            -- Initially no entities
            local count = 0
            for _, len in query() do
                for _ = 1, len do
                    count = count + 1
                end
            end
            luassert.is_equal(0, count, "Query should have no matches initially")

            -- Add entities
            world:spawn(Position(1, 1))
            world:spawn(Position(2, 2))
            world:update(0)

            -- Query should automatically include new entities
            count = 0
            for _, len in query() do
                for _ = 1, len do
                    count = count + 1
                end
            end
            luassert.is_equal(2, count, "Query should update with new entities")
        end)

        it("calls onMatch when entity starts matching", function()
            local onMatchSpy = spy.new(function() end)

            world:query({
                include = {Position, Health},
                onMatch = onMatchSpy,
                save = true
            })

            -- Create entity with only Position
            local e = world:spawn(Position(1, 1))
            world:update(0)

            -- Get initial call count (spy might have been called already)
            local initialCalls = 0

            -- Add Health to make it match
            world:set(e, Health(100))
            world:update(0)

            luassert.spy(onMatchSpy).was_called(initialCalls + 1)
        end)

        it("calls onRemove when entity stops matching", function()
            local onRemoveSpy = spy.new(function() end)

            -- Create entity that matches
            local e = world:spawn(Position(1, 1))
            world:update(0)

            world:query({
                include = {Position},
                onRemove = onRemoveSpy,
                save = true
            })

            -- Remove Position to stop matching
            world:remove(e, Position)
            world:update(0)

            luassert.spy(onRemoveSpy).was_called(1)
        end)

        it("calls onRemove when entity is despawned", function()
            local onRemoveSpy = spy.new(function() end)

            local e = world:spawn(Position(1, 1))
            world:update(0)

            world:query({
                include = {Position},
                onRemove = onRemoveSpy,
                save = true
            })

            world:despawn(e)
            world:update(0)

            luassert.spy(onRemoveSpy).was_called(1)
        end)
    end)

    describe("each iterator with 1 component", function()
        it("iterates over entities returning id and component pairs", function()
            -- Create entities with Position
            world:spawn(Position(1, 1))
            world:spawn(Position(2, 2))
            world:spawn(Position(3, 3))
            -- Entity without Position
            world:spawn(Velocity(10, 10))
            world:update(0)

            local query = world:query({
                include = {Position}
            })

            local entities = {}
            local positions = {} as {TestHelpers.Pos}
            for archetype, len, entityList in query() do
                local poss = archetype[Position]
                for row = 1, len do
                    local id = entityList[row]
                    local pos = poss[row]
                    table.insert(entities, id)
                    table.insert(positions, pos as TestHelpers.Pos)
                end
            end

            luassert.equals(3, #entities, "Should iterate over all 3 entities with Position")
            -- Sort positions by x value to ensure consistent order
            table.sort(positions, function(a: TestHelpers.Pos, b: TestHelpers.Pos): boolean return a.x < b.x end)
            luassert.equals(1, positions[1].x)
            luassert.equals(2, positions[2].x)
            luassert.equals(3, positions[3].x)
        end)
    end)

    describe("each iterator with 2 components", function()
        it("iterates over entities returning id and two component pairs", function()
            world:spawn(Position(1, 1), Velocity(10, 10))
            world:spawn(Position(2, 2), Velocity(20, 20))
            world:spawn(Position(3, 3)) -- No velocity
            world:spawn(Velocity(30, 30)) -- No position
            world:update(0)

            local query = world:query({
                include = {Position, Velocity}
            })

            local entities = {}
            local positions = {} as {TestHelpers.Pos}
            local velocities = {} as {TestHelpers.Vel}
            for archetype, len, entityList in query() do
                local poss = archetype[Position]
                local vels = archetype[Velocity]
                for row = 1, len do
                    local id = entityList[row]
                    local pos = poss[row]
                    local vel = vels[row]
                    table.insert(entities, id)
                    table.insert(positions, pos as TestHelpers.Pos)
                    table.insert(velocities, vel as TestHelpers.Vel)
                end
            end

            luassert.equals(2, #entities, "Should iterate over entities with both components")
            -- Sort by x value to ensure consistent order
            local record SortedItem
                pos: TestHelpers.Pos
                vel: TestHelpers.Vel
            end
            local sorted: {SortedItem} = {}
            for i = 1, #positions do
                sorted[i] = {pos = positions[i], vel = velocities[i]}
            end
            table.sort(sorted, function(a: SortedItem, b: SortedItem): boolean return a.pos.x < b.pos.x end)
            for i = 1, #sorted do
                positions[i] = sorted[i].pos
                velocities[i] = sorted[i].vel
            end
            luassert.equals(1, positions[1].x)
            luassert.equals(10, velocities[1].x)
            luassert.equals(2, positions[2].x)
            luassert.equals(20, velocities[2].x)
        end)
    end)

    describe("each iterator with 3 components", function()
        it("iterates over entities returning id and three component tuples", function()
            world:spawn(Position(1, 1), Velocity(10, 10), Health(100))
            world:spawn(Position(2, 2), Velocity(20, 20), Health(80))
            world:spawn(Position(3, 3), Velocity(30, 30)) -- No health
            world:update(0)

            local query = world:query({
                include = {Position, Velocity, Health}
            })

            local entities = {}
            local positions = {} as {TestHelpers.Pos}
            local velocities = {} as {TestHelpers.Vel}
            local healths = {} as {TestHelpers.Health}
            for archetype, len, entityList in query() do
                local poss = archetype[Position]
                local vels = archetype[Velocity]
                local hths = archetype[Health]
                for row = 1, len do
                    local id = entityList[row]
                    local pos = poss[row]
                    local vel = vels[row]
                    local health = hths[row]
                    table.insert(entities, id)
                    table.insert(positions, pos as TestHelpers.Pos)
                    table.insert(velocities, vel as TestHelpers.Vel)
                    table.insert(healths, health as TestHelpers.Health)
                end
            end

            luassert.equals(2, #entities)
            -- Sort by x value to ensure consistent order
            local record SortedItem3
                pos: TestHelpers.Pos
                vel: TestHelpers.Vel
                health: TestHelpers.Health
            end
            local sorted: {SortedItem3} = {}
            for i = 1, #positions do
                sorted[i] = {pos = positions[i], vel = velocities[i], health = healths[i]}
            end
            table.sort(sorted, function(a: SortedItem3, b: SortedItem3): boolean return a.pos.x < b.pos.x end)
            for i = 1, #sorted do
                positions[i] = sorted[i].pos
                velocities[i] = sorted[i].vel
                healths[i] = sorted[i].health
            end
            luassert.equals(1, positions[1].x)
            luassert.equals(10, velocities[1].x)
            luassert.equals(100, healths[1].value)
            luassert.equals(2, positions[2].x)
            luassert.equals(20, velocities[2].x)
            luassert.equals(80, healths[2].value)
        end)
    end)

    describe("each iterator with 4 components", function()
        it("iterates over entities returning id and four component tuples", function()
            world:spawn(Position(1, 1), Velocity(10, 10), Health(100), Sprite("player.png", 32, 32))
            world:spawn(Position(2, 2), Velocity(20, 20), Health(80)) -- No sprite
            world:update(0)

            local query = world:query({
                include = {Position, Velocity, Health, Sprite}
            })

            local entities = {}
            local positions = {} as {TestHelpers.Pos}
            local velocities = {} as {TestHelpers.Vel}
            local healths = {} as {TestHelpers.Health}
            local sprites = {} as {TestHelpers.Sprite}
            for archetype, len, entityList in query() do
                local poss = archetype[Position]
                local vels = archetype[Velocity]
                local hths = archetype[Health]
                local sprs = archetype[Sprite]
                for row = 1, len do
                    local id = entityList[row]
                    local pos = poss[row]
                    local vel = vels[row]
                    local health = hths[row]
                    local sprite = sprs[row]
                    table.insert(entities, id)
                    table.insert(positions, pos as TestHelpers.Pos)
                    table.insert(velocities, vel as TestHelpers.Vel)
                    table.insert(healths, health as TestHelpers.Health)
                    table.insert(sprites, sprite as TestHelpers.Sprite)
                end
            end

            luassert.equals(1, #entities)
            luassert.equals(1, positions[1].x)
            luassert.equals(10, velocities[1].x)
            luassert.equals(100, healths[1].value)
            luassert.equals("player.png", sprites[1].texture)
        end)
    end)

    describe("each iterator with 5 components", function()
        it("iterates over entities returning id and five component tuples", function()
            world:spawn(
                Position(1, 1),
                Velocity(10, 10),
                Health(100),
                Sprite("player.png", 32, 32),
                Transform(1.5, 45)
            )
            world:spawn(Position(2, 2), Velocity(20, 20), Health(80), Sprite("enemy.png", 16, 16)) -- No transform
            world:update(0)

            local query = world:query({
                include = {Position, Velocity, Health, Sprite, Transform}
            })

            local entities = {}
            local positions = {} as {TestHelpers.Pos}
            local velocities = {} as {TestHelpers.Vel}
            local healths = {} as {TestHelpers.Health}
            local sprites = {} as {TestHelpers.Sprite}
            local transforms = {} as {TestHelpers.Transform}
            for archetype, len, entityList in query() do
                local poss = archetype[Position]
                local vels = archetype[Velocity]
                local hths = archetype[Health]
                local sprs = archetype[Sprite]
                local trns = archetype[Transform]
                for row = 1, len do
                    local id = entityList[row]
                    local pos = poss[row]
                    local vel = vels[row]
                    local health = hths[row]
                    local sprite = sprs[row]
                    local transform = trns[row]
                    table.insert(entities, id)
                    table.insert(positions, pos as TestHelpers.Pos)
                    table.insert(velocities, vel as TestHelpers.Vel)
                    table.insert(healths, health as TestHelpers.Health)
                    table.insert(sprites, sprite as TestHelpers.Sprite)
                    table.insert(transforms, transform as TestHelpers.Transform)
                end
            end

            luassert.equals(1, #entities)
            luassert.equals(1, positions[1].x)
            luassert.equals(10, velocities[1].x)
            luassert.equals(100, healths[1].value)
            luassert.equals("player.png", sprites[1].texture)
            luassert.equals(1.5, transforms[1].scale)
            luassert.equals(45, transforms[1].rotation)
        end)
    end)

    describe("each iterator", function()
        it("dispatches to the correct eachN method based on arguments", function()
            -- Create entity with multiple components
            world:spawn(
                Position(1, 1),
                Velocity(10, 10),
                Health(100)
            )
            world:update(0)

            -- Test with 1 component
            local query1 = world:query({include = {Position}})
            local count1 = 0
            for archetype, len in query1() do
                local poss = archetype[Position]
                for row = 1, len do
                    local pos = poss[row]
                    count1 = count1 + 1
                    luassert.equals(1, (pos as TestHelpers.Pos).x)
                end
            end
            luassert.equals(1, count1)

            -- Test with 2 components
            local query2 = world:query({include = {Position, Velocity}})
            local count2 = 0
            for archetype, len in query2() do
                local poss = archetype[Position]
                local vels = archetype[Velocity]
                for row = 1, len do
                    local pos = poss[row]
                    local vel = vels[row]
                    count2 = count2 + 1
                    luassert.equals(1, (pos as TestHelpers.Pos).x)
                    luassert.equals(10, (vel as TestHelpers.Vel).x)
                end
            end
            luassert.equals(1, count2)

            -- Test with 3 components
            local query3 = world:query({include = {Position, Velocity, Health}})
            local count3 = 0
            for archetype, len in query3() do
                local poss = archetype[Position]
                local vels = archetype[Velocity]
                local hths = archetype[Health]
                for row = 1, len do
                    local pos = poss[row]
                    local vel = vels[row]
                    local health = hths[row]
                    count3 = count3 + 1
                    luassert.equals(1, (pos as TestHelpers.Pos).x)
                    luassert.equals(10, (vel as TestHelpers.Vel).x)
                    luassert.equals(100, (health as TestHelpers.Health).value)
                end
            end
            luassert.equals(1, count3)
        end)
    end)
end)