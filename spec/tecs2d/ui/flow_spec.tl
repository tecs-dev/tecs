require("busted")

local luassert <const> = require("luassert")
local tecs <const> = require("tecs")
local ui <const> = require("tecs2d.ui")

local ChildOf <const> = tecs.builtins.ChildOf
local RelativeTransform <const> = tecs.builtins.RelativeTransform
local Transform <const> = tecs.builtins.Transform
local FPS <const> = 1 / 60

local function newWorld(): tecs.World
    local world = tecs.newWorld()
    world:addPlugin(ui.new({origin = "topLeft"}))
    return world
end

local function spawnChild(
    world: tecs.World,
    parent: integer,
    width: number,
    height: number,
    order?: number,
    originX?: number,
    originY?: number
): integer
    if order ~= nil then
        return world:spawn(
            Transform(0, 0),
            ChildOf(parent),
            RelativeTransform(),
            ui.LayoutBox(width, height, originX or 0, originY or 0),
            ui.FlowOrder(order)
        )
    end
    return world:spawn(
        Transform(0, 0),
        ChildOf(parent),
        RelativeTransform(),
        ui.LayoutBox(width, height, originX or 0, originY or 0)
    )
end

describe("ui.Flow", function()
    it("arranges children by FlowOrder with entity ID as the tiebreaker", function()
        local world = newWorld()
        local parent = world:spawn(
            Transform(0, 0),
            ui.LayoutBox(100, 40, 0, 0),
            ui.Flow("right", 5)
        )
        local second = spawnChild(world, parent, 10, 10, 2)
        local first = spawnChild(world, parent, 20, 10, 1)

        world:update(FPS)

        local firstTransform = world:get(first, RelativeTransform)
        local secondTransform = world:get(second, RelativeTransform)
        luassert.are.equal(0, firstTransform.x)
        luassert.are.equal(25, secondTransform.x)
    end)

    it("wraps into rows and aligns children within each row", function()
        local world = newWorld()
        local parent = world:spawn(
            Transform(0, 0),
            ui.LayoutBox(100, 100, 0, 0),
            ui.Flow.new({
                direction = "right",
                wrap = "down",
                gap = 4,
                lineGap = 3,
                maxItems = 2,
                align = "center",
            })
        )
        local a = spawnChild(world, parent, 10, 10, 1)
        local b = spawnChild(world, parent, 20, 20, 2)
        local c = spawnChild(world, parent, 30, 8, 3)

        world:update(FPS)

        local at = world:get(a, RelativeTransform)
        local bt = world:get(b, RelativeTransform)
        local ct = world:get(c, RelativeTransform)
        luassert.are.equal(0, at.x)
        luassert.are.equal(5, at.y)
        luassert.are.equal(14, bt.x)
        luassert.are.equal(0, bt.y)
        luassert.are.equal(0, ct.x)
        luassert.are.equal(23, ct.y)
    end)

    it("wraps against a fixed parent extent when maxItems is omitted", function()
        local world = newWorld()
        local parent = world:spawn(
            Transform(0, 0),
            ui.LayoutBox(25, 100, 0, 0),
            ui.Flow.new({
                direction = "right",
                wrap = "down",
                gap = 5,
                lineGap = 2,
            })
        )
        local a = spawnChild(world, parent, 10, 10)
        local b = spawnChild(world, parent, 10, 10)
        local c = spawnChild(world, parent, 10, 10)

        world:update(FPS)

        luassert.are.equal(0, world:get(a, RelativeTransform).y)
        luassert.are.equal(0, world:get(b, RelativeTransform).y)
        luassert.are.equal(12, world:get(c, RelativeTransform).y)
    end)

    it("uses the final fitted origin and padding in the same update", function()
        local world = newWorld()
        local parent = world:spawn(
            Transform(0, 0),
            ui.LayoutBox(0, 0, 0.5, 0.5),
            ui.Flow("right", 5),
            ui.FitContent(4)
        )
        local a = spawnChild(world, parent, 10, 10, 1)
        local b = spawnChild(world, parent, 20, 20, 2)

        world:update(FPS)

        local box = world:get(parent, ui.LayoutBox)
        luassert.are.equal(43, box.width)
        luassert.are.equal(28, box.height)
        luassert.are.equal(-21.5, box.offsetX)
        luassert.are.equal(-14, box.offsetY)
        luassert.are.equal(-17.5, world:get(a, RelativeTransform).x)
        luassert.are.equal(-2.5, world:get(b, RelativeTransform).x)
    end)

    it("fits only the cross axis of a wrapped flow", function()
        local world = newWorld()
        local parent = world:spawn(
            Transform(0, 0),
            ui.LayoutBox(0, 50, 0, 0),
            ui.Flow.new({
                direction = "down",
                wrap = "right",
                gap = 5,
                lineGap = 7,
                maxItems = 2,
            }),
            ui.FitContent.new({fit = "width"})
        )
        spawnChild(world, parent, 10, 10, 1)
        spawnChild(world, parent, 10, 10, 2)
        spawnChild(world, parent, 10, 10, 3)

        world:update(FPS)

        local box = world:get(parent, ui.LayoutBox)
        luassert.are.equal(27, box.width)
        luassert.are.equal(50, box.height)
    end)

    it("rejects size-driven wrapping on an axis fitted by FitContent", function()
        local world = newWorld()
        local parent = world:spawn(
            Transform(0, 0),
            ui.LayoutBox(0, 40, 0, 0),
            ui.Flow.new({direction = "right", wrap = "down"}),
            ui.FitContent.new({fit = "width"})
        )
        spawnChild(world, parent, 10, 10)

        luassert.has_error(function()
            world:update(FPS)
        end, "Flow: size-driven wrapping requires a fixed main axis or maxItems")
    end)
end)
