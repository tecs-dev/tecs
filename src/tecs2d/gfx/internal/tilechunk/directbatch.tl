--- Direct-texture fallback for oversized TileChunk atlases.
---
--- The normal TileChunk renderer remains GPU-instanced. Only chunks tagged
--- by Tiled as oversized take this path: one Love SpriteBatch per 16x16
--- chunk, sampling the source atlas without copying it into an array.

local tecs <const> = require("tecs")
local types <const> = require("tecs2d.gfx.internal.gpu.types")
local Color <const> = require("tecs2d.gfx.internal.Color")
local shaderUtils <const> = require("tecs2d.gfx.internal.gpu.shaders")
local bit <const> = require("bit")

local lg <const> = love.graphics
local floor <const> = math.floor
local band <const> = bit.band
local lshift <const> = bit.lshift
local Transform <const> = tecs.builtins.Transform
local SHADER_PATH <const> = "tecs2d/gfx/internal/tilechunk/"
-- Love accepts SpriteBatch in graphics.draw; the bundled declaration models
-- Drawable and SpriteBatch as unrelated records, so narrow the overload here.
local drawSpriteBatch <const> =
    lg.draw as function(love.graphics.SpriteBatch)

local renderShader <const> = lg.newShader(shaderUtils.insertAfterPragma(
    shaderUtils.loadShader("direct", SHADER_PATH),
    shaderUtils.RENDER_COMMON .. shaderUtils.DEPTH_COMMON
))
local shadowShader <const> = lg.newShader(
    shaderUtils.loadShadowMaskShader("directshadow", SHADER_PATH)
)
renderShader:send("LayerRange", {0, 65535})

local record directbatch
    record Config
        TileChunk: tecs.Component
        DirectTileChunk: tecs.Component
        DirtyTileChunk: tecs.Component
        renderer: types.Renderer
    end

    install: function(world: tecs.World, config: Config)
end

local record TileChunkData
    tileset: love.graphics.Texture
    normalMap: love.graphics.Texture
    emissionMap: love.graphics.Texture
    ormMap: love.graphics.Texture
    tileWidth: number
    tileHeight: number
    columns: integer
    spacing: number
    margin: number
    tiles: {integer}
    _occluderHeights: {integer: number}
end

local record ColorData
    r: number
    g: number
    b: number
    a: number
end

local record CacheEntry
    batch: love.graphics.SpriteBatch
    hasOccluders: boolean
end

local record VisibleEntry
    cache: CacheEntry
    chunk: TileChunkData
    x: number
    y: number
    layer: integer
    z: number
    r: number
    g: number
    b: number
    a: number
end

