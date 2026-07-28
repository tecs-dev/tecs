-- Component-dirty contract for the post-row-dirty model.
--
-- Replaces row-level `_dirtyBits` / `_allDirty` / `markDirty(row)` with
-- a per-archetype, per-component dirty bitset. The signal is set by:
--   1. `archetype:getMut(Foo)` -- explicit intent at access site
--   2. spawn / archetype move-in / swap-pop -- structural changes
--   3. `world:set` / `archetype:set` -- value writes
--   4. `archetype:markComponentDirty(Foo)` / `markAllComponentsDirty()` -- explicit
--
-- And cleared by `world:update` at end of frame.
--
-- This file IS the migration's contract. Phase 1 makes every assertion
-- pass; phase 3's API removals must not break any of them.

local tecs <const> = require("tecs")
local internal <const> = require("tecs.internal.types")

local Pos = tecs.ecs.newComponent({
    name = "ComponentDirtySpecPos",
    container = {},
    fields = {"x", "y"},
})
local Vel = tecs.ecs.newComponent({
    name = "ComponentDirtySpecVel",
    container = {},
    fields = {"dx", "dy"},
})
local Tag = tecs.ecs.newTagComponent({name = "ComponentDirtySpecTag"})

local function clearDirty(arch: tecs.Archetype)
    (arch as internal.ArchetypeInternal):clearDirtyComponents()
end

local function findArchetype(world: tecs.World, components: {tecs.Component}): tecs.Archetype
    -- forEachArchetype to avoid leaking a query scope (see
    -- project_query_iter_scope_trap memory).
    local match: tecs.Archetype = nil
    world:forEachArchetype(function(arch: tecs.Archetype)
        if match ~= nil then
            return
        end
        if ((arch as {string: any}).entities as {integer})[0] == 0 then
            return
        end
        for i = 1, #components do
            if (arch as {string: any}):get(components[i]) == nil then
                return
            end
        end
        match = arch
    end)
    return match
end

