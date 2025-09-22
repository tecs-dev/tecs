--- Scene 2: Dynamic Dimensions
--- Shows LayoutBox pulling dimensions dynamically from render components,
--- and FitContent auto-sizing containers to fit their children.

local tecs <const> = require("tecs")
local gfx <const> = require("tecs2d.gfx")
local ui <const> = require("tecs2d.ui")
local common <const> = require("scenes.common")

local Transform <const> = tecs.builtins.Transform
local ChildOf <const> = tecs.builtins.ChildOf
local RelativeTransform <const> = tecs.builtins.RelativeTransform
local LayoutBox <const> = ui.LayoutBox
local FitContent <const> = ui.FitContent
local Text <const> = gfx.Text

local record dynamic is common.Scene
end

dynamic.name = "Dynamic Dimensions"

function dynamic.setup(world: tecs.World, spawn: function(tecs.World, ...: tecs.Component): integer, WINDOW_WIDTH: number, _WINDOW_HEIGHT: number)
    -- Header
    common.header(world, spawn, WINDOW_WIDTH, "Dynamic Dimensions",
        "LayoutBox pulls dimensions from components\nFitContent auto-sizes containers")

    -- Column positions for wider window
    local col1, col2, col3 = 220, 640, 1060

    -- LayoutBox demos
    spawn(world,
        Transform(col1, 240),
        Text(common.DEFAULT_FONT, "Rectangle", common.SUBTITLE_SCALE),
        LayoutBox(Text),
        gfx.Color(0.85, 0.55, 0.75)
    )

    local dynamicRect = spawn(world,
        Transform(col1, 340),
        gfx.Rectangle(100, 60),
        LayoutBox(gfx.Rectangle),
        gfx.Color(0.6, 0.3, 0.5)
    )

    spawn(world,
        Transform(col2, 240),
        Text(common.DEFAULT_FONT, "Circle", common.SUBTITLE_SCALE),
        LayoutBox(Text),
        gfx.Color(0.65, 0.55, 0.85)
    )

    local dynamicCircle = spawn(world,
        Transform(col2, 340),
        gfx.Circle(40),
        LayoutBox(gfx.Circle),
        gfx.Color(0.4, 0.3, 0.6)
    )

    spawn(world,
        Transform(col3, 240),
        Text(common.DEFAULT_FONT, "Text", common.SUBTITLE_SCALE),
        LayoutBox(Text),
        gfx.Color(0.75, 0.50, 0.90)
    )

    local dynamicText = spawn(world,
        Transform(col3, 340),
        Text(common.DEFAULT_FONT, "Hello!", 1.5),
        LayoutBox(Text),
        gfx.Color(0.5, 0.3, 0.7)
    )

    -- FitContent demo
    spawn(world,
        Transform(col2, 510),
        Text(common.DEFAULT_FONT, "FitContent - container grows with text", common.SUBTITLE_SCALE),
        LayoutBox(Text),
        gfx.Color(0.8, 0.8, 0.8)
    )

    -- Container that auto-sizes to fit its text child
    local fitContainer = spawn(world,
        Transform(col2, 620),
        gfx.Rectangle(0, 0),  -- size set by FitContent
        gfx.RoundedCorners(8),
        LayoutBox(gfx.Rectangle, nil, 0.5, 0.5),  -- centered origin
        FitContent(20, gfx.Rectangle),  -- 20px padding, adjust Rectangle
        gfx.Color(0.15, 0.12, 0.20)
    )
    -- Border (manually synced via animation system)
    local fitBorder = spawn(world,
        Transform(col2, 620, 0.5),
        gfx.Rectangle(0, 0, 1),  -- outline
        gfx.RoundedCorners(8),
        LayoutBox(gfx.Rectangle, nil, 0.5, 0.5),
        gfx.Color(0.4, 0.3, 0.5)
    )

    -- Child text that changes
    local fitText = spawn(world,
        Transform(0, 0, 1),
        ChildOf(fitContainer),
        RelativeTransform.new({x = 0, y = 0, z = 1}),
        Text(common.DEFAULT_FONT, "Fit!", common.SUBTITLE_SCALE),
        LayoutBox(Text),
        gfx.Color(0.9, 0.85, 0.95)
    )

    -- Store for animation
    world.resources["dynamicRect" as tecs.Key<integer>] = dynamicRect
    world.resources["dynamicCircle" as tecs.Key<integer>] = dynamicCircle
    world.resources["dynamicText" as tecs.Key<integer>] = dynamicText
    world.resources["fitContainer" as tecs.Key<integer>] = fitContainer
    world.resources["fitBorder" as tecs.Key<integer>] = fitBorder
    world.resources["fitText" as tecs.Key<integer>] = fitText

end

return dynamic
