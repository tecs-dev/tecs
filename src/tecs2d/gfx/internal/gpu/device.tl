--- Process-owned GPU resources shared by every render pipeline.
---
--- This object contains only resources whose contents do not belong to a
--- world: compiled shaders and fallback textures, plus transient render
--- targets that sequential pipelines may reuse. Entity mirrors, cull output,
--- cameras, and persistent pipeline outputs remain world/pipeline-owned.

local gpuTypes <const> = require("tecs2d.gfx.internal.gpu.types")
local devicestate <const> = require("tecs2d.gfx.internal.gpu.devicestate")
local shaders <const> = require("tecs2d.gfx.internal.gpu.shaders")

local lg <const> = love.graphics

local record device
    get: function(): devicestate.Resources
end

local resources <const> = devicestate.get()

local function solidImage(width: integer, height: integer,
        r: number, g: number, b: number, a: number): love.graphics.Image
    local data = love.image.newImageData(width, height)
    data:mapPixel(function(): number, number, number, number
        return r, g, b, a
    end)
    local image = lg.newImage(data)
    image:setFilter("nearest", "nearest")
    return image
end

function device.get(): devicestate.Resources
    if resources.lightingShader then return resources end

    resources.lightingShader = lg.newShader(shaders.LIGHTING)
    resources.shadowBlurShader = lg.newShader(shaders.SHADOW_BLUR)
    resources.screenUnlitShader = lg.newShader(shaders.SCREEN_UNLIT)
    resources.bloomDownsampleShader = lg.newShader(shaders.BLOOM_DOWNSAMPLE)
    resources.bloomUpsampleShader = lg.newShader(shaders.BLOOM_UPSAMPLE)
    resources.cpuWorldShader = lg.newShader(shaders.CPU_WORLD)
    resources.layerCompositeShader = lg.newShader(shaders.LAYER_COMPOSITE)
    resources.dummyMaterialParamsBuffer = lg.newBuffer(
        gpuTypes.MATERIAL_PARAMS_FORMAT,
        1,
        {usage = "dynamic", shaderstorage = true}
    )
    resources.defaultTexture = solidImage(16, 16, 1, 1, 1, 1)
    resources.flatNormalTexture = solidImage(1, 1, 0.5, 0.5, 1, 0)
    resources.blackEmissionTexture = solidImage(1, 1, 0, 0, 0, 1)
    resources.defaultORMTexture = solidImage(1, 1, 1, 0.5, 0, 0)
    return resources
end

return device
