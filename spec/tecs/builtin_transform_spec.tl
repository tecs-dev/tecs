require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")

-- Use the actual built-in Transform2D component
local Transform2D <const> = tecs.Transform2D

describe(
    "Built-in Transform2D spawn/respawn",
    function()
        -- Create a test tag component with unique name for each test
        local TestTag: tecs.ecs.Component
        local TestColor: tecs.ecs.Component

        before_each(function()
            local testId = math.random(1, 1000000)

            local tagContainer: tecs.ecs.Component = {}
            TestTag = tecs.ecs.newTagComponent({name = "BuiltinTest_Tag" .. testId, container = tagContainer})

            local colorContainer: tecs.ecs.Component = {}
            TestColor = tecs.ecs.newFFIComponent({
                name = "BuiltinTest_Color" .. testId,
                container = colorContainer,
                fields = {{"r", "float"}, {"g", "float"}, {"b", "float"}},
                defaults = {1, 1, 1},
            })
        end)

        it(
            "preserves Transform2D values after spawn/despawn cycles using builtin Transform2D",
            function()
                local w = tecs.ecs.newWorld()

                -- This test mimics the UI example scene switching
                for cycle = 1, 3 do
                    -- Spawn entities with two different signatures (like Text vs Circle)
                    -- Signature A: Transform2D + TestTag + TestColor (like Text entities)
                    -- Signature B: Transform2D + TestColor (like Circle entities)

                    local signatureA_entities: {integer} = {}
                    local signatureA_expected: {integer: {number, number, number}} = {}

                    local signatureB_entities: {integer} = {}
                    local signatureB_expected: {integer: {number, number, number}} = {}

                    -- Spawn signature A entities with z=0
                    for i = 1, 10 do
                        local x = 100 + i * 10
                        local y = 200 + i * 20
                        local z = 0 -- Text-like entities have z=0
                        local e = w:spawn(Transform2D(x, y, z), TestTag(), TestColor(1, 1, 1))
                        signatureA_entities[i] = e
                        signatureA_expected[e] = {x, y, z}
                    end

                    -- Spawn signature B entities with z=10
                    for i = 1, 10 do
                        local x = 300 + i * 10
                        local y = 400 + i * 20
                        local z = 10 -- Circle-like entities have z=10 (red dots)
                        local e = w:spawn(Transform2D(x, y, z), TestColor(1, 0, 0))
                        signatureB_entities[i] = e
                        signatureB_expected[e] = {x, y, z}
                    end

                    w:enqueueCommit()

                    -- Verify signature A entities
                    for _, e in ipairs(signatureA_entities) do
                        local t = w:get(e, Transform2D)
                        luassert.is_not_nil(t, "Signature A entity should have Transform2D")
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
                        local t = w:get(e, Transform2D)
                        luassert.is_not_nil(t, "Signature B entity should have Transform2D")
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
                    w:enqueueCommit()
                end
            end
        )

        it(
            "handles many entities across multiple cycles",
            function()
                local w = tecs.ecs.newWorld()

                -- Run many cycles with many entities to stress test
                for cycle = 1, 10 do
                    local entities: {integer} = {}
                    local expected: {integer: {number, number, number}} = {}

                    for i = 1, 50 do
                        local x = cycle * 1000 + i
                        local y = cycle * 2000 + i * 2
                        local z = i % 5 -- Mix of z values
                        local e = w:spawn(Transform2D(x, y, z))
                        entities[i] = e
                        expected[e] = {x, y, z}
                    end
                    w:enqueueCommit()

                    -- Verify all entities
                    for _, e in ipairs(entities) do
                        local t = w:get(e, Transform2D)
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
                    w:enqueueCommit()
                end
            end
        )

        it(
            "verifies entity-to-component value consistency within same archetype",
            function()
                local w = tecs.ecs.newWorld()

                -- Spawn multiple entities with same component signature but different values
                -- This tests if values are correctly mapped to entities within the same archetype
                local entities: {integer} = {}
                local expected: {integer: {number, number, number}} = {}

                -- All entities have Transform2D + TestColor (same signature)
                for i = 1, 20 do
                    local x = i * 100
                    local y = i * 200
                    local z = i -- Each entity has unique z for easy identification
                    local e = w:spawn(Transform2D(x, y, z), TestColor(0.1 * i, 0.2 * i, 0.3 * i))
                    entities[i] = e
                    expected[e] = {x, y, z}
                end
                w:enqueueCommit()

                -- Verify each entity has its own values (not another entity's values)
                for idx, e in ipairs(entities) do
                    local t = w:get(e, Transform2D)
                    luassert.is_not_nil(t, "Entity " .. e .. " should have Transform2D")
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
                                            .. ") got Transform2D from entity "
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
                                    .. " has wrong Transform2D: expected ("
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
    "RelativeTransform2D hierarchy",
    function()
        local ChildOf <const> = tecs.ecs.ChildOf
        local RelativeTransform2D <const> = tecs.ecs.RelativeTransform2D
        local WorldImpl <const> = require("tecs.internal.world")

        -- Records, per update, whether the child's archetype had a dirty
        -- component column when the frame ended (the relative-transform
        -- system marks Transform2D when it recomputes).
        local function addDirtyProbe(w: tecs.World, child: integer): {boolean}
            local seen: {boolean} = {}
            w:addSystem({
                name = "TransformDirtyProbe",
                phase = tecs.ecs.phases.Last,
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
            "recomputes children when the parent moves and marks Transform2D dirty",
            function()
                local w = tecs.ecs.newWorld()
                local parent = w:spawn(Transform2D(100, 200, 0))
                local child = w:spawn(
                    Transform2D(0, 0, 0), RelativeTransform2D(10, 20, 0), ChildOf(parent) as tecs.ecs.Component
                )
                w:enqueueCommit()

                local seen = addDirtyProbe(w, child)

                w:update(1 / 60)
                luassert.equals(110, w:get(child, Transform2D).x)
                luassert.equals(220, w:get(child, Transform2D).y)

                w:update(1 / 60)
                luassert.is_false(seen[2], "an idle frame must skip the hierarchy walk")

                w:set(parent, Transform2D(500, 600, 0))
                w:update(1 / 60)
                luassert.equals(510, w:get(child, Transform2D).x)
                luassert.equals(620, w:get(child, Transform2D).y)
                luassert.is_true(seen[3], "a parent move must leave the child's Transform2D column dirty")
            end
        )

        it(
            "recomputes children when ChildOf retargets",
            function()
                local w = tecs.ecs.newWorld()
                local parent1 = w:spawn(Transform2D(100, 0, 0))
                local parent2 = w:spawn(Transform2D(1000, 0, 0))
                local child = w:spawn(
                    Transform2D(0, 0, 0), RelativeTransform2D(5, 0, 0), ChildOf(parent1) as tecs.ecs.Component
                )
                w:enqueueCommit()

                w:update(1 / 60)
                luassert.equals(105, w:get(child, Transform2D).x)

                w:update(1 / 60)

                -- Sparse retarget: no structural change, but the commit-time
                -- container mark must reopen the dirty gate.
                w:set(child, ChildOf(parent2) as tecs.ecs.Component)
                w:update(1 / 60)
                luassert.equals(1005, w:get(child, Transform2D).x)
            end
        )

        it(
            "carries hierarchy writes from Last into the next update",
            function()
                local w = tecs.ecs.newWorld()
                local parent1 = w:spawn(Transform2D(100, 0, 0))
                local parent2 = w:spawn(Transform2D(1000, 0, 0))
                local transformChild = w:spawn(
                    Transform2D(0, 0, 0), RelativeTransform2D(5, 0, 0), ChildOf(parent1) as tecs.ecs.Component
                )
                local relativeChild = w:spawn(
                    Transform2D(0, 0, 0), RelativeTransform2D(6, 0, 0), ChildOf(parent1) as tecs.ecs.Component
                )
                local relationshipChild = w:spawn(
                    Transform2D(0, 0, 0), RelativeTransform2D(7, 0, 0), ChildOf(parent1) as tecs.ecs.Component
                )
                w:enqueueCommit()

                w:update(1 / 60)
                luassert.equals(105, w:get(transformChild, Transform2D).x)
                luassert.equals(106, w:get(relativeChild, Transform2D).x)
                luassert.equals(107, w:get(relationshipChild, Transform2D).x)
                w:update(1 / 60)

                local wrote = false
                w:addSystem({
                    name = "LastHierarchyWriter",
                    phase = tecs.ecs.phases.Last,
                    run = function()
                        if not wrote then
                            wrote = true
                            w:set(parent1, Transform2D(500, 0, 0))
                            w:set(relativeChild, RelativeTransform2D(60, 0, 0))
                            w:set(relationshipChild, ChildOf(parent2) as tecs.ecs.Component)
                        end
                    end,
                })

                -- The hierarchy system has already run when Last writes.
                w:update(1 / 60)
                luassert.equals(105, w:get(transformChild, Transform2D).x)
                luassert.equals(106, w:get(relativeChild, Transform2D).x)
                luassert.equals(107, w:get(relationshipChild, Transform2D).x)

                -- End-of-update dirty carry must reopen the hierarchy gate.
                w:update(1 / 60)
                luassert.equals(505, w:get(transformChild, Transform2D).x)
                luassert.equals(560, w:get(relativeChild, Transform2D).x)
                luassert.equals(1007, w:get(relationshipChild, Transform2D).x)
            end
        )
    end
)