local function buildBatch(chunk: TileChunkData): CacheEntry
    local texture <const> = chunk.tileset
    local textureWidth, textureHeight = texture:getDimensions()
    local batch <const> = lg.newSpriteBatch(texture, 256, "dynamic")
    local quadCache: {integer: love.graphics.Quad} = {}
    local hasOccluders = false

    for localIndex = 1, 256 do
        local rawTile <const> = chunk.tiles[localIndex] or 0
        local tileId <const> = band(rawTile, 0x1FFFFFFF)
        if tileId > 0 then
            local atlasId <const> = tileId - 1
            local quad = quadCache[atlasId]
            if not quad then
                local column <const> = atlasId % chunk.columns
                local row <const> = floor(atlasId / chunk.columns)
                quad = lg.newQuad(
                    chunk.margin
                        + column * (chunk.tileWidth + chunk.spacing),
                    chunk.margin
                        + row * (chunk.tileHeight + chunk.spacing),
                    chunk.tileWidth,
                    chunk.tileHeight,
                    textureWidth,
                    textureHeight
                )
                quadCache[atlasId] = quad
            end

            local flipH <const> = band(rawTile, 0x80000000) ~= 0
            local flipV <const> = band(rawTile, 0x40000000) ~= 0
            local flipD <const> = band(rawTile, 0x20000000) ~= 0
            local rotation = 0.0
            local scaleX, scaleY = 1.0, 1.0
            if flipD then
                rotation = math.pi * 0.5
                scaleY = -scaleY
                if flipH then scaleY = -scaleY end
                if flipV then scaleX = -scaleX end
            else
                if flipH then scaleX = -scaleX end
                if flipV then scaleY = -scaleY end
            end

            local cellX <const> = (localIndex - 1) % 16
            local cellY <const> = floor((localIndex - 1) / 16)
            local height = 0.0
            if chunk._occluderHeights then
                height = chunk._occluderHeights[atlasId] or 0.0
            end
            if height > 0 then
                hasOccluders = true
            end

            -- R carries shadow height; G carries the tile's bottom row
            -- for depth sorting in the render shader.
            batch:setColor(height, (cellY + 1) / 16, 0, 1)
            batch:add(
                quad,
                (cellX + 0.5) * chunk.tileWidth,
                (cellY + 0.5) * chunk.tileHeight,
                rotation,
                scaleX,
                scaleY,
                chunk.tileWidth * 0.5,
                chunk.tileHeight * 0.5,
                0,
                0
            )
        end
    end
    batch:setColor(1, 1, 1, 1)
    batch:flush()
    return {
        batch = batch,
        hasOccluders = hasOccluders,
    }
end

