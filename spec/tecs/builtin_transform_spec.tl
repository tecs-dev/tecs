require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")

-- Use the actual built-in Transform component
local Transform <const> = tecs.builtins.Transform

describe(
    "Built-in Transform spawn/respawn",
    function()
        -- Create a test tag component with unique name for each test
        local TestTag: tecs.Component
        local TestColor: tecs.Component

        before_each(function()
            local testId = math.random(1, 1000000)

            local tagContainer: tecs.Component = {}
            TestTag = tecs.newTagComponent({name = "BuiltinTest_Tag" .. testId, container = tagContainer})

            local colorContainer: tecs.Component = {}
            TestColor = tecs.newFFIComponent({
                name = "BuiltinTest_Color" .. testId,
                container = colorContainer,
                fields = {{"r", "float"}, {"g", "float"}, {"b", "float"}},
                defaults = {1, 1, 1},
            })
        end)

        it(
            "preserves Transform values after spawn/despawn cycles using builtin Transform",
            function()
                local w = tecs.newWorld()

                -- This test mimics the UI example scene switching
                for cycle = 1, 3 do
                    -- Spawn entities with two different signatures (like Text vs Circle)
                    -- Signature A: Transform + TestTag + TestColor (like Text entities)
                    -- Signature B: Transform + TestColor (like Circle entities)

                    local signatureA_entities: {integer} = {}
                    local signatureA_expected: {integer: {number, number, number}} = {}

                    local signatureB_entities: {integer} = {}
                    local signatureB_expected: {integer: {number, number, number}} = {}

                    -- Spawn signature A entities with z=0
                    for i = 1, 10 do
                        local x = 100 + i * 10
                        local y = 200 + i * 20
                        local z = 0 -- Text-like entities have z=0
                        local e = w:spawn(Transform(x, y, z), TestTag(), TestColor(1, 1, 1))
                        signatureA_entities[i] = e
                        signatureA_expected[e] = {x, y, z}
                    end

                    -- Spawn signature B entities with z=10
                    for i = 1, 10 do
                        local x = 300 + i * 10
                        local y = 400 + i * 20
                        local z = 10 -- Circle-like entities have z=10 (red dots)
                        local e = w:spawn(Transform(x, y, z), TestColor(1, 0, 0))
                        signatureB_entities[i] = e
                        signatureB_expected[e] = {x, y, z}
                    end

                    w:commit()

                    -- Verify signature A entities
                    for _, e in ipairs(signatureA_entities) do
                        local t = w:get(e, Transform)
                        luassert.is_not_nil(t, "Signature A entity should have Transform")
                        local expected = signatureA_expected[e]
                        luassert.are_equal(
                            expected[1],
                            t.x,
                            "Cycle "
                                .. cycle
                                .. ": Signature A entity "
                                .. e
                                .. " x mismatch - expected "
                                .. expected[1]
                                .. " got "
                                .. t.x
                        )
                        luassert.are_equal(
                            expected[2],
                            t.y,
                            "Cycle "
                                .. cycle
                                .. ": Signature A entity "
                                .. e
                                .. " y mismatch - expected "
                                .. expected[2]
                                .. " got "
                                .. t.y
                        )
                        luassert.are_equal(
                            expected[3],
                            t.z,
                            "Cycle "
                                .. cycle
                                .. ": Signature A entity "
                                .. e
                                .. " z mismatch - expected "
                                .. expected[3]
                                .. " got "
                                .. t.z
                                .. " (got signature B's z=10?)"
                        )
                    end

                    -- Verify signature B entities
                    for _, e in ipairs(signatureB_entities) do
                        local t = w:get(e, Transform)
                        luassert.is_not_nil(t, "Signature B entity should have Transform")
                        local expected = signatureB_expected[e]
                        luassert.are_equal(
                            expected[1], t.x, "Cycle " .. cycle .. ": Signature B entity " .. e .. " x mismatch"
                        )
                        luassert.are_equal(
                            expected[2], t.y, "Cycle " .. cycle .. ": Signature B entity " .. e .. " y mismatch"
                        )
                        luassert.are_equal(
                            expected[3], t.z, "Cycle " .. cycle .. ": Signature B entity " .. e .. " z mismatch"
                        )
                    end

                    -- Despawn all entities (like clearing a scene)
                    for _, e in ipairs(signatureA_entities) do
                        w:despawn(e)
                    end
                    for _, e in ipairs(signatureB_entities) do
                        w:despawn(e)
                    end
                    w:commit()
                end
            end
        )

        it(
            "handles many entities across multiple cycles",
            function()
                local w = tecs.newWorld()

                -- Run many cycles with many entities to stress test
                for cycle = 1, 10 do
                    local entities: {integer} = {}
                    local expected: {integer: {number, number, number}} = {}

                    for i = 1, 50 do
                        local x = cycle * 1000 + i
                        local y = cycle * 2000 + i * 2
                        local z = i % 5 -- Mix of z values
                        local e = w:spawn(Transform(x, y, z))
                        entities[i] = e
                        expected[e] = {x, y, z}
                    end
                    w:commit()

                    -- Verify all entities
                    for _, e in ipairs(entities) do
                        local t = w:get(e, Transform)
                        luassert.is_not_nil(t)
                        local exp = expected[e]
                        luassert.are_equal(exp[1], t.x, "x mismatch in cycle " .. cycle)
                        luassert.are_equal(exp[2], t.y, "y mismatch in cycle " .. cycle)
                        luassert.are_equal(exp[3], t.z, "z mismatch in cycle " .. cycle)
                    end

                    -- Despawn all
                    for _, e in ipairs(entities) do
                        w:despawn(e)
                    end
                    w:commit()
                end
            end
        )

        it(
            "verifies entity-to-component value consistency within same archetype",
            function()
                local w = tecs.newWorld()

                -- Spawn multiple entities with same component signature but different values
                -- This tests if values are correctly mapped to entities within the same archetype
                local entities: {integer} = {}
                local expected: {integer: {number, number, number}} = {}

                -- All entities have Transform + TestColor (same signature)
                for i = 1, 20 do
                    local x = i * 100
                    local y = i * 200
                    local z = i -- Each entity has unique z for easy identification
                    local e = w:spawn(Transform(x, y, z), TestColor(0.1 * i, 0.2 * i, 0.3 * i))
                    entities[i] = e
                    expected[e] = {x, y, z}
                end
                w:commit()

                -- Verify each entity has its own values (not another entity's values)
                for idx, e in ipairs(entities) do
                    local t = w:get(e, Transform)
                    luassert.is_not_nil(t, "Entity " .. e .. " should have Transform")
                    local exp = expected[e]

                    -- If values don't match, we have component-entity mismatch
                    if t.x ~= exp[1] or t.y ~= exp[2] or t.z ~= exp[3] then
                        -- Find which entity's values we got instead
                        local foundMatch = false
                        for otherIdx, otherE in ipairs(entities) do
                            if otherE ~= e then
                                local otherExp = expected[otherE]
                                if t.x == otherExp[1] and t.y == otherExp[2] and t.z == otherExp[3] then
                                    luassert.fail(
                                        "Entity "
                                            .. e
                                            .. " (idx "
                                            .. idx
                                            .. ") got Transform from entity "
                                            .. otherE
                                            .. " (idx "
                                            .. otherIdx
                                            .. ") - component-entity mismatch!"
                                    )
                                    foundMatch = true
                                    break
                                end
                            end
                        end
                        if not foundMatch then
                            luassert.fail(
                                "Entity "
                                    .. e
                                    .. " has wrong Transform: expected ("
                                    .. exp[1]
                                    .. ", "
                                    .. exp[2]
                                    .. ", "
                                    .. exp[3]
                                    .. ") got ("
                                    .. t.x
                                    .. ", "
                                    .. t.y
                                    .. ", "
                                    .. t.z
                                    .. ")"
                            )
                        end
                    end
                end
            end
        )
    end
)

describe(
    "RelativeTransform hierarchy",
    function()
        local ChildOf <const> = tecs.builtins.ChildOf
        local RelativeTransform <const> = tecs.builtins.RelativeTransform
        local WorldImpl <const> = require("tecs.internal.world")

        -- Records, per update, whether the child's archetype had a dirty
        -- component column when the frame ended (the relative-transform
        -- system marks Transform when it recomputes).
        local function addDirtyProbe(w: tecs.World, child: integer): {boolean}
            local seen: {boolean} = {}
            w:addSystem({
                name = "TransformDirtyProbe",
                phase = tecs.phases.Last,
                run = function()
                    local arch = (w as WorldImpl):currentArchetype(child)
                    local found = false
                    for darch in w:dirtyArchetypes() do
                        if darch == arch then
                            found = true
                            break
                        end
                    end
                    seen[#seen + 1] = found
                end,
            })
            return seen
        end

        it(
            "recomputes children when the parent moves and marks Transform dirty",
            function()
                local w = tecs.newWorld()
                local parent = w:spawn(Transform(100, 200, 0))
                local child = w:spawn(
                    Transform(0, 0, 0), RelativeTransform(10, 20, 0), ChildOf(parent) as tecs.Component
                )
                w:commit()

                local seen = addDirtyProbe(w, child)

                w:update(1 / 60)
                luassert.equals(110, w:get(child, Transform).x)
                luassert.equals(220, w:get(child, Transform).y)

                w:update(1 / 60)
                luassert.is_false(seen[2], "an idle frame must skip the hierarchy walk")

                w:set(parent, Transform(500, 600, 0))
                w:update(1 / 60)
                luassert.equals(510, w:get(child, Transform).x)
                luassert.equals(620, w:get(child, Transform).y)
                luassert.is_true(seen[3], "a parent move must leave the child's Transform column dirty")
            end
        )

        it(
            "recomputes children when ChildOf retargets",
            function()
                local w = tecs.newWorld()
                local parent1 = w:spawn(Transform(100, 0, 0))
                local parent2 = w:spawn(Transform(1000, 0, 0))
                local child = w:spawn(
                    Transform(0, 0, 0), RelativeTransform(5, 0, 0), ChildOf(parent1) as tecs.Component
                )
                w:commit()

                w:update(1 / 60)
                luassert.equals(105, w:get(child, Transform).x)

                w:update(1 / 60)

                -- Sparse retarget: no structural change, but the commit-time
                -- container mark must reopen the dirty gate.
                w:set(child, ChildOf(parent2) as tecs.Component)
                w:update(1 / 60)
                luassert.equals(1005, w:get(child, Transform).x)
            end
        )
    end
)
