local tecs <const> = require("tecs")
local types <const> = require("tecs2d.gfx.types")
local gpuTypes <const> = require("tecs2d.gfx.internal.gpu.types")
local shaderUtils <const> = require("tecs2d.gfx.internal.gpu.shaders")
local material_compiler <const> = require("tecs2d.gfx.internal.material_compiler")
local shadow_plugin <const> = require("tecs2d.gfx.internal.gpu.shadow_plugin")
local std430 <const> = require("tecs2d.gfx.internal.gpu.std430")

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
    shadow_plugin.register(world, {
        prefix = "Rect",
        plural = "Rects",
        materialShapeName = "rectangle",
        sizeHintKey = "rects",
        registryName = "rectangle.shadows",
        renderStateSystemName = "rectangle.ShadowRenderState",
        uploadSystemName = "rectangle.ShadowUpload",

        primary = Rectangle as tecs.Component,
        primaryLayout = std430.layouts.Rectangle,
        primaryInputName = "RectangleInput",

        optional = {
            {component = ColorComponent,    layout = std430.layouts.Color,          mask = 0x1,  ssboName = "ColorInput"},
            {component = ClipBounds,        layout = std430.layouts.ClipBounds,     mask = 0x2,  ssboName = "ClipBoundsInput"},
            {component = Occluder,          layout = std430.layouts.Occluder,       mask = 0x8,  ssboName = "OccluderInput"},
            {component = Material,          layout = std430.layouts.Material,       mask = 0x10, ssboName = "MaterialInput"},
            {component = LayoutBox,         layout = std430.layouts.LayoutBox,      mask = 0x20, ssboName = "LayoutBoxInput"},
            {component = Pivot,             layout = std430.layouts.Pivot,          mask = 0x40, ssboName = "PivotInput"},
            {component = RoundedCorners,    layout = std430.layouts.RoundedCorners, mask = 0x80, ssboName = "RoundedCornersInput"},
        },

        tagFlags = {
            {component = Unlit, flag = gpuTypes.FLAG_UNLIT},
        },

        cullShader = cullShader,
        renderShader = renderShader,
        shadowMaskShader = shadowMaskShader,
        outputFormat = gpuTypes.RECT_FORMAT,
        outputName = "RectOutput",
        shadowOutputName = "RectShadowOutput",

        stub = {
            transformFormat = gpuTypes.RECT_TRANSFORM_FORMAT,
            transformCtype = gpuTypes.RECT_TRANSFORM_CTYPE,
            metadataFormat = gpuTypes.RECT_METADATA_FORMAT,
            metadataCtype = gpuTypes.RECT_METADATA_CTYPE,
            inputFormat = gpuTypes.RECT_FORMAT,
            inputCtype = gpuTypes.RECT_CTYPE,
        },

        hasShadow = true,
        hasAlphaBlendFilter = true,
    })
end

return rectangle
