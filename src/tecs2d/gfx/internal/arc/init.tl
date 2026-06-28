local tecs <const> = require("tecs")
local types <const> = require("tecs2d.gfx.types")
local shaderUtils <const> = require("tecs2d.gfx.internal.gpu.shaders")
local material_compiler <const> = require("tecs2d.gfx.internal.material_compiler")
local defineShape <const> = require("tecs2d.gfx.internal.gpu.define_shape")

local ColorComponent <const> = require("tecs2d.gfx.internal.Color")
local ClipBounds <const> = require("tecs2d.gfx.internal.ClipBounds")
local Unlit <const> = require("tecs2d.gfx.internal.Unlit")
local Material <const> = require("tecs2d.gfx.internal.Material")
local Pivot <const> = require("tecs2d.gfx.internal.Pivot")

local lg <const> = love.graphics

-- Arc uses the renderer-owned shadow-column path; wiring is provided
-- by `shadow_plugin`. No shadow path (arcs don't cast raymarched
-- shadows in the legacy renderer either).
local ARC_SHADERS <const> = "tecs2d/gfx/internal/arc/"
local renderSource <const> = shaderUtils.loadRenderShader("arc", ARC_SHADERS)
local renderShader <const> = lg.newShader(renderSource)
local cullShader <const> =
    lg.newComputeShader(shaderUtils.loadCullShader("arc_cull", ARC_SHADERS))
material_compiler.registerBaseSource("arc", renderSource)

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
    defaults = {nil, nil, 0, math.pi * 2, 0, -1},
    init = function(instance: Arc)
        assert(instance.radiusX, "Missing Arc radiusX")
        assert(instance.radiusY, "Missing Arc radiusY")
    end
})

function arc.plugin(world: tecs.World)
    defineShape.register(world, {
        name = "Arc",
        component = Arc as tecs.Component,
        render = renderShader,
        cull = cullShader,
        modifiers = {ColorComponent, ClipBounds, Material, Pivot},
        tags = {Unlit},
        alphaBlendFilter = false,
    })
end

return arc
