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
local Material <const> = require("tecs2d.gfx.internal.Material")
local Pivot <const> = require("tecs2d.gfx.internal.Pivot")

local lg <const> = love.graphics

-- Ellipse uses the renderer-owned shadow-column path; wiring is
-- provided by `shadow_plugin`. No shadow path (ellipses don't cast
-- raymarched shadows in the legacy renderer either).
local ELLIPSE_SHADERS <const> = "tecs2d/gfx/internal/ellipse/"
local renderSource <const> = shaderUtils.loadRenderShader("ellipse", ELLIPSE_SHADERS)
local renderShader <const> = lg.newShader(renderSource)
local cullShader <const> =
    lg.newComputeShader(shaderUtils.loadCullShader("ellipse_cull", ELLIPSE_SHADERS))
material_compiler.registerBaseSource("ellipse", renderSource)

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
    defaults = {nil, nil, 0, -1},
    init = function(instance: Ellipse)
        assert(instance.radiusX, "Missing Ellipse radiusX")
        assert(instance.radiusY, "Missing Ellipse radiusY")
    end
})

function ellipse.plugin(world: tecs.World)
    shadow_plugin.register(world, {
        prefix = "Ellipse",
        plural = "Ellipses",
        materialShapeName = "ellipse",
        sizeHintKey = "ellipses",
        registryName = "ellipse.shadows",
        renderStateSystemName = "ellipse.ShadowRenderState",
        uploadSystemName = "ellipse.ShadowUpload",

        primary = Ellipse as tecs.Component,
        primaryLayout = std430.layouts.Ellipse,
        primaryInputName = "EllipseInput",

        optional = {
            {component = ColorComponent, layout = std430.layouts.Color,       mask = 0x1,  ssboName = "ColorInput"},
            {component = ClipBounds,     layout = std430.layouts.ClipBounds,  mask = 0x2,  ssboName = "ClipBoundsInput"},
            {component = Material,       layout = std430.layouts.Material,    mask = 0x8,  ssboName = "MaterialInput"},
            {component = Pivot,          layout = std430.layouts.Pivot,       mask = 0x10, ssboName = "PivotInput"},
        },

        tagFlags = {
            {component = Unlit, flag = gpuTypes.FLAG_UNLIT},
        },

        cullShader = cullShader,
        renderShader = renderShader,
        shadowMaskShader = nil,
        outputFormat = gpuTypes.ELLIPSE_FORMAT,
        outputName = "EllipseOutput",
        shadowOutputName = "",

        stub = {
            transformFormat = gpuTypes.ELLIPSE_TRANSFORM_FORMAT,
            transformCtype = gpuTypes.ELLIPSE_TRANSFORM_CTYPE,
            metadataFormat = gpuTypes.ELLIPSE_METADATA_FORMAT,
            metadataCtype = gpuTypes.ELLIPSE_METADATA_CTYPE,
            inputFormat = gpuTypes.ELLIPSE_FORMAT,
            inputCtype = gpuTypes.ELLIPSE_CTYPE,
        },

        hasShadow = false,
        hasAlphaBlendFilter = false,
    })
end

return ellipse
