require("busted")

local luassert <const> = require("luassert")
local tecs <const> = require("tecs")
local dirty <const> = require("tecs2d.ui.internal.dirty")

local record DirtyA is tecs.Component
    value: number
end

local record DirtyB is tecs.Component
    value: number
end

tecs.newComponent({
    name = "UiDirtySpecA",
    container = DirtyA,
    fields = {"value"},
    defaults = {0},
})

tecs.newComponent({
    name = "UiDirtySpecB",
    container = DirtyB,
    fields = {"value"},
    defaults = {0},
})

describe("ui layout dirty watches", function()
    it("distinguishes dirty columns on the same archetype", function()
        local world = tecs.newWorld()
        local aWatch = dirty.watch(world, "a", {DirtyA})
        local bWatch = dirty.watch(world, "b", {DirtyB})
        local entity = world:spawn(DirtyA(), DirtyB())

        -- The first update carries spawn dirtiness forward; the second
        -- closes both watches after the world settles.
        world:update(1 / 60)
        world:update(1 / 60)
        luassert.is_false(dirty.changed(world, aWatch))
        luassert.is_false(dirty.changed(world, bWatch))

        world:getMut(entity, DirtyA).value = 1
        luassert.is_true(dirty.changed(world, aWatch))
        luassert.is_false(dirty.changed(world, bWatch))
    end)
end)
