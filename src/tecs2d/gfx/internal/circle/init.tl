local tecs <const> = require("tecs")
local types <const> = require("tecs2d.gfx.types")
local shaderUtils <const> = require("tecs2d.gfx.internal.gpu.shaders")
local material_compiler <const> = require("tecs2d.gfx.internal.material_compiler")
local defineShape <const> = require("tecs2d.gfx.internal.gpu.define_shape")

local ColorComponent <const> = require("tecs2d.gfx.internal.Color")
local ClipBounds <const> = require("tecs2d.gfx.internal.ClipBounds")
local Unlit <const> = require("tecs2d.gfx.internal.Unlit")
local Occluder <const> = require("tecs2d.gfx.internal.Occluder")
local Material <const> = require("tecs2d.gfx.internal.Material")
local LayoutBox <const> = require("tecs2d.ui.internal.LayoutBox")

local lg <const> = love.graphics

-- Circle uses the renderer-owned shadow-column path: per-archetype
-- dispatch, std430 source SSBOs read directly by the cull shader, no
-- slot management. Wiring is provided by `shadow_plugin`.
local CIRCLE_SHADERS <const> = "tecs2d/gfx/internal/circle/"
local renderSource <const> = shaderUtils.loadRenderShader("circle", CIRCLE_SHADERS)
local renderShader <const> = lg.newShader(renderSource)
local cullShader <const> =
    lg.newComputeShader(shaderUtils.loadCullShader("circle_cull", CIRCLE_SHADERS))
local shadowMaskShader <const> = lg.newShader(shaderUtils.loadShader("shadow_mask_circle"))
material_compiler.registerBaseSource("circle", renderSource)

local record circle
    record Circle is tecs.Component, types.Rect
        radius: number
        lineWidth: number  -- 0 = filled, >0 = outline with this width

        metamethod __call: function(self, radius: number, lineWidth?: number): Circle
    end

    plugin: function(world: tecs.World)
end

local Circle <const> = circle.Circle

tecs.newFFIComponent({
    name = "Circle",
    container = Circle,
    fields = {
        {"radius", "float"},
        {"lineWidth", "float"},
    },
    metatable = {
        __index = {
            getRect = function(self: Circle): number, number, number, number
                local r = self.radius
                local size = r * 2
                return -r, -r, size, size
            end
        }
    },
    defaults = {nil, 0},
    init = function(instance: Circle)
        assert(instance.radius, "Missing Circle radius")
    end
})

function circle.plugin(world: tecs.World)
    defineShape.register(world, {
        name = "Circle",
        component = Circle as tecs.Component,
        render = renderShader,
        cull = cullShader,
        shadowMask = shadowMaskShader,
        modifiers = {ColorComponent, ClipBounds, Occluder, Material, LayoutBox},
        tags = {Unlit},
        alphaBlendFilter = true,
    })
end

return circle
