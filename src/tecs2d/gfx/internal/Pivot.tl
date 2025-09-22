local tecs <const> = require("tecs")

--- Pivot component for controlling render origin.
--- Entities with this component will render with the specified pivot point.
--- pivotX/pivotY are percentages (0-1) where 0,0 is top-left and 0.5,0.5 is center.
local record Pivot is tecs.Component
    --- Pivot X as a percentage (0-1). 0 = left edge, 0.5 = center, 1 = right edge.
    x: number

    --- Pivot Y as a percentage (0-1). 0 = top edge, 0.5 = center, 1 = bottom edge.
    y: number

    --- Create a new Pivot component.
    metamethod __call: function(
        self,
        x?: number,
        y?: number
    ): Pivot
end

tecs.newFFIComponent({
    name = "Pivot",
    container = Pivot,
    fields = {
        {"x", "float"},
        {"y", "float"}
    },
    defaults = {0.5, 0.5}
})

return Pivot
