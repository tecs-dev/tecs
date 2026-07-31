require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")

-- Helper record for expected values
local record ExpectedPos
    x: number
    y: number
    z: number
end

describe(
    "Spawn/Respawn consistency",
    function()
        -- Create FFI components that use recycling (like Transform does)
        local record TestTransform is tecs.ecs.Component
            x: number
            y: number
            z: number
        end

        local record TestColor is tecs.ecs.Component
            r: number
            g: number
            b: number
        end

        local record TestTag is tecs.ecs.Component
        end

        local TransformComp: TestTransform
        local ColorComp: TestColor
        local TagComp: TestTag

        before_each(function()
            -- Create unique FFI components for each test
            local testId = math.random(1, 1000000)

            local transformContainer: TestTransform = {}
            TransformComp = tecs.ecs.newFFIComponent({
                name = "SpawnTest_Transform" .. testId,
                container = transformContainer,
                fields = {{"x", "float"}, {"y", "float"}, {"z", "float"}},
                defaults = {0, 0, 0},
            })

            local colorContainer: TestColor = {}
            ColorComp = tecs.ecs.newFFIComponent({
                name = "SpawnTest_Color" .. testId,
                container = colorContainer,
                fields = {{"r", "float"}, {"g", "float"}, {"b", "float"}},
                defaults = {1, 1, 1},
            })

            local tagContainer: TestTag = {}
            TagComp = tecs.ecs.newTagComponent({name = "SpawnTest_Tag" .. testId, container = tagContainer})
        end)

        it(
            "preserves component values after spawn/despawn/respawn cycle",
            function()
                local w = tecs.ecs.newWorld()

                -- Spawn 10 entities with different Transform values
                local entities: {integer} = {}
                local expectedValues: {integer: ExpectedPos} = {}

                for i = 1, 10 do
                    local x, y, z = i * 100, i * 200, i
                    local e = w:spawn(TransformComp(x, y, z), ColorComp(0.1 * i, 0.2 * i, 0.3 * i))
                    entities[i] = e
                    expectedValues[e] = {x = x, y = y, z = z}
                end
                w:commit()

                -- Verify initial values
                for _, e in ipairs(entities) do
                    local t = w:get(e, TransformComp)
                    luassert.is_not_nil(t, "Entity should have Transform")
                    local expected = expectedValues[e]
                    luassert.are_equal(expected.x, t.x, "Initial x should match for entity " .. e)
                    luassert.are_equal(expected.y, t.y, "Initial y should match for entity " .. e)
                    luassert.are_equal(expected.z, t.z, "Initial z should match for entity " .. e)
                end

                -- Despawn all entities
                for _, e in ipairs(entities) do
                    w:despawn(e)
                end
                w:commit()

                -- Re-spawn entities with new values
                local newEntities: {integer} = {}
                local newExpectedValues: {integer: ExpectedPos} = {}

                for i = 1, 10 do
                    -- Use different values than before
                    local x, y, z = i * 10, i * 20, i * 30
                    local e = w:spawn(TransformComp(x, y, z), ColorComp(0.5, 0.5, 0.5))
                    newEntities[i] = e
                    newExpectedValues[e] = {x = x, y = y, z = z}
                end
                w:commit()

                -- Reused storage must contain only the new values.
                for _, e in ipairs(newEntities) do
                    local t = w:get(e, TransformComp)
                    luassert.is_not_nil(t, "New entity should have Transform")
                    local expected = newExpectedValues[e]
                    luassert.are_equal(expected.x, t.x, "New x should match for entity " .. e)
                    luassert.are_equal(expected.y, t.y, "New y should match for entity " .. e)
                    luassert.are_equal(expected.z, t.z, "New z should match for entity " .. e)
                end
            end
        )

        it(
            "preserves component values after multiple spawn/despawn cycles",
            function()
                local w = tecs.ecs.newWorld()

                -- Run multiple cycles to stress test the spawn/despawn logic
                for cycle = 1, 5 do
                    local entities: {integer} = {}
                    local expectedValues: {integer: ExpectedPos} = {}

                    -- Spawn entities with cycle-specific values
                    for i = 1, 20 do
                        local x = cycle * 1000 + i * 10
                        local y = cycle * 2000 + i * 20
                        local z = cycle * 100 + i
                        local e = w:spawn(TransformComp(x, y, z), ColorComp(0.1, 0.2, 0.3))
                        entities[i] = e
                        expectedValues[e] = {x = x, y = y, z = z}
                    end
                    w:commit()

                    -- Verify values immediately after spawn
                    for _, e in ipairs(entities) do
                        local t = w:get(e, TransformComp)
                        luassert.is_not_nil(t, "Entity should have Transform in cycle " .. cycle)
                        local expected = expectedValues[e]
                        luassert.are_equal(expected.x, t.x, "Cycle " .. cycle .. ": x mismatch for entity " .. e)
                        luassert.are_equal(expected.y, t.y, "Cycle " .. cycle .. ": y mismatch for entity " .. e)
                        luassert.are_equal(expected.z, t.z, "Cycle " .. cycle .. ": z mismatch for entity " .. e)
                    end

                    -- Despawn all entities
                    for _, e in ipairs(entities) do
                        w:despawn(e)
                    end
                    w:commit()
                end
            end
        )

        it(
            "preserves values when spawning entities with different component signatures",
            function()
                local w = tecs.ecs.newWorld()

                -- This test mimics the UI example where Text entities (Transform+Text+Color)
                -- and Circle entities (Transform+Circle+Color) are spawned together

                -- Spawn "text-like" entities (Transform + Color + Tag)
                local textEntities: {integer} = {}
                local textExpected: {integer: ExpectedPos} = {}

                for i = 1, 5 do
                    local x, y, z = 100 + i * 10, 200 + i * 20, 0
                    local e = w:spawn(TransformComp(x, y, z), ColorComp(1, 1, 1), TagComp())
                    textEntities[i] = e
                    textExpected[e] = {x = x, y = y, z = z}
                end

                -- Spawn "circle-like" entities (Transform + Color only, different signature)
                local circleEntities: {integer} = {}
                local circleExpected: {integer: ExpectedPos} = {}

                for i = 1, 5 do
                    -- Circle entities have z=10 (like red dots in the UI example)
                    local x, y, z = 300 + i * 10, 400 + i * 20, 10
                    local e = w:spawn(TransformComp(x, y, z), ColorComp(1, 0, 0))
                    circleEntities[i] = e
                    circleExpected[e] = {x = x, y = y, z = z}
                end

                w:commit()

                -- Verify text entities have correct values (not circle values!)
                for _, e in ipairs(textEntities) do
                    local t = w:get(e, TransformComp)
                    luassert.is_not_nil(t, "Text entity should have Transform")
                    local expected = textExpected[e]
                    luassert.are_equal(expected.x, t.x, "Text entity " .. e .. ": x mismatch")
                    luassert.are_equal(expected.y, t.y, "Text entity " .. e .. ": y mismatch")
                    luassert.are_equal(expected.z, t.z, "Text entity " .. e .. ": z mismatch (got circle z?)")
                end

                -- Verify circle entities have correct values
                for _, e in ipairs(circleEntities) do
                    local t = w:get(e, TransformComp)
                    luassert.is_not_nil(t, "Circle entity should have Transform")
                    local expected = circleExpected[e]
                    luassert.are_equal(expected.x, t.x, "Circle entity " .. e .. ": x mismatch")
                    luassert.are_equal(expected.y, t.y, "Circle entity " .. e .. ": y mismatch")
                    luassert.are_equal(expected.z, t.z, "Circle entity " .. e .. ": z mismatch")
                end

                -- Now despawn all and respawn - mimicking scene switch
                for _, e in ipairs(textEntities) do
                    w:despawn(e)
                end
                for _, e in ipairs(circleEntities) do
                    w:despawn(e)
                end
                w:commit()

                -- Respawn with same pattern
                local newTextEntities: {integer} = {}
                local newTextExpected: {integer: ExpectedPos} = {}

                for i = 1, 5 do
                    local x, y, z = 100 + i * 10, 200 + i * 20, 0
                    local e = w:spawn(TransformComp(x, y, z), ColorComp(1, 1, 1), TagComp())
                    newTextEntities[i] = e
                    newTextExpected[e] = {x = x, y = y, z = z}
                end

                local newCircleEntities: {integer} = {}
                local newCircleExpected: {integer: ExpectedPos} = {}

                for i = 1, 5 do
                    local x, y, z = 300 + i * 10, 400 + i * 20, 10
                    local e = w:spawn(TransformComp(x, y, z), ColorComp(1, 0, 0))
                    newCircleEntities[i] = e
                    newCircleExpected[e] = {x = x, y = y, z = z}
                end

                w:commit()

                -- New text entities must not inherit despawned values.
                for _, e in ipairs(newTextEntities) do
                    local t = w:get(e, TransformComp)
                    luassert.is_not_nil(t, "New text entity should have Transform")
                    local expected = newTextExpected[e]
                    luassert.are_equal(expected.x, t.x, "After respawn: Text entity " .. e .. " x mismatch")
                    luassert.are_equal(expected.y, t.y, "After respawn: Text entity " .. e .. " y mismatch")
                    luassert.are_equal(
                        expected.z, t.z, "After respawn: Text entity " .. e .. " z mismatch (got circle z=10?)"
                    )
                end

                -- Verify new circle entities
                for _, e in ipairs(newCircleEntities) do
                    local t = w:get(e, TransformComp)
                    luassert.is_not_nil(t, "New circle entity should have Transform")
                    local expected = newCircleExpected[e]
                    luassert.are_equal(expected.x, t.x, "After respawn: Circle entity " .. e .. " x mismatch")
                    luassert.are_equal(expected.y, t.y, "After respawn: Circle entity " .. e .. " y mismatch")
                    luassert.are_equal(expected.z, t.z, "After respawn: Circle entity " .. e .. " z mismatch")
                end
            end
        )
    end
)
