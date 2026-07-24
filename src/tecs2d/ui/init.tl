--- Tecs UI Library
--- Provides UI components and layout system for Tecs.

local tecs <const> = require("tecs")
local Anchor <const> = require("tecs2d.ui.internal.Anchor")
local LayoutBox <const> = require("tecs2d.ui.internal.LayoutBox")
local Viewport <const> = require("tecs2d.ui.internal.Viewport")
local FitContent <const> = require("tecs2d.ui.internal.FitContent")

local type World = tecs.World
local RelativeTransform <const> = tecs.builtins.RelativeTransform

local record ui
    enum Origin
        "center"
        "topLeft"
    end

    record Config
        --- Origin inherited by LayoutBox values that omit explicit origins.
        --- Defaults to "center".
        origin: Origin
    end

    --- Viewport-relative positioning using anchor percentages and pixel offsets.
    Anchor: Anchor

    --- Layout dimensions and origin for UI positioning.
    LayoutBox: LayoutBox

    --- A viewport that provides clipping and scrolling for its children.
    Viewport: Viewport

    --- Auto-sizes a container to fit its children with optional padding.
    FitContent: FitContent

    --- Unified layout plugin.
    --- Installs Anchor, LayoutBox, Viewport, and FitContent systems.
    --- Call this once after creating the render pipeline.
    plugin: function(world: World)

    --- Create a UI plugin with world-local defaults.
    --- `ui.new({origin = "topLeft"})` makes omitted LayoutBox origins top-left.
    new: function(config?: Config): tecs.Plugin

    --- Simple helper that sets each child's RelativeTransform.y sequentially (child[i].y = startY + sum of
    --- prior child heights + spacing). This is a placement convenience, not a layout engine: it ignores origin,
    --- parent constraints, wrap, alignment, and re-running it moves children again. Call once after spawn, or
    --- use a proper layout system for anything dynamic.
    stackVertical: function(world: World, children: {integer}, spacing: number, startY?: number)

    --- Like stackVertical but along the X axis. Same "simple helper" caveats.
    stackHorizontal: function(world: World, children: {integer}, spacing: number, startX?: number)

    --- Calculate the bounding-box size of a set of children. Accounts for the LayoutBox origin offset
    --- (so centered children aren't measured from their center) and for children placed at negative RelativeTransform
    --- offsets. Returns 0,0 if no child has both LayoutBox and RelativeTransform.
    --- @param world The world instance.
    --- @param children Array of entity IDs to measure.
    --- @return width, height of bounding box.
    measureContent: function(world: World, children: {integer}): number, number
end

ui.Anchor = Anchor
ui.LayoutBox = LayoutBox
ui.Viewport = Viewport
ui.FitContent = FitContent

local function install(world: World, config?: ui.Config)
    local originX, originY = 0.5, 0.5
    if config and config.origin then
        if config.origin == "topLeft" then
            originX, originY = 0, 0
        elseif config.origin ~= "center" then
            error("unknown UI origin: " .. tostring(config.origin))
        end
    end
    Anchor.plugin(world)
    LayoutBox.plugin(world, {defaultOriginX = originX, defaultOriginY = originY})
    Viewport.plugin(world)
    FitContent.plugin(world)
end

function ui.plugin(world: World)
    install(world)
end

function ui.new(config?: ui.Config): tecs.Plugin
    return function(world: World)
        install(world, config)
    end
end

-- Shared body of stackVertical/stackHorizontal: place children sequentially
-- along one axis, advancing by each child's extent on that axis plus spacing.
local function stackChildren(world: World, children: {integer}, spacing: number, start: number, vertical: boolean)
    local current = start
    for i = 1, #children do
        local childId = children[i]
        local relTransform = world:get(childId, RelativeTransform)
        local layoutBox = world:get(childId, LayoutBox)
        if relTransform then
            local step = spacing
            if layoutBox then
                step = step + (vertical and layoutBox.height or layoutBox.width)
            end
            if vertical then
                relTransform.y = current
            else
                relTransform.x = current
            end
            current = current + step
        end
    end
end

function ui.stackVertical(world: World, children: {integer}, spacing: number, startY?: number)
    stackChildren(world, children, spacing, startY or 0, true)
end

function ui.stackHorizontal(world: World, children: {integer}, spacing: number, startX?: number)
    stackChildren(world, children, spacing, startX or 0, false)
end

-- Reusable measurement context (measureContent runs synchronously, so one
-- module-level context is safe and avoids a per-call allocation).
local measureCtx: FitContent.MeasureCtx = {
    world = nil, hasChildren = false,
    minX = 0.0, minY = 0.0, maxX = 0.0, maxY = 0.0,
}

function ui.measureContent(world: World, children: {integer}): number, number
    -- Track full bounding box including negative offsets.
    measureCtx.world = world
    measureCtx.hasChildren = false
    measureCtx.minX, measureCtx.minY = math.huge, math.huge
    measureCtx.maxX, measureCtx.maxY = -math.huge, -math.huge
    for i = 1, #children do
        FitContent.measureChild(children[i], measureCtx)
    end
    measureCtx.world = nil
    if not measureCtx.hasChildren then
        return 0, 0
    end
    return measureCtx.maxX - measureCtx.minX, measureCtx.maxY - measureCtx.minY
end

return ui
