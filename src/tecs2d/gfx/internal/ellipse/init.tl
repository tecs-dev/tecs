local tecs <const> = require("tecs")
local types <const> = require("tecs2d.gfx.types")
local defineshape <const> = require("tecs2d.gfx.internal.gpu.defineshape")

local ColorComponent <const> = require("tecs2d.gfx.internal.Color")
local ClipBounds <const> = require("tecs2d.gfx.internal.ClipBounds")
local Unlit <const> = require("tecs2d.gfx.internal.Unlit")
local Material <const> = require("tecs2d.gfx.internal.Material")
local Pivot <const> = require("tecs2d.gfx.internal.Pivot")

-- Ellipse uses the renderer-owned shadow-column path; wiring is
-- provided by `shadow_plugin`. No shadow-mask shader: ellipses do not
-- cast raymarched shadows.
local shaders <const> = defineshape.loadShaders({
    name = "ellipse",
    dir = "tecs2d/gfx/internal/ellipse/",
})

local record ellipse
    record Ellipse is tecs.Component, types.Rect
        radiusX: number
        radiusY: number
        lineWidth: number  -- 0 = filled, >0 = outline with this width

        metamethod __call: function(self, radiusX: number, radiusY: number, lineWidth?: number): Ellipse
    end

    plugin: function(world: tecs.World)
end

local Ellipse <const> = ellipse.Ellipse

tecs.newFFIComponent({
    name = "Ellipse",
    container = Ellipse,
    fields = {
        {"radiusX", "float"},
        {"radiusY", "float"},
        {"lineWidth", "float"},
    },
    metatable = {
        __index = {
            getRect = function(self: Ellipse): number, number, number, number
                local rx, ry = self.radiusX, self.radiusY
                local w, h = rx * 2, ry * 2
                return -rx, -ry, w, h
            end
        }
    },
    defaults = {nil, nil, 0},
    init = function(instance: Ellipse)
        assert(instance.radiusX, "Missing Ellipse radiusX")
        assert(instance.radiusY, "Missing Ellipse radiusY")
    end
})

function ellipse.plugin(world: tecs.World)
    defineshape.register(world, {
        name = "Ellipse",
        component = Ellipse as tecs.Component,
        render = shaders.render,
        cull = shaders.cull,
        modifiers = {ColorComponent, ClipBounds, Material, Pivot},
        tags = {Unlit},
        alphaBlendFilter = false,
    })
end

return ellipse
