--- Flow component for arranging direct UI children in rows or columns.

local tecs <const> = require("tecs")

local enum FlowDirection
    "right"
    "left"
    "down"
    "up"
end

local enum FlowWrap
    "none"
    "right"
    "left"
    "down"
    "up"
end

local enum FlowAlign
    "start"
    "center"
    "end"
end

local record FlowConfig
    direction: FlowDirection
    wrap: FlowWrap
    gap: number
    lineGap: number
    maxItems: integer
    align: FlowAlign
end

--- Arranges direct children that have LayoutBox and RelativeTransform.
--- Flow owns only the children's RelativeTransform x/y fields.
local record Flow is tecs.Component
    --- Direction in which items are added to a row or column.
    direction: FlowDirection

    --- Direction in which additional rows or columns are added.
    --- Must be perpendicular to direction. "none" disables wrapping.
    wrap: FlowWrap

    --- Space between items in the same row or column.
    gap: number

    --- Space between wrapped rows or columns.
    lineGap: number

    --- Maximum items per row or column. Zero wraps against the fixed
    --- parent LayoutBox extent, or does not wrap when wrap is "none".
    maxItems: integer

    --- Cross-axis alignment within each row or column.
    align: FlowAlign

    --- Creates a single-line Flow.
    metamethod __call: function(
        self,
        direction?: FlowDirection,
        gap?: number
    ): Flow

    --- Creates a configured Flow.
    new: function(config: FlowConfig): Flow

end

local function isHorizontal(direction: string): boolean
    return direction == "right" or direction == "left"
end

local function validate(
    direction: FlowDirection,
    wrap: FlowWrap,
    gap: number,
    lineGap: number,
    maxItems: integer,
    align: FlowAlign
)
    if direction ~= "right" and direction ~= "left"
            and direction ~= "down" and direction ~= "up" then
        error("Flow: direction must be right, left, down, or up")
    end
    if wrap ~= "none" and wrap ~= "right" and wrap ~= "left"
            and wrap ~= "down" and wrap ~= "up" then
        error("Flow: wrap must be none, right, left, down, or up")
    end
    if wrap ~= "none" and isHorizontal(direction) == isHorizontal(wrap) then
        error("Flow: wrap must be perpendicular to direction")
    end
    if gap < 0 or lineGap < 0 then
        error("Flow: gap and lineGap must be non-negative")
    end
    if maxItems < 0 or maxItems ~= math.floor(maxItems) then
        error("Flow: maxItems must be a non-negative integer")
    end
    if wrap == "none" and maxItems > 0 then
        error("Flow: maxItems requires wrapping")
    end
    if align ~= "start" and align ~= "center" and align ~= "end" then
        error("Flow: align must be start, center, or end")
    end
end

tecs.newComponent({
    name = "Flow",
    container = Flow,
    fields = {
        "direction",
        "wrap",
        "gap",
        "lineGap",
        "maxItems",
        "align",
    },
    defaults = {"right", "none", 0, 0, 0, "start"},
    __call = function(instance: Flow, direction?: FlowDirection, gap?: number)
        local resolvedDirection = direction or "right"
        local resolvedGap = gap or 0
        validate(resolvedDirection, "none", resolvedGap, resolvedGap, 0, "start")
        instance.direction = resolvedDirection
        instance.wrap = "none"
        instance.gap = resolvedGap
        instance.lineGap = resolvedGap
        instance.maxItems = 0
        instance.align = "start"
    end,
    new = function(data: {string: any}): Flow
        local config = data as FlowConfig
        local direction = config.direction or "right"
        local wrap = config.wrap or "none"
        local gap = config.gap or 0
        local lineGap = config.lineGap
        if lineGap == nil then lineGap = gap end
        local maxItems = config.maxItems or 0
        local align = config.align or "start"
        validate(direction, wrap, gap, lineGap, maxItems, align)
        return {
            direction = direction,
            wrap = wrap,
            gap = gap,
            lineGap = lineGap,
            maxItems = maxItems,
            align = align,
        }
    end,
})

return Flow
