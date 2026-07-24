require("busted")

local luassert <const> = require("luassert")
local tecs <const> = require("tecs")
local ui <const> = require("tecs2d.ui")

local ChildOf <const> = tecs.builtins.ChildOf
local RelativeTransform <const> = tecs.builtins.RelativeTransform
local Transform <const> = tecs.builtins.Transform
local FPS <const> = 1 / 60

local record Adjustable is tecs.Component
    width: number
    height: number
end

tecs.newComponent({
    name = "FitContentSpecAdjustable",
    container = Adjustable,
    fields = {"width", "height"},
    defaults = {0, 0},
})

local function setup(fit: ui.FitContent): tecs.World, integer
    local world = tecs.newWorld()
    world:addPlugin(ui.new({origin = "topLeft"}))
    local parent = world:spawn(
        Transform(0, 0),
        ui.LayoutBox(100, 50, 0, 0),
        Adjustable(100, 50),
        fit
    )
    world:spawn(
        Transform(0, 0),
        ChildOf(parent),
        RelativeTransform(5, 7),
        ui.LayoutBox(20, 10, 0, 0)
    )
    return world, parent
end

describe("ui.FitContent axes", function()
    it("fits width while preserving height", function()
        local world, parent = setup(ui.FitContent.new({
            padding = 2,
            fit = "width",
            adjust = Adjustable,
        }))

        world:update(FPS)

        local box = world:get(parent, ui.LayoutBox)
        local adjustable = world:get(parent, Adjustable)
        luassert.are.equal(24, box.width)
        luassert.are.equal(50, box.height)
        luassert.are.equal(24, adjustable.width)
        luassert.are.equal(50, adjustable.height)
    end)

    it("fits height while preserving width", function()
        local world, parent = setup(ui.FitContent.new({
            paddingTop = 3,
            paddingBottom = 4,
            fit = "height",
            adjust = Adjustable,
        }))

        world:update(FPS)

        local box = world:get(parent, ui.LayoutBox)
        local adjustable = world:get(parent, Adjustable)
        luassert.are.equal(100, box.width)
        luassert.are.equal(17, box.height)
        luassert.are.equal(100, adjustable.width)
        luassert.are.equal(17, adjustable.height)
    end)

    it("keeps the positional constructor fitting both axes", function()
        local world, parent = setup(ui.FitContent(1, Adjustable))

        world:update(FPS)

        local box = world:get(parent, ui.LayoutBox)
        luassert.are.equal(22, box.width)
        luassert.are.equal(12, box.height)
    end)

    it("rejects unknown fit modes", function()
        luassert.has_error(function()
            ui.FitContent.new({fit = "depth" as any})
        end, "FitContent: fit must be both, width, or height")
    end)
end)
