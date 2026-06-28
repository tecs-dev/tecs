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
local Pivot <const> = require("tecs2d.gfx.internal.Pivot")
local RoundedCorners <const> = require("tecs2d.gfx.internal.rectangle.RoundedCorners")

local lg <const> = love.graphics

-- Rectangle uses the renderer-owned shadow-column path; wiring is
-- provided by `shadow_plugin`.
local RECT_SHADERS <const> = "tecs2d/gfx/internal/rectangle/"
local renderSource <const> = shaderUtils.loadRenderShader("rectangle", RECT_SHADERS)
local renderShader <const> = lg.newShader(renderSource)
local cullShader <const> =
    lg.newComputeShader(shaderUtils.loadCullShader("rect_cull", RECT_SHADERS))
local shadowMaskShader <const> = lg.newShader(shaderUtils.loadShader("shadow_mask_rect"))
material_compiler.registerBaseSource("rectangle", renderSource)

local record rectangle
    record Rectangle is tecs.Component, types.Rect
        width: number
        height: number
        lineWidth: number  -- 0 = filled, >0 = outline with this width

        metamethod __call: function(
            self,
            width: number,
            height: number,
            lineWidth?: number
        ): Rectangle
    end

    plugin: function(world: tecs.World)
end

local Rectangle <const> = rectangle.Rectangle

tecs.newFFIComponent({
    name = "Rectangle",
    container = Rectangle,
    fields = {
        {"width", "float"},
        {"height", "float"},
        {"lineWidth", "float"},
    },
    metatable = {
        __index = {
            getRect = function(self: Rectangle): number, number, number, number
                local w, h = self.width, self.height
                return -w * 0.5, -h * 0.5, w, h
            end
        }
    },
    defaults = {nil, nil, 0, -1},
    init = function(instance: Rectangle)
        -- Reject negative width/height: the SDF fragment math assumes
        -- non-negative half extents, and the cull shader silently
        -- takes the magnitude to stay robust against negative
        -- scaleX/scaleY (mirroring). For mirroring, use a negative
        -- Transform scale.
        assert(instance.width, "Missing Rectangle width")
        assert(instance.height, "Missing Rectangle height")
        assert(instance.width >= 0, "Rectangle width must be non-negative")
        assert(instance.height >= 0, "Rectangle height must be non-negative")
    end
})

function rectangle.plugin(world: tecs.World)
    defineShape.register(world, {
        name = "Rectangle",
        prefix = "Rect",                 -- gpuTypes constants are RECT_*
        component = Rectangle as tecs.Component,
        render = renderShader,
        cull = cullShader,
        shadowMask = shadowMaskShader,
        modifiers = {
            ColorComponent, ClipBounds, Occluder, Material,
            LayoutBox, Pivot, RoundedCorners,
        },
        tags = {Unlit},
        alphaBlendFilter = true,
    })
end

return rectangle
