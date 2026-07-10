--- Transform Demo
--- Demonstrates rotation, scale, and pivot for GPU-rendered drawable types
--- Simplified data-driven grid layout

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local SpriteSheet <const> = gfx.SpriteSheet
local input <const> = require("tecs2d.input")
local mcp <const> = require("tecs2d.mcp")

local lg <const> = love.graphics
local sin, pi <const> = math.sin, math.pi

local Text <const> = gfx.Text
local TextEffects <const> = gfx.TextEffects
local AdditiveBlend <const> = gfx.blend.AdditiveBlend
local FONT_PATH <const> = "assets/press-start-2p.fnt"
local MSDF_FONT <const> = "assets/firacode-nerd-msdf.json"


-- Rainbow material for Row 6 testing
local rainbowMat = gfx.newMaterial("rainbow", { fragment = "shaders/rainbow.glsl" })

-------------------------------------------------------------------------------
-- Grid Configuration
-------------------------------------------------------------------------------

local GRID <const> = {
    cols = 6,
    rows = 8,
    cellSize = 120,
}

local GRID_WIDTH <const> = GRID.cols * GRID.cellSize
local GRID_HEIGHT <const> = GRID.rows * GRID.cellSize

-- Grid is centered at origin
local function gridCenter(col: integer, row: integer): number, number
    local x = (col - 0.5 - GRID.cols / 2) * GRID.cellSize
    local y = (row - 0.5 - GRID.rows / 2) * GRID.cellSize
    return x, y
end

local function gridTopLeft(col: integer, row: integer): number, number
    local x = (col - 1 - GRID.cols / 2) * GRID.cellSize
    local y = (row - 1 - GRID.rows / 2) * GRID.cellSize
    return x, y
end

-------------------------------------------------------------------------------
-- Cell Definitions
-------------------------------------------------------------------------------

local record CellDef
    desc: string
    spawn: function(world: tecs.World, x: number, y: number)
end

local cells: {integer: {integer: CellDef}} = {}

local function defineCell(col: integer, row: integer, desc: string, spawn: function(world: tecs.World, x: number, y: number))
    if not cells[row] then cells[row] = {} end
    cells[row][col] = { desc = desc, spawn = spawn }
end

-------------------------------------------------------------------------------
-- Components
-------------------------------------------------------------------------------

local Transform <const> = tecs.builtins.Transform

local record AnimateTransform is tecs.Component
    rotationSpeed: number
    scaleSpeed: number
    scaleMin: number
    scaleMax: number
    phase: number

    metamethod __call: function(self, rotationSpeed: number, scaleSpeed: number, scaleMin: number, scaleMax: number, phase: number): AnimateTransform
end

tecs.newComponent({
    name = "AnimateTransform",
    container = AnimateTransform,
    fields = {"rotationSpeed", "scaleSpeed", "scaleMin", "scaleMax", "phase"},
    defaults = {0, 1, 0.5, 1.5, 0},
    init = function(instance: AnimateTransform)
        instance.rotationSpeed = instance.rotationSpeed or 0
        instance.scaleSpeed = instance.scaleSpeed or 1
        instance.scaleMin = instance.scaleMin or 0.5
        instance.scaleMax = instance.scaleMax or 1.5
        instance.phase = instance.phase or 0
    end
})

-- AnimateLineWidth: animate lineWidth on shape components
local record AnimateLineWidth is tecs.Component
    speed: number
    minWidth: number
    maxWidth: number
    phase: number

    metamethod __call: function(self, speed: number, minWidth: number, maxWidth: number, phase: number): AnimateLineWidth
end

tecs.newComponent({
    name = "AnimateLineWidth",
    container = AnimateLineWidth,
    fields = {"speed", "minWidth", "maxWidth", "phase"},
    defaults = {1, 1, 5, 0},
    init = function(instance: AnimateLineWidth)
        instance.speed = instance.speed or 1
        instance.minWidth = instance.minWidth or 1
        instance.maxWidth = instance.maxWidth or 5
        instance.phase = instance.phase or 0
    end
})

-------------------------------------------------------------------------------
-- Game
-------------------------------------------------------------------------------

