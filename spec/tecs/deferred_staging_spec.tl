require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")

-- Components exclusive to this spec to avoid cross-spec collisions.
local Shared = tecs.newComponent({
    name = "DeferStageShared",
    container = {},
    fields = {"v"},
    defaults = {0},
})

local Extra = tecs.newComponent({
    name = "DeferStageExtra",
    container = {},
    fields = {"e"},
    defaults = {0},
})

local Absent = tecs.newComponent({
    name = "DeferStageAbsent",
    container = {},
    fields = {"a"},
    defaults = {0},
})

describe("deferred staging", function()
    describe("set-path column cache", function()
        it("routes a set correctly after a remove touched another archetype", function()
            local w = tecs.newWorld()
            -- e1 lives in archetype {Shared}; e2 in archetype {Shared, Extra}.
            local e1 = w:spawn(Shared(11))
            local e2 = w:spawn(Shared(22), Extra(1))
            w:commit()

            w:defer()
            -- Caches ( {Shared} archetype, Shared, its column ).
            w:set(e1, Shared(100))
            -- Remove of a component e2's archetype lacks; must not pair the
            -- {Shared, Extra} archetype with the cached {Shared} column.
            w:remove(e2, Absent)
            -- Same-archetype value update for e2.
            w:set(e2, Shared(200))
            w:commit()

            luassert.equals(100, w:get(e1, Shared).v)
            luassert.equals(200, w:get(e2, Shared).v)
        end)

        it("routes a set correctly after a remove staged a structural move", function()
            local w = tecs.newWorld()
            local e1 = w:spawn(Shared(11))
            local e2 = w:spawn(Shared(22), Extra(1))
            w:commit()

            w:defer()
            w:set(e1, Shared(100))
            -- Structural remove staging a move out of {Shared, Extra}.
            w:remove(e2, Extra)
            w:set(e2, Shared(200))
            w:commit()

            luassert.equals(100, w:get(e1, Shared).v)
            luassert.equals(200, w:get(e2, Shared).v)
            luassert.is_nil(w:get(e2, Extra))
        end)
    end)
end)
