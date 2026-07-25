--- Shadow rendering for direct Images.
---
--- Images stay on the CPU/direct draw path. This plugin only participates in
--- the renderer-owned shadow-mask and drop-shadow AO passes, so enabling an
--- Image does not move ordinary Image drawing into the Sprite batcher.

local tecs <const> = require("tecs")
local types <const> = require("tecs2d.gfx.internal.gpu.types")
local shaderUtils <const> = require("tecs2d.gfx.internal.gpu.shaders")
local Pivot <const> = require("tecs2d.gfx.internal.Pivot")
local ClipBounds <const> = require("tecs2d.gfx.internal.ClipBounds")
local Occluder <const> = require("tecs2d.gfx.internal.Occluder")
local DropShadow <const> = require("tecs2d.gfx.internal.DropShadow")
local Color <const> = require("tecs2d.gfx.internal.Color")
local Material <const> = require("tecs2d.gfx.internal.Material")
local Unlit <const> = require("tecs2d.gfx.internal.Unlit")
local lightMod <const> = require("tecs2d.gfx.internal.Light")
local blend <const> = require("tecs2d.gfx.internal.blend")
local imagematerial <const> =
    require("tecs2d.gfx.internal.image.material")
local gfxTypes <const> = require("tecs2d.gfx.types")
local setOrthographic <const> =
    require("tecs2d.gfx.internal.ortho").setOrthographic
local bit <const> = require("bit")

local lg <const> = love.graphics
local floor <const> = math.floor
local abs <const> = math.abs
local sqrt <const> = math.sqrt
local atan2 <const> = math.atan2
local band <const> = bit.band
local lshift <const> = bit.lshift
local Transform <const> = tecs.builtins.Transform
local Light <const> = lightMod.Light
local SHADER_PATH <const> = "tecs2d/gfx/internal/image/"
local shadowShader <const> = lg.newShader(
    shaderUtils.loadShadowMaskShader("shadow", SHADER_PATH)
)
local dropShadowShader <const> = lg.newShader(
    shaderUtils.loadRenderShader("dropshadow", SHADER_PATH)
)
dropShadowShader:send("LayerRange", {0, 65535})
local uniformPosition <const>: {number} = {0, 0}
local uniformSize <const>: {number} = {0, 0}
local uniformScale <const>: {number} = {1, 1}
local uniformPivot <const>: {number} = {0, 0}
local uniformClip <const>: {number} = {0, 0, 0, 0}

-- Love accepts every Texture in graphics.draw; the bundled declarations do
-- not model Texture as a Drawable subtype.
local drawTexture <const> =
    lg.draw as function(love.graphics.Texture)
local drawImage <const> = lg.draw as function(
    love.graphics.Texture,
    number,
    number,
    number,
    number,
    number,
    number,
    number,
    number,
    number
)

local record image_renderplugin
    record Config
        Image: tecs.Component
        renderer: types.Renderer
        pipeline: gfxTypes.Pipeline
    end

    install: function(world: tecs.World, config: Config)
end

local record ImageData
    texture: love.graphics.Texture
    width: number
    height: number
    repeatX: boolean
    repeatY: boolean
end

local record PivotData
    x: number
    y: number
end

local record ClipData
    minX: number
    minY: number
    maxX: number
    maxY: number
end

local record OccluderData
    height: number
    alphaThreshold: number
end

local record DropShadowData
    height: number
    opacity: number
end

local record LightData
    radius: number
    intensity: number
    height: number
end

local record ImageEntry
    texture: love.graphics.Texture
    width: number
    height: number
    x: number
    y: number
    rotation: number
    scaleX: number
    scaleY: number
    pivotX: number
    pivotY: number
    layer: integer
    hasClip: boolean
    clipMinX: number
    clipMinY: number
    clipMaxX: number
    clipMaxY: number
    occluderHeight: number
    alphaThreshold: number
    dropShadowHeight: number
    dropShadowOpacity: number
