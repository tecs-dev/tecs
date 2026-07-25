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
        it("formats queries consistently in tostring", function()
            local GroupA = tecs.newComponent({ name = "FormatGroupA_" .. testId, container = {} })
            local GroupB = tecs.newComponent({ name = "FormatGroupB_" .. testId, container = {} })
            local query = world:query({
                name = "Moving",
                include = {Position, Velocity},
                includeAny = {GroupA, GroupB},
                exclude = {Health}
            })

            local includeNames = {}
            for i = 1, #query.descriptor.include do
                includeNames[i] = tostring(query.descriptor.include[i])
            end
            local includeAnyNames = {}
            for i = 1, #(query.descriptor.includeAny) do
                includeAnyNames[i] = tostring(query.descriptor.includeAny[i])
            end
            local excludeNames = {}
            for i = 1, #(query.descriptor.exclude) do
                excludeNames[i] = tostring(query.descriptor.exclude[i])
            end
            local expected = string.format(
                "Moving {include: %s, includeAny: %s, exclude: %s} [0 archetypes]",
                table.concat(includeNames, ", "),
                table.concat(includeAnyNames, ", "),
                table.concat(excludeNames, ", ")
            )
            luassert.is_equal(
                expected,
                tostring(query)
            )
        end)

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
            for archetype, len in query:iter() do
                local poss = archetype:get(Position)
                local vels = archetype:get(Velocity)
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
            for archetype, len in query:iter() do
                -- Access component columns directly from archetype
                local positions = archetype:get(Position)
                local velocities = archetype:get(Velocity)

                luassert.is_not_nil(positions, "Should be able to access Position column via archetype:get(Position)")
                luassert.is_not_nil(velocities, "Should be able to access Velocity column via archetype:get(Velocity)")

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
            for _, len in query:iter() do
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
            for archetype, len in query:iter() do
                local poss = archetype:get(Position)
                for row = 1, len do
                    local pos = poss[row]
                    count = count + 1
                    luassert.is_not_nil(pos, "Position should exist")
                end
            end
            luassert.is_equal(2, count, "Query should match 2 entities")
        end)

        it("counts matched entities across archetypes and updates live", function()
            local query = world:query({ include = {Position} })
            luassert.is_equal(0, query:count())

            world:spawn(Position(1, 1))
            world:spawn(Position(2, 2))
            local mixed = world:spawn(Position(3, 3), Velocity(1, 0))
            world:update(0)
            luassert.is_equal(3, query:count())

            world:despawn(mixed)
            world:update(0)
            luassert.is_equal(2, query:count())
        end)

        it("counts grouped queries", function()
            world:spawn(Position(1, 1))
            world:spawn(Position(2, 2), Velocity(1, 0))
            world:update(0)

            local query = world:query({
                include = {Position},
                groupBy = function(archetype: tecs.Archetype): integer
                    return archetype.id
                end,
            })
            luassert.is_equal(2, query:count())
        end)

        it("catchup fires onEntitiesAdded for existing entities", function()
            local totalSeen = 0
            local callbackInvocations = 0

            world:spawn(Position(1, 1))
            world:spawn(Position(2, 2))
            world:spawn(Position(3, 3))
            world:update(0)

            world:query({
                include = {Position},
                onEntitiesAdded = function(_arch: tecs.Archetype, _firstRow: integer, _lastRow: integer, count: integer)
                    callbackInvocations = callbackInvocations + 1
                    totalSeen = totalSeen + count
                end,
            })

            -- Single archetype, batched catchup: one callback for all 3.
            luassert.equals(1, callbackInvocations)
            luassert.equals(3, totalSeen)
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
            for _, len in query:iter() do
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
            for archetype, len in query:iter() do
                local poss = archetype:get(Position)
                local vels = archetype:get(Velocity)
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
            for archetype, len in query:iter() do
                local poss = archetype:get(Position)
                for row = 1, len do
                    local pos = poss[row]
                    count = count + 1
                    luassert.is_not_nil(pos, "Position should exist")
                end
            end
            luassert.is_equal(1, count, "Should only match 1 entity without Health")
        end)

        it("filters initial matches with includeAny correctly", function()
            local groupA = tecs.newComponent({ name = "IncludeAnyGroupA_" .. testId, container = {} })
            local groupB = tecs.newComponent({ name = "IncludeAnyGroupB_" .. testId, container = {} })
            local other = tecs.newComponent({ name = "IncludeAnyOther_" .. testId, container = {} })

            world:spawn(Position(1, 1), groupA)
            world:spawn(Position(2, 2), groupB)
            world:spawn(Position(3, 3), other)
            world:update(0)

            local query = world:query({
                include = {Position},
                includeAny = {groupA, groupB},
            })

            local count = 0
            for archetype, len in query:iter() do
                if archetype:get(groupA) or archetype:get(groupB) then
                    count = count + len
                else
                    luassert.fail("Query matched archetype outside includeAny set")
                end
            end

            luassert.is_equal(2, count, "Should only match entities in includeAny groups")
        end)
    end)

    describe("Dynamic query updates", function()
        it("updates when new matching entities are added", function()
            local query = world:query({
                include = {Position}
            })

            -- Initially no entities
            local count = 0
            for _, len in query:iter() do
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
            for _, len in query:iter() do
                for _ = 1, len do
                    count = count + 1
                end
            end
            luassert.is_equal(2, count, "Query should update with new entities")
        end)

        it("fires onEntitiesAdded when entity starts matching", function()
            local addCalls = 0
            world:query({
                include = {Position, Health},
                onEntitiesAdded = function(_arch: tecs.Archetype, _firstRow: integer, _lastRow: integer, count: integer)
                    addCalls = addCalls + count
                end,
            })

            local e = world:spawn(Position(1, 1))
            world:update(0)
            luassert.equals(0, addCalls, "doesn't match yet (no Health)")

            world:set(e, Health(100))
            world:update(0)
            luassert.equals(1, addCalls)
        end)

        it("fires onEntitiesRemoved when entity stops matching", function()
            local removeCalls = 0
            local e = world:spawn(Position(1, 1))
            world:update(0)

            world:query({
                include = {Position},
                onEntitiesRemoved = function(_arch: tecs.Archetype, _firstRow: integer, _lastRow: integer, count: integer)
                    removeCalls = removeCalls + count
                end,
            })

            world:remove(e, Position)
            world:update(0)

            luassert.equals(1, removeCalls)
        end)

        it("fires onEntitiesRemoved when entity is despawned", function()
            local removeCalls = 0
            local e = world:spawn(Position(1, 1))
            world:update(0)

            world:query({
                include = {Position},
                onEntitiesRemoved = function(_arch: tecs.Archetype, _firstRow: integer, _lastRow: integer, count: integer)
                    removeCalls = removeCalls + count
                end,
            })

            world:despawn(e)
            world:update(0)

            luassert.equals(1, removeCalls)
        end)

        it("fires on re-entry after archetype excursion", function()
            local addCalls = 0
            local removeCalls = 0

            world:query({
                include = {Position, Health},
                onEntitiesAdded = function(_arch: tecs.Archetype, _firstRow: integer, _lastRow: integer, count: integer)
                    addCalls = addCalls + count
                end,
                onEntitiesRemoved = function(_arch: tecs.Archetype, _firstRow: integer, _lastRow: integer, count: integer)
                    removeCalls = removeCalls + count
                end,
            })

            local e = world:spawn(Position(1, 1), Health(100))
            world:update(0)
            luassert.equals(1, addCalls)

            world:remove(e, Health)
            world:update(0)
            luassert.equals(1, removeCalls)

            world:set(e, Health(50))
            world:update(0)
            luassert.equals(2, addCalls)
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
            for archetype, len, entityList in query:iter() do
                local poss = archetype:get(Position)
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
            for archetype, len, entityList in query:iter() do
                local poss = archetype:get(Position)
                local vels = archetype:get(Velocity)
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
            for archetype, len, entityList in query:iter() do
                local poss = archetype:get(Position)
                local vels = archetype:get(Velocity)
                local hths = archetype:get(Health)
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
            for archetype, len, entityList in query:iter() do
                local poss = archetype:get(Position)
                local vels = archetype:get(Velocity)
                local hths = archetype:get(Health)
                local sprs = archetype:get(Sprite)
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
            for archetype, len, entityList in query:iter() do
                local poss = archetype:get(Position)
                local vels = archetype:get(Velocity)
                local hths = archetype:get(Health)
                local sprs = archetype:get(Sprite)
                local trns = archetype:get(Transform)
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
            for archetype, len in query1:iter() do
                local poss = archetype:get(Position)
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
            for archetype, len in query2:iter() do
                local poss = archetype:get(Position)
                local vels = archetype:get(Velocity)
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
            for archetype, len in query3:iter() do
                local poss = archetype:get(Position)
                local vels = archetype:get(Velocity)
                local hths = archetype:get(Health)
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

    describe("query cursors", function()
        it("closes and drains a traversal after an early break", function()
            world:spawn(Position(1, 1))
            world:spawn(Position(2, 2), Velocity(1, 0))
            world:update(0)

            local query = world:query({include = {Position}})
            local cursor: tecs.QueryCursor = query:cursor()
            local selected: integer = nil

            for _archetype, _len, entities in cursor:iter() do
                selected = entities[1]
                world:set(selected, Health(100))
                luassert.is_nil(world:get(selected, Health),
                    "structural mutation should remain staged while the cursor is open")
                break
            end

            cursor:close()
            luassert.is_not_nil(world:get(selected, Health),
                "closing the cursor should drain its staged mutation")
        end)

        it("closes automatically on natural exhaustion and close is idempotent", function()
            local first = world:spawn(Position(1, 1))
            local second = world:spawn(Position(2, 2), Velocity(1, 0))
            world:update(0)

            local query = world:query({include = {Position}})
            local cursor = query:cursor()
            for _archetype, _len, entities in cursor:iter() do
                for row = 1, _len do
                    world:set(entities[row], Health(100))
                end
            end

            luassert.is_not_nil(world:get(first, Health))
            luassert.is_not_nil(world:get(second, Health))
            cursor:close()
            cursor:close()

            world:set(first, Sprite("after-close.png"))
            luassert.is_not_nil(world:get(first, Sprite),
                "repeated close must not leave or underflow the world scope")
        end)

        it("keeps nested cursor scopes independent", function()
            world:spawn(Position(1, 1))
            world:spawn(Position(2, 2), Velocity(1, 0))
            world:update(0)

            local query = world:query({include = {Position}})
            local outer = query:cursor()
            local selected: integer = nil

            for _outerArchetype in outer:iter() do
                local inner = query:cursor()
                for _innerArchetype, _len, entities in inner:iter() do
                    selected = entities[1]
                    world:set(selected, Health(100))
                    break
                end
                inner:close()
                inner:close()

                luassert.is_nil(world:get(selected, Health),
                    "closing the inner cursor must not drain the outer scope")
                break
            end

            outer:close()
            luassert.is_not_nil(world:get(selected, Health),
                "closing the outer cursor should drain the pending mutation")
        end)

        it("supports closing interleaved cursors out of order", function()
            local selected = world:spawn(Position(1, 1))
            world:update(0)

            local query = world:query({include = {Position}})
            local first = query:cursor()
            local firstNext, firstState, firstControl = first:iter()
            luassert.is_not_nil(firstNext(firstState, firstControl))

            local second = query:cursor()
            local secondNext, secondState, secondControl = second:iter()
            luassert.is_not_nil(secondNext(secondState, secondControl))

            world:set(selected, Health(100))
            first:close()
            luassert.is_nil(world:get(selected, Health),
                "the second cursor should keep the deferred scope open")

            second:close()
            luassert.is_not_nil(world:get(selected, Health),
                "the final cursor close should drain the staged mutation")
        end)

        it("supports grouped cursor traversal", function()
            world:spawn(Position(1, 1))
            world:spawn(Position(2, 2), Velocity(1, 0))
            world:update(0)

            local query = world:query({
                include = {Position},
                groupBy = function(archetype: tecs.Archetype): integer
                    return archetype.id
                end,
            })

            local matchedArchetypes = 0
            local iterCursor = query:cursor()
            for _archetype in iterCursor:iter() do
                matchedArchetypes = matchedArchetypes + 1
                break
            end
            iterCursor:close()
            luassert.equals(1, matchedArchetypes)

            local groupId: integer = nil
            local groupsCursor = query:cursor()
            for currentGroupId in groupsCursor:groups() do
                groupId = currentGroupId
                break
            end
            groupsCursor:close()
            luassert.is_not_nil(groupId)

            local archetypeCount = 0
            local groupCursor = query:cursor()
            for _archetype in groupCursor:group(groupId) do
                archetypeCount = archetypeCount + 1
                break
            end
            groupCursor:close()
            luassert.equals(1, archetypeCount)
        end)

        it("cannot reuse a closed cursor", function()
            local query = world:query({include = {Position}})
            local cursor = query:cursor()
            cursor:close()
            cursor:close()

            luassert.has_error(function()
                cursor:iter()
            end)
        end)
    end)

    describe("Disabled component exclusion", function()
        it("excludes disabled entities from queries by default", function()
            local builtins = tecs.builtins

            -- Spawn normal entities
            world:spawn(Position(1, 1), Velocity(10, 10))
            world:spawn(Position(2, 2), Velocity(20, 20))

            -- Spawn disabled entity
            world:spawn(Position(3, 3), Velocity(30, 30), builtins.Disabled)

            world:update(0)

            -- Query without including Disabled (should exclude e3)
            local query = world:query({
                include = {Position, Velocity}
            })

            local count = 0
            for archetype, len in query:iter() do
                for row = 1, len do
                    count = count + 1
                end
            end

            luassert.equals(2, count, "Expected 2 enabled entities")
        end)

        it("includes disabled entities when explicitly requested", function()
            local builtins = tecs.builtins

            -- Spawn disabled entity
            world:spawn(Position(1, 1), Velocity(10, 10), builtins.Disabled)

            world:update(0)

            -- Query with explicit include of Disabled
            local query = world:query({
                include = {Position, Velocity, builtins.Disabled}
            })

            local count = 0
            for archetype, len in query:iter() do
                for row = 1, len do
                    count = count + 1
                end
            end

            luassert.equals(1, count, "Expected 1 disabled entity when explicitly included")
        end)
    end)

    describe("query type", function()
        local function countEntities(query: tecs.Query): integer
            local count = 0
            for _archetype, len in query:iter() do
                count = count + len
            end
            return count
        end

        before_each(function()
            world:spawn(Position(1, 1), Velocity(10, 10))
            world:spawn(Position(2, 2), Velocity(20, 20), tecs.builtins.Paused)
            world:update(0)
        end)

        it("excludes paused entities from logic queries", function()
            local query = world:query({
                include = {Position, Velocity},
                type = "logic",
            })

            luassert.equals(1, countEntities(query), "Expected the unpaused entity only")
        end)

        it("keeps paused entities in render queries", function()
            local query = world:query({
                include = {Position, Velocity},
                type = "render",
            })

            luassert.equals(2, countEntities(query), "Expected both entities")
        end)

        it("keeps paused entities when type is omitted", function()
            local query = world:query({include = {Position, Velocity}})

            luassert.equals(2, countEntities(query), "Expected both entities")
        end)

        it("keeps paused entities that a logic query includes explicitly", function()
            local query = world:query({
                include = {Position, Velocity, tecs.builtins.Paused},
                type = "logic",
            })

            luassert.equals(1, countEntities(query), "Expected the paused entity only")
        end)

        it("rejects an unknown type", function()
            luassert.has_error(function()
                world:query({
                    include = {Position},
                    type = "gameplay" as tecs.Query.Kind,
                })
            end)
        end)
    end)

    describe("groupBy archetype grouping", function()
        local GroupA: tecs.Component
        local GroupB: tecs.Component
        local GroupC: tecs.Component

        before_each(function()
            local containerA: tecs.Component = {}
            local containerB: tecs.Component = {}
            local containerC: tecs.Component = {}
            GroupA = tecs.newComponent({ name = "GroupA_" .. testId, container = containerA })
            GroupB = tecs.newComponent({ name = "GroupB_" .. testId, container = containerB })
            GroupC = tecs.newComponent({ name = "GroupC_" .. testId, container = containerC })
        end)

        it("groups archetypes by the groupBy function result", function()
            -- Spawn entities in different groups (interleaved order)
            world:spawn(Position(1, 1), GroupB)
            world:spawn(Position(2, 2), GroupA)
            world:spawn(Position(3, 3), GroupC)
            world:update(0)

            local query = world:query({
                include = {Position},
                includeAny = {GroupA, GroupB, GroupC},
                groupBy = function(archetype: tecs.Archetype): integer
                    if archetype:get(GroupA) then return 1 end
                    if archetype:get(GroupB) then return 2 end
                    if archetype:get(GroupC) then return 3 end
                    return 99
                end,
            })

            -- Collect iteration order via regular iteration
            local groups: {integer} = {}
            for archetype in query:iter() do
                local group = query:getGroup(archetype)
                table.insert(groups, group)
            end

            -- Verify archetypes are grouped and sorted by group ID
            luassert.equals(3, #groups, "Should have 3 archetypes")
            luassert.equals(1, groups[1], "First archetype should be group 1")
            luassert.equals(2, groups[2], "Second archetype should be group 2")
            luassert.equals(3, groups[3], "Third archetype should be group 3")
        end)

        it("maintains grouping when new archetypes are added", function()
            local query = world:query({
                include = {Position},
                includeAny = {GroupA, GroupB, GroupC},
                groupBy = function(archetype: tecs.Archetype): integer
                    if archetype:get(GroupA) then return 1 end
                    if archetype:get(GroupB) then return 2 end
                    if archetype:get(GroupC) then return 3 end
                    return 99
                end,
            })

            -- Add entities in reverse order (C, A, B)
            world:spawn(Position(1, 1), GroupC)
            world:update(0)
            world:spawn(Position(2, 2), GroupA)
            world:update(0)
            world:spawn(Position(3, 3), GroupB)
            world:update(0)

            -- Collect iteration order
            local groups: {integer} = {}
            for archetype in query:iter() do
                table.insert(groups, query:getGroup(archetype))
            end

            -- Should be sorted 1, 2, 3 regardless of spawn order
            luassert.equals(3, #groups, "Should have 3 archetypes")
            luassert.equals(1, groups[1], "First archetype should be group 1")
            luassert.equals(2, groups[2], "Second archetype should be group 2")
            luassert.equals(3, groups[3], "Third archetype should be group 3")
        end)

        it("groups() iterates active group IDs in sorted order", function()
            world:spawn(Position(1, 1), GroupC)  -- group 3
            world:spawn(Position(2, 2), GroupA)  -- group 1
            world:spawn(Position(3, 3), GroupB)  -- group 2
            world:update(0)

            local query = world:query({
                include = {Position},
                includeAny = {GroupA, GroupB, GroupC},
                groupBy = function(archetype: tecs.Archetype): integer
                    if archetype:get(GroupA) then return 1 end
                    if archetype:get(GroupB) then return 2 end
                    if archetype:get(GroupC) then return 3 end
                    return 99
                end,
            })

            local groupIds: {integer} = {}
            for groupId in query:groups() do
                table.insert(groupIds, groupId)
            end

            luassert.equals(3, #groupIds, "Should have 3 groups")
            luassert.equals(1, groupIds[1], "First group should be 1")
            luassert.equals(2, groupIds[2], "Second group should be 2")
            luassert.equals(3, groupIds[3], "Third group should be 3")
        end)

        it("group() iterates only archetypes in that group", function()
            world:spawn(Position(1, 1), GroupA)
            world:spawn(Position(2, 2), GroupA)  -- different entity, same archetype
            world:spawn(Position(3, 3), GroupB)
            world:spawn(Position(4, 4), GroupC)
            world:update(0)

            local query = world:query({
                include = {Position},
                includeAny = {GroupA, GroupB, GroupC},
                groupBy = function(archetype: tecs.Archetype): integer
                    if archetype:get(GroupA) then return 1 end
                    if archetype:get(GroupB) then return 2 end
                    if archetype:get(GroupC) then return 3 end
                    return 99
                end,
            })

            -- Iterate only group 2 (GroupB)
            local count = 0
            local foundGroupB = false
            for archetype, len in query:group(2) do
                count = count + 1
                if archetype:get(GroupB) then
                    foundGroupB = true
                end
            end

            luassert.equals(1, count, "Should have 1 archetype in group 2")
            luassert.is_true(foundGroupB, "Should have found GroupB archetype")
        end)

        it("group() returns empty iterator for non-existent group", function()
            world:spawn(Position(1, 1), GroupA)
            world:update(0)

            local query = world:query({
                include = {Position},
                includeAny = {GroupA, GroupB, GroupC},
                groupBy = function(archetype: tecs.Archetype): integer
                    if archetype:get(GroupA) then return 1 end
                    if archetype:get(GroupB) then return 2 end
                    if archetype:get(GroupC) then return 3 end
                    return 99
                end,
            })

            local count = 0
            for _ in query:group(999) do
                count = count + 1
            end

            luassert.equals(0, count, "Should have no archetypes in non-existent group")
        end)

        it("getGroup() returns cached group ID for archetype", function()
            world:spawn(Position(1, 1), GroupA)
            world:spawn(Position(2, 2), GroupB)
            world:update(0)

            local query = world:query({
                include = {Position},
                includeAny = {GroupA, GroupB},
                groupBy = function(archetype: tecs.Archetype): integer
                    if archetype:get(GroupA) then return 10 end
                    if archetype:get(GroupB) then return 20 end
                    return 99
                end,
            })

            for archetype in query:iter() do
                local group = query:getGroup(archetype)
                if archetype:get(GroupA) then
                    luassert.equals(10, group, "GroupA archetype should have group 10")
                elseif archetype:get(GroupB) then
                    luassert.equals(20, group, "GroupB archetype should have group 20")
                end
            end
        end)

        it("getGroup() returns nil when groupBy is not specified", function()
            world:spawn(Position(1, 1), GroupA)
            world:update(0)

            local query = world:query({
                include = {Position},
                includeAny = {GroupA},
            })

            for archetype in query:iter() do
                local group = query:getGroup(archetype)
                luassert.is_nil(group, "getGroup should return nil when groupBy not specified")
            end
        end)

        it("groups() returns empty iterator when groupBy is not specified", function()
            world:spawn(Position(1, 1), GroupA)
            world:update(0)

            local query = world:query({
                include = {Position},
                includeAny = {GroupA},
            })

            local count = 0
            for _ in query:groups() do
                count = count + 1
            end

            luassert.equals(0, count, "groups() should return empty iterator without groupBy")
        end)

        it("supports iterating groups then archetypes within each group", function()
            world:spawn(Position(1, 1), GroupA)
            world:spawn(Position(2, 2), GroupB)
            world:spawn(Position(3, 3), GroupC)
            world:update(0)

            local query = world:query({
                include = {Position},
                includeAny = {GroupA, GroupB, GroupC},
                groupBy = function(archetype: tecs.Archetype): integer
                    if archetype:get(GroupA) then return 1 end
                    if archetype:get(GroupB) then return 2 end
                    if archetype:get(GroupC) then return 3 end
                    return 99
                end,
            })

            -- Typical usage pattern: iterate groups, then iterate within each group
            local results: {{integer, integer}} = {}  -- {groupId, entityCount}
            for groupId in query:groups() do
                local entityCount = 0
                for archetype, len in query:group(groupId) do
                    entityCount = entityCount + len
                end
                table.insert(results, {groupId, entityCount})
            end

            luassert.equals(3, #results, "Should have 3 groups")
            luassert.equals(1, results[1][1], "First group ID should be 1")
            luassert.equals(1, results[1][2], "First group should have 1 entity")
            luassert.equals(2, results[2][1], "Second group ID should be 2")
            luassert.equals(1, results[2][2], "Second group should have 1 entity")
            luassert.equals(3, results[3][1], "Third group ID should be 3")
            luassert.equals(1, results[3][2], "Third group should have 1 entity")
        end)
    end)

    describe("Batched observer hooks", function()
        it("fires onEntitiesAdded once per batchSpawn with count=N", function()
            local calls: {{integer}} = {}
            world:query({
                include = {Position},
                onEntitiesAdded = function(_arch: tecs.Archetype, firstRow: integer, lastRow: integer, count: integer)
                    table.insert(calls, {firstRow, lastRow, count})
                end,
            })

            world:batchSpawn(10, {Position as tecs.Component},
                function(arch: tecs.Archetype, startRow: integer, lastRow: integer, n: integer)
                    local positions = arch:getMut(Position)
                    for i = startRow, lastRow do
                        positions[i] = Position(i, i)
                    end
                end)
            world:commit()

            luassert.equals(1, #calls, "should fire once for a batch of 10")
            luassert.equals(1, calls[1][1], "firstRow = 1")
            luassert.equals(10, calls[1][2], "lastRow = 10")
            luassert.equals(10, calls[1][3], "count = 10")
        end)

        it("fires onEntitiesAdded with count=1 on single spawn", function()
            local calls: {{integer}} = {}
            world:query({
                include = {Position},
                onEntitiesAdded = function(_arch: tecs.Archetype, firstRow: integer, lastRow: integer, count: integer)
                    table.insert(calls, {firstRow, lastRow, count})
                end,
            })

            world:spawn(Position(1, 1))
            world:commit()

            luassert.equals(1, #calls, "should fire once")
            luassert.equals(1, calls[1][1], "firstRow=1")
            luassert.equals(1, calls[1][2], "lastRow=1")
            luassert.equals(1, calls[1][3], "count=1")
        end)

        it("fires onEntitiesAdded when an entity transitions into the match set", function()
            local calls: {{integer}} = {}
            world:query({
                include = {Position, Velocity},
                onEntitiesAdded = function(_arch: tecs.Archetype, _firstRow: integer, _lastRow: integer, count: integer)
                    table.insert(calls, {count})
                end,
            })

            -- Pre-existing entity without Velocity: doesn't match yet.
            local id = world:spawn(Position(1, 1))
            world:commit()
            luassert.equals(0, #calls)

            -- Add Velocity: entity transitions to match query.
            world:set(id, Velocity(1, 1))
            world:commit()

            luassert.equals(1, #calls, "should fire after archetype transition")
            luassert.equals(1, calls[1][1], "count=1 for single transition")
        end)

        it("fires onEntitiesRemoved once per batchDespawn truncate", function()
            local calls: {{integer}} = {}
            world:query({
                include = {Position},
                onEntitiesRemoved = function(_arch: tecs.Archetype, firstRow: integer, lastRow: integer, count: integer)
                    table.insert(calls, {firstRow, lastRow, count})
                end,
            })

            world:batchSpawn(10, {Position as tecs.Component},
                function(arch: tecs.Archetype, startRow: integer, lastRow: integer, n: integer)
                    local positions = arch:getMut(Position)
                    for i = startRow, lastRow do
                        positions[i] = Position(i, i)
                    end
                end)
            world:commit()

            local despawnQuery = world:query({include = {Position}})
            world:batchDespawn(despawnQuery)
            world:commit()

            luassert.equals(1, #calls, "should fire once for full truncate")
            luassert.equals(1, calls[1][1], "firstRow = 1")
            luassert.equals(10, calls[1][2], "lastRow = 10")
            luassert.equals(10, calls[1][3], "count = 10")
        end)

        it("fires onEntitiesRemoved with count=1 on single despawn", function()
            local calls: {{integer}} = {}
            world:query({
                include = {Position},
                onEntitiesRemoved = function(_arch: tecs.Archetype, _firstRow: integer, _lastRow: integer, count: integer)
                    table.insert(calls, {count})
                end,
            })

            local id = world:spawn(Position(1, 1))
            world:commit()

            world:despawn(id)
            world:commit()

            luassert.equals(1, #calls)
            luassert.equals(1, calls[1][1], "count=1 for single despawn")
        end)

        it("skips dispatch when entity moves between matching archetypes", function()
            local addedCalls: {any} = {}
            local removedCalls: {any} = {}
            world:query({
                include = {Position},
                onEntitiesAdded = function(_arch: tecs.Archetype, _firstRow: integer, _lastRow: integer, _count: integer)
                    table.insert(addedCalls, true)
                end,
                onEntitiesRemoved = function(_arch: tecs.Archetype, _firstRow: integer, _lastRow: integer, _count: integer)
                    table.insert(removedCalls, true)
                end,
            })

            local id = world:spawn(Position(1, 1))
            world:commit()
            luassert.equals(1, #addedCalls)
            luassert.equals(0, #removedCalls)

            -- Adding Velocity creates a new archetype that still matches {Position}.
            -- Both src and dst match -- add/remove should be suppressed.
            world:set(id, Velocity(1, 1))
            world:commit()

            luassert.equals(1, #addedCalls, "no add when transitioning within match set")
            luassert.equals(0, #removedCalls, "no remove when transitioning within match set")
        end)

        it("catches up existing entities with one batched call per archetype", function()
            world:batchSpawn(7, {Position as tecs.Component},
                function(arch: tecs.Archetype, startRow: integer, lastRow: integer, n: integer)
                    local positions = arch:getMut(Position)
                    for i = startRow, lastRow do
                        positions[i] = Position(i, i)
                    end
                end)
            world:commit()

            local calls: {{integer}} = {}
            world:query({
                include = {Position},
                onEntitiesAdded = function(_arch: tecs.Archetype, firstRow: integer, lastRow: integer, count: integer)
                    table.insert(calls, {firstRow, lastRow, count})
                end,
            })

            luassert.equals(1, #calls, "catchup fires one batched call")
            luassert.equals(1, calls[1][1], "firstRow=1")
            luassert.equals(7, calls[1][2], "lastRow=7")
            luassert.equals(7, calls[1][3], "count=7")
        end)

        it("rejects onEntitiesAdded on a temp query", function()
            local ok = pcall(function()
                world:query({
                    include = {Position},
                    temp = true,
                    onEntitiesAdded = function() end,
                })
            end)
            luassert.is_false(ok)
        end)

        it("observer-cascade add does not leave stale entries in the source arch", function()
            -- Regression: when an observer on arch{A} fires and stages
            -- `world:set(e, B)` during the drain, the entity must end
            -- up PHYSICALLY only in arch{A,B}, not in both arch{A} and
            -- arch{A,B}. Tracks the bug where observer-driven staging
            -- appended a new spawn record on the destination without
            -- marking the source arch for `pendingMoveOut`.
            local TagA = tecs.newTagComponent({name = "CascadeTagA"})
            local TagB = tecs.newTagComponent({name = "CascadeTagB"})
            local TagC = tecs.newTagComponent({name = "CascadeTagC"})

            world:query({
                name = "AObs",
                include = {TagA},
                onEntitiesAdded = function(arch: tecs.Archetype, firstRow: integer, lastRow: integer, _c: integer)
                    local entities = arch.entities
                    for row = firstRow, lastRow do
                        world:set(entities[row], TagB)
                    end
                end,
            })
            world:query({
                name = "BObs",
                include = {TagB},
                onEntitiesAdded = function(arch: tecs.Archetype, firstRow: integer, lastRow: integer, _c: integer)
                    local entities = arch.entities
                    for row = firstRow, lastRow do
                        world:set(entities[row], TagC)
                    end
                end,
            })

            world:defer()
            local ids: {integer} = {}
            for i = 1, 3 do
                ids[i] = world:spawn(TagA)
            end
            world:commit()

            -- Entity count: each of the three entities should appear
            -- in arch{A,B,C} exactly once and NOT appear in arch{A}
            -- (alone) or arch{A,B} (no C) at all.
            local function countIn(include: {tecs.Component}, exclude: {tecs.Component}): integer
                local q = world:query({
                    name = "regress_probe_" .. tostring({}),
                    include = include,
                    exclude = exclude,
                    temp = true,
                })
                local n = 0
                for _arch, len in q:iter() do n = n + len end
                return n
            end

            luassert.equals(0, countIn({TagA}, {TagB}), "no entity should be stuck in arch{A}")
            luassert.equals(0, countIn({TagA, TagB}, {TagC}), "no entity should be stuck in arch{A,B}")
            luassert.equals(3, countIn({TagA, TagB, TagC}, {}), "all 3 entities land in arch{A,B,C}")

            -- No duplicate physical placement: each entity id should
            -- appear in exactly one active archetype. Scan via the
            -- trio of includes we know exist -- they cover the full
            -- set of arches entities could legitimately land in.
            local function eachEntityInQuery(q: tecs.Query, fn: function(integer))
                for _arch, len, entities in q:iter() do
                    for r = 1, len do fn((entities as {integer})[r]) end
                end
            end

            local seen: {integer: integer} = {}
            eachEntityInQuery(
                world:query({name = "dupe_probe_A", include = {TagA}, temp = true}),
                function(id: integer) seen[id] = (seen[id] or 0) + 1 end
            )
            for i = 1, 3 do
                luassert.equals(1, seen[ids[i]], "entity " .. i .. " must be in exactly one archetype matching {TagA}")
            end
        end)
    end)

    describe("re-entrant iteration", function()
        it("nested iteration of the same query sees all archetypes", function()
            -- Two matching archetypes: {Position} and {Position, Velocity}.
            world:spawn(Position(1, 1))
            world:spawn(Position(2, 2), Velocity(0, 0))
            world:update(0)

            local q = world:query({include = {Position}})

            local outer = 0
            local inner = 0
            for _ in q:iter() do
                outer = outer + 1
                for _ in q:iter() do
                    inner = inner + 1
                end
            end

            luassert.equals(2, outer, "outer loop must see both archetypes")
            luassert.equals(4, inner, "each outer step runs a full inner pass")
        end)

        it("nested iteration of the same grouped query sees all archetypes", function()
            world:spawn(Position(1, 1))
            world:spawn(Position(2, 2), Velocity(0, 0))
            world:update(0)

            local q = world:query({
                include = {Position},
                groupBy = function(archetype: tecs.Archetype): integer
                    return archetype:get(Velocity) and 2 or 1
                end,
            })

            local outer = 0
            local inner = 0
            for _ in q:iter() do
                outer = outer + 1
                for _ in q:iter() do
                    inner = inner + 1
                end
            end

            luassert.equals(2, outer)
            luassert.equals(4, inner)
        end)

        it("nested groups() and group() iteration stays correct", function()
            world:spawn(Position(1, 1))
            world:spawn(Position(2, 2), Velocity(0, 0))
            world:update(0)

            local q = world:query({
                include = {Position},
                groupBy = function(archetype: tecs.Archetype): integer
                    return archetype:get(Velocity) and 2 or 1
                end,
            })

            local groupsSeen: {integer} = {}
            local archsSeen = 0
            for groupId in q:groups() do
                groupsSeen[#groupsSeen + 1] = groupId
                for _ in q:group(groupId) do
                    archsSeen = archsSeen + 1
                end
            end

            luassert.equals(2, #groupsSeen)
            luassert.equals(2, archsSeen)
        end)
    end)

    describe("archetype subscription window", function()
        it("registers archetypes created by initial onEntitiesAdded callbacks", function()
            local e1 = world:spawn(Position(1, 1))
            world:update(0)

            local spawned: integer = nil
            local triggered = false
            local q = world:query({
                include = {Position},
                onEntitiesAdded = function(_arch: tecs.Archetype, _first: integer, _last: integer, _count: integer)
                    if not triggered then
                        triggered = true
                        -- Creates a new matching archetype during query
                        -- construction, before the initial scan finishes.
                        spawned = world:spawn(Position(9, 9), Velocity(1, 1))
                    end
                end,
            })
            world:commit()

            local seen: {integer: boolean} = {}
            local count = 0
            for _, len, entities in q:iter() do
                for r = 1, len do
                    count = count + 1
                    seen[entities[r]] = true
                end
            end

            luassert.equals(2, count,
                "the archetype created by the initial callback must join the query")
            luassert.is_true(seen[e1])
            luassert.is_true(seen[spawned])
        end)
    end)
end)
