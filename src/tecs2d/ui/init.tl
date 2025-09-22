--- Tecs UI Library
--- Provides UI components and layout system for Tecs.

local tecs <const> = require("tecs")
local Anchor <const> = require("tecs2d.ui.internal.Anchor")
local LayoutBox <const> = require("tecs2d.ui.internal.LayoutBox")
local LayoutNode <const> = require("tecs2d.ui.internal.LayoutNode")
local FitContent <const> = require("tecs2d.ui.internal.FitContent")

local type World = tecs.World
local RelativeTransform <const> = tecs.builtins.RelativeTransform

local record ui
    --- Viewport-relative positioning using anchor percentages and pixel offsets.
    Anchor: Anchor

    --- Layout dimensions and origin for UI positioning.
    LayoutBox: LayoutBox

    --- A layout node that provides clipping and scrolling for its children.
    LayoutNode: LayoutNode

    --- Auto-sizes a container to fit its children with optional padding.
    FitContent: FitContent

    --- Unified layout plugin. Installs LayoutBox, LayoutNode, and FitContent systems.
    --- Call this once after creating the render pipeline.
    plugin: function(world: World)

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
ui.LayoutNode = LayoutNode
ui.FitContent = FitContent

function ui.plugin(world: World)
    Anchor.plugin(world)
    LayoutBox.plugin(world)
    LayoutNode.plugin(world)
    FitContent.plugin(world)
end

function ui.stackVertical(world: World, children: {integer}, spacing: number, startY?: number)
    local currentY = startY or 0
    for i = 1, #children do
        local childId = children[i]
        local relTransform = world:get(childId, RelativeTransform)
        local layoutBox = world:get(childId, LayoutBox)
        if relTransform then
            relTransform.y = currentY
            if layoutBox then
                currentY = currentY + layoutBox.height + spacing
            else
                currentY = currentY + spacing
            end
        end
    end
end

function ui.stackHorizontal(world: World, children: {integer}, spacing: number, startX?: number)
    local currentX = startX or 0
    for i = 1, #children do
        local childId = children[i]
        local relTransform = world:get(childId, RelativeTransform)
        local layoutBox = world:get(childId, LayoutBox)
        if relTransform then
            relTransform.x = currentX
            if layoutBox then
                currentX = currentX + layoutBox.width + spacing
            else
                currentX = currentX + spacing
            end
        end
    end
end

function ui.measureContent(world: World, children: {integer}): number, number
    -- Track full bounding box including negative offsets.
    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge
    local found = false
    for i = 1, #children do
        local childId = children[i]
        local layoutBox = world:get(childId, LayoutBox)
        local relTransform = world:get(childId, RelativeTransform)
        if layoutBox and relTransform then
            local left = relTransform.x + layoutBox.offsetX
            local top = relTransform.y + layoutBox.offsetY
            local right = left + layoutBox.width
            local bottom = top + layoutBox.height
            if left < minX then minX = left end
            if top < minY then minY = top end
            if right > maxX then maxX = right end
            if bottom > maxY then maxY = bottom end
            found = true
        end
    end
    if not found then
        return 0, 0
    end
    return maxX - minX, maxY - minY
end

return ui
