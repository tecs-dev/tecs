-- Common utilities for Box2D physics scenes

local tecs = require("tecs")
local gfx = require("tecs2d.gfx")

local physics = require("tecs2d.physics")

local Transform = tecs.builtins.Transform
local Collider = physics.Collider
local StaticBody = physics.StaticBody

local record Label
    x: number
    y: number
    text: string
    r: number
    g: number
    b: number
end

local record common
    headerFont: love.graphics.Font
    subFont: love.graphics.Font
    bodyFont: love.graphics.Font

    -- Stored header/footer data for current scene
    headerTitle: string
    headerSubtitle: string
    footerLine1: string
    footerLine2: string

    -- Stored labels for current scene
    labels: {Label}
end

local WALL_THICKNESS <const> = 20
local WALL_COLOR <const> = { 0.3, 0.3, 0.35 }

function common.initFonts()
    if not common.headerFont then
        common.headerFont = love.graphics.newFont(28)
        common.subFont = love.graphics.newFont(16)
        common.bodyFont = love.graphics.newFont(18)
    end
end

-- Set header text for the current scene
function common.header(
    _world: tecs.World,
    _spawn: function(tecs.World, tecs.Component...): integer,
    _WINDOW_WIDTH: number,
    title: string,
    subtitle: string
)
    common.initFonts()
    common.headerTitle = title
    common.headerSubtitle = subtitle
    common.labels = {}  -- Clear labels for new scene
end

-- Add a label at the specified position
function common.addLabel(x: number, y: number, text: string, r: number, g: number, b: number)
    if not common.labels then
        common.labels = {}
    end
    table.insert(common.labels, { x = x, y = y, text = text, r = r, g = g, b = b })
end

-- Set footer text for the current scene
function common.footer(
    _world: tecs.World,
    _spawn: function(tecs.World, tecs.Component...): integer,
    _WINDOW_WIDTH: number,
    _WINDOW_HEIGHT: number,
    line1: string,
    line2: string
)
    common.initFonts()
    common.footerLine1 = line1
    common.footerLine2 = line2
end

-- Call this from a PostRender system to draw the header/footer
function common.renderText(WINDOW_WIDTH: number, WINDOW_HEIGHT: number)
    common.initFonts()

    -- Draw header
    if common.headerTitle then
        love.graphics.setFont(common.headerFont)
        love.graphics.setColor(0.9, 0.9, 0.95, 1)
        local titleW = common.headerFont:getWidth(common.headerTitle)
        love.graphics.print(common.headerTitle, WINDOW_WIDTH / 2 - titleW / 2, 26)
    end

    if common.headerSubtitle then
        love.graphics.setFont(common.subFont)
        love.graphics.setColor(0.6, 0.6, 0.65, 1)
        local subtitleW = common.subFont:getWidth(common.headerSubtitle)
        love.graphics.print(common.headerSubtitle, WINDOW_WIDTH / 2 - subtitleW / 2, 62)
    end

    -- Draw footer
    if common.footerLine1 then
        love.graphics.setFont(common.subFont)
        love.graphics.setColor(0.5, 0.5, 0.55, 1)
        local line1W = common.subFont:getWidth(common.footerLine1)
        love.graphics.print(common.footerLine1, WINDOW_WIDTH / 2 - line1W / 2, WINDOW_HEIGHT - 80)
    end

    if common.footerLine2 then
        local line2W = common.subFont:getWidth(common.footerLine2)
        love.graphics.print(common.footerLine2, WINDOW_WIDTH / 2 - line2W / 2, WINDOW_HEIGHT - 60)
    end

    -- Draw labels
    if common.labels then
        love.graphics.setFont(common.bodyFont)
        for _, label in ipairs(common.labels) do
            love.graphics.setColor(label.r, label.g, label.b, 1)
            local textW = common.bodyFont:getWidth(label.text)
            love.graphics.print(label.text, label.x - textW / 2, label.y - 9)
        end
    end
end

function common.walls(
    world: tecs.World,
    spawn: function(tecs.World, tecs.Component...): integer,
    WINDOW_WIDTH: number,
    WINDOW_HEIGHT: number
)
    local headerHeight = 100
    local footerHeight = 100
    local playHeight = WINDOW_HEIGHT - headerHeight - footerHeight
    local playWidth = WINDOW_WIDTH - WALL_THICKNESS * 2

    local topY = headerHeight + WALL_THICKNESS / 2
    local bottomY = WINDOW_HEIGHT - footerHeight - WALL_THICKNESS / 2
    local leftX = WALL_THICKNESS / 2
    local rightX = WINDOW_WIDTH - WALL_THICKNESS / 2

    -- Bottom wall
    spawn(world,
        Transform(WINDOW_WIDTH / 2, bottomY),
        Collider.new({ shape = "rectangle", width = playWidth, height = WALL_THICKNESS }),
        StaticBody(),
        gfx.Rectangle(playWidth, WALL_THICKNESS),
        gfx.RoundedCorners(2),
        gfx.Color(WALL_COLOR[1], WALL_COLOR[2], WALL_COLOR[3])
    )

    -- Top wall
    spawn(world,
        Transform(WINDOW_WIDTH / 2, topY),
        Collider.new({ shape = "rectangle", width = playWidth, height = WALL_THICKNESS }),
        StaticBody(),
        gfx.Rectangle(playWidth, WALL_THICKNESS),
        gfx.RoundedCorners(2),
        gfx.Color(WALL_COLOR[1], WALL_COLOR[2], WALL_COLOR[3])
    )

    -- Left wall
    spawn(world,
        Transform(leftX, WINDOW_HEIGHT / 2),
        Collider.new({ shape = "rectangle", width = WALL_THICKNESS, height = playHeight }),
        StaticBody(),
        gfx.Rectangle(WALL_THICKNESS, playHeight),
        gfx.RoundedCorners(2),
        gfx.Color(WALL_COLOR[1], WALL_COLOR[2], WALL_COLOR[3])
    )

    -- Right wall
    spawn(world,
        Transform(rightX, WINDOW_HEIGHT / 2),
        Collider.new({ shape = "rectangle", width = WALL_THICKNESS, height = playHeight }),
        StaticBody(),
        gfx.Rectangle(WALL_THICKNESS, playHeight),
        gfx.RoundedCorners(2),
        gfx.Color(WALL_COLOR[1], WALL_COLOR[2], WALL_COLOR[3])
    )
end

return common
