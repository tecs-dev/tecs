local tecs <const> = require("tecs")
local defineshape <const> = require("tecs2d.gfx.internal.gpu.defineshape")

local ColorComponent <const> = require("tecs2d.gfx.internal.Color")
local ClipBounds <const> = require("tecs2d.gfx.internal.ClipBounds")
local Unlit <const> = require("tecs2d.gfx.internal.Unlit")
local Material <const> = require("tecs2d.gfx.internal.Material")

-- Line uses the renderer-owned shadow-column path; wiring is provided
-- by `shadow_plugin`. No shadow-mask shader (lines do not cast
-- raymarched shadows) and no Pivot (lines have explicit endpoints).
local shaders <const> = defineshape.loadShaders({
    name = "line",
    dir = "tecs2d/gfx/internal/line/",
})

local record line
    record Line is tecs.Component
        -- Line endpoints relative to transform position
        x1: number
        y1: number
        x2: number
        y2: number
        width: number    -- Line width in pixels (default 1)

        metamethod __call: function(self, x1: number, y1: number, x2: number, y2: number, width?: number): Line
    end

    plugin: function(world: tecs.World)
end

local Line <const> = line.Line

tecs.newFFIComponent({
    name = "Line",
    container = Line,
    fields = {
        {"x1", "float"},
        {"y1", "float"},
        {"x2", "float"},
        {"y2", "float"},
        {"width", "float"},
    },
    defaults = {0, 0, 0, 0, 1}
})

function line.plugin(world: tecs.World)
    defineshape.register(world, {
        name = "Line",
        component = Line as tecs.Component,
        render = shaders.render,
        cull = shaders.cull,
        modifiers = {ColorComponent, ClipBounds, Material},
        tags = {Unlit},
        alphaBlendFilter = false,
    })
end

return line