end

local record LightEntry
    x: number
    y: number
    radius: number
    intensity: number
    height: number
end

local record ProjectedShadow
    source: ImageEntry
    x: number
    y: number
    rotation: number
    scaleX: number
    scaleY: number
    opacity: number
end

local function setImageUniforms(
    shader: love.graphics.Shader,
    entry: ImageEntry,
    x: number,
    y: number,
    rotation: number,
    scaleX: number,
    scaleY: number,
    pivotX: number,
    pivotY: number
)
    uniformPosition[1], uniformPosition[2] = x, y
    uniformSize[1], uniformSize[2] = entry.width, entry.height
    uniformScale[1], uniformScale[2] = scaleX, scaleY
    uniformPivot[1], uniformPivot[2] = pivotX, pivotY
    shader:send("ImagePosition", uniformPosition)
    shader:send("ImageSize", uniformSize)
    shader:send("ImageScale", uniformScale)
    shader:send("ImagePivot", uniformPivot)
    shader:send("ImageRotation", rotation)
    if shader:hasUniform("ImageLayer") then
        shader:send("ImageLayer", entry.layer)
    end
    shader:send("HasClipBounds", entry.hasClip)
    if entry.hasClip then
        uniformClip[1], uniformClip[2] =
            entry.clipMinX, entry.clipMinY
        uniformClip[3], uniformClip[4] =
            entry.clipMaxX, entry.clipMaxY
        shader:send("ClipBounds", uniformClip)
    end
end