describe(
    "component-dirty contract",
    function()
        describe(
            "access primitives",
            function()
                it(
                    "archetype:get(Foo) does not mark Foo dirty",
                    function()
                        local world = tecs.ecs.newWorld()
                        world:spawn(Pos(1, 2))
                        world:update(0) -- clear dirty from spawn

                        local arch = findArchetype(world, {Pos})
                        local _ = arch:get(Pos)

                        assert.is_false(arch:isComponentDirty(Pos))
                    end
                )

                it(
                    "archetype:getMut(Foo) marks Foo dirty",
                    function()
                        local world = tecs.ecs.newWorld()
                        world:spawn(Pos(1, 2))
                        world:update(0)

                        local arch = findArchetype(world, {Pos})
                        local _ = arch:getMut(Pos)

                        assert.is_true(arch:isComponentDirty(Pos))
                    end
                )

                it(
                    "getMut(Foo) does NOT mark other components dirty",
                    function()
                        local world = tecs.ecs.newWorld()
                        world:spawn(Pos(1, 2), Vel(0, 0))
                        world:update(0)

                        local arch = findArchetype(world, {Pos, Vel})
                        local _ = arch:getMut(Pos)

                        assert.is_true(arch:isComponentDirty(Pos))
                        assert.is_false(arch:isComponentDirty(Vel))
                    end
                )

                it(
                    "repeated getMut(Foo) is idempotent",
                    function()
                        local world = tecs.ecs.newWorld()
                        world:spawn(Pos(1, 2))
                        world:update(0)

                        local arch = findArchetype(world, {Pos})
                        local _ = arch:getMut(Pos)
                        local _ = arch:getMut(Pos)
                        local _ = arch:getMut(Pos)

                        assert.is_true(arch:isComponentDirty(Pos))
                    end
                )

                it(
                    "archetype:get(Foo) returns the same column as archetype:getMut(Foo)",
                    function()
                        -- Same underlying storage; the difference is the dirty mark.
                        local world = tecs.ecs.newWorld()
                        world:spawn(Pos(1, 2))

                        local arch = findArchetype(world, {Pos})
                        local readCol = arch:get(Pos)
                        local writeCol = arch:getMut(Pos)

                        assert.is_equal(readCol, writeCol)
                    end
                )
            end
        )

        describe(
            "structural change marks all components dirty",
            function()
                it(
                    "spawn into a new archetype marks every component on it dirty",
                    function()
                        local world = tecs.ecs.newWorld()
                        world:spawn(Pos(1, 2), Vel(3, 4))

                        local arch = findArchetype(world, {Pos, Vel})
                        assert.is_true(arch:isComponentDirty(Pos), "Pos should be dirty after spawn")
                        assert.is_true(arch:isComponentDirty(Vel), "Vel should be dirty after spawn")
                    end
                )

                it(
                    "archetype move-in marks every component on the destination dirty",
                    function()
                        -- Spawn into Pos archetype, then add Tag -- that's a move-in
                        -- to {Pos, Tag} archetype.
                        local world = tecs.ecs.newWorld()
                        local e = world:spawn(Pos(1, 2))
                        world:update(0) -- clear dirty from initial spawn

                        world:set(e, Tag)

                        local destArch = findArchetype(world, {Pos, Tag})
                        assert.is_not_nil(destArch)
                        assert.is_true(
                            destArch:isComponentDirty(Pos), "Pos should be dirty on destination archetype after move-in"
                        )
                    end
                )

                it(
                    "swap-pop on entity removal marks every component on the source dirty",
                    function()
                        local world = tecs.ecs.newWorld()
                        local a = world:spawn(Pos(1, 1))
                        local _b = world:spawn(Pos(2, 2))
                        local _c = world:spawn(Pos(3, 3))
                        world:update(0) -- clear dirty

                        world:despawn(a)

                        local arch = findArchetype(world, {Pos})
                        assert.is_not_nil(arch)
                        assert.is_true(
                            arch:isComponentDirty(Pos), "swap-pop changes the surviving rows' bytes; Pos must be dirty"
                        )
                    end
                )
            end
        )

        describe(
            "value writes mark the affected component dirty",
            function()
                it(
                    "world:set on existing component marks it dirty",
                    function()
                        local world = tecs.ecs.newWorld()
                        local e = world:spawn(Pos(1, 2), Vel(0, 0))
                        world:update(0)

                        world:set(e, Pos(99, 99))

                        local arch = findArchetype(world, {Pos, Vel})
                        assert.is_true(arch:isComponentDirty(Pos), "world:set Pos should mark Pos dirty")
                        assert.is_false(arch:isComponentDirty(Vel), "world:set Pos should NOT mark Vel dirty")
                    end
                )

                it(
                    "archetype:set marks the affected component dirty",
                    function()
                        local world = tecs.ecs.newWorld()
                        world:spawn(Pos(1, 2), Vel(0, 0))
                        world:update(0)

                        local arch = findArchetype(world, {Pos, Vel})
                        arch:set(1, Pos(99, 99))

                        assert.is_true(arch:isComponentDirty(Pos))
                        assert.is_false(arch:isComponentDirty(Vel))
                    end
                )
            end
        )

        describe(
            "clearing",
            function()
                it(
                    "world:update clears component-dirty bitsets at end of frame",
                    function()
                        local world = tecs.ecs.newWorld()
                        world:spawn(Pos(1, 2))
                        local arch = findArchetype(world, {Pos})
                        assert.is_true(arch:isComponentDirty(Pos))

                        world:update(0)

                        assert.is_false(
                            arch:isComponentDirty(Pos), "post-pipeline clear should reset every archetype's dirty bits"
                        )
                    end
                )

                it(
                    "the internal clear clears every bit",
                    function()
                        local world = tecs.ecs.newWorld()
                        world:spawn(Pos(1, 2), Vel(0, 0))
                        local arch = findArchetype(world, {Pos, Vel})

                        clearDirty(arch)

                        assert.is_false(arch:isComponentDirty(Pos))
                        assert.is_false(arch:isComponentDirty(Vel))
                    end
                )
            end
        )

        describe(
            "explicit marking helpers",
            function()
                it(
                    "archetype:markComponentDirty sets the bit for that component only",
                    function()
                        local world = tecs.ecs.newWorld()
                        world:spawn(Pos(1, 2), Vel(0, 0))
                        local arch = findArchetype(world, {Pos, Vel})
                        clearDirty(arch)

                        arch:markComponentDirty(Pos)

                        assert.is_true(arch:isComponentDirty(Pos))
                        assert.is_false(arch:isComponentDirty(Vel))
                    end
                )

                it(
                    "world:markComponentDirty ignores a stale entity handle",
                    function()
                        local world = tecs.ecs.newWorld()
                        local stale = world:spawn(Pos(1, 2))
                        world:despawn(stale)
                        local fresh = world:spawn(Pos(3, 4))
                        world:update(0)

                        local arch = findArchetype(world, {Pos})
                        assert.is_true(world:isAlive(fresh))
                        assert.is_false(arch:isComponentDirty(Pos))

                        world:markComponentDirty(stale, Pos)

                        assert.is_false(
                            arch:isComponentDirty(Pos),
                            "a recycled handle must not dirty the replacement entity's archetype"
                        )
                    end
                )

                it(
                    "archetype:markAllComponentsDirty sets every component's bit",
                    function()
                        local world = tecs.ecs.newWorld()
                        world:spawn(Pos(1, 2), Vel(0, 0))
                        local arch = findArchetype(world, {Pos, Vel})
                        clearDirty(arch)

                        arch:markAllComponentsDirty()

                        assert.is_true(arch:isComponentDirty(Pos))
                        assert.is_true(arch:isComponentDirty(Vel))
                    end
                )
            end
        )

        describe(
            "world:dirtyArchetypes membership",
            function()
                it(
                    "an archetype with any component dirty is in world:dirtyArchetypes",
                    function()
                        local world = tecs.ecs.newWorld()
                        world:spawn(Pos(1, 2))

                        local arch = findArchetype(world, {Pos})
                        local found = false
                        for a in world:dirtyArchetypes() do
                            if a == arch then
                                found = true
                            end
                        end
                        assert.is_true(found, "archetype with dirty Pos should appear in world:dirtyArchetypes")
                    end
                )

                it(
                    "world:update clears the dirty-archetype set",
                    function()
                        local world = tecs.ecs.newWorld()
                        world:spawn(Pos(1, 2))
                        world:update(0)

                        local count = 0
                        for _ in world:dirtyArchetypes() do
                            count = count + 1
                        end
                        assert.equals(0, count, "dirty-archetype set should be empty after world:update")
                    end
                )
            end
        )

        describe(
            "dirtyComponents iterator",
            function()
                it(
                    "yields exactly the components currently marked dirty",
                    function()
                        local world = tecs.ecs.newWorld()
                        world:spawn(Pos(1, 2), Vel(0, 0))
                        local arch = findArchetype(world, {Pos, Vel})
                        clearDirty(arch)

                        arch:markComponentDirty(Pos)
                        -- Vel intentionally not marked.

                        local seen: {tecs.Component: boolean} = {}
                        for comp in arch:dirtyComponents() do
                            seen[comp] = true
                        end

                        assert.is_true(seen[Pos as tecs.Component], "Pos should appear in dirty iterator")
                        assert.is_nil(seen[Vel as tecs.Component], "Vel should NOT appear in dirty iterator")
                    end
                )
            end
        )
    end
)