function directbatch.install(world: tecs.World, config: directbatch.Config)
    local TileChunk <const> = config.TileChunk
    local DirectTileChunk <const> = config.DirectTileChunk
    local DirtyTileChunk <const> = config.DirtyTileChunk
    local renderer <const> = config.renderer
    local cache: {integer: CacheEntry} = {}
    local visible: {VisibleEntry} = {}
    local visibleCount = 0

    local directQuery <const> = world:query({
        name = "tileChunk.DirectLifecycle",
        include = {TileChunk, DirectTileChunk, Transform},
        onEntitiesRemoved = function(
            archetype: tecs.Archetype,
            firstRow: integer,
            lastRow: integer,
            _count: integer
        )
            local entities <const> = archetype.entities
            for row = firstRow, lastRow do
                cache[entities[row]] = nil
            end
        end,
    })
    local dirtyQuery <const> = world:query({
        name = "tileChunk.DirectDirty",
        include = {TileChunk, DirectTileChunk, Transform, DirtyTileChunk},
    })

    local toClean: {integer} = {}
    world:addSystem({
        name = "tileChunk.DirectSync",
        phase = tecs.phases.PreRender,
        run = function()
            local cleanCount = 0
            for archetype, len, entities in dirtyQuery:iter() do
                local chunks <const> =
                    archetype:get(TileChunk) as {TileChunkData}
                for row = 1, len do
                    cache[entities[row]] = buildBatch(chunks[row])
                    cleanCount = cleanCount + 1
                    toClean[cleanCount] = entities[row]
                end
            end
            for index = 1, cleanCount do
                world:remove(toClean[index], DirtyTileChunk)
                toClean[index] = nil
            end
        end,
    })

    local plugin: types.RenderPlugin = {
        name = "TileChunkDirect",
    }

    plugin.cull = function(r: types.Renderer, _cullParams: love.graphics.Buffer)
        visibleCount = 0
        local viewport <const> = r._cullViewport
        local camera <const> = r._cullCameraPos
        local cameraMask <const> = r._cullCameraLayerMask

        for archetype, len, entities in directQuery:iter() do
            local chunks <const> =
                archetype:get(TileChunk) as {TileChunkData}
            local transforms <const> =
                archetype:get(Transform) as {tecs.builtins.Transform}
            local colors <const> = archetype:get(Color) as {ColorData}

            for row = 1, len do
                local entity <const> = entities[row]
                local chunk <const> = chunks[row]
                local transform <const> = transforms[row]
                local layer <const> = transform.layer or 1
                if band(cameraMask, lshift(1, layer - 1)) ~= 0 then
                    local entry = cache[entity]
                    if not entry then
                        entry = buildBatch(chunk)
                        cache[entity] = entry
                    end

                    local parallaxX <const> =
                        r._cullParallaxMatX[layer] or 1.0
                    local parallaxY <const> =
                        r._cullParallaxMatY[layer] or 1.0
                    local x <const> =
                        transform.x + camera[1] * (1.0 - parallaxX)
                    local y <const> =
                        transform.y + camera[2] * (1.0 - parallaxY)
                    local margin <const> =
                        entry.hasOccluders
                        and (r.config.shadowMargin or 200)
                        or 0
                    local right <const> =
                        x + chunk.tileWidth * 16 + margin
                    local bottom <const> =
                        y + chunk.tileHeight * 16 + margin
                    if right > viewport[1]
                        and x - margin < viewport[3]
                        and bottom > viewport[2]
                        and y - margin < viewport[4]
                    then
                        local red, green, blue, alpha = 1.0, 1.0, 1.0, 1.0
                        if colors then
                            local color <const> = colors[row]
                            red = color.r or 1.0
                            green = color.g or 1.0
                            blue = color.b or 1.0
                            alpha = color.a or 1.0
                        end

                        visibleCount = visibleCount + 1
                        visible[visibleCount] = {
                            cache = entry,
                            chunk = chunk,
                            x = x,
                            y = y,
                            layer = layer,
                            z = transform.z or 0,
                            r = red,
                            g = green,
                            b = blue,
                            a = alpha,
                        }
                    end
                end
            end
        end
        for index = visibleCount + 1, #visible do
            visible[index] = nil
        end
    end

    plugin.renderGBuffer = function(
        _r: types.Renderer,
        renderParams: love.graphics.Buffer,
        _globalTime: number
    )
        if visibleCount == 0 then return end
        lg.setShader(renderShader)
        renderShader:send("RenderParams", renderParams)
        lg.setColor(1, 1, 1, 1)

        for index = 1, visibleCount do
            local item <const> = visible[index]
            local chunk <const> = item.chunk
            renderShader:send("ChunkPositionSize", {
                item.x, item.y, chunk.tileWidth, chunk.tileHeight,
            })
            renderShader:send("ChunkLayerZ", {item.layer, item.z})
            renderShader:send("ChunkColor", {
                item.r, item.g, item.b, item.a,
            })
            renderShader:send("HasNormalMap", chunk.normalMap ~= nil)
            renderShader:send("HasEmissionMap", chunk.emissionMap ~= nil)
            renderShader:send("HasORMMap", chunk.ormMap ~= nil)
            if chunk.normalMap then
                renderShader:send("NormalTex", chunk.normalMap)
            end
            if chunk.emissionMap then
                renderShader:send("EmissionTex", chunk.emissionMap)
            end
            if chunk.ormMap then
                renderShader:send("ORMTex", chunk.ormMap)
            end
            drawSpriteBatch(item.cache.batch)
        end
    end

    plugin.renderShadowMask = function(
        _r: types.Renderer,
        shadowTransform: love.math.Transform
    )
        if visibleCount == 0 then return end
        lg.setShader(shadowShader)
        shadowShader:send("ShadowViewProj", shadowTransform)
        shadowShader:send("AlphaThreshold", 0.5)
        lg.setColor(1, 1, 1, 1)
        for index = 1, visibleCount do
            local item <const> = visible[index]
            if item.cache.hasOccluders then
                shadowShader:send("ChunkPosition", {item.x, item.y})
                drawSpriteBatch(item.cache.batch)
            end
        end
    end

    plugin.setLayerRange = function(
        _r: types.Renderer,
        range: {number}
    )
        renderShader:send("LayerRange", range)
    end

    renderer:registerPlugin(plugin)
end

return directbatch
