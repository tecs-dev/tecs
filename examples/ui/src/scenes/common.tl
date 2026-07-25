--- Common scene utilities
--- Provides shared layout for titles, subheadings, and footers

local tecs <const> = require("tecs")
local gfx <const> = require("tecs2d.gfx")
local ui <const> = require("tecs2d.ui")

local Transform <const> = tecs.builtins.Transform
local LayoutBox <const> = ui.LayoutBox
local Anchor <const> = ui.Anchor
local Text <const> = gfx.Text

local record common
    -- Default font path (Press Start 2P, 18px base)
    DEFAULT_FONT: string

    -- Scale factors for different text sizes (base font is 18px)
    TITLE_SCALE: number      -- ~36px
    SUBTITLE_SCALE: number   -- ~24px
    BODY_SCALE: number       -- ~20px
    SMALL_SCALE: number      -- 18px

    -- Standard scene header: title + optional subtitle
    header: function(
        world: tecs.World,
        WINDOW_WIDTH: number,
        title: string,
        subtitle?: string
    )

    -- Standard scene footer: up to 2 lines of text
    footer: function(
        world: tecs.World,
        WINDOW_WIDTH: number,
        WINDOW_HEIGHT: number,
        line1: string,
        line2?: string
    )

    -- Scene interface type that all scenes should follow
    interface Scene
        name: string
        setup: function(world: tecs.World, WINDOW_WIDTH: number, WINDOW_HEIGHT: number)
    end
end

-- Default BMFont path
common.DEFAULT_FONT = "assets/press-start-2p.fnt"

-- Scale factors (base font is 18px, use 0.5 as small baseline)
common.SMALL_SCALE = 0.6
common.BODY_SCALE = 0.7
common.SUBTITLE_SCALE = 1.0
common.TITLE_SCALE = 1.0

function common.header(
    world: tecs.World,
    WINDOW_WIDTH: number,
    title: string,
    subtitle?: string
)
    -- Title (orange, larger)
    world:spawn(
        Transform(WINDOW_WIDTH / 2, 40),
        Text(common.DEFAULT_FONT, title, 1.5),
        LayoutBox(Text),
        gfx.Color(0.95, 0.65, 0.25)
    )

    -- Optional subtitle
    if subtitle then
        world:spawn(
            Transform(WINDOW_WIDTH / 2, 109),
            Text(common.DEFAULT_FONT, subtitle, common.SUBTITLE_SCALE),
            LayoutBox(Text),
            gfx.Color(0.7, 0.7, 0.7)
        )
    end
end

function common.footer(
    world: tecs.World,
    _WINDOW_WIDTH: number,
    _WINDOW_HEIGHT: number,
    line1: string,
    line2?: string
)
    world:spawn(
        Transform(0, 0),
        Anchor(0.5, 1, 0, -130),
        Text(common.DEFAULT_FONT, line1, common.SUBTITLE_SCALE),
        LayoutBox(Text),
        gfx.Color(0.7, 0.7, 0.7)
    )

    if line2 then
        world:spawn(
            Transform(0, 0),
            Anchor(0.5, 1, 0, -100),
            Text(common.DEFAULT_FONT, line2, common.SUBTITLE_SCALE),
            LayoutBox(Text),
            gfx.Color(0.7, 0.7, 0.7)
        )
    end
end

return common