function image_renderplugin.install(
    world: tecs.World,
    config: image_renderplugin.Config
)
    local Image <const> = config.Image
    local renderer <const> = config.renderer
    local pipeline <const> = config.pipeline
    local imageQuery <const> = world:query({
        name = "image.Shadows",
        include = {Image, Transform},
    })
    local lightQuery <const> = world:query({
        name = "image.ShadowLights",
        include = {Light, Transform},
    })

    local images: {ImageEntry} = {}
    local imageCount = 0
    local lights: {LightEntry} = {}
    local lightCount = 0
    local shadows: {ProjectedShadow} = {}
    local shadowCount = 0

    local function drawForwardImage(
        value: ImageData,
        transform: tecs.builtins.Transform,
        material: Material,
        pivot: Pivot,
        clip: ClipBounds,
        unlit: boolean,
        x: number,
        y: number
    )
        local pivotX <const> = pivot and pivot.x or 0
        local pivotY <const> = pivot and pivot.y or 0
        local width <const> = value.width
        local height <const> = value.height
        local scaleX <const> = transform.scaleX or 1
        local scaleY <const> = transform.scaleY or 1
        local bottomY <const> =
            y + (height - height * pivotY) * scaleY
        local depth <const> = pipeline:computeDepth(
            transform.layer,
            transform.z,
            x,
            bottomY
        )
        local shader <const> = imagematerial.bind(
            material,
            transform,
            value as imagematerial.ImageGeometry,
            pivot,
            clip,
            unlit,
            depth,
            renderer._cullGlobalTime,
            x,
            y
        )
        lg.setShader(shader)
        drawImage(
            value.texture,
            x,
            y,
            transform.rotation,
            scaleX,
            scaleY,
            width * pivotX,
            height * pivotY,
            0,
            0
        )
    end

    local function appendImage(
        value: ImageData,
        transform: tecs.builtins.Transform,
        pivot: PivotData,
        clip: ClipData,
        occluder: OccluderData,
        dropShadow: DropShadowData,
        x: number,
        y: number
    )
        imageCount = imageCount + 1
        local entry = images[imageCount]
        if not entry then
            entry = {} as ImageEntry
            images[imageCount] = entry
        end
        entry.texture = value.texture
        entry.width = value.width
        entry.height = value.height
        entry.x = x
        entry.y = y
        entry.rotation = transform.rotation or 0
        entry.scaleX = transform.scaleX or 1
        entry.scaleY = transform.scaleY or 1
        entry.pivotX = pivot and pivot.x or 0
        entry.pivotY = pivot and pivot.y or 0
        entry.layer = transform.layer or 1
        entry.hasClip = clip ~= nil
        entry.clipMinX = clip and clip.minX or 0
        entry.clipMinY = clip and clip.minY or 0
        entry.clipMaxX = clip and clip.maxX or 0
        entry.clipMaxY = clip and clip.maxY or 0
        entry.occluderHeight = occluder and occluder.height or -1
        entry.alphaThreshold =
            occluder and occluder.alphaThreshold or 0.5
        entry.dropShadowHeight =
            dropShadow and dropShadow.height or -1
        entry.dropShadowOpacity =
            dropShadow and dropShadow.opacity or 0
    end

    local plugin: types.RenderPlugin = {
        name = "ImageShadows",
    }

    plugin.cull = function(r: types.Renderer, _params: love.graphics.Buffer)
        imageCount = 0
        shadowCount = 0
        local viewport <const> = r._cullViewport
        local camera <const> = r._cullCameraPos
        local cameraMask <const> = r._cullCameraLayerMask
        local margin <const> = r.config.shadowMargin or 200

        lightCount = 0
        for archetype, len in lightQuery:iter() do
            local lightValues <const> =
                archetype:get(Light) as {LightData}
            local lightTransforms <const> =
                archetype:get(Transform) as {tecs.builtins.Transform}
            for row = 1, len do
                lightCount = lightCount + 1
                local entry = lights[lightCount]
                if not entry then
                    entry = {} as LightEntry
                    lights[lightCount] = entry
                end
                local light <const> = lightValues[row]
                local transform <const> = lightTransforms[row]
                entry.x = transform.x
                entry.y = transform.y
                entry.radius = light.radius
                entry.intensity = light.intensity
                entry.height = light.height
            end
        end

        for archetype, len in imageQuery:iter() do
            local values <const> =
                archetype:get(Image) as {ImageData}
            local transforms <const> =
                archetype:get(Transform) as {tecs.builtins.Transform}
            local pivots <const> =
                archetype:get(Pivot) as {PivotData}
            local clips <const> =
                archetype:get(ClipBounds) as {ClipData}
            local occluders <const> =
                archetype:get(Occluder) as {OccluderData}
            local dropShadows <const> =
                archetype:get(DropShadow) as {DropShadowData}

            for row = 1, len do
                local value <const> = values[row]
                local transform <const> = transforms[row]
                local layer <const> = transform.layer or 1
                if band(cameraMask, lshift(1, layer - 1)) ~= 0
                    and (occluders ~= nil or dropShadows ~= nil)
                then
                    local pivot = pivots and pivots[row]
                    local pivotX <const> = pivot and pivot.x or 0
                    local pivotY <const> = pivot and pivot.y or 0
                    local scaleX <const> = transform.scaleX or 1
                    local scaleY <const> = transform.scaleY or 1
                    local drawWidth <const> = value.width * abs(scaleX)
                    local drawHeight <const> = value.height * abs(scaleY)
                    local parallaxX <const> =
                        r._cullParallaxMatX[layer] or 1
                    local parallaxY <const> =
                        r._cullParallaxMatY[layer] or 1
                    local drawX <const> =
                        transform.x + camera[1] * (1 - parallaxX)
                    local drawY <const> =
                        transform.y + camera[2] * (1 - parallaxY)

                    if value.repeatX or value.repeatY then
                        local baseLeft <const> =
                            drawX - value.width * pivotX * scaleX
                        local baseTop <const> =
                            drawY - value.height * pivotY * scaleY
                        local firstX, lastX = 0, 0
                        local firstY, lastY = 0, 0
                        if value.repeatX and drawWidth > 0 then
                            firstX =
                                floor((viewport[1] - margin - baseLeft)
                                    / drawWidth) - 1
                            lastX =
                                floor((viewport[3] + margin - baseLeft)
                                    / drawWidth) + 1
                        end
                        if value.repeatY and drawHeight > 0 then
                            firstY =
                                floor((viewport[2] - margin - baseTop)
                                    / drawHeight) - 1
                            lastY =
                                floor((viewport[4] + margin - baseTop)
                                    / drawHeight) + 1
                        end
                        for repeatY = firstY, lastY do
                            for repeatX = firstX, lastX do
                                appendImage(
                                    value,
                                    transform,
                                    pivot,
                                    clips and clips[row],
                                    occluders and occluders[row],
                                    dropShadows and dropShadows[row],
                                    drawX + repeatX * drawWidth,
                                    drawY + repeatY * drawHeight
                                )
                            end
                        end
                    else
                        local radius <const> = sqrt(
                            drawWidth * drawWidth
                            + drawHeight * drawHeight
                        )
                        if drawX + radius + margin > viewport[1]
                            and drawX - radius - margin < viewport[3]
                            and drawY + radius + margin > viewport[2]
                            and drawY - radius - margin < viewport[4]
                        then
                            appendImage(
                                value,
                                transform,
                                pivot,
                                clips and clips[row],
                                occluders and occluders[row],
                                dropShadows and dropShadows[row],
                                drawX,
                                drawY
                            )
                        end
                    end
                end
            end
        end

        for imageIndex = 1, imageCount do
            local source <const> = images[imageIndex]
            if source.dropShadowHeight >= 0 then
                local footX <const> = source.x
                    + source.width * source.scaleX
                        * (0.5 - source.pivotX)
                local footY <const> = source.y
                    + source.height * source.scaleY
                        * (1 - source.pivotY)
                local imageHeight <const> =
                    source.height * abs(source.scaleY)
                for lightIndex = 1, lightCount do
                    local light <const> = lights[lightIndex]
                    local dx <const> = footX - light.x
                    local dy <const> = footY - light.y
                    local distance <const> = sqrt(dx * dx + dy * dy)
                    if distance <= light.radius then
                        local ratio <const> = distance / light.radius
                        local attenuation <const> = 1 - ratio * ratio
                        local weight <const> =
                            light.intensity * attenuation
                        if weight >= 0.05 then
                            local dirX, dirY = 0.0, 1.0
                            if distance > 0.001 then
                                dirX = dx / distance
                                dirY = dy / distance
                            end
                            local distanceRatio <const> =
                                distance / math.max(
                                    light.radius * light.height,
                                    1
                                )
                            local heightFactor <const> =
                                (1 - light.height)
                                / math.max(light.height, 0.15)
                            local length <const> = math.max(
                                imageHeight * 0.2,
                                math.min(
                                    imageHeight * 3,
                                    imageHeight
                                        * source.dropShadowHeight
                                        * (0.3 + distanceRatio * 1.5)
                                        * math.min(heightFactor, 2)
                                )
                            )

                            shadowCount = shadowCount + 1
                            local shadow = shadows[shadowCount]
                            if not shadow then
                                shadow = {} as ProjectedShadow
                                shadows[shadowCount] = shadow
                            end
                            shadow.source = source
                            shadow.x = footX
                            shadow.y = footY
                            shadow.rotation = atan2(-dirX, dirY)
                            shadow.scaleX = abs(source.scaleX)
                            shadow.scaleY =
                                abs(source.scaleY)
                                * length
                                / math.max(imageHeight, 0.001)
                            shadow.opacity =
                                source.dropShadowOpacity
                                * math.max(0, math.min(weight, 1))
                        end
                    end
                end
            end
        end
        r._hasDropShadows =
            r._hasDropShadows or shadowCount > 0
    end

    plugin.renderShadowMask = function(
        _r: types.Renderer,
        shadowTransform: love.math.Transform
    )
        if imageCount == 0 then return end
        lg.setShader(shadowShader)
        shadowShader:send("ShadowViewProj", shadowTransform)
        lg.setColor(1, 1, 1, 1)
        for index = 1, imageCount do
            local entry <const> = images[index]
            if entry.occluderHeight >= 0 then
                setImageUniforms(
                    shadowShader,
                    entry,
                    entry.x,
                    entry.y,
                    entry.rotation,
                    entry.scaleX,
                    entry.scaleY,
                    entry.pivotX,
                    entry.pivotY
                )
                shadowShader:send(
                    "OccluderHeight",
                    entry.occluderHeight
                )
                shadowShader:send(
                    "AlphaThreshold",
                    entry.alphaThreshold
                )
                drawTexture(entry.texture)
            end
        end
    end

    plugin.renderDropShadowAO = function(
        _r: types.Renderer,
        renderParams: love.graphics.Buffer
    )
        if shadowCount == 0 then return end
        lg.setShader(dropShadowShader)
        dropShadowShader:send("RenderParams", renderParams)
        lg.setColor(1, 1, 1, 1)

        dropShadowShader:send("StampSource", false)
        dropShadowShader:send("FlipTextureY", true)
        for index = 1, shadowCount do
            local shadow <const> = shadows[index]
            local source <const> = shadow.source
            setImageUniforms(
                dropShadowShader,
                source,
                shadow.x,
                shadow.y,
                shadow.rotation,
                shadow.scaleX,
                shadow.scaleY,
                0.5,
                0
            )
            dropShadowShader:send("ShadowOpacity", shadow.opacity)
            dropShadowShader:send("MainTex", source.texture)
            drawTexture(source.texture)
        end

        lg.setBlendMode("lighten", "premultiplied")
        dropShadowShader:send("StampSource", true)
        dropShadowShader:send("FlipTextureY", false)
        for index = 1, imageCount do
            local source <const> = images[index]
            setImageUniforms(
                dropShadowShader,
                source,
                source.x,
                source.y,
                source.rotation,
                source.scaleX,
                source.scaleY,
                source.pivotX,
                source.pivotY
            )
            dropShadowShader:send("MainTex", source.texture)
            drawTexture(source.texture)
        end
        lg.setShader()
    end

    plugin.renderForwardBlend = function(
        r: types.Renderer,
        cameraX: number,
        cameraY: number,
        cameraZoom: number,
        useLowRes: boolean,
        subPixelX: number,
        subPixelY: number
    )
        local virtualW <const> = r.config.virtualRes[1]
        local virtualH <const> = r.config.virtualRes[2]
        local renderW <const> = useLowRes and virtualW or r.screenWidth
        local renderH <const> = useLowRes and virtualH or r.screenHeight
        local rotation <const> =
            r._renderPhase == "screen" and 0 or r.camera._renderRotation
        setOrthographic(
            r._renderTransform,
            cameraX,
            cameraY,
            cameraZoom,
            rotation,
            renderW,
            renderH,
            subPixelX,
            subPixelY
        )

        local viewport <const> = r._cullViewport
        local cameraMask <const> = r._cullCameraLayerMask
        local layerRange <const> = r._layerRange
        local camera <const> = r._cullCameraPos
        local drew = false

        lg.push("transform")
        lg.replaceTransform(r._renderTransform)
        for archetype, len in imageQuery:iter() do
            local blendId <const> = blend.groupBy(archetype)
            if blendId > 0 then
                local blendInfo <const> = blend.INFO_BY_ID[blendId]
                local values <const> =
                    archetype:get(Image) as {ImageData}
                local transforms <const> =
                    archetype:get(Transform) as {tecs.builtins.Transform}
                local colors <const> =
                    archetype:get(Color) as {Color}
                local pivots <const> =
                    archetype:get(Pivot) as {Pivot}
                local clips <const> =
                    archetype:get(ClipBounds) as {ClipBounds}
                local materials <const> =
                    archetype:get(Material) as {Material}
                local unlit <const> = archetype:get(Unlit) ~= nil

                lg.setBlendMode(blendInfo.mode, blendInfo.alphaMode)
                for row = 1, len do
                    local value <const> = values[row]
                    local transform <const> = transforms[row]
                    local layer <const> = transform.layer or 1
                    if band(cameraMask, lshift(1, layer - 1)) ~= 0
                            and layer >= layerRange[1]
                            and layer <= layerRange[2] then
                        local pivot <const> = pivots and pivots[row]
                        local pivotX <const> = pivot and pivot.x or 0
                        local pivotY <const> = pivot and pivot.y or 0
                        local scaleX <const> = transform.scaleX or 1
                        local scaleY <const> = transform.scaleY or 1
                        local width <const> = value.width
                        local height <const> = value.height
                        local drawWidth <const> = width * abs(scaleX)
                        local drawHeight <const> = height * abs(scaleY)
                        local parallaxX <const> =
                            r._cullParallaxMatX[layer] or 1
                        local parallaxY <const> =
                            r._cullParallaxMatY[layer] or 1
                        local anchorX <const> =
                            transform.x + camera[1] * (1 - parallaxX)
                        local anchorY <const> =
                            transform.y + camera[2] * (1 - parallaxY)
                        local color <const> = colors and colors[row]
                        if color then
                            lg.setColor(
                                color.r,
                                color.g,
                                color.b,
                                color.a
                            )
                        else
                            lg.setColor(1, 1, 1, 1)
                        end

                        if value.repeatX or value.repeatY then
                            local baseLeft <const> =
                                anchorX - width * pivotX * scaleX
                            local baseTop <const> =
                                anchorY - height * pivotY * scaleY
                            local firstX, lastX = 0, 0
                            local firstY, lastY = 0, 0
                            if value.repeatX and drawWidth > 0 then
                                firstX = floor(
                                    (viewport[1] - baseLeft) / drawWidth
                                ) - 1
                                lastX = floor(
                                    (viewport[3] - baseLeft) / drawWidth
                                ) + 1
                            end
                            if value.repeatY and drawHeight > 0 then
                                firstY = floor(
                                    (viewport[2] - baseTop) / drawHeight
                                ) - 1
                                lastY = floor(
                                    (viewport[4] - baseTop) / drawHeight
                                ) + 1
                            end
                            for repeatY = firstY, lastY do
                                local y <const> =
                                    anchorY + repeatY * drawHeight
                                for repeatX = firstX, lastX do
                                    drawForwardImage(
                                        value,
                                        transform,
                                        materials and materials[row],
                                        pivot,
                                        clips and clips[row],
                                        unlit,
                                        anchorX + repeatX * drawWidth,
                                        y
                                    )
                                    drew = true
                                end
                            end
                        else
                            local radius <const> = sqrt(
                                drawWidth * drawWidth
                                + drawHeight * drawHeight
                            )
                            if anchorX + radius > viewport[1]
                                    and anchorX - radius < viewport[3]
                                    and anchorY + radius > viewport[2]
                                    and anchorY - radius < viewport[4] then
                                drawForwardImage(
                                    value,
                                    transform,
                                    materials and materials[row],
                                    pivot,
                                    clips and clips[row],
                                    unlit,
                                    anchorX,
                                    anchorY
                                )
                                drew = true
                            end
                        end
                    end
                end
            end
        end
        lg.pop()

        if drew then
            lg.setColor(1, 1, 1, 1)
            lg.setBlendMode("alpha", "alphamultiply")
            lg.setShader()
        end
    end

    plugin.setLayerRange = function(
        _r: types.Renderer,
        range: {number}
    )
        dropShadowShader:send("LayerRange", range)
    end

    renderer:registerPlugin(plugin)
end

return image_renderplugin
