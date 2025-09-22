--- Scene 3: Scrollable Container
--- Shows LayoutNode for scrolling and clipping

local tecs <const> = require("tecs")
local gfx <const> = require("tecs2d.gfx")
local ui <const> = require("tecs2d.ui")
local common <const> = require("scenes.common")

local Transform <const> = tecs.builtins.Transform
local ChildOf <const> = tecs.builtins.ChildOf
local RelativeTransform <const> = tecs.builtins.RelativeTransform
local LayoutBox <const> = ui.LayoutBox
local LayoutNode <const> = ui.LayoutNode
local Text <const> = gfx.Text

local record scrollable is common.Scene
end

scrollable.name = "Scrollable Container"

function scrollable.setup(world: tecs.World, spawn: function(tecs.World, ...: tecs.Component): integer, WINDOW_WIDTH: number, WINDOW_HEIGHT: number)
    -- Header
    common.header(world, spawn, WINDOW_WIDTH, "Scrollable Container (LayoutNode)")

    -- Container background (visually centered in window, using top-left origin)
    local containerW, containerH = 400, 400
    local containerX = (WINDOW_WIDTH - containerW) / 2  -- Visual left edge
    local containerY = 120  -- Visual top edge (below title)
    local contentHeight = 32 * 40 + 10  -- 32 items * 40px spacing + padding

    local container = spawn(world,
        Transform(containerX, containerY),
        gfx.Rectangle(containerW, containerH),  -- filled
        gfx.RoundedCorners(8),
        LayoutBox(gfx.Rectangle, nil, 0, 0),  -- top-left origin for child positioning
        gfx.Pivot(0, 0),
        LayoutNode(0, 0, containerW, contentHeight),
        gfx.Color(0.15, 0.12, 0.20)  -- Dark purple background
    )
    -- Border
    spawn(world,
        Transform(containerX, containerY, 0.5),
        gfx.Rectangle(containerW, containerH, 1),  -- outline
        gfx.RoundedCorners(8),
        LayoutBox(gfx.Rectangle, nil, 0, 0),  -- top-left origin
        gfx.Pivot(0, 0),
        gfx.Color(0.4, 0.3, 0.5)  -- Purple border
    )

    -- Add items to container (positioned relative to parent's visual top-left)
    local itemW, itemH = containerW - 20, 35
    local padding = 10
    local spacing = 40
    for i = 1, 32 do
        local x = padding  -- From left edge
        local y = padding + (i - 1) * spacing  -- From top edge
        local itemId = spawn(world,
            Transform(0, 0, 1),  -- z=1 to render above container
            ChildOf(container),
            RelativeTransform.new({x = x, y = y, z = 1}),
            gfx.Rectangle(itemW, itemH),
            LayoutBox(gfx.Rectangle, nil, 0, 0),  -- top-left origin
            gfx.Pivot(0, 0),
            gfx.Color(0.35 + (i % 3) * 0.08, 0.25, 0.45 + (i % 3) * 0.08)  -- Purple tones
        )

        spawn(world,
            Transform(0, 0, 2),  -- z=2 to render above item rectangle
            ChildOf(itemId),
            RelativeTransform.new({x = itemW / 2, y = itemH / 2, z = 1}),  -- center of item
            Text(common.DEFAULT_FONT, "Item " .. i, common.BODY_SCALE),
            LayoutBox(Text),  -- centered origin for text
            gfx.Color(1, 1, 1)
        )
    end

    -- Store container for scroll handling
    world.resources["scrollContainer" as tecs.Key<integer>] = container

    -- Footer
    common.footer(world, spawn, WINDOW_WIDTH, WINDOW_HEIGHT,
        "Use UP/DOWN arrows or mouse wheel to scroll",
        "Content is clipped to container bounds")
end

return scrollable
