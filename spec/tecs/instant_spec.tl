-- Verification spec for the eager-by-default / auto-defer-during-query
-- behavior. Covers three scenarios:
--   * Plain mutations outside a query apply immediately.
--   * Mutations inside a `for arch, len in query:iter() do ... end`
--     loop stage until iteration finishes, preserving iterator safety.
--   * `world:defer()` / `world:commit()` scopes still work explicitly.

local tecs <const> = require("tecs")
local Pos = tecs.ecs.newComponent({
    name = "InstantSpecPos",
    container = {},
    fields = {"x", "y"},
})
local Mark = tecs.ecs.newTagComponent({name = "InstantSpecMark"})

describe(
    "eager mutation semantics",
    function()
        it(
            "applies world:set immediately outside any scope",
            function()
                local world = tecs.ecs.newWorld()
                local e = world:spawn(Pos(1, 2))
                world:set(e, Pos(10, 20))
                -- Eager: no explicit commit required before read.
                local p = world:get(e, Pos)
                assert.equals(10, p.x)
                assert.equals(20, p.y)
            end
        )

        it(
            "applies world:remove immediately outside any scope",
            function()
                local world = tecs.ecs.newWorld()
                local e = world:spawn(Pos(1, 2), Mark)
                assert.is_true(world:has(e, Mark))
                world:remove(e, Mark)
                assert.is_false(world:has(e, Mark))
            end
        )

        it(
            "applies world:spawn/despawn immediately outside any scope",
            function()
                local world = tecs.ecs.newWorld()
                local e = world:spawn(Pos(1, 2))
                assert.is_true(world:isAlive(e))
                world:despawn(e)
                assert.is_false(world:isAlive(e))
            end
        )

        it(
            "defers mutations made inside a query iteration",
            function()
                -- While iterating, world:set routes through the deferred
                -- transaction so the iterator's active-archetype list doesn't
                -- shift mid-loop. After the loop exits, the staged mutation
                -- applies automatically.
                local world = tecs.ecs.newWorld()
                local e1 = world:spawn(Pos(1, 1))
                local e2 = world:spawn(Pos(2, 2))
                local e3 = world:spawn(Pos(3, 3))
                local q = world:newQuery({include = {Pos}})

                local seen = {}
                for arch, len in q:iter() do
                    for i = 1, len do
                        local id = arch.entities[i]
                        seen[#seen + 1] = id
                        -- Adding Mark moves the entity to a different
                        -- archetype. Under eager semantics that would
                        -- invalidate the iterator; auto-defer makes it safe.
                        world:set(id, Mark)
                    end
                end

                -- All three entities were visited exactly once.
                assert.equals(3, #seen)
                -- After the loop, the deferred mutations drained.
                assert.is_true(world:has(e1, Mark))
                assert.is_true(world:has(e2, Mark))
                assert.is_true(world:has(e3, Mark))
            end
        )

        it(
            "honors explicit defer/commit scopes for structural changes",
            function()
                -- Per the design: value-only updates apply immediately even
                -- inside a defer scope (since writing to an existing column
                -- doesn't affect iteration safety). Only STRUCTURAL mutations
                -- (archetype transitions) defer. Use Mark-add to observe it.
                local world = tecs.ecs.newWorld()
                local e = world:spawn(Pos(1, 1))
                world:defer()
                world:set(e, Mark)
                assert.is_false(world:has(e, Mark), "Mark should not be applied yet")
                world:commit()
                assert.is_true(world:has(e, Mark), "Mark should be applied after commit")
            end
        )

        it(
            "nested defer requires balanced commits",
            function()
                local world = tecs.ecs.newWorld()
                local e = world:spawn(Pos(1, 1))
                world:defer()
                world:defer()
                world:set(e, Mark)
                world:commit() -- depth 2 → 1, no flush yet
                assert.is_false(world:has(e, Mark))
                world:commit() -- depth 1 → 0, flush
                assert.is_true(world:has(e, Mark))
            end
        )
    end
)
