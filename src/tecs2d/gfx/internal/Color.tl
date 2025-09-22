local tecs <const> = require("tecs")

--- A Color component that applies RGBA tinting to any draw.
--- In GPU rendering, drawable components include this color in their GPU instance data.
local record Color is tecs.Component
    --- Red component (0.0-1.0)
    r: number
    --- Green component (0.0-1.0)
    g: number
    --- Blue component (0.0-1.0)
    b: number
    --- Alpha component (0.0-1.0)
    a: number

    --- Plugin that registers the Color component (no observers needed for GPU rendering).
    plugin: function(world: tecs.World)

    --- Create a new Color component.
    --- @param r Red component (0.0-1.0)
    --- @param g Green component (0.0-1.0)
    --- @param b Blue component (0.0-1.0)
    --- @param a Alpha component (0.0-1.0)
    --- @return the new Color component instance
    metamethod __call: function(
        self,
        r?: number,
        g?: number,
        b?: number,
        a?: number
    ): Color
end

--- Plugin is a no-op for GPU rendering.
--- Drawable components sync Color data to GPU buffers when they sync.
Color.plugin = function(_world: tecs.World)
    -- No OnDraw observers needed - GPU handles color in instance data
end

tecs.newFFIComponent({
    name = "Color",
    container = Color,
    fields = {
        {"r", "float"},
        {"g", "float"},
        {"b", "float"},
        {"a", "float"}
    },
    defaults = {1, 1, 1, 1}
})

return Color
