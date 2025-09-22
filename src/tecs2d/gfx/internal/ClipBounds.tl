local tecs <const> = require("tecs")

--- ClipBounds component for GPU-based clipping.
--- Entities with this component will have their rendering clipped to the specified bounds.
--- Used by LayoutNode for scroll container clipping.
local record ClipBounds is tecs.Component
    --- Minimum X coordinate (world space)
    minX: number

    --- Minimum Y coordinate (world space)
    minY: number

    --- Maximum X coordinate (world space)
    maxX: number

    --- Maximum Y coordinate (world space)
    maxY: number

    --- Create a new ClipBounds component.
    metamethod __call: function(
        self,
        minX: number,
        minY: number,
        maxX: number,
        maxY: number
    ): ClipBounds
end

tecs.newFFIComponent({
    name = "ClipBounds",
    container = ClipBounds,
    fields = {
        {"minX", "float"},
        {"minY", "float"},
        {"maxX", "float"},
        {"maxY", "float"}
    },
    defaults = {0, 0, 0, 0}
})

return ClipBounds
