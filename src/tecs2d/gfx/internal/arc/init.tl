local tecs <const> = require("tecs")
local types <const> = require("tecs2d.gfx.types")
local defineshape <const> = require("tecs2d.gfx.internal.gpu.defineshape")

local ColorComponent <const> = require("tecs2d.gfx.internal.Color")
local ClipBounds <const> = require("tecs2d.gfx.internal.ClipBounds")
local Unlit <const> = require("tecs2d.gfx.internal.Unlit")
local Material <const> = require("tecs2d.gfx.internal.Material")
local Pivot <const> = require("tecs2d.gfx.internal.Pivot")

-- Arc uses the renderer-owned shadow-column path; wiring is provided
-- by `shadow_plugin`. No shadow-mask shader: arcs do not cast
-- raymarched shadows.
local shaders <const> = defineshape.loadShaders({
    name = "arc",
    dir = "tecs2d/gfx/internal/arc/",
})

local record arc
    record Arc is tecs.Component, types.Rect
        radiusX: number
        radiusY: number
        startAngle: number  -- radians
        endAngle: number    -- radians
        lineWidth: number   -- 0 = filled, >0 = outline with this width

        metamethod __call: function(self, radiusX: number, radiusY: number, startAngle: number, endAngle: number, lineWidth?: number): Arc
    end

    plugin: function(world: tecs.World)
end

local Arc <const> = arc.Arc

tecs.newFFIComponent({
    name = "Arc",
    container = Arc,
    fields = {
        {"radiusX", "float"},
        {"radiusY", "float"},
        {"startAngle", "float"},
        {"endAngle", "float"},
        {"lineWidth", "float"},
    },
    metatable = {
        __index = {
            getRect = function(self: Arc): number, number, number, number
                local rx, ry = self.radiusX, self.radiusY
                local w, h = rx * 2, ry * 2
                return -rx, -ry, w, h
            end
        }
    },
    defaults = {nil, nil, 0, math.pi * 2, 0},
    init = function(instance: Arc)
        assert(instance.radiusX, "Missing Arc radiusX")
        assert(instance.radiusY, "Missing Arc radiusY")
    end
})

function arc.plugin(world: tecs.World)
    defineshape.register(world, {
        name = "Arc",
        component = Arc as tecs.Component,
        render = shaders.render,
        cull = shaders.cull,
        modifiers = {ColorComponent, ClipBounds, Material, Pivot},
        tags = {Unlit},
        alphaBlendFilter = false,
    })
end

return arc
