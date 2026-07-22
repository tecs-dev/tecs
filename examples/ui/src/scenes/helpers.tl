--- Scene 4: Layout Helpers
--- Shows stackVertical, stackHorizontal, and measureContent patterns

local tecs <const> = require("tecs")
local gfx <const> = require("tecs2d.gfx")
local ui <const> = require("tecs2d.ui")
local common <const> = require("scenes.common")

local Transform <const> = tecs.builtins.Transform
local ChildOf <const> = tecs.builtins.ChildOf
local RelativeTransform <const> = tecs.builtins.RelativeTransform
local LayoutBox <const> = ui.LayoutBox
local Text <const> = gfx.Text

local record helpers is common.Scene
end

helpers.name = "Layout Helpers"

function helpers.setup(world: tecs.World, spawn: function(tecs.World, ...: tecs.Component): integer, WINDOW_WIDTH: number, _WINDOW_HEIGHT: number)
    -- Header
    common.header(world, spawn, WINDOW_WIDTH, "Layout Helpers")

    local yOffset = 64

    -- Vertical stack demo with top-left origin
    local vContainerW, vContainerH = 200, 280
    local vLabelX = 380
    local vContainerX, vContainerY = vLabelX - vContainerW/2, 140 + yOffset

    spawn(world,
        Transform(vLabelX, 100 + yOffset),
        Text(common.DEFAULT_FONT, "stackVertical()", common.SUBTITLE_SCALE),
        LayoutBox(Text),
        gfx.Color(0.8, 0.8, 0.8)
    )

    local vContainer = spawn(world,
        Transform(vContainerX, vContainerY),
        gfx.Rectangle(vContainerW, vContainerH),
        gfx.RoundedCorners(8),
        LayoutBox(gfx.Rectangle, nil, 0, 0),
        gfx.Color(0.15, 0.12, 0.20)
    )
    -- Border
    spawn(world,
        Transform(vContainerX, vContainerY, 0.5),
        gfx.Rectangle(vContainerW, vContainerH, 1),
        gfx.RoundedCorners(8),
        LayoutBox(gfx.Rectangle, nil, 0, 0),
        gfx.Color(0.4, 0.3, 0.5)
    )

    -- Children stacked vertically
    local vChildW, vChildH = 180, 45
    local vGap = 8
    local vChildren: {integer} = {}
    for i = 1, 5 do
        local child = spawn(world,
            Transform(0, 0, 1),
            ChildOf(vContainer),
            RelativeTransform.new({x = 10, y = 0, z = 1}),
            gfx.Rectangle(vChildW, vChildH),
            LayoutBox(vChildW, vChildH, 0, 0),  -- Fixed dimensions for stacking
            gfx.Color(0.4 + i * 0.08, 0.25, 0.55 + i * 0.05)
        )
        table.insert(vChildren, child)
    end
    ui.stackVertical(world, vChildren, vGap, 10)

    -- Horizontal stack demo
    local hContainerW, hContainerH = 400, 100
    local hLabelX = 840
    local hContainerX, hContainerY = hLabelX - hContainerW/2, 140 + yOffset

    spawn(world,
        Transform(hLabelX, 100 + yOffset),
        Text(common.DEFAULT_FONT, "stackHorizontal()", common.SUBTITLE_SCALE),
        LayoutBox(Text),
        gfx.Color(0.8, 0.8, 0.8)
    )

    local hContainer = spawn(world,
        Transform(hContainerX, hContainerY),
        gfx.Rectangle(hContainerW, hContainerH),
        gfx.RoundedCorners(8),
        LayoutBox(gfx.Rectangle, nil, 0, 0),
        gfx.Color(0.15, 0.12, 0.20)
    )
    -- Border
    spawn(world,
        Transform(hContainerX, hContainerY, 0.5),
        gfx.Rectangle(hContainerW, hContainerH, 1),
        gfx.RoundedCorners(8),
        LayoutBox(gfx.Rectangle, nil, 0, 0),
        gfx.Color(0.4, 0.3, 0.5)
    )

    -- Children stacked horizontally
    local hChildW, hChildH = 85, 80
    local hGap = 10
    local hChildren: {integer} = {}
    for i = 1, 4 do
        local child = spawn(world,
            Transform(0, 0, 1),
            ChildOf(hContainer),
            RelativeTransform.new({x = 0, y = 10, z = 1}),
            gfx.Rectangle(hChildW, hChildH),
            LayoutBox(hChildW, hChildH, 0, 0),  -- Fixed dimensions for stacking
            gfx.Color(0.3 + i * 0.08, 0.25, 0.5 + i * 0.08)
        )
        table.insert(hChildren, child)
    end
    ui.stackHorizontal(world, hChildren, hGap, 10)

    -- measureContent demo
    local mContainerW, mContainerH = 400, 220
    local mLabelX = 840
    local mContainerX, mContainerY = mLabelX - mContainerW/2, 296 + yOffset

    spawn(world,
        Transform(mLabelX, 276 + yOffset),
        Text(common.DEFAULT_FONT, "measureContent()", common.SUBTITLE_SCALE),
        LayoutBox(Text),
        gfx.Color(0.8, 0.8, 0.8)
    )

    local mContainer = spawn(world,
        Transform(mContainerX, mContainerY),
        gfx.Rectangle(mContainerW, mContainerH),
        gfx.RoundedCorners(8),
        LayoutBox(gfx.Rectangle, nil, 0, 0),
        gfx.Color(0.15, 0.12, 0.20)
    )
    -- Border
    spawn(world,
        Transform(mContainerX, mContainerY, 0.5),
        gfx.Rectangle(mContainerW, mContainerH, 1),
        gfx.RoundedCorners(8),
        LayoutBox(gfx.Rectangle, nil, 0, 0),
        gfx.Color(0.4, 0.3, 0.5)
    )

    -- Children at arbitrary positions
    local mChildW, mChildH = 80, 60
    local positions = {{20, 20}, {200, 50}, {100, 130}, {280, 100}}
    local mChildren: {integer} = {}
    for i, pos in ipairs(positions) do
        local child = spawn(world,
            Transform(0, 0, 1),
            ChildOf(mContainer),
            RelativeTransform.new({x = pos[1], y = pos[2], z = 1}),
            gfx.Rectangle(mChildW, mChildH),
            LayoutBox(mChildW, mChildH, 0, 0),  -- Fixed dimensions for measuring
            gfx.Color(0.5 + i * 0.08, 0.25, 0.45 + i * 0.08)
        )
        table.insert(mChildren, child)
    end

    -- Show calculated content dimensions
    local contentW, contentH = ui.measureContent(world, mChildren)
    spawn(world,
        Transform(mLabelX, 542 + yOffset),
        Text(common.DEFAULT_FONT, string.format("Content size: %dx%d px", contentW as integer, contentH as integer), common.SUBTITLE_SCALE),
        LayoutBox(Text),
        gfx.Color(0.8, 0.8, 0.8)
    )
end

return helpers
