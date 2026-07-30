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

-- A consumer opts a component into `valueCount` by setting this on it, which is
-- what extraction does for the columns a row is drawn from.
local Counted = tecs.ecs.newComponent({
    name = "ComponentDirtySpecCounted",
    container = {},
    fields = {"n"},
})
local countedInternal <const> = Counted as internal.ComponentInternal
countedInternal.valueCounted = true

local function clearDirty(arch: tecs.ecs.Archetype)
    (arch as internal.ArchetypeInternal):clearDirtyComponents()
end

local function findArchetype(world: tecs.World, components: {tecs.ecs.Component}): tecs.ecs.Archetype
    -- forEachArchetype to avoid leaking a query scope (see
    -- project_query_iter_scope_trap memory).
    local match: tecs.ecs.Archetype = nil
    world:forEachArchetype(function(arch: tecs.ecs.Archetype)
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
            "structural residue",
            function()
                -- `isComponentDirty` answers for a structural change and a
                -- value write together, which is what every consumer reads.
                -- These are the other half: the rows a structural change wrote,
                -- so a consumer that can rewrite one row does not have to
                -- rewrite the column.
                local function inner(arch: tecs.ecs.Archetype): internal.ArchetypeInternal
                    return arch as internal.ArchetypeInternal
                end

                it(
                    "counts a structural change and not a value write",
                    function()
                        local world = tecs.ecs.newWorld()
                        local e = world:spawn(Pos(1, 2))
                        local arch = inner(findArchetype(world, {Pos}))
                        local afterSpawn = arch:structuralCount()
                        assert.is_true(afterSpawn > 0, "a placement is a structural change")

                        world:update(0)
                        world:set(e, Pos(3, 4))
                        assert.are.equal(
                            afterSpawn, arch:structuralCount(), "a value write moves no row, so it counts nothing"
                        )

                        world:update(0)
                        world:spawn(Pos(5, 6))
                        assert.is_true(arch:structuralCount() > afterSpawn, "and the next placement counts again")
                    end
                )

                it(
                    "names the appended rows as a suffix",
                    function()
                        local world = tecs.ecs.newWorld()
                        world:spawn(Pos(1, 1))
                        world:spawn(Pos(2, 2))
                        world:update(0)

                        local arch = inner(findArchetype(world, {Pos}))
                        local before = arch:structuralCount()
                        assert.are.equal(0, arch:structuralAdded(), "the frame-end clear closed the last window")

                        world:spawn(Pos(3, 3))
                        world:spawn(Pos(4, 4))

                        assert.is_true(arch:structuralDescribed(before))
                        assert.are.equal(3, arch:structuralAdded(), "the lowest row the two placements wrote")
                        local _, touched = arch:structuralTouched()
                        assert.are.equal(0, touched, "and no row already in the run moved")
                    end
                )

                it(
                    "names the row a swap-pop overwrote",
                    function()
                        local world = tecs.ecs.newWorld()
                        local a = world:spawn(Pos(1, 1))
                        world:spawn(Pos(2, 2))
                        world:spawn(Pos(3, 3))
                        world:update(0)

                        local arch = inner(findArchetype(world, {Pos}))
                        local before = arch:structuralCount()
                        world:despawn(a)

                        assert.is_true(arch:structuralDescribed(before))
                        assert.are.equal(0, arch:structuralAdded(), "nothing was appended")
                        local rows, touched = arch:structuralTouched()
                        assert.are.equal(1, touched)
                        assert.are.equal(1, rows[1], "the last row was moved down into row one")
                    end
                )

                it(
                    "names nothing for a pop from the end",
                    function()
                        -- The bytes at no row changed. What a consumer owes the
                        -- slot it gave up is to stop drawing it, which the
                        -- shorter run says on its own.
                        local world = tecs.ecs.newWorld()
                        world:spawn(Pos(1, 1))
                        local last = world:spawn(Pos(2, 2))
                        world:update(0)

                        local arch = inner(findArchetype(world, {Pos}))
                        local before = arch:structuralCount()
                        world:despawn(last)

                        assert.is_true(arch:structuralCount() > before, "the run still shortened")
                        assert.is_true(arch:structuralDescribed(before))
                        assert.are.equal(0, arch:structuralAdded())
                        local _, touched = arch:structuralTouched()
                        assert.are.equal(0, touched)
                    end
                )

                it(
                    "stops describing a window it overran",
                    function()
                        local world = tecs.ecs.newWorld()
                        local ids: {integer} = {}
                        for index = 1, 400 do
                            ids[index] = world:spawn(Pos(index, index))
                        end
                        world:update(0)

                        local arch = inner(findArchetype(world, {Pos}))
                        local before = arch:structuralCount()
                        -- The lowest rows, so each removal swaps the run's last
                        -- row down rather than popping from the end.
                        for index = 1, 200 do
                            world:despawn(ids[index])
                        end

                        assert.is_false(
                            arch:structuralDescribed(before), "past the window's ceiling the rows stop being named"
                        )
                        assert.is_true(
                            arch:isComponentDirty(Pos), "and the column is still dirty, which is what consumers read"
                        )
                    end
                )

                it(
                    "stops describing a count from before the window opened",
                    function()
                        local world = tecs.ecs.newWorld()
                        world:spawn(Pos(1, 1))
                        world:update(0)

                        local arch = inner(findArchetype(world, {Pos}))
                        local stale = arch:structuralCount()

                        -- A structural change the frame-end clear then closes
                        -- the window over: a reader holding `stale` never saw
                        -- the rows it wrote and must not be told the residue
                        -- covers them.
                        world:spawn(Pos(2, 2))
                        world:update(0)

                        assert.is_false(arch:structuralDescribed(stale))
                        assert.is_true(arch:structuralDescribed(arch:structuralCount()))
                    end
                )

                it(
                    "stops describing a window markAllComponentsDirty was called in",
                    function()
                        -- The only way the surface lets a caller announce a raw
                        -- write to every row of every column, so it must not
                        -- read as the rows the placements before it wrote.
                        local world = tecs.ecs.newWorld()
                        world:spawn(Pos(1, 1))
                        world:update(0)

                        local arch = findArchetype(world, {Pos})
                        local before = inner(arch):structuralCount()
                        arch:markAllComponentsDirty()

                        assert.is_true(arch:isComponentDirty(Pos))
                        assert.is_false(inner(arch):structuralDescribed(before))
                    end
                )

                it(
                    "marks the placement after clearEntities",
                    function()
                        -- The structural flag is what a reader composes, so
                        -- leaving it set through a clear made the next
                        -- placement's mark short-circuit and say nothing.
                        local world = tecs.ecs.newWorld()
                        world:spawn(Pos(1, 1))
                        world:clearEntities()

                        world:spawn(Pos(2, 2))
                        local arch = findArchetype(world, {Pos})
                        assert.is_true(arch:isComponentDirty(Pos), "a placement after a clear is still a placement")
                        assert.are.equal(1, inner(arch):structuralAdded())
                    end
                )
            end
        )

        describe(
            "counted value writes",
            function()
                -- The value analogue of the structural count above, and it
                -- exists for the same reader: one whose work runs before the
                -- frame's later phases and whose copy of the columns therefore
                -- outlives the frame the dirty bits belong to.
                local function inner(arch: tecs.ecs.Archetype): internal.ArchetypeInternal
                    return arch as internal.ArchetypeInternal
                end

                it(
                    "counts a write to a counted column and not to an uncounted one",
                    function()
                        local world = tecs.ecs.newWorld()
                        local e = world:spawn(Counted(1), Pos(1, 2))
                        local arch = inner(findArchetype(world, {Counted, Pos}))

                        local before = arch:valueCount()
                        world:set(e, Pos(3, 4))
                        assert.are.equal(before, arch:valueCount(), "nobody asked for Pos to be counted")

                        world:set(e, Counted(2))
                        assert.is_true(arch:valueCount() > before, "and somebody asked for this one")
                    end
                )

                it(
                    "counts every write rather than the first of a frame",
                    function()
                        -- The dirty bit is set by the first write and stays set
                        -- until the frame ends, so a count deduplicated against
                        -- it would not move for the second write. A reader that
                        -- ran between the two is owed exactly that difference.
                        local world = tecs.ecs.newWorld()
                        local e = world:spawn(Counted(1))
                        local arch = inner(findArchetype(world, {Counted}))

                        local before = arch:valueCount()
                        world:getMut(e, Counted).n = 2
                        local between = arch:valueCount()
                        world:getMut(e, Counted).n = 3

                        assert.is_true(between > before, "the first write counts")
                        assert.is_true(arch:valueCount() > between, "and so does the second")
                    end
                )

                it(
                    "counts a placement as structure rather than as a value",
                    function()
                        local world = tecs.ecs.newWorld()
                        world:spawn(Counted(1))
                        local arch = inner(findArchetype(world, {Counted}))
                        world:update(0)

                        local before = arch:valueCount()
                        world:spawn(Counted(2))
                        assert.are.equal(before, arch:valueCount(), "a placement names rows, not columns")
                        assert.is_true(arch:structuralCount() > 0, "which is what the structural count answers for")
                    end
                )

                it(
                    "outlives the frame the write was made in",
                    function()
                        -- What the dirty bits cannot do. A reader samples the
                        -- count, a write lands after it, and the frame's clear
                        -- takes the bit away: the count still differs, so the
                        -- reader is told on its next pass instead of never.
                        local world = tecs.ecs.newWorld()
                        local e = world:spawn(Counted(1))
                        local arch = inner(findArchetype(world, {Counted}))
                        world:update(0)

                        local sampled = arch:valueCount()
                        world:getMut(e, Counted).n = 2
                        world:update(0)

                        assert.is_false(arch:isComponentDirty(Counted), "the frame took the bit")
                        assert.is_true(arch:valueCount() > sampled, "and left the count")
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

                        local seen: {tecs.ecs.Component: boolean} = {}
                        for comp in arch:dirtyComponents() do
                            seen[comp] = true
                        end

                        assert.is_true(seen[Pos as tecs.ecs.Component], "Pos should appear in dirty iterator")
                        assert.is_nil(seen[Vel as tecs.ecs.Component], "Vel should NOT appear in dirty iterator")
                    end
                )
            end
        )
    end
)
