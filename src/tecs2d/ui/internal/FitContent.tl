--- FitContent component for auto-sizing containers to fit their children.
--- Measures child bounds and updates LayoutBox (and optionally a render component).

local tecs <const> = require("tecs")

local RelativeTransform <const> = tecs.builtins.RelativeTransform

local type Component = tecs.Component
local type World = tecs.World

local LayoutBox: Component

local enum FitMode
    "both"
    "width"
    "height"
end

local record FitContentConfig
    padding: number
    paddingTop: number
    paddingRight: number
    paddingBottom: number
    paddingLeft: number
    adjust: Component
    fit: FitMode
end

--- Auto-sizes a container to fit its children with optional padding.
--- Requires LayoutBox on the same entity.
local record FitContent is Component
    --- Uniform padding applied on all sides (used if per-side padding is 0).
    padding: number

    --- Padding for top edge.
    paddingTop: number

    --- Padding for right edge.
    paddingRight: number

    --- Padding for bottom edge.
    paddingBottom: number

    --- Padding for left edge.
    paddingLeft: number

    --- Component ID to update with new dimensions (0 = none).
    --- The component must have width/height fields.
    adjustComponentId: integer

    --- Whether LayoutBox width is fitted to the measured content.
    fitWidth: boolean

    --- Whether LayoutBox height is fitted to the measured content.
    fitHeight: boolean

    --- Creates a new FitContent component from positional args.
    --- For the table form, use `FitContent.new({ padding = 10, adjust = ... })`.
    ---
    --- @param padding Uniform padding in world units.
    --- @param adjustComponent Optional component to update dimensions on.
    --- @return the created FitContent component.
    metamethod __call: function(
        self,
        padding?: number,
        adjustComponent?: Component
    ): FitContent

    new: function(config: FitContentConfig): FitContent

    --- Reusable bounding-box accumulator for measuring child layout bounds.
    record MeasureCtx
        world: World
        hasChildren: boolean
        minX: number
        minY: number
        maxX: number
        maxY: number
    end

    --- Accumulate one child's layout bounds (RelativeTransform position plus
    --- LayoutBox offset and size) into ctx. Children missing RelativeTransform
    --- or LayoutBox are ignored. Usable directly as a world:targets visitor.
    measureChild: function(childId: integer, ctx: MeasureCtx)

end

local function resolveAdjustId(c: Component): integer
    if c then
        local componentId = c.componentId
        if componentId and type(componentId) == "number" then
            return componentId as integer
        end
    end
    return 0
end

-- LayoutBox is lazily required (as a generic Component) to avoid a circular
-- dependency, so column reads are cast into the structural shape used here.
local record SizableBox
    width: number
    height: number
    offsetX: number
    offsetY: number
    originX: number
    originY: number
end

function FitContent.measureChild(childId: integer, ctx: FitContent.MeasureCtx)
    if not LayoutBox then
        LayoutBox = require("tecs2d.ui.internal.LayoutBox")
    end
    local relTransform = ctx.world:get(childId, RelativeTransform)
    local childBox = ctx.world:get(childId, LayoutBox) as SizableBox
    if relTransform and childBox then
        ctx.hasChildren = true
        local left = relTransform.x + childBox.offsetX
        local top = relTransform.y + childBox.offsetY
        local right = left + childBox.width
        local bottom = top + childBox.height
        if left < ctx.minX then ctx.minX = left end
        if top < ctx.minY then ctx.minY = top end
        if right > ctx.maxX then ctx.maxX = right end
        if bottom > ctx.maxY then ctx.maxY = bottom end
    end
end

tecs.newComponent({
    name = "FitContent",
    container = FitContent,
    fields = {
        "padding",
        "paddingTop",
        "paddingRight",
        "paddingBottom",
        "paddingLeft",
        "adjustComponentId",
        "fitWidth",
        "fitHeight",
    },
    defaults = {0, 0, 0, 0, 0, 0, true, true},
    __call = function(instance: FitContent, padding?: number, adjustComponent?: Component)
        instance.padding = padding or 0
        instance.adjustComponentId = resolveAdjustId(adjustComponent)
        instance.fitWidth = true
        instance.fitHeight = true
    end,
    new = function(data: {string: any}): FitContent
        local config = data as FitContentConfig
        local fit = config.fit or "both"
        if fit ~= "both" and fit ~= "width" and fit ~= "height" then
            error("FitContent: fit must be both, width, or height")
        end
        return {
            padding = config.padding or 0,
            paddingTop = config.paddingTop or 0,
            paddingRight = config.paddingRight or 0,
            paddingBottom = config.paddingBottom or 0,
            paddingLeft = config.paddingLeft or 0,
            adjustComponentId = resolveAdjustId(config.adjust),
            fitWidth = fit == "both" or fit == "width",
            fitHeight = fit == "both" or fit == "height",
        }
    end,
})

return FitContent
