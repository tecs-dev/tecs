--- Material shader binding for direct Image draws.

local Material <const> = require("tecs2d.gfx.internal.Material")
local ClipBounds <const> = require("tecs2d.gfx.internal.ClipBounds")
local Pivot <const> = require("tecs2d.gfx.internal.Pivot")
local tecs <const> = require("tecs")
local materialcompiler <const> =
    require("tecs2d.gfx.internal.materialcompiler")
local materialregistry <const> =
    require("tecs2d.gfx.internal.materialregistry")
local lg <const> = love.graphics

local record imagematerial
    --- Image geometry needed by the direct shader binder.
    ---
    --- Kept structural so this module does not create an Image module cycle.
    interface ImageGeometry
        width: number
        height: number
    end

    --- Bind the base or Material shader for a direct Image draw.
    ---
    --- The returned shader is ready to pass to
    --- `pipeline:worldShader():shader()`.
    bind: function(
        material: Material | nil,
        transform: tecs.builtins.Transform,
        image: ImageGeometry,
        pivot: Pivot | nil,
        clipBounds: ClipBounds | nil,
        unlit: boolean,
        depth: number,
        globalTime: number,
        anchorX?: number,
        anchorY?: number
    ): love.graphics.Shader
end

local source, sourceError = love.filesystem.read(
    "tecs2d/gfx/internal/image/material.glsl"
)
if not source then
    error("Failed to load Image material shader: " .. tostring(sourceError))
end
materialcompiler.registerBaseSource("image", source)
local baseShader <const> = lg.newShader(source)

-- Reused uniform values keep Image's direct draw path allocation-free.
local anchor <const>: {number} = {0, 0}
local scale <const>: {number} = {1, 1}
local size <const>: {number} = {1, 1}
local origin <const>: {number} = {0, 0}
local clip <const>: {number} = {-3.4e38, -3.4e38, 3.4e38, 3.4e38}
local params <const>: {number} = {0, 0, 0, 0}
local worldToScreen <const>: {number} = {1, 0, 0, 1}

function imagematerial.bind(
    material: Material | nil,
    transform: tecs.builtins.Transform,
    image: imagematerial.ImageGeometry,
    pivot: Pivot | nil,
    clipBounds: ClipBounds | nil,
    unlit: boolean,
    depth: number,
    globalTime: number,
    anchorX?: number,
    anchorY?: number
): love.graphics.Shader
    local shader = baseShader
    local materialValue <const> = material as Material
    if materialValue and materialValue.materialId ~= 0 then
        shader = materialcompiler.compile(materialValue.materialId, "image")
        if not shader then
            error("Image has an unregistered Material id "
                .. tostring(materialValue.materialId))
        end
    end

    anchor[1] = anchorX or transform.x
    anchor[2] = anchorY or transform.y
    scale[1], scale[2] = transform.scaleX, transform.scaleY
    size[1], size[2] = image.width, image.height
    local pivotValue <const> = pivot as Pivot
    local pivotX <const> = pivotValue and pivotValue.x or 0
    local pivotY <const> = pivotValue and pivotValue.y or 0
    origin[1] = image.width * pivotX
    origin[2] = image.height * pivotY
    local clipValue <const> = clipBounds as ClipBounds
    if clipValue then
        clip[1], clip[2] = clipValue.minX, clipValue.minY
        clip[3], clip[4] = clipValue.maxX, clipValue.maxY
    else
        clip[1], clip[2] = -3.4e38, -3.4e38
        clip[3], clip[4] = 3.4e38, 3.4e38
    end
    if materialValue then
        params[1], params[2] = materialValue.p0, materialValue.p1
        params[3], params[4] = materialValue.p2, materialValue.p3
    else
        params[1], params[2], params[3], params[4] = 0, 0, 0, 0
    end

    shader:send("tecs_ImageAnchor", anchor)
    shader:send("tecs_ImageScale", scale)
    shader:send("tecs_ImageSize", size)
    shader:send("tecs_ImageRotation", transform.rotation)
    shader:send("tecs_ImageOrigin", origin)
    shader:send("tecs_ClipBounds", clip)
    shader:send("tecs_Depth", depth)
    shader:send("tecs_Lit", unlit and 0.0 or 1.0)

    if materialValue and materialValue.materialId ~= 0 then
        shader:send("MaterialParams", params)
        shader:send("GlobalTime", globalTime)
        local def <const> =
            materialregistry.getById(materialValue.materialId)
        if def then
            if def.vertexSource then
                local screenX, screenY = lg.transformPoint(0, 0)
                local screenXX, screenXY = lg.transformPoint(1, 0)
                local screenYX, screenYY = lg.transformPoint(0, 1)
                worldToScreen[1], worldToScreen[2] =
                    screenXX - screenX, screenYX - screenX
                worldToScreen[3], worldToScreen[4] =
                    screenXY - screenY, screenYY - screenY
                shader:send(
                    "tecs_WorldToScreenLinear",
                    worldToScreen
                )
            end
            for uniformName, texture in pairs(def.textures) do
                if shader:hasUniform(uniformName) then
                    shader:send(uniformName, texture)
                end
            end
        end
    end

    return shader
end

return imagematerial
