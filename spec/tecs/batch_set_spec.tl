require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")

-- Components exclusive to this spec to avoid cross-spec collisions.
local Position = tecs.newComponent({
    name = "BatchSetTestPosition",
    container = {},
    fields = {"x", "y"},
    defaults = {0, 0},
})

local Velocity = tecs.newComponent({
    name = "BatchSetTestVelocity",
    container = {},
    fields = {"vx", "vy"},
    defaults = {0, 0},
})

local Tag = tecs.newTagComponent({name = "BatchSetTestTag"})
local OtherTag = tecs.newTagComponent({name = "BatchSetTestOtherTag"})

describe("world:batchSet()", function()
    describe("constant value form", function()
        it("writes the same value to every entity in-place when arch already has the component", function()
            local world = tecs.newWorld()
            local a = world:spawn(Position(1, 1), Tag)
            local b = world:spawn(Position(2, 2), Tag)
            local c = world:spawn(Position(3, 3), Tag)
            world:commit()

            local q = world:query({include = {Tag}})
            world:batchSet(q, Position(99, 99))
            world:commit()

            luassert.equals(99, world:get(a, Position).x)
            luassert.equals(99, world:get(b, Position).x)
            luassert.equals(99, world:get(c, Position).x)
            luassert.equals(99, world:get(a, Position).y)
        end)

        it("bulk-moves entities that lacked the component (structural add)", function()
            local world = tecs.newWorld()
            local a = world:spawn(Tag)
            local b = world:spawn(Tag)
            world:commit()

            luassert.is_nil(world:get(a, Position))
            luassert.is_nil(world:get(b, Position))

            local q = world:query({include = {Tag}})
            world:batchSet(q, Position(5, 7))
            world:commit()

            luassert.equals(5, world:get(a, Position).x)
            luassert.equals(7, world:get(a, Position).y)
            luassert.equals(5, world:get(b, Position).x)
        end)

        it("leaves non-matching entities untouched", function()
            local world = tecs.newWorld()
            local tagged = world:spawn(Tag, Position(1, 1))
            local untagged = world:spawn(Position(2, 2))
            world:commit()

            local q = world:query({include = {Tag}})
            world:batchSet(q, Position(99, 99))
            world:commit()

            luassert.equals(99, world:get(tagged, Position).x)
            luassert.equals(2, world:get(untagged, Position).x)
        end)

        it("handles a mixed selector (some archetypes have component, some don't)", function()
            local world = tecs.newWorld()
            -- Archetype A: {Tag}
            local a = world:spawn(Tag)
            -- Archetype B: {Tag, Position}
            local b = world:spawn(Tag, Position(1, 1))
            world:commit()

            local q = world:query({include = {Tag}})
            world:batchSet(q, Position(42, 42))
            world:commit()

            luassert.equals(42, world:get(a, Position).x)
            luassert.equals(42, world:get(b, Position).x)
        end)

        it("works on a tag component (no value data)", function()
            local world = tecs.newWorld()
            local e1 = world:spawn(Position(1, 1))
            local e2 = world:spawn(Position(2, 2))
            world:commit()

            -- Apply Tag to every Position-carrying entity.
            local q = world:query({include = {Position}})
            world:batchSet(q, Tag)
            world:commit()

            -- Matched entities should now be in a Position+Tag archetype.
            local tagged = world:query({include = {Position, Tag}})
            local count = 0
            for _ in tagged:iter() do count = count + 1 end
            luassert.equals(1, count, "one merged archetype")
        end)

        it("accepts a query with include/exclude", function()
            local world = tecs.newWorld()
            local a = world:spawn(Position(1, 1), Tag)
            local b = world:spawn(Position(2, 2), Tag, OtherTag)
            world:commit()

            local q = world:query({include = {Tag}, exclude = {OtherTag}})
            world:batchSet(q, Position(50, 50))
            world:commit()

            luassert.equals(50, world:get(a, Position).x)
            luassert.equals(2, world:get(b, Position).x)
        end)

        it("no-ops when the query matches nothing", function()
            local world = tecs.newWorld()
            world:spawn(Position(1, 1))
            world:commit()

            local q = world:query({include = {OtherTag}})
            world:batchSet(q, Position(99, 99))
            world:commit()
        end)
    end)

    describe("callback form", function()
        it("invokes callback once per affected archetype with 1-based row range", function()
            local world = tecs.newWorld()
            for i = 1, 5 do
                world:spawn(Tag, Position(i, i))
            end
            world:commit()

            local calls = 0
            local seenFirst, seenLast, seenCount = 0, 0, 0
            local q = world:query({include = {Tag}})
            world:batchSet(q, Position, function(arch, firstRow, lastRow, count)
                calls = calls + 1
                seenFirst = firstRow
                seenLast = lastRow
                seenCount = count
                local col = arch:getMut(Position)
                for r = firstRow, lastRow do
                    local p = col[r]
                    p.x = 100
                    p.y = 200
                end
            end)
            world:commit()

            luassert.equals(1, calls, "single archetype, single call")
            luassert.equals(1, seenFirst)
            luassert.equals(5, seenLast)
            luassert.equals(5, seenCount)

            -- Verify the writes stuck.
            local qTagPos = world:query({include = {Tag, Position}})
            for arch, len in qTagPos:iter() do
                local col = arch:get(Position)
                for r = 1, len do
                    luassert.equals(100, col[r].x)
                    luassert.equals(200, col[r].y)
                end
            end
        end)

        it("structural add via callback populates the destination column", function()
            local world = tecs.newWorld()
            local a = world:spawn(Tag)
            local b = world:spawn(Tag)
            world:commit()

            -- Tag archetype lacks Position; the callback runs against the
            -- destination archetype. For table-storage components, new
            -- rows are nil until the callback assigns an instance -- the
            -- in-place `col[r].field = ...` mutation pattern is only
            -- safe for FFI columns (where the struct comes zero-init'd).
            local q = world:query({include = {Tag}})
            world:batchSet(q, Position, function(arch, firstRow, lastRow, _count)
                local col = arch:getMut(Position)
                for r = firstRow, lastRow do
                    col[r] = Position(r * 10, r * 20)
                end
            end)
            world:commit()

            -- Row ordering is stable: first-spawned at row 1, etc.
            luassert.equals(10, world:get(a, Position).x)
            luassert.equals(20, world:get(a, Position).y)
            luassert.equals(20, world:get(b, Position).x)
            luassert.equals(40, world:get(b, Position).y)
        end)
    end)

    describe("interaction with commit lifecycle", function()
        it("defers until commit when wrapped in world:defer()", function()
            local world = tecs.newWorld()
            local a = world:spawn(Position(1, 1), Tag)

            local q = world:query({include = {Tag}})
            world:defer()
            world:batchSet(q, Position(99, 99))
            -- Inside defer scope, the write hasn't happened.
            luassert.equals(1, world:get(a, Position).x)

            world:commit()
            luassert.equals(99, world:get(a, Position).x)
        end)

        it("applies immediately in eager mode (outside any defer scope)", function()
            local world = tecs.newWorld()
            local a = world:spawn(Position(1, 1), Tag)

            local q = world:query({include = {Tag}})
            world:batchSet(q, Position(99, 99))
            -- Eager default: the write applied synchronously.
            luassert.equals(99, world:get(a, Position).x)
        end)
    end)
end)

describe("world:batchRemove()", function()
    it("bulk-moves entities out of archetypes carrying the component", function()
        local world = tecs.newWorld()
        local a = world:spawn(Position(1, 1), Velocity(10, 20))
        local b = world:spawn(Position(2, 2), Velocity(30, 40))
        world:commit()

        luassert.is_not_nil(world:get(a, Velocity))
        local q = world:query({include = {Position}})
        world:batchRemove(q, Velocity)
        world:commit()

        luassert.is_nil(world:get(a, Velocity))
        luassert.is_nil(world:get(b, Velocity))
        -- Position stays.
        luassert.equals(1, world:get(a, Position).x)
        luassert.equals(2, world:get(b, Position).x)
    end)

    it("skips archetypes that don't carry the component", function()
        local world = tecs.newWorld()
        -- {Position} archetype (no Velocity)
        local a = world:spawn(Position(1, 1))
        -- {Position, Velocity} archetype
        local b = world:spawn(Position(2, 2), Velocity(5, 5))
        world:commit()

        -- Query matches BOTH archetypes via Position.
        local q = world:query({include = {Position}})
        world:batchRemove(q, Velocity)
        world:commit()

        luassert.is_nil(world:get(a, Velocity))  -- was never there
        luassert.is_nil(world:get(b, Velocity))  -- was removed
        luassert.equals(1, world:get(a, Position).x)
        luassert.equals(2, world:get(b, Position).x)
    end)

    it("no-ops when the query matches nothing", function()
        local world = tecs.newWorld()
        world:spawn(Position(1, 1))
        world:commit()
        local q = world:query({include = {OtherTag}})
        world:batchRemove(q, Velocity)
        world:commit()
    end)

    it("defers until commit when wrapped in world:defer()", function()
        local world = tecs.newWorld()
        local a = world:spawn(Position(1, 1), Velocity(1, 1))

        local q = world:query({include = {Velocity}})
        world:defer()
        world:batchRemove(q, Velocity)
        -- Inside defer, Velocity still present.
        luassert.is_not_nil(world:get(a, Velocity))

        world:commit()
        luassert.is_nil(world:get(a, Velocity))
    end)

    it("applies immediately in eager mode", function()
        local world = tecs.newWorld()
        local a = world:spawn(Position(1, 1), Velocity(1, 1))

        local q = world:query({include = {Velocity}})
        world:batchRemove(q, Velocity)
        -- Eager default: applied synchronously.
        luassert.is_nil(world:get(a, Velocity))
    end)
end)

describe("batch APIs reject non-query selectors", function()
    it("batchDespawn errors on a component array", function()
        local world = tecs.newWorld()
        world:spawn(Position(1, 1))
        world:commit()
        luassert.has_error(function()
            (world as any):batchDespawn({Position})
        end)
    end)

    it("batchSet errors on a component array", function()
        local world = tecs.newWorld()
        world:spawn(Tag, Position(1, 1))
        world:commit()
        luassert.has_error(function()
            (world as any):batchSet({Tag}, Position(99, 99))
        end)
    end)

    it("batchRemove errors on a QueryDescriptor", function()
        local world = tecs.newWorld()
        world:spawn(Position(1, 1), Velocity(1, 1))
        world:commit()
        luassert.has_error(function()
            (world as any):batchRemove({include = {Position}}, Velocity)
        end)
    end)
end)

describe("batchSet argument validation", function()
    it("rejects passing an instance when a callback is supplied", function()
        local world = tecs.newWorld()
        world:spawn(Tag, Position(1, 1))
        world:commit()
        local q = world:query({include = {Tag}})
        luassert.has_error(function()
            -- Mistake: instance as arg2 when also passing a callback.
            -- Must be the container (Position), not an instance.
            world:batchSet(q, Position(0, 0), function(_a, _f, _l, _c)
                -- body irrelevant, the precondition check fires first
            end)
        end)
    end)

end)
