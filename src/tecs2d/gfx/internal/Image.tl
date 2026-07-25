--- Direct, unbatched rendering for complete textures.
---
--- Image is the explicit path for a small number of unique textures,
--- textures that do not fit Sprite's buckets, canvases, and Tiled image
--- layers. Use Sprite when batching or animation matters.

local tecs <const> = require("tecs")
local pipelinekey <const> = require("tecs2d.gfx.internal.pipelinekey")
local gpuTypes <const> = require("tecs2d.gfx.internal.gpu.types")
local Color <const> = require("tecs2d.gfx.internal.Color")
local Pivot <const> = require("tecs2d.gfx.internal.Pivot")
local Unlit <const> = require("tecs2d.gfx.internal.Unlit")
local Material <const> = require("tecs2d.gfx.internal.Material")
local ClipBounds <const> = require("tecs2d.gfx.internal.ClipBounds")
local blend <const> = require("tecs2d.gfx.internal.blend")
local bit <const> = require("bit")

local Transform <const> = tecs.builtins.Transform
local lg <const> = love.graphics
local floor <const> = math.floor
local abs <const> = math.abs
local sqrt <const> = math.sqrt
local band <const> = bit.band
local lshift <const> = bit.lshift
-- Love accepts every Texture in graphics.draw; narrow the overload because
-- the bundled declarations do not model Texture as a Drawable subtype.
local lgDraw <const> = lg.draw as function(
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

local record image
    --- Construction options for a directly drawn Image.
    record ImageOptions
        --- Durable asset path used to reconstruct the texture in snapshots.
        --- Images without a path are omitted from snapshot serialization.
        path: string

        --- Repeat the complete texture horizontally across the visible view.
        repeatX: boolean

        --- Repeat the complete texture vertically across the visible view.
        repeatY: boolean
    end

    --- A complete texture drawn directly through Love.
    ---
    --- Image is intentionally unbatched. Prefer Sprite for animation or
    --- collections of textures that benefit from automatic batching.
    --- Requires a Transform component.
    record Image is tecs.Component
        --- Texture drawn by this component.
        texture: love.graphics.Texture

        --- Texture width captured at construction.
        width: number

        --- Texture height captured at construction.
        height: number

        --- Durable asset path, or an empty string for an in-memory texture.
        path: string

        --- Whether the complete texture repeats horizontally.
        repeatX: boolean

        --- Whether the complete texture repeats vertically.
        repeatY: boolean

        --- Construct an Image from an already-loaded texture.
        --- @param texture Texture to draw.
        --- @param options Optional path and repetition settings.
        --- @return A directly drawn Image component.
        metamethod __call: function(
            self,
            texture: love.graphics.Texture,
            options?: ImageOptions
        ): Image

        --- Construct an Image from an already-loaded texture.
        --- @param texture Texture to draw.
        --- @param options Optional path and repetition settings.
        --- @return A directly drawn Image component.
        fromTexture: function(
            texture: love.graphics.Texture,
            options?: ImageOptions
        ): Image
    end

    --- Register direct Image rendering for a world.
    plugin: function(world: tecs.World)
end

local Image <const> = image.Image

local function initialize(
    instance: image.Image,
    texture: love.graphics.Texture,
    options?: image.ImageOptions
)
    assert(texture, "Image requires a texture")
    local width, height = texture:getDimensions()
    instance.texture = texture
    instance.width = width
    instance.height = height
    instance.path = (options and options.path) or ""
    instance.repeatX = options and options.repeatX == true or false
    instance.repeatY = options and options.repeatY == true or false
end

tecs.newComponent({
    name = "Image",
    container = Image,
    fields = {"texture", "width", "height", "path", "repeatX", "repeatY"},
    __call = function(
        instance: image.Image,
        texture: love.graphics.Texture,
        options?: image.ImageOptions
    )
        initialize(instance, texture, options)
    end,
    serialize = function(instance: image.Image): {string: any}
        if instance.path == "" then
            return nil
        end
        return {
            path = instance.path,
            repeatX = instance.repeatX,
            repeatY = instance.repeatY,
        }
    end,
    deserialize = function(_world: tecs.World, data: {string: any}): image.Image
        local path = data.path as string
        local texture = love.graphics.newImage(path)
        return Image(texture as love.graphics.Texture, {
            path = path,
            repeatX = data.repeatX == true,
            repeatY = data.repeatY == true,
        })
    end,
})

function Image.fromTexture(
    texture: love.graphics.Texture,
    options?: image.ImageOptions
): image.Image
    return Image(texture, options)
end

function image.plugin(world: tecs.World)
    -- Shader-backed helpers are loaded only when the rendering plugin is
    -- installed. Constructing and serializing Image values stays usable in
    -- tooling and unit-test environments without a Love 12 GPU context.
    local imagematerial <const> =
        require("tecs2d.gfx.internal.image.material")
    local renderplugin <const> =
        require("tecs2d.gfx.internal.image.renderplugin")
    local pipeline <const> =
        world.resources[pipelinekey.PIPELINE]
    if not pipeline then
        error("Image rendering requires a render pipeline")
    end
    local renderer <const> =
        (pipeline as gpuTypes.PipelineInternal):getRenderer()
    renderplugin.install(world, {
        Image = Image as tecs.Component,
        renderer = renderer,
        pipeline = pipeline,
    })

    local function drawImage(
        value: image.Image,
        x: number,
        y: number,
        transform: tecs.builtins.Transform,
        pivot: Pivot,
        unlit: boolean,
        material: Material,
        clipBounds: ClipBounds,
        globalTime: number
    )
        local texture <const> = value.texture
        local width <const> = value.width
        local height <const> = value.height
        local pivotX <const> = pivot and pivot.x or 0
        local pivotY <const> = pivot and pivot.y or 0
        local originX <const> = width * pivotX
        local originY <const> = height * pivotY
        local bottomY <const> =
            y + (height - originY) * transform.scaleY
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
            clipBounds,
            unlit,
            depth,
            globalTime,
            x,
            y
        )
        local ws = pipeline:worldShader():at(
            transform.layer,
            transform.z,
            x,
            bottomY
        ):shader(shader)
        if unlit then
            ws:unlit()
        end
        ws:attach()
        lgDraw(
            texture,
            x,
            y,
            transform.rotation,
            transform.scaleX,
            transform.scaleY,
            originX,
            originY,
            0,
            0
        )
        pipeline:detachWorldShader()
    end

    local query <const> = world:query({
        name = "image.Draw",
        include = {Image, Transform},
    })

    world:addSystem({
        name = "image.Draw",
        phase = tecs.phases.Draw,
        run = function()
            local viewport <const> = renderer._cullViewport
            local viewX1 <const> = viewport[1]
            local viewY1 <const> = viewport[2]
            local viewX2 <const> = viewport[3]
            local viewY2 <const> = viewport[4]
            local cameraMask <const> = renderer._cullCameraLayerMask
            local layerRange <const> = renderer._layerRange
            local globalTime <const> = renderer._cullGlobalTime

            for archetype, len in query:iter() do
                if blend.groupBy(archetype) == 0 then
                    local images <const> =
                        archetype:get(Image) as {image.Image}
                    local transforms <const> =
                        archetype:get(Transform) as {tecs.builtins.Transform}
                    local colors <const> = archetype:get(Color) as {Color}
                    local pivots <const> = archetype:get(Pivot) as {Pivot}
                    local materials <const> =
                        archetype:get(Material) as {Material}
                    local clips <const> =
                        archetype:get(ClipBounds) as {ClipBounds}
                    local unlit <const> = archetype:get(Unlit) ~= nil

                    for row = 1, len do
                        local value <const> = images[row]
                        local transform <const> = transforms[row]
                        local width <const> = value.width
                        local height <const> = value.height
                        local scaleX <const> = transform.scaleX
                        local scaleY <const> = transform.scaleY
                        local drawWidth <const> = width * abs(scaleX)
                        local drawHeight <const> = height * abs(scaleY)
                        local pivotX <const> = pivots and pivots[row].x or 0
                        local pivotY <const> = pivots and pivots[row].y or 0
                        local layer <const> = transform.layer or 1
                        if band(cameraMask, lshift(1, layer - 1)) ~= 0
                                and layer >= layerRange[1]
                                and layer <= layerRange[2] then
                            local parallaxX <const> =
                                renderer._cullParallaxMatX[layer] or 1.0
                            local parallaxY <const> =
                                renderer._cullParallaxMatY[layer] or 1.0
                            local drawX <const> = transform.x
                                + renderer._cullCameraPos[1]
                                    * (1.0 - parallaxX)
                            local drawY <const> = transform.y
                                + renderer._cullCameraPos[2]
                                    * (1.0 - parallaxY)

                            if colors then
                                local color <const> = colors[row]
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
                                    drawX - width * pivotX * scaleX
                                local baseTop <const> =
                                    drawY - height * pivotY * scaleY
                                local firstX = 0
                                local lastX = 0
                                local firstY = 0
                                local lastY = 0

                                if value.repeatX and drawWidth > 0 then
                                    firstX = floor(
                                        (viewX1 - baseLeft) / drawWidth
                                    ) - 1
                                    lastX = floor(
                                        (viewX2 - baseLeft) / drawWidth
                                    ) + 1
                                end
                                if value.repeatY and drawHeight > 0 then
                                    firstY = floor(
                                        (viewY1 - baseTop) / drawHeight
                                    ) - 1
                                    lastY = floor(
                                        (viewY2 - baseTop) / drawHeight
                                    ) + 1
                                end

                                for repeatY = firstY, lastY do
                                    local y <const> =
                                        drawY + repeatY * drawHeight
                                    for repeatX = firstX, lastX do
                                        local x <const> =
                                            drawX + repeatX * drawWidth
                                        drawImage(
                                            value,
                                            x,
                                            y,
                                            transform,
                                            pivots and pivots[row],
                                            unlit,
                                            materials and materials[row],
                                            clips and clips[row],
                                            globalTime
                                        )
                                    end
                                end
                            else
                                -- Conservative rotation-safe visibility bound.
                                local radius <const> = sqrt(
                                    drawWidth * drawWidth
                                    + drawHeight * drawHeight
                                )
                                if drawX + radius > viewX1
                                        and drawX - radius < viewX2
                                        and drawY + radius > viewY1
                                        and drawY - radius < viewY2 then
                                    drawImage(
                                        value,
                                        drawX,
                                        drawY,
                                        transform,
                                        pivots and pivots[row],
                                        unlit,
                                        materials and materials[row],
                                        clips and clips[row],
                                        globalTime
                                    )
                                end
                            end
                        end
                    end
                end
            end
            lg.setColor(1, 1, 1, 1)
        end,
    })
end

return image