local function transformDemoPlugin(world: tecs.World)
    world:addPlugin(mcp.new())
    world:addPlugin(require("tecs2d.debug").new())

    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline

    local runnerSheet = SpriteSheet.fromFile("assets/running.png")

    ---------------------------------------------------------------------------
    -- Shared Colors (vibrant, saturated)
    ---------------------------------------------------------------------------
    local COLOR_BLUE <const> = gfx.Color(0.3, 0.5, 1.0, 1.0)
    local COLOR_ORANGE <const> = gfx.Color(1.0, 0.4, 0.1, 1.0)
    local COLOR_GREEN <const> = gfx.Color(0.2, 0.85, 0.4, 1.0)
    local COLOR_YELLOW <const> = gfx.Color(0.9, 0.75, 0.1, 1.0)
    local COLOR_PURPLE <const> = gfx.Color(0.6, 0.3, 1.0, 1.0)
    local COLOR_PEACH <const> = gfx.Color(1.0, 0.5, 0.3, 1.0)
    local COLOR_PIVOT_MARKER <const> = gfx.Color(1, 1, 0, 1)
    local COLOR_GRID_LINE <const> = gfx.Color(0.35, 0.35, 0.55, 1.0)

    ---------------------------------------------------------------------------
    -- Focus Tracking
    ---------------------------------------------------------------------------
    local focusCol, focusRow = 0, 0  -- 0,0 = no focus
    local selectedDesc = "Click a cell to see its description"
    local highlightTransform: tecs.builtins.Transform

    ---------------------------------------------------------------------------
    -- Define Cell Contents
    -- Structure: Each row has a theme, column 6 shows blend modes
    ---------------------------------------------------------------------------

    -- Row 1: FILLED SHAPES - showcase each primitive type filled
    defineCell(1, 1, "Circle: basic filled circle", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Circle(35), COLOR_BLUE)
    end)
    defineCell(2, 1, "Ellipse: filled ellipse with non-uniform axes", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Ellipse(45, 28), COLOR_ORANGE)
    end)
    defineCell(3, 1, "Rectangle: filled rectangle", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Rectangle(55, 38), COLOR_GREEN)
    end)
    defineCell(4, 1, "Arc: filled 270 degree arc", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Arc(38, 38, 0, pi * 1.5), COLOR_YELLOW)
    end)
    defineCell(5, 1, "Sprite: animated character from sprite sheet", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 0.7, 0.7), gfx.Sprite.fromSheet(runnerSheet, "run", {centered = true}), gfx.Color(1, 1, 1, 1))
    end)
    defineCell(6, 1, "BLEND: Additive sprites - brighten when overlapping", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x - 2, y, 0, 1, 0, 2, 2), gfx.Sprite.fromSheet(runnerSheet, "run", {centered = true}), gfx.Color(1.0, 0.3, 0.3, 0.8), AdditiveBlend())
        w:spawn(Transform(x + 2, y, 0, 1, 0, 2, 2), gfx.Sprite.fromSheet(runnerSheet, "run", {centered = true}), gfx.Color(0.3, 0.3, 1.0, 0.8), AdditiveBlend())
    end)

    -- Row 2: OUTLINED SHAPES - showcase each primitive type as outline (line width pulsates)
    defineCell(1, 2, "Circle outline - pulsating stroke width", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Circle(35, 3), COLOR_BLUE, AnimateLineWidth(2, 1, 6, 0))
    end)
    defineCell(2, 2, "Ellipse outline - pulsating stroke", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Ellipse(45, 28, 3), COLOR_ORANGE, AnimateLineWidth(2, 1, 6, pi/3))
    end)
    defineCell(3, 2, "Rectangle outline - pulsating stroke", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Rectangle(55, 38, 3), COLOR_GREEN, AnimateLineWidth(2, 1, 6, 2*pi/3))
    end)
    defineCell(4, 2, "Arc outline - pulsating stroke", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Arc(38, 38, 0, pi * 1.5, 4), COLOR_YELLOW, AnimateLineWidth(2, 1, 8, pi))
    end)
    defineCell(5, 2, "Line segment - pulsating stroke", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Line(-40, -25, 40, 25, 5), COLOR_PURPLE, AnimateLineWidth(2, 2, 8, 4*pi/3))
    end)
    defineCell(6, 2, "BLEND: Additive outline - pulsating glow", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Circle(30, 6), gfx.Color(1.0, 0.8, 0.3, 0.9), AdditiveBlend(), AnimateLineWidth(1.5, 2, 10, 0))
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Circle(20, 4), gfx.Color(1.0, 0.5, 0.2, 0.7), AdditiveBlend(), AnimateLineWidth(1.5, 2, 8, pi))
    end)

    -- Row 3: SCALE ANIMATION - shapes only pulsing in size, no rotation
    defineCell(1, 3, "Circle pulsing scale 0.5x to 1.5x", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Circle(30), COLOR_BLUE, AnimateTransform(0, 2.0, 0.5, 1.5, 0))
    end)
    defineCell(2, 3, "Ellipse pulsing with phase offset", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Ellipse(40, 25), COLOR_ORANGE, AnimateTransform(0, 2.0, 0.5, 1.5, pi/2))
    end)
    defineCell(3, 3, "Rectangle breathing effect", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Rectangle(50, 35), COLOR_GREEN, AnimateTransform(0, 2.5, 0.4, 1.6, 0))
    end)
    defineCell(4, 3, "Arc pulsing open/close effect", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Arc(35, 35, 0, pi * 1.5), COLOR_YELLOW, AnimateTransform(0, 1.8, 0.6, 1.4, pi))
    end)
    defineCell(5, 3, "Sprite pulsing scale - grows and shrinks from center", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 0.6, 0.6), gfx.Sprite.fromSheet(runnerSheet, "run", {centered = true}), gfx.Color(1, 1, 1, 1), AnimateTransform(0, 2.0, 0.4, 1.0, 0))
    end)
    defineCell(6, 3, "BLEND: Additive pulsing glow", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Circle(25), gfx.Color(1.0, 0.6, 0.2, 0.9), AdditiveBlend(), AnimateTransform(0, 2.0, 0.6, 1.5, 0))
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Circle(35, 3), gfx.Color(1.0, 0.4, 0.1, 0.6), AdditiveBlend(), AnimateTransform(0, 2.0, 0.5, 1.6, pi))
    end)

    -- Row 4: ROTATION ANIMATION - shapes spinning, no scale change
    defineCell(1, 4, "Counter-rotating arcs", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Arc(35, 35, 0, pi * 1.2), COLOR_BLUE, AnimateTransform(1.5, 0, 1, 1, 0))
        w:spawn(Transform(x, y, pi, 1, 0, 1, 1), gfx.Arc(35, 35, 0, pi * 1.2), COLOR_ORANGE, AnimateTransform(-1.5, 0, 1, 1, 0))
    end)
    defineCell(2, 4, "Ellipse rotating to show axis orientation", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Ellipse(45, 25), COLOR_ORANGE, AnimateTransform(1.2, 0, 1, 1, 0))
    end)
    defineCell(3, 4, "Rectangle spinning continuously", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Rectangle(50, 35), COLOR_GREEN, AnimateTransform(1.0, 0, 1, 1, 0))
    end)
    defineCell(4, 4, "Arc rotating like a radar sweep", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Circle(35, 2), gfx.Color(0.5, 0.5, 0.6, 0.8))
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Arc(35, 35, 0, pi * 0.4), COLOR_YELLOW, AnimateTransform(2.0, 0, 1, 1, 0))
    end)
    defineCell(5, 4, "Sprite rotating continuously", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 0.6, 0.6), gfx.Sprite.fromSheet(runnerSheet, "run", {centered = true}), gfx.Color(1, 1, 1, 1), AnimateTransform(1.5, 0, 1, 1, 0))
    end)
    defineCell(6, 4, "BLEND: Rotating additive star burst", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Rectangle(60, 8), gfx.Color(1.0, 0.8, 0.3, 0.7), AdditiveBlend(), AnimateTransform(1.0, 0, 1, 1, 0))
        w:spawn(Transform(x, y, pi/3, 1, 0, 1, 1), gfx.Rectangle(60, 8), gfx.Color(1.0, 0.5, 0.2, 0.7), AdditiveBlend(), AnimateTransform(1.0, 0, 1, 1, 0))
        w:spawn(Transform(x, y, 2*pi/3, 1, 0, 1, 1), gfx.Rectangle(60, 8), gfx.Color(1.0, 0.3, 0.1, 0.7), AdditiveBlend(), AnimateTransform(1.0, 0, 1, 1, 0))
    end)

    -- Row 5: PIVOT POINTS - demonstrate rotation around different pivot locations
    defineCell(1, 5, "Pivot TOP-LEFT (0,0): orbits around corner", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Rectangle(45, 30), gfx.Pivot(0, 0), gfx.Color(1.0, 0.7, 0.8, 1.0), AnimateTransform(1.2, 0, 1, 1, 0))
        w:spawn(Transform(x, y, 0, 2, 0, 1, 1), gfx.Circle(6), COLOR_PIVOT_MARKER)
    end)
    defineCell(2, 5, "Pivot BOTTOM-RIGHT (1,1): orbits around corner", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Rectangle(45, 30), gfx.Pivot(1, 1), COLOR_GREEN, AnimateTransform(1.2, 0, 1, 1, 0))
        w:spawn(Transform(x, y, 0, 2, 0, 1, 1), gfx.Circle(6), COLOR_PIVOT_MARKER)
    end)
    defineCell(3, 5, "Ellipse with right-edge pivot (1.0, 0.5)", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Ellipse(40, 25), gfx.Pivot(1.0, 0.5), COLOR_PEACH, AnimateTransform(1.2, 0, 1, 1, 0))
        w:spawn(Transform(x, y, 0, 2, 0, 1, 1), gfx.Circle(6), COLOR_PIVOT_MARKER)
    end)
    defineCell(4, 5, "Arc with top-left pivot (0, 0)", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Arc(35, 35, 0, pi * 1.2), gfx.Pivot(0, 0), COLOR_PURPLE, AnimateTransform(1.2, 0, 1, 1, 0))
        w:spawn(Transform(x, y, 0, 2, 0, 1, 1), gfx.Circle(6), COLOR_PIVOT_MARKER)
    end)
    defineCell(5, 5, "Sprite with top-middle pivot rotation", function(w: tecs.World, x: number, y: number)
        -- GPU-rendered sprite rotating with top-middle pivot (pivotX=0.5, pivotY=0)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Circle(6), COLOR_PIVOT_MARKER)
        w:spawn(Transform(x, y, 0, 2, 0, 0.5, 0.5), gfx.Sprite.fromSheet(runnerSheet, "run", {centered = false, pivotX = 0.5, pivotY = 0}), gfx.Color(1, 1, 1, 1), AnimateTransform(1.2, 0, 1, 1, 0))
    end)
    defineCell(6, 5, "BLEND: Rotating additive rectangle", function(w: tecs.World, x: number, y: number)
        -- Centered rotation to avoid culling bounds issues
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Rectangle(45, 20), gfx.Color(0.3, 1.0, 0.5, 0.8), AdditiveBlend(), AnimateTransform(1.2, 0, 1, 1, 0))
        w:spawn(Transform(x, y, 0, 2, 0, 1, 1), gfx.Circle(5), COLOR_PIVOT_MARKER)
    end)

    -- Row 6: MATERIALS - each shape type with rainbow cycling material
    defineCell(1, 6, "MATERIAL: Circle with rainbow color cycling", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Circle(35), gfx.Color(1, 1, 1, 1), rainbowMat)
    end)
    defineCell(2, 6, "MATERIAL: Ellipse with rainbow color cycling", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Ellipse(45, 28), gfx.Color(1, 1, 1, 1), rainbowMat)
    end)
    defineCell(3, 6, "MATERIAL: Rectangle with rainbow color cycling", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Rectangle(55, 38), gfx.Color(1, 1, 1, 1), rainbowMat)
    end)
    defineCell(4, 6, "MATERIAL: Arc with rainbow color cycling", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Arc(38, 38, 0, pi * 1.5), gfx.Color(1, 1, 1, 1), rainbowMat)
    end)
    defineCell(5, 6, "MATERIAL: Line with rainbow color cycling", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), gfx.Line(-40, -25, 40, 25, 8), gfx.Color(1, 1, 1, 1), rainbowMat)
    end)
    defineCell(6, 6, "MATERIAL: Sprite with rainbow color cycling", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 0.7, 0.7), gfx.Sprite.fromSheet(runnerSheet, "run", {centered = true}), gfx.Color(1, 1, 1, 1), rainbowMat)
    end)

    -- Row 7: BITMAP TEXT - various text rendering demonstrations
    defineCell(1, 7, "Text: basic text rendering", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), Text(FONT_PATH, "Hello", 1.0), gfx.Color(1, 1, 1, 1))
    end)
    defineCell(2, 7, "Text: colored rotating text", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), Text(FONT_PATH, "Spin!", 1.0), COLOR_ORANGE, AnimateTransform(1.5, 0, 1, 1, 0))
    end)
    defineCell(3, 7, "Text: rotating around pivot (0,0)", function(w: tecs.World, x: number, y: number)
        -- Text with pivot (0,0) rotates around top-left corner - marker shows the pivot point
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), Text(FONT_PATH, "Orbit", 1.0), gfx.Pivot(0, 0), COLOR_PURPLE, AnimateTransform(1.2, 0, 1, 1, 0))
        w:spawn(Transform(x, y, 0, 2, 0, 1, 1), gfx.Circle(6), COLOR_PIVOT_MARKER)
    end)
    defineCell(4, 7, "Text: pulsing scale animation", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), Text(FONT_PATH, "Pulse", 1.0), COLOR_GREEN, AnimateTransform(0, 2.0, 0.7, 1.2, 0))
    end)
    defineCell(5, 7, "MATERIAL: Text with rainbow material", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), Text(FONT_PATH, "Shade", 1.0), gfx.Color(1, 1, 1, 1), rainbowMat)
    end)
    defineCell(6, 7, "BLEND: Additive Text glow", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x - 8, y, 0, 1, 0, 1, 1), Text(FONT_PATH, "Glow", 1.0), gfx.Color(1.0, 0.5, 0.2, 0.9), AdditiveBlend())
        w:spawn(Transform(x + 8, y, 0, 1, 0, 1, 1), Text(FONT_PATH, "Glow", 1.0), gfx.Color(0.2, 0.5, 1.0, 0.9), AdditiveBlend())
    end)

    -- Row 8: MSDF TEXT - SDF text with effects (outline, glow, shadow)
    defineCell(1, 8, "MSDF: basic SDF text rendering", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), Text(MSDF_FONT, "Hello", 0.5), gfx.Color(1, 1, 1, 1))
    end)
    defineCell(2, 8, "MSDF: outline effect around text", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), Text(MSDF_FONT, "Edge", 0.5),
            gfx.Color(1, 1, 1, 1),
            TextEffects.new({ outline = { width = 0.15, color = {0, 0, 0, 1} } }))
    end)
    defineCell(3, 8, "MSDF: glow effect on text", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), Text(MSDF_FONT, "Glow", 0.5),
            gfx.Color(1, 1, 1, 1),
            TextEffects.new({ glow = { radius = 1.0, color = {0, 1, 0.2, 1.0} } }))
    end)
    defineCell(4, 8, "MSDF: shadow effect on text", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), Text(MSDF_FONT, "Drop", 0.5),
            gfx.Color(1, 1, 1, 1),
            TextEffects.new({ shadow = { offset = {3, 3}, blur = 0.05, color = {0, 0, 0, 0.8} } }))
    end)
    defineCell(5, 8, "MATERIAL: MSDF text with rainbow material", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x, y, 0, 1, 0, 1, 1), Text(MSDF_FONT, "Rain", 0.5),
            gfx.Color(1, 1, 1, 1), rainbowMat)
    end)
    defineCell(6, 8, "BLEND: Additive MSDF text (two overlapping)", function(w: tecs.World, x: number, y: number)
        w:spawn(Transform(x - 4, y, 0, 1, 0, 1, 1), Text(MSDF_FONT, "Neon", 0.5),
            gfx.Color(1.0, 0.5, 0.2, 0.9), AdditiveBlend())
        w:spawn(Transform(x + 4, y, 0, 1, 0, 1, 1), Text(MSDF_FONT, "Neon", 0.5),
            gfx.Color(0.2, 0.5, 1.0, 0.9), AdditiveBlend())
    end)

    ---------------------------------------------------------------------------
    -- World Background (layer 1, z=-40: furthest back)
    ---------------------------------------------------------------------------
    world:spawn(
        Transform(0, 0, -40, 1, 0, 1, 1),
        gfx.Rectangle(2000, 2000),
        gfx.Color(0.12, 0.12, 0.18, 1.0)
    )

    ---------------------------------------------------------------------------
    -- Gray Background for Column 6 (layer 1, z=-30)
    ---------------------------------------------------------------------------
    local bgX, bgY = gridTopLeft(6, 1)
    world:spawn(
        Transform(bgX, bgY, -30, 1, 0, 1, 1),
        gfx.Rectangle(GRID.cellSize, GRID_HEIGHT),
        gfx.Pivot(0, 0),
        gfx.Color(0.2, 0.2, 0.25, 1.0)
    )

    ---------------------------------------------------------------------------
    -- Draw Grid Lines (layer 1, z=-20)
    ---------------------------------------------------------------------------

    local gridLeft = -GRID_WIDTH / 2
    local gridTop = -GRID_HEIGHT / 2

    for col = 0, GRID.cols do
        local x = gridLeft + col * GRID.cellSize
        world:spawn(
            Transform(x, 0, -20, 1, 0, 1, 1),
            gfx.Line(0, -GRID_HEIGHT/2, 0, GRID_HEIGHT/2, 2),
            COLOR_GRID_LINE
        )
    end

    for row = 0, GRID.rows do
        local y = gridTop + row * GRID.cellSize
        world:spawn(
            Transform(0, y, -20, 1, 0, 1, 1),
            gfx.Line(-GRID_WIDTH/2, 0, GRID_WIDTH/2, 0, 2),
            COLOR_GRID_LINE
        )
    end

    ---------------------------------------------------------------------------
    -- Cell Highlight (layer 1, z=-10)
    ---------------------------------------------------------------------------
    highlightTransform = Transform(-9999, -9999, -10, 1, 0, 1, 1)
    world:spawn(
        highlightTransform,
        gfx.Rectangle(GRID.cellSize, GRID.cellSize),
        gfx.Pivot(0, 0),
        gfx.Color(0.4, 0.4, 0.5, 0.4)
    )

    ---------------------------------------------------------------------------
    -- Spawn All Cells
    ---------------------------------------------------------------------------

    for row = 1, GRID.rows do
        for col = 1, GRID.cols do
            local cellDef = cells[row] and cells[row][col]
            if cellDef then
                local x, y = gridCenter(col, row)
                cellDef.spawn(world, x, y)
            end
        end
    end

    ---------------------------------------------------------------------------
    -- Systems
    ---------------------------------------------------------------------------

    local animQuery = world:query({
        name = "AnimatedTransforms",
        include = {Transform, AnimateTransform}
    })

    -- Queries for each shape type that can have animated line width
    local circleAnimQuery = world:query({
        name = "AnimatedCircleLineWidth",
        include = {gfx.Circle, AnimateLineWidth}
    })
    local ellipseAnimQuery = world:query({
        name = "AnimatedEllipseLineWidth",
        include = {gfx.Ellipse, AnimateLineWidth}
    })
    local rectAnimQuery = world:query({
        name = "AnimatedRectLineWidth",
        include = {gfx.Rectangle, AnimateLineWidth}
    })
    local arcAnimQuery = world:query({
        name = "AnimatedArcLineWidth",
        include = {gfx.Arc, AnimateLineWidth}
    })
    local lineAnimQuery = world:query({
        name = "AnimatedLineWidth",
        include = {gfx.Line, AnimateLineWidth}
    })

    local time = 0.0

    world:addSystem({
        name = "AnimateTransforms",
        phase = tecs.phases.Update,
        run = function(dt: number)
            time = time + dt
            for archetype, len in animQuery:iter() do
                local transforms = archetype:getMut(Transform)
                local anims = archetype:get(AnimateTransform)
                for i = 1, len do
                    local transform = transforms[i]
                    local anim = anims[i]
                    if anim.rotationSpeed ~= 0 then
                        transform.rotation = transform.rotation + anim.rotationSpeed * dt
                    end
                    if anim.scaleSpeed ~= 0 then
                        local scaleT = (sin(time * anim.scaleSpeed + anim.phase) + 1) * 0.5
                        local scale = anim.scaleMin + scaleT * (anim.scaleMax - anim.scaleMin)
                        transform.scaleX = scale
                        transform.scaleY = scale
                    end
                end
            end
        end
    })

    -- Animate circle lineWidth (requires dirty marking)
    world:addSystem({
        name = "AnimateCircleLineWidth",
        phase = tecs.phases.Update,
        run = function()
            for archetype, len in circleAnimQuery:iter() do
                local circles = archetype:getMut(gfx.Circle)
                local anims = archetype:get(AnimateLineWidth)
                for i = 1, len do
                    local circle = circles[i]
                    local anim = anims[i]
                    local t = (sin(time * anim.speed + anim.phase) + 1) * 0.5
                    circle.lineWidth = anim.minWidth + t * (anim.maxWidth - anim.minWidth)
                end
            end
        end
    })

    -- Animate ellipse lineWidth (requires dirty marking)
    world:addSystem({
        name = "AnimateEllipseLineWidth",
        phase = tecs.phases.Update,
        run = function()
            for archetype, len in ellipseAnimQuery:iter() do
                local ellipses = archetype:getMut(gfx.Ellipse)
                local anims = archetype:get(AnimateLineWidth)
                for i = 1, len do
                    local ellipse = ellipses[i]
                    local anim = anims[i]
                    local t = (sin(time * anim.speed + anim.phase) + 1) * 0.5
                    ellipse.lineWidth = anim.minWidth + t * (anim.maxWidth - anim.minWidth)
                end
            end
        end
    })

    -- Animate rectangle lineWidth (requires dirty marking)
    world:addSystem({
        name = "AnimateRectLineWidth",
        phase = tecs.phases.Update,
        run = function()
            for archetype, len in rectAnimQuery:iter() do
                local rectangles = archetype:getMut(gfx.Rectangle)
                local anims = archetype:get(AnimateLineWidth)
                for i = 1, len do
                    local rectangle = rectangles[i]
                    local anim = anims[i]
                    local t = (sin(time * anim.speed + anim.phase) + 1) * 0.5
                    rectangle.lineWidth = anim.minWidth + t * (anim.maxWidth - anim.minWidth)
                end
            end
        end
    })

    -- Animate arc lineWidth (requires dirty marking)
    world:addSystem({
        name = "AnimateArcLineWidth",
        phase = tecs.phases.Update,
        run = function()
            for archetype, len in arcAnimQuery:iter() do
                local arcs = archetype:getMut(gfx.Arc)
                local anims = archetype:get(AnimateLineWidth)
                for i = 1, len do
                    local arc = arcs[i]
                    local anim = anims[i]
                    local t = (sin(time * anim.speed + anim.phase) + 1) * 0.5
                    arc.lineWidth = anim.minWidth + t * (anim.maxWidth - anim.minWidth)
                end
            end
        end
    })

    -- Animate line width (requires dirty marking)
    world:addSystem({
        name = "AnimateLineComponentWidth",
        phase = tecs.phases.Update,
        run = function()
            for archetype, len in lineAnimQuery:iter() do
                local lines = archetype:getMut(gfx.Line)
                local anims = archetype:get(AnimateLineWidth)
                for i = 1, len do
                    local line = lines[i]
                    local anim = anims[i]
                    local t = (sin(time * anim.speed + anim.phase) + 1) * 0.5
                    line.width = anim.minWidth + t * (anim.maxWidth - anim.minWidth)
                end
            end
        end
    })

    local targetZoom = 1.0
    local targetX, targetY = 0.0, 0.0

    world:addSystem({
        name = "HandleInput",
        phase = tecs.phases.First,
        run = function()
            -- Manual zoom with +/- or mouse wheel
            if input.isKeyDown("=") then
                targetZoom = targetZoom * 1.02
            elseif input.isKeyDown("-") then
                targetZoom = targetZoom / 1.02
            end

            local wheelY = input.mouseWheelMoved[2]
            if wheelY ~= 0 then
                targetZoom = targetZoom * (1 + wheelY * 0.1)
                targetZoom = math.max(0.5, math.min(5.0, targetZoom))
            end

            -- Reset view with space or 0
            if input.isKeyPressed("space") or input.isKeyPressed("0") then
                targetZoom = 1.0
                targetX, targetY = 0, 0
                selectedDesc = "Click a cell to see its description"
            end

            -- Click to zoom into cell
            if input.isMousePressed(1) then
                local mx, my = input.mouseX, input.mouseY
                local wx, wy = pipeline:getCamera():toWorld(mx, my)

                local col = math.floor((wx - gridLeft) / GRID.cellSize) + 1
                local row = math.floor((wy - gridTop) / GRID.cellSize) + 1

                if col >= 1 and col <= GRID.cols and row >= 1 and row <= GRID.rows then
                    focusCol, focusRow = col, row
                    local cellDef = cells[row] and cells[row][col]
                    if cellDef then
                        selectedDesc = string.format("[%d,%d] %s", col, row, cellDef.desc)
                    else
                        selectedDesc = string.format("[%d,%d] Empty", col, row)
                    end

                    -- Pan and zoom to clicked cell (only zoom in if not already zoomed in enough)
                    local cellX, cellY = gridCenter(col, row)
                    targetX, targetY = cellX, cellY
                    if targetZoom < 2.5 then targetZoom = 2.5 end

                    -- Update highlight
                    local hlX, hlY = gridTopLeft(col, row)
                    highlightTransform.x, highlightTransform.y = hlX, hlY
                end
            end

            -- Right-click to reset view
            if input.isMousePressed(2) then
                targetZoom = 1.0
                targetX, targetY = 0, 0
                focusCol, focusRow = 0, 0
                selectedDesc = "Click a cell to see its description"
                highlightTransform.x, highlightTransform.y = -9999, -9999
            end

            -- Arrow key navigation
            local function updateHighlight()
                if focusCol > 0 and focusRow > 0 then
                    local hlX, hlY = gridTopLeft(focusCol, focusRow)
                    highlightTransform.x, highlightTransform.y = hlX, hlY
                else
                    highlightTransform.x, highlightTransform.y = -9999, -9999
                end
            end

            local function moveFocus(dc: integer, dr: integer)
                if focusCol == 0 and focusRow == 0 then
                    focusCol, focusRow = 1, 1
                else
                    focusCol = math.max(1, math.min(GRID.cols, focusCol + dc))
                    focusRow = math.max(1, math.min(GRID.rows, focusRow + dr))
                end
                local cellDef = cells[focusRow] and cells[focusRow][focusCol]
                if cellDef then
                    selectedDesc = string.format("[%d,%d] %s", focusCol, focusRow, cellDef.desc)
                else
                    selectedDesc = string.format("[%d,%d] Empty", focusCol, focusRow)
                end
                local cellX, cellY = gridCenter(focusCol, focusRow)
                targetX, targetY = cellX, cellY
                if targetZoom < 2.5 then targetZoom = 2.5 end
                updateHighlight()
            end

            if input.isKeyPressed("left") then moveFocus(-1, 0) end
            if input.isKeyPressed("right") then moveFocus(1, 0) end
            if input.isKeyPressed("up") then moveFocus(0, -1) end
            if input.isKeyPressed("down") then moveFocus(0, 1) end

            -- Smooth camera movement
            local cam = pipeline:getCamera()
            local currentZoom = cam:getZoom()
            local camX, camY = cam:getPosition()
            local lerpSpeed = 0.1
            cam:setZoom(currentZoom + (targetZoom - currentZoom) * lerpSpeed)
            cam:setPosition(
                camX + (targetX - camX) * lerpSpeed,
                camY + (targetY - camY) * lerpSpeed
            )
        end
    })

    local captionFont = lg.newFont(22)
    local helpFont = lg.newFont(16)


    world:addSystem({
        name = "DrawUI",
        phase = tecs.phases.Render,  -- Draw before PostRender so stats overlay draws on top
        run = function()
            -- Reset ALL graphics state to ensure UI draws correctly after GPU render
            lg.reset()
            -- Explicitly disable depth test so UI always draws on top
            lg.setDepthMode()

            local screenW, screenH = lg.getDimensions()

            -- Bottom caption bar
            lg.setColor(0.1, 0.1, 0.15, 0.98)
            lg.rectangle("fill", 0, screenH - 70, screenW, 70)

            -- Top help bar
            lg.rectangle("fill", 0, 0, screenW, 42)

            -- Caption text
            lg.setColor(1, 1, 1, 1)
            lg.setFont(captionFont)
            lg.print(selectedDesc, 16, screenH - 50)

            -- Help text
            lg.setColor(0.6, 0.6, 0.7, 1)
            lg.setFont(helpFont)
            lg.print("Click/Arrows to select | Space to reset | Scroll to zoom | ESC Quit", 16, 12)
        end
    })
end

love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = transformDemoPlugin,
    render = {
        virtualHeight = 800,
        pixelMode = false,
        lightingMode = "none",
    },
})
