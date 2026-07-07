require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")
local LayoutNode <const> = require("tecs2d.ui.internal.LayoutNode")
local LayoutBox <const> = require("tecs2d.ui.internal.LayoutBox")

local Transform <const> = tecs.builtins.Transform
local ChildOf <const> = tecs.builtins.ChildOf
local RelativeTransform <const> = tecs.builtins.RelativeTransform
local FPS <const> = 1 / 60

local function newWorldWithPlugin(): tecs.World
    local w = tecs.newWorld()
    -- LayoutBox's plugin provides the ui.RelativeTransform pass that
    -- rebuilds child transforms each frame; scroll offsets are applied
    -- on top of it (matching ui.plugin's composition order).
    LayoutBox.plugin(w)
    LayoutNode.plugin(w)
    return w
end

describe("ui.LayoutNode scroll", function()
    it("offsets RelativeTransform children by the scroll amount", function()
        local w = newWorldWithPlugin()
        local node = w:spawn(
            Transform(100, 100, 0, 1),
            LayoutBox(200, 200),
            LayoutNode(0, 30, 200, 400)
        )
        local child = w:spawn(
            Transform(0, 0, 0, 1),
            RelativeTransform(10, 20),
            ChildOf(node)
        )

        for _ = 1, 5 do
            w:update(FPS)
        end

        local t = w:get(child, Transform)
        -- Parent 100 + relative 20 - scroll 30 = 90, stable across frames.
        luassert.are.equal(90, t.y)
        luassert.are.equal(110, t.x)
    end)

    it("does not drift plain-Transform children frame over frame", function()
        local w = newWorldWithPlugin()
        local node = w:spawn(
            Transform(0, 0, 0, 1),
            LayoutBox(200, 200),
            LayoutNode(0, 10, 200, 400)
        )
        -- A child positioned manually, without RelativeTransform: the
        -- scroll system must leave it alone (an in-place subtraction
        -- would accumulate 10 px of drift per frame).
        local child = w:spawn(
            Transform(50, 50, 0, 1),
            ChildOf(node)
        )

        for _ = 1, 10 do
            w:update(FPS)
        end

        local t = w:get(child, Transform)
        luassert.are.equal(50, t.y, "plain-Transform child drifted under an ancestor scroll")
        luassert.are.equal(50, t.x)
    end)
end)
