require("busted")
local tecs <const> = require("tecs")
local ui <const> = require("tecs2d.ui")
local Pivot <const> = require("tecs2d.gfx.internal.Pivot")
local luassert <const> = require("luassert")

local Transform <const> = tecs.builtins.Transform

local function spawnBox(world: tecs.World, originX?: number, originY?: number): integer
    local box: ui.LayoutBox
    if originX == nil then
        box = ui.LayoutBox(100, 50)
    else
        box = ui.LayoutBox(100, 50, originX, originY)
    end
    return world:spawn(Transform(20, 30), box)
end

describe("ui.LayoutBox defaults", function()
    it("keeps defaults world-local and supplies the renderer pivot", function()
        local centered = tecs.newWorld()
        centered:addPlugin(ui.plugin)
        local centeredId = spawnBox(centered)

        local topLeft = tecs.newWorld()
        topLeft:addPlugin(ui.new({origin = "topLeft"}))
        local topLeftId = spawnBox(topLeft)

        -- LayoutBox requires Pivot, so both components arrive in the same
        -- spawn transition instead of adding Pivot during an update.
        luassert.is_not_nil(centered:get(centeredId, Pivot))
        luassert.is_not_nil(topLeft:get(topLeftId, Pivot))

        centered:update(1 / 60)
        topLeft:update(1 / 60)

        local centeredBox = centered:get(centeredId, ui.LayoutBox)
        local centeredPivot = centered:get(centeredId, Pivot)
        luassert.are.equal(0.5, centeredBox.originX)
        luassert.are.equal(0.5, centeredBox.originY)
        luassert.are.equal(-50, centeredBox.offsetX)
        luassert.are.equal(-25, centeredBox.offsetY)
        luassert.are.equal(0.5, centeredPivot.x)
        luassert.are.equal(0.5, centeredPivot.y)

        local topLeftBox = topLeft:get(topLeftId, ui.LayoutBox)
        local topLeftPivot = topLeft:get(topLeftId, Pivot)
        luassert.are.equal(0, topLeftBox.originX)
        luassert.are.equal(0, topLeftBox.originY)
        luassert.are.equal(0, topLeftBox.offsetX)
        luassert.are.equal(0, topLeftBox.offsetY)
        luassert.are.equal(0, topLeftPivot.x)
        luassert.are.equal(0, topLeftPivot.y)
    end)

    it("preserves an explicit origin in a top-left-default world", function()
        local world = tecs.newWorld()
        world:addPlugin(ui.new({origin = "topLeft"}))
        local id = spawnBox(world, 1, 0.5)
        world:update(1 / 60)

        local box = world:get(id, ui.LayoutBox)
        local pivot = world:get(id, Pivot)
        luassert.are.equal(1, box.originX)
        luassert.are.equal(0.5, box.originY)
        luassert.are.equal(-100, box.offsetX)
        luassert.are.equal(-25, box.offsetY)
        luassert.are.equal(1, pivot.x)
        luassert.are.equal(0.5, pivot.y)
    end)
end)
