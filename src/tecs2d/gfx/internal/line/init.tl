local tecs <const> = require("tecs")
local gpuTypes <const> = require("tecs2d.gfx.internal.gpu.types")
local shaderUtils <const> = require("tecs2d.gfx.internal.gpu.shaders")
local material_compiler <const> = require("tecs2d.gfx.internal.material_compiler")
local shadow_plugin <const> = require("tecs2d.gfx.internal.gpu.shadow_plugin")
local std430 <const> = require("tecs2d.gfx.internal.gpu.std430")

local ColorComponent <const> = require("tecs2d.gfx.internal.Color")
local ClipBounds <const> = require("tecs2d.gfx.internal.ClipBounds")
local Unlit <const> = require("tecs2d.gfx.internal.Unlit")
local Material <const> = require("tecs2d.gfx.internal.Material")

local lg <const> = love.graphics

-- Line uses the renderer-owned shadow-column path; wiring is provided
-- by `shadow_plugin`. No shadow path (lines don't cast raymarched
-- shadows) and no Pivot (lines have explicit endpoints).
local LINE_SHADERS <const> = "tecs2d/gfx/internal/line/"
local renderSource <const> = shaderUtils.loadRenderShader("line", LINE_SHADERS)
local renderShader <const> = lg.newShader(renderSource)
local cullShader <const> =
    lg.newComputeShader(shaderUtils.loadCullShader("line_cull", LINE_SHADERS))
material_compiler.registerBaseSource("line", renderSource)

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
    shadow_plugin.register(world, {
        prefix = "Line",
        plural = "Lines",
        materialShapeName = "line",
        sizeHintKey = "lines",
        registryName = "line.shadows",
        renderStateSystemName = "line.ShadowRenderState",
        uploadSystemName = "line.ShadowUpload",

        primary = Line as tecs.Component,
        primaryLayout = std430.layouts.Line,
        primaryInputName = "LineInput",

        optional = {
            {component = ColorComponent, layout = std430.layouts.Color,       mask = 0x1, ssboName = "ColorInput"},
            {component = ClipBounds,     layout = std430.layouts.ClipBounds,  mask = 0x2, ssboName = "ClipBoundsInput"},
            {component = Material,       layout = std430.layouts.Material,    mask = 0x8, ssboName = "MaterialInput"},
        },

        tagFlags = {
            {component = Unlit, flag = gpuTypes.FLAG_UNLIT},
        },

        cullShader = cullShader,
        renderShader = renderShader,
        shadowMaskShader = nil,
        outputFormat = gpuTypes.LINE_FORMAT,
        outputName = "LineOutput",
        shadowOutputName = "",

        stub = {
            transformFormat = gpuTypes.LINE_TRANSFORM_FORMAT,
            transformCtype = gpuTypes.LINE_TRANSFORM_CTYPE,
            metadataFormat = gpuTypes.LINE_METADATA_FORMAT,
            metadataCtype = gpuTypes.LINE_METADATA_CTYPE,
            inputFormat = gpuTypes.LINE_FORMAT,
            inputCtype = gpuTypes.LINE_CTYPE,
        },

        hasShadow = false,
        hasAlphaBlendFilter = false,
    })
end

return line
