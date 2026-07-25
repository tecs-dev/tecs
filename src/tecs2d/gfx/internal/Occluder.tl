--- Occluder component for opting entities into shadow casting.
--- Entities with this component will render their silhouette to the shadow mask,
--- allowing them to block light and cast shadows on surfaces behind them.
---
--- For Sprites and Images, the alpha channel determines the silhouette.
--- For shapes (circle, rectangle, mesh), the filled geometry is used.
---
--- Usage (table style):
---   world:spawn(Transform(x, y), Circle(50), Occluder.new({ height = 100 }))
---   world:spawn(Transform(x, y), sprite, Occluder.new({ alphaThreshold = 0.5, height = 200 }))
---
--- Usage (positional style - height, alphaThreshold):
---   world:spawn(Transform(x, y), Circle(50), Occluder())        -- defaults
---   world:spawn(Transform(x, y), Circle(50), Occluder(100))     -- height = 100
---   world:spawn(Transform(x, y), sprite, Occluder(200, 0.5))    -- height = 200, alpha = 0.5

local tecs <const> = require("tecs")

local record OccluderConfig
    --- Alpha threshold for texture shadows (0.0 - 1.0). Defaults to 0.5.
    alphaThreshold: number
    --- Height of the occluder (0.0 - 1.0). Defaults to 0.5.
    height: number
end

local record Occluder is tecs.Component
    --- Alpha threshold for Sprite and Image shadows (0.0 - 1.0).
    --- Pixels with alpha below this value won't cast shadows.
    --- Defaults to 0.5.
    alphaThreshold: number

    --- Height of the occluder (0.0 - 1.0, normalized).
    --- Controls perspective shadow projection: higher lights cast shorter shadows.
    --- Defaults to 0.5.
    height: number

    metamethod __call: function(
        self,
        height?: number,
        alphaThreshold?: number
    ): Occluder

    new: function(config: OccluderConfig): Occluder
end

tecs.newFFIComponent({
    name = "Occluder",
    container = Occluder,
    fields = {
        {"height", "float"},
        {"alphaThreshold", "float"},
    },
    defaults = {0.5, 0.5},
    new = function(data: {string: any}): Occluder
        local c = data as OccluderConfig
        return Occluder(c.height, c.alphaThreshold)
    end,
})

return Occluder
