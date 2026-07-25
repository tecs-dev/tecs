--- Scene 1: Origin Comparison
--- Shows the difference between centered (0.5, 0.5) and top-left (0, 0) origins

local tecs <const> = require("tecs")
local gfx <const> = require("tecs2d.gfx")
local ui <const> = require("tecs2d.ui")
local common <const> = require("scenes.common")

local Transform <const> = tecs.builtins.Transform
local LayoutBox <const> = ui.LayoutBox
local Text <const> = gfx.Text

local record origin is common.Scene
end

origin.name = "Origin Comparison"

function origin.setup(world: tecs.World, WINDOW_WIDTH: number, _WINDOW_HEIGHT: number)
    -- Column positions (centered with labels, 1280px window)
    local col1, col2, col3 = 450, 710, 970
    local row1, row2 = 272, 472  -- Shifted down

    -- Gray grid lines (z=-1 to render behind shapes)
    local gridColor: gfx.Color = gfx.Color(0.25, 0.25, 0.28)

    -- Vertical grid lines at each column (from just above row1 to below row2)
    local gridTop = 258
    local gridBottom = row2 + 128
    local gridHeight = gridBottom - gridTop
    local gridCenterY = (gridTop + gridBottom) / 2
    world:spawn( Transform(col1, gridCenterY, -1), gfx.Rectangle(2, gridHeight), LayoutBox(gfx.Rectangle), gridColor)
    world:spawn( Transform(col2, gridCenterY, -1), gfx.Rectangle(2, gridHeight), LayoutBox(gfx.Rectangle), gridColor)
    world:spawn( Transform(col3, gridCenterY, -1), gfx.Rectangle(2, gridHeight), LayoutBox(gfx.Rectangle), gridColor)

    -- Horizontal grid lines at each row
    world:spawn( Transform((col1 + col3) / 2, row1, -1), gfx.Rectangle(col3 - col1 + 100, 2), LayoutBox(gfx.Rectangle), gridColor)
    world:spawn( Transform((col1 + col3) / 2, row2, -1), gfx.Rectangle(col3 - col1 + 100, 2), LayoutBox(gfx.Rectangle), gridColor)

    -- Header
    common.header(world, WINDOW_WIDTH, "Origin Comparison", "Red dots mark the Transform position")

    -- Row labels
    local labelX = 230
    world:spawn(
        Transform(labelX, 252),
        Text(common.DEFAULT_FONT, "Centered", common.TITLE_SCALE),
        LayoutBox(Text),
        gfx.Color(1, 1, 1)  -- White
    )
    world:spawn(
        Transform(labelX, 287),
        Text(common.DEFAULT_FONT, "(0.5, 0.5)", common.SUBTITLE_SCALE),
        LayoutBox(Text),
        gfx.Color(0.6, 0.6, 0.6)
    )

    world:spawn(
        Transform(labelX, 452),
        Text(common.DEFAULT_FONT, "Top-Left", common.TITLE_SCALE),
        LayoutBox(Text),
        gfx.Color(1, 1, 1)  -- White
    )
    world:spawn(
        Transform(labelX, 487),
        Text(common.DEFAULT_FONT, "(0, 0)", common.SUBTITLE_SCALE),
        LayoutBox(Text),
        gfx.Color(0.6, 0.6, 0.6)
    )

    -- Column headers (shifted down 12px)
    world:spawn( Transform(col1, 172), Text(common.DEFAULT_FONT, "Rectangle", common.SUBTITLE_SCALE), LayoutBox(Text), gfx.Color(0.8, 0.8, 0.8))
    world:spawn( Transform(col2, 172), Text(common.DEFAULT_FONT, "Circle", common.SUBTITLE_SCALE), LayoutBox(Text), gfx.Color(0.8, 0.8, 0.8))
    world:spawn( Transform(col3, 172), Text(common.DEFAULT_FONT, "Text", common.SUBTITLE_SCALE), LayoutBox(Text), gfx.Color(0.8, 0.8, 0.8))

    -- ROW 1: Centered origin (0.5, 0.5) - default
    -- Red dots at Transform position
    world:spawn( Transform(col1, row1, 10), gfx.Circle(5), LayoutBox(gfx.Circle), gfx.Color(1, 0, 0))
    world:spawn( Transform(col2, row1, 10), gfx.Circle(5), LayoutBox(gfx.Circle), gfx.Color(1, 0, 0))
    world:spawn( Transform(col3, row1, 10), gfx.Circle(5), LayoutBox(gfx.Circle), gfx.Color(1, 0, 0))

    -- Shapes with centered origin (default)
    world:spawn( Transform(col1, row1), gfx.Rectangle(120, 80), LayoutBox(gfx.Rectangle), gfx.Color(0.4, 0.3, 0.6))
    world:spawn( Transform(col2, row1), gfx.Circle(45), LayoutBox(gfx.Circle), gfx.Color(0.4, 0.3, 0.6))
    world:spawn( Transform(col3, row1), Text(common.DEFAULT_FONT, "Hello!", common.TITLE_SCALE), LayoutBox(Text), gfx.Color(0.4, 0.3, 0.6))

    -- ROW 2: Top-left origin (0, 0) - Transform is at top-left corner of shapes
    -- Red dots at Transform position
    world:spawn( Transform(col1, row2, 10), gfx.Circle(5), LayoutBox(gfx.Circle), gfx.Color(1, 0, 0))
    world:spawn( Transform(col2, row2, 10), gfx.Circle(5), LayoutBox(gfx.Circle), gfx.Color(1, 0, 0))
    world:spawn( Transform(col3, row2, 10), gfx.Circle(5), LayoutBox(gfx.Circle), gfx.Color(1, 0, 0))

    -- Shapes with top-left origin (0, 0) - no manual offset needed!
    world:spawn( Transform(col1, row2), gfx.Rectangle(120, 80), LayoutBox(gfx.Rectangle, nil, 0, 0), gfx.Color(0.5, 0.3, 0.5))
    world:spawn( Transform(col2, row2), gfx.Circle(45), LayoutBox(gfx.Circle, nil, 0, 0), gfx.Color(0.5, 0.3, 0.5))
    world:spawn( Transform(col3, row2), Text(common.DEFAULT_FONT, "Hello!", common.TITLE_SCALE), LayoutBox(Text, nil, 0, 0), gfx.Color(0.5, 0.3, 0.5))

    -- Footer
    common.footer(world, WINDOW_WIDTH, _WINDOW_HEIGHT,
        "Centered: Transform is at visual center of shape",
        "Top-Left: Transform is at top-left corner of shape")
end

return origin
