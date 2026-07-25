--- DropShadow component for dynamically projecting a Sprite or Image shadow
--- based on nearby light sources. One shadow per affecting light, stretched
--- away from the light with length based on entity height and light distance.
---
--- Renders to a standalone AO canvas that attenuates all lighting (ambient and
--- dynamic). Emission is unaffected, so glowing objects shine through shadows.
---
--- Usage (table style):
---   world:spawn(Transform(x, y), sprite, DropShadow.new({ height = 0.5 }))
---
--- Usage (positional style - height, opacity):
---   world:spawn(Transform(x, y), sprite, DropShadow())            -- defaults
---   world:spawn(Transform(x, y), sprite, DropShadow(0.8))         -- taller object
---   world:spawn(Transform(x, y), sprite, DropShadow(0.5, 0.4))   -- height=0.5, opacity=0.4

local tecs <const> = require("tecs")

local record DropShadowConfig
    --- Entity height (0-1). Controls shadow length. Defaults to 0.5.
    height: number
    --- Shadow darkness 0-1. Defaults to 0.4.
    opacity: number
end

local record DropShadow is tecs.Component
    --- Entity height (0-1). Controls shadow length: taller objects cast longer shadows.
    --- Defaults to 0.5.
    height: number

    --- Shadow darkness 0-1. Defaults to 0.4.
    opacity: number

    metamethod __call: function(
        self,
        height?: number,
        opacity?: number
    ): DropShadow

    new: function(config: DropShadowConfig): DropShadow
end

local DEFAULT_HEIGHT <const> = 0.5
local DEFAULT_OPACITY <const> = 0.4

local function clampOpacity(o: number): number
    if o < 0 then return 0 end
    if o > 1 then return 1 end
    return o
end

local function clampHeight(h: number): number
    return h < 0 and 0 or h
end

tecs.newFFIComponent({
    name = "DropShadow",
    container = DropShadow,
    fields = {
        {"height", "float"},
        {"opacity", "float"},
    },
    defaults = {DEFAULT_HEIGHT, DEFAULT_OPACITY},
    init = function(instance: DropShadow)
        instance.height = clampHeight(instance.height)
        instance.opacity = clampOpacity(instance.opacity)
    end,
    new = function(data: {string: any}): DropShadow
        local c = data as DropShadowConfig
        return DropShadow(c.height, c.opacity)
    end,
})

return DropShadow
