--- Chunk management for GPU TileChunk-based tile rendering.
---
--- Spawns TileChunk ECS entities for efficient GPU-driven tile rendering.
--- Each 16x16 chunk becomes a single GPU draw call via compute shader culling.

local tecs <const> = require("tecs")
local types <const> = require("tecs2d.tiled.types")
local tileset_utils <const> = require("tecs2d.tiled.internal.tileset")
local gfx <const> = require("tecs2d.gfx")
local sprite_module <const> = require("tecs2d.gfx.internal.sprite")
local sprite_sheet <const> = require("tecs2d.gfx.internal.sprite.sheet")
local sheet <const> = require("tecs2d.gfx.sheet")
local collision_module <const> = require("tecs2d.tiled.collision")

local type TilemapData = types.TilemapData
local type LayerData = types.LayerData
local type TilesetData = types.TilesetData
local type TileData = types.TileData

local TileSource <const> = types.TileSource

local Transform <const> = tecs.builtins.Transform
local TileChunk <const> = gfx.TileChunk
local DirtyTileChunk <const> = gfx.DirtyTileChunk
local TILE_CHUNK_SIZE <const> = gfx.TILE_CHUNK_SIZE  -- 16

local math_floor <const> = math.floor
local math_ceil <const> = math.ceil
local math_min <const> = math.min

local decodeFlipFlags <const> = tileset_utils.decodeFlipFlags
local getTilesetForGid <const> = tileset_utils.getTilesetForGid
local getLocalTileId <const> = tileset_utils.getLocalTileId

local record chunk
    --- Spawn TileChunk entities for all tile layers in a tilemap.
    --- Each 16x16 area with non-empty tiles becomes a TileChunk entity.
    --- Animated tiles are skipped (set to 0) and rendered separately.
    --- @param world The ECS world
    --- @param map The tilemap data
    --- @param baseX World X position of tilemap
    --- @param baseY World Y position of tilemap
    --- @param baseLayer Base render layer
    --- @return Array of spawned entity IDs
    spawnTileChunkEntities: function(
        world: tecs.World,
        map: TilemapData,
        baseX: number,
        baseY: number,
        baseLayer: integer
    ): {integer}

    --- Despawn all TileChunk entities for a tilemap layer.
    --- @param world The ECS world
    --- @param layer The layer data
    despawnLayerChunks: function(world: tecs.World, layer: LayerData)

    --- Mark a tile's chunk entity as dirty.
    --- Also marks chunk collision dirty if tile has collision shapes.
    --- @param world The ECS world
    --- @param map The tilemap data
    --- @param layerIndex Layer index (1-based)
    --- @param tileX Tile X coordinate (1-based)
    --- @param tileY Tile Y coordinate (1-based)
    --- @param oldGid Optional old GID before the change (for collision checking)
    markTileDirty: function(world: tecs.World, map: TilemapData, layerIndex: integer, tileX: integer, tileY: integer, oldGid?: integer)

    --- Mark a chunk's collision as dirty (needs rebuild).
    --- @param map The tilemap data
    --- @param layerIndex Layer index (1-based)
    --- @param chunkX Chunk X coordinate (0-based)
    --- @param chunkY Chunk Y coordinate (0-based)
    markChunkCollisionDirty: function(map: TilemapData, layerIndex: integer, chunkX: integer, chunkY: integer)

    --- Check if a chunk has dirty collision and needs rebuild.
    --- @param map The tilemap data
    --- @param layerIndex Layer index (1-based)
    --- @param chunkX Chunk X coordinate (0-based)
    --- @param chunkY Chunk Y coordinate (0-based)
    --- @return true if chunk collision is dirty
    isChunkCollisionDirty: function(map: TilemapData, layerIndex: integer, chunkX: integer, chunkY: integer): boolean

    --- Clear dirty flag for a chunk's collision.
    --- @param map The tilemap data
    --- @param layerIndex Layer index (1-based)
    --- @param chunkX Chunk X coordinate (0-based)
    --- @param chunkY Chunk Y coordinate (0-based)
    clearChunkCollisionDirty: function(map: TilemapData, layerIndex: integer, chunkX: integer, chunkY: integer)

    --- Get all dirty chunk collision coordinates for a layer.
    --- @param map The tilemap data
    --- @param layerIndex Layer index (1-based)
    --- @return Iterator of (chunkX, chunkY) pairs
    getDirtyChunkCollisions: function(map: TilemapData, layerIndex: integer): function(): integer, integer

    --- Spawn Sprite entities for all animated tiles in a tilemap.
    --- Each animated tile becomes a Sprite entity with globally-synced animation.
    --- @param world The ECS world
    --- @param map The tilemap data
    --- @param baseX World X position of tilemap
    --- @param baseY World Y position of tilemap
    --- @param baseLayer Base render layer
    --- @return Array of spawned entity IDs
    spawnAnimatedTileEntities: function(
        world: tecs.World,
        map: TilemapData,
        baseX: number,
        baseY: number,
        baseLayer: integer
    ): {integer}

    --- Despawn all animated tile Sprite entities for a tilemap layer.
    --- @param world The ECS world
    --- @param layer The layer data
    despawnLayerAnimatedTiles: function(world: tecs.World, layer: LayerData)

    --- Spawn Sprite entities for all image layers in a tilemap.
    --- Each image layer becomes a Sprite with optional RepeatedSprite.
    --- Parallax is configured at the layer level (not per-entity).
    --- @param world The ECS world
    --- @param map The tilemap data
    --- @param baseX World X position of tilemap
    --- @param baseY World Y position of tilemap
    --- @param baseLayer Base render layer
    spawnImageLayerEntities: function(
        world: tecs.World,
        map: TilemapData,
        baseX: number,
        baseY: number,
        baseLayer: integer
    )

    --- Despawn image layer Sprite entity for a layer.
    --- @param world The ECS world
    --- @param layer The layer data
    despawnImageLayerEntity: function(world: tecs.World, layer: LayerData)
end

-- Build a TileChunk component value plus its tracking entry. Returns the
-- entity id and registers it in layer._chunkEntities + layer._chunkEntityMap.
local function buildChunkComponents(
    layer: LayerData,
    tileset: TilesetData,
    chunkWorldX: number,
    chunkWorldY: number,
    renderLayer: integer,
    zOrder: number,
    tw: number,
    th: number,
    tiles: {integer}
): {tecs.Component}
    local components: {tecs.Component} = {}
    components[#components + 1] = Transform.new({
        x = chunkWorldX,
        y = chunkWorldY,
        layer = renderLayer,
        z = zOrder,
    })
    components[#components + 1] = TileChunk.new({
        tileset = tileset.image as love.graphics.Texture,
        normalMap = tileset.normalImage as love.graphics.Texture,
        emissionMap = tileset.emissionImage as love.graphics.Texture,
        ormMap = tileset.ormImage as love.graphics.Texture,
        tileWidth = tw,
        tileHeight = th,
        columns = tileset.columns,
        tiles = tiles,
        occluderHeights = tileset._occluderHeights,
        -- Tile values are stored as 1-based LOCAL ids (+flip bits), so
        -- the occluder-height lookup subtracts 1, not the map firstgid.
        firstgid = 1,
    })
    if layer.tintcolor then
        local tint = layer.tintcolor
        components[#components + 1] = gfx.Color(tint[1], tint[2], tint[3], tint[4] or 1)
    end
    return components
end

-- Spawn TileChunk entities for all tile layers
function chunk.spawnTileChunkEntities(
    world: tecs.World,
    map: TilemapData,
    baseX: number,
    baseY: number,
    baseLayer: integer
): {integer}
    local allEntities: {integer} = {}
    local tw = map.tilewidth
    local th = map.tileheight

    local mapLayers <const> = map.layers
    for layerIdx = 1, #mapLayers do
        local layer = mapLayers[layerIdx]
        if layer.type == "tilelayer" and layer.visible then
            local renderLayer = baseLayer + layer.groupIndex - 1
            local zOffset = layer.zOffset

            -- Calculate number of 16x16 chunks needed
            local chunksX = math_ceil(layer.width / TILE_CHUNK_SIZE)
            local chunksY = math_ceil(layer.height / TILE_CHUNK_SIZE)

            -- Capture spawn parameters so setTile can later spawn a new
            -- per-tileset chunk entity on demand (when a tile is set to a
            -- tileset that didn't yet have a chunk entity at that position).
            layer._baseX = baseX
            layer._baseY = baseY
            layer._baseLayer = baseLayer

            -- Initialize entity tracking. _chunkEntityMap[cy][cx] is itself a
            -- map keyed by tileset firstgid so a chunk holding tiles from
            -- multiple tilesets has one entry per tileset.
            layer._chunkEntities = {}
            layer._chunkEntityMap = {}

            -- Iterate over 16x16 chunk areas
            for cy = 0, chunksY - 1 do
                layer._chunkEntityMap[cy] = {}
                for cx = 0, chunksX - 1 do
                    -- Collect tiles for this chunk, grouped by tileset
                    local tilesetTiles: {types.TilesetData: {integer}} = {}
                    local hasAnyTile = false

                    local startCol = cx * TILE_CHUNK_SIZE + 1
                    local startRow = cy * TILE_CHUNK_SIZE + 1
                    local endCol = math_min(startCol + TILE_CHUNK_SIZE - 1, layer.width)
                    local endRow = math_min(startRow + TILE_CHUNK_SIZE - 1, layer.height)

                    for row = startRow, endRow do
                        for col = startCol, endCol do
                            -- 0-based FFI index
                            local idx = (row - 1) * layer.width + (col - 1)
                            local gid = layer.data[idx]

                            -- Local position in chunk (0-based)
                            local localX = col - startCol
                            local localY = row - startRow
                            local localIdx = localY * TILE_CHUNK_SIZE + localX + 1

                            if gid and gid > 0 then
                                local flipH, flipV, flipD, cleanGid = decodeFlipFlags(gid)
                                local tileset = getTilesetForGid(map, cleanGid)

                                if tileset and tileset.image then
                                    local localId = getLocalTileId(tileset, cleanGid)
                                    local tile = tileset.tiles[localId]

                                    -- Skip animated tiles (rendered separately)
                                    if not tile or not tile.animation then
                                        -- Get or create tile array for this tileset
                                        if not tilesetTiles[tileset] then
                                            tilesetTiles[tileset] = {}
                                            for i = 1, 256 do
                                                tilesetTiles[tileset][i] = 0
                                            end
                                        end
                                        -- Store the 1-based LOCAL tile id with the
                                        -- flip flags re-packed into the high bits
                                        -- (H bit 31, V bit 30, anti-diagonal bit
                                        -- 29). The render and shadow-mask shaders
                                        -- mask the low bits for the atlas lookup
                                        -- and flip the sampled UVs; local ids keep
                                        -- that lookup correct for tilesets whose
                                        -- firstgid is not 1.
                                        local value = localId + 1
                                        if flipH then value = value + 0x80000000 end
                                        if flipV then value = value + 0x40000000 end
                                        if flipD then value = value + 0x20000000 end
                                        tilesetTiles[tileset][localIdx] = value
                                        hasAnyTile = true
                                    end
                                end
                            end
                        end
                    end

                    -- Spawn TileChunk entity for each tileset used in this chunk
                    if hasAnyTile then
                        local chunkWorldX = baseX + layer.offsetx + cx * TILE_CHUNK_SIZE * tw
                        local chunkWorldY = baseY + layer.offsety + cy * TILE_CHUNK_SIZE * th
                        local zOffsetIncrement: number = 0
                        local cellMap: {integer: integer} = {}
                        layer._chunkEntityMap[cy][cx] = cellMap

                        for tileset, tiles in pairs(tilesetTiles) do
                            local components = buildChunkComponents(
                                layer, tileset, chunkWorldX, chunkWorldY, renderLayer,
                                zOffset + zOffsetIncrement, tw, th, tiles
                            )
                            local entityId = world:spawn(table.unpack(components))
                            layer._chunkEntities[#layer._chunkEntities + 1] = entityId
                            cellMap[tileset.firstgid] = entityId
                            allEntities[#allEntities + 1] = entityId

                            -- Slight z offset for multi-tileset chunks (avoid z-fighting)
                            zOffsetIncrement = zOffsetIncrement + 0.01
                        end
                    end
                end
            end
        end
    end

    return allEntities
end

-- Despawn TileChunk entities for a layer
function chunk.despawnLayerChunks(world: tecs.World, layer: LayerData)
    if layer._chunkEntities then
        for _, entityId in ipairs(layer._chunkEntities) do
            if world:isAlive(entityId) then
                world:despawn(entityId)
            end
        end
        layer._chunkEntities = nil
        layer._chunkEntityMap = nil
    end
end

-- Mark a tile's chunk entity as dirty
-- Cache of SpriteSheets created for animated tiles (forward-declared since
-- spawnAnimatedSprite uses createAnimatedTileSpriteSheet which appears later
-- in the file). The local function declared below picks up the closure ref
-- once both sides are defined.
local createAnimatedTileSpriteSheet: function(TilesetData, TileData, integer): sprite_sheet.SpriteSheet

-- Spawn an animated tile sprite at a specific tile position. Used by both the
-- initial bulk spawn and runtime setTile transitions.
local function spawnAnimatedSprite(
    world: tecs.World,
    layer: LayerData,
    tileset: TilesetData,
    tile: TileData,
    localId: integer,
    flipH: boolean, flipV: boolean, flipD: boolean,
    cleanGid: integer,
    tileX: integer, tileY: integer,
    tw: number, th: number,
    baseX: number, baseY: number,
    renderLayer: integer,
    zOffset: number
): integer
    local spriteSheet = createAnimatedTileSpriteSheet(tileset, tile, localId)

    local worldX = baseX + layer.offsetx + (tileX - 1) * tw
    local worldY = baseY + layer.offsety + (tileY - 1) * th
    local tx, ty = worldX + tw * 0.5, worldY + th * 0.5

    -- Tiled applies D (anti-diagonal), then H, then V to the tile image.
    -- Scale is applied before rotation here, so under the diagonal's 90
    -- degree rotation a post-rotation X flip (H) maps to a pre-rotation Y
    -- negation and V maps to X; routing them straight to sx/sy renders
    -- D+H and D+V swapped (90 vs 270 degrees).
    local rot = 0.0
    local sx, sy = 1.0, 1.0
    if flipD then
        rot = math.pi * 0.5
        sy = -sy
        if flipH then sy = -sy end
        if flipV then sx = -sx end
    else
        if flipH then sx = -sx end
        if flipV then sy = -sy end
    end

    return world:spawn(
        Transform.new({
            x = tx, y = ty,
            layer = renderLayer,
            z = zOffset + 0.5,
            rotation = rot,
            scaleX = sx,
            scaleY = sy,
        }),
        sprite_module.Sprite.fromSheet(spriteSheet as sheet.SpriteSheet, "default", {
            centered = true,
            startTime = 0,
        }),
        TileSource.new({
            gid = cleanGid,
            localId = localId,
            tilesetName = tileset.name,
            properties = tile.properties,
            class = tile.class,
        })
    )
end

-- Find or create the per-tileset chunk entity at (cx, cy) for a given firstgid.
local function findOrCreateChunkEntity(
    world: tecs.World,
    map: TilemapData,
    layer: LayerData,
    cy: integer, cx: integer,
    tileset: TilesetData
): integer
    local chunkRow = layer._chunkEntityMap[cy]
    if not chunkRow then
        chunkRow = {}
        layer._chunkEntityMap[cy] = chunkRow
    end
    local cellMap = chunkRow[cx] as {integer: integer}
    if not cellMap then
        cellMap = {}
        chunkRow[cx] = cellMap
    end

    local existing = cellMap[tileset.firstgid]
    if existing and world:isAlive(existing) then
        return existing
    end

    local tw = map.tilewidth
    local th = map.tileheight
    local renderLayer = (layer._baseLayer or 0) + layer.groupIndex - 1
    local zOffset = layer.zOffset
    local existingCount = 0
    for _ in pairs(cellMap) do existingCount = existingCount + 1 end

    local chunkWorldX = (layer._baseX or 0) + layer.offsetx + cx * TILE_CHUNK_SIZE * tw
    local chunkWorldY = (layer._baseY or 0) + layer.offsety + cy * TILE_CHUNK_SIZE * th

    local tiles: {integer} = {}
    for i = 1, 256 do tiles[i] = 0 end

    local components = buildChunkComponents(
        layer, tileset, chunkWorldX, chunkWorldY, renderLayer,
        zOffset + existingCount * 0.01, tw, th, tiles
    )
    local entityId = world:spawn(table.unpack(components))
    cellMap[tileset.firstgid] = entityId
    layer._chunkEntities[#layer._chunkEntities + 1] = entityId
    return entityId
end

-- Set localIdx in a chunk entity's tiles[] and mark it dirty.
local function writeChunkTile(world: tecs.World, entityId: integer, localIdx: integer, value: integer)
    if not world:isAlive(entityId) then return end
    world:set(entityId, DirtyTileChunk)
    local tileChunk = world:get(entityId, TileChunk)
    if tileChunk then
        tileChunk.tiles[localIdx] = value
    end
end

function chunk.markTileDirty(world: tecs.World, map: TilemapData, layerIndex: integer, tileX: integer, tileY: integer, oldGid?: integer)
    local layer = map.layers[layerIndex]
    if not layer or layer.type ~= "tilelayer" then
        return
    end

    local chunkX = math_floor((tileX - 1) / TILE_CHUNK_SIZE)
    local chunkY = math_floor((tileY - 1) / TILE_CHUNK_SIZE)

    -- Check if collision is enabled and either old or new tile has collision
    if map._collisionConfig then
        local newGid = layer.data[(tileY - 1) * layer.width + (tileX - 1)] or 0
        local oldHasCollision = oldGid and collision_module.tileHasCollision(map, oldGid)
        local newHasCollision = newGid > 0 and collision_module.tileHasCollision(map, newGid)

        if oldHasCollision or newHasCollision then
            chunk.markChunkCollisionDirty(map, layerIndex, chunkX, chunkY)
        end
    end

    if not layer._chunkEntityMap then
        return
    end

    local localX = (tileX - 1) % TILE_CHUNK_SIZE
    local localY = (tileY - 1) % TILE_CHUNK_SIZE
    local localIdx = localY * TILE_CHUNK_SIZE + localX + 1

    -- Resolve old tile's tileset (if any) so we can clear its cell or its
    -- animated sprite when the tile transitions to a different tileset / mode.
    local oldTileset: TilesetData = nil
    local oldTile: TileData = nil
    if oldGid and oldGid > 0 then
        local _, _, _, oldCleanGid = decodeFlipFlags(oldGid)
        oldTileset = getTilesetForGid(map, oldCleanGid)
        if oldTileset then
            oldTile = oldTileset.tiles[getLocalTileId(oldTileset, oldCleanGid)]
        end
    end

    -- Resolve new tile's tileset.
    local newGid = layer.data[(tileY - 1) * layer.width + (tileX - 1)] or 0
    local newFlipH, newFlipV, newFlipD, newCleanGid = decodeFlipFlags(newGid)
    local newTileset: TilesetData = nil
    local newTile: TileData = nil
    local newLocalId: integer = -1
    if newGid > 0 then
        newTileset = getTilesetForGid(map, newCleanGid)
        if newTileset then
            newLocalId = getLocalTileId(newTileset, newCleanGid)
            newTile = newTileset.tiles[newLocalId]
        end
    end

    local oldWasAnimated = oldTile and oldTile.animation ~= nil
    local newIsAnimated = newTile and newTile.animation ~= nil

    -- 1. If the OLD tile lived in a different (static) tileset, clear its cell
    --    so the leftover doesn't keep rendering. Same-tileset transitions get
    --    overwritten in step 3.
    if oldTileset and not oldWasAnimated then
        local oldFirstgid = oldTileset.firstgid
        local sameTileset = newTileset and newTileset.firstgid == oldFirstgid and not newIsAnimated
        if not sameTileset then
            local row = layer._chunkEntityMap[chunkY]
            local cell = row and row[chunkX] as {integer: integer}
            local oldEntityId = cell and cell[oldFirstgid]
            if oldEntityId then
                writeChunkTile(world, oldEntityId, localIdx, 0)
            end
        end
    end

    -- 2. Despawn the old animated sprite if any.
    local animMap = layer._animatedSpriteEntityMap
    if oldWasAnimated and animMap then
        local row = animMap[tileY]
        local oldSprite = row and row[tileX]
        if oldSprite then
            if world:isAlive(oldSprite) then world:despawn(oldSprite) end
            row[tileX] = nil
        end
    end

    -- 3. Apply the NEW tile.
    if newGid > 0 and newTileset then
        if newIsAnimated then
            -- Animated tiles render via separate Sprite entities; the static
            -- chunk's cell stays 0.
            if not animMap then
                animMap = {}
                layer._animatedSpriteEntityMap = animMap
            end
            local row = animMap[tileY]
            if not row then row = {}; animMap[tileY] = row end

            local renderLayer = (layer._baseLayer or 0) + layer.groupIndex - 1
            local newSprite = spawnAnimatedSprite(
                world, layer, newTileset, newTile, newLocalId,
                newFlipH, newFlipV, newFlipD, newCleanGid,
                tileX, tileY, map.tilewidth, map.tileheight,
                layer._baseX or 0, layer._baseY or 0,
                renderLayer, layer.zOffset
            )
            row[tileX] = newSprite
            if not layer._animatedSpriteEntities then
                layer._animatedSpriteEntities = {}
            end
            layer._animatedSpriteEntities[#layer._animatedSpriteEntities + 1] = newSprite

            -- Defensive: clear the new tileset's static cell in case a stale
            -- value from a previous static tile remains.
            local row2 = layer._chunkEntityMap[chunkY]
            local cell = row2 and row2[chunkX] as {integer: integer}
            local existingEntity = cell and cell[newTileset.firstgid]
            if existingEntity then
                writeChunkTile(world, existingEntity, localIdx, 0)
            end
        else
            -- Static tile: route to (or spawn) the chunk entity for the new tileset.
            local entityId = findOrCreateChunkEntity(world, map, layer, chunkY, chunkX, newTileset)
            writeChunkTile(world, entityId, localIdx, newGid)
        end
    end
end

-- Mark a chunk's collision as dirty
function chunk.markChunkCollisionDirty(map: TilemapData, layerIndex: integer, chunkX: integer, chunkY: integer)
    local layer = map.layers[layerIndex]
    if not layer or layer.type ~= "tilelayer" then
        return
    end

    -- Initialize dirty tracking if needed
    if not layer._dirtyChunkCollisions then
        layer._dirtyChunkCollisions = {}
    end

    local key = tostring(chunkY) .. "," .. tostring(chunkX)
    layer._dirtyChunkCollisions[key] = true
end

-- Check if a chunk has dirty collision
function chunk.isChunkCollisionDirty(map: TilemapData, layerIndex: integer, chunkX: integer, chunkY: integer): boolean
    local layer = map.layers[layerIndex]
    if not layer or not layer._dirtyChunkCollisions then
        return false
    end

    local key = tostring(chunkY) .. "," .. tostring(chunkX)
    return layer._dirtyChunkCollisions[key] == true
end

-- Clear dirty flag for a chunk's collision
function chunk.clearChunkCollisionDirty(map: TilemapData, layerIndex: integer, chunkX: integer, chunkY: integer)
    local layer = map.layers[layerIndex]
    if not layer or not layer._dirtyChunkCollisions then
        return
    end

    local key = tostring(chunkY) .. "," .. tostring(chunkX)
    layer._dirtyChunkCollisions[key] = nil
end

-- Get all dirty chunk collision coordinates for a layer
function chunk.getDirtyChunkCollisions(map: TilemapData, layerIndex: integer): function(): integer, integer
    local layer = map.layers[layerIndex]
    if not layer or not layer._dirtyChunkCollisions then
        return function(): integer, integer
            return nil, nil
        end
    end

    local dirtyChunks = layer._dirtyChunkCollisions
    local key: string = nil

    return function(): integer, integer
        key = next(dirtyChunks, key)
        if key then
            -- Parse "chunkY,chunkX" back to integers
            local chunkY, chunkX = key:match("^(%d+),(%d+)$")
            return tonumber(chunkX) as integer, tonumber(chunkY) as integer
        end
        return nil, nil
    end
end

-- Cache of SpriteSheets created for animated tiles (keyed by tileset + localId)
local animatedTileSpriteSheets: {string: sprite_sheet.SpriteSheet} = {}

-- Assign to the forward-declared local so spawnAnimatedSprite (above) picks up
-- the real implementation. This is a single closure, not two functions.
createAnimatedTileSpriteSheet = function(
    tileset: TilesetData,
    tile: TileData,
    localId: integer
): sprite_sheet.SpriteSheet
    -- Create cache key
    local cacheKey = tostring(tileset.firstgid) .. "_" .. tostring(localId)
    local cached = animatedTileSpriteSheets[cacheKey]
    if cached then
        return cached
    end

    local image = tileset.image
    local tw = tileset.tilewidth
    local th = tileset.tileheight
    local columns = tileset.columns
    local spacing = tileset.spacing or 0
    local margin = tileset.margin or 0
    local imgW, imgH = (image as love.graphics.Texture):getDimensions()

    -- Build frame data from Tiled animation
    local frames: {table} = {}
    local animation = tile.animation
    for i = 1, #animation do
        local frame = animation[i]
        local frameLocalId = frame.tileid

        -- Calculate UV position for this frame's tile
        local col = frameLocalId % columns
        local row = math_floor(frameLocalId / columns)
        local x = margin + col * (tw + spacing)
        local y = margin + row * (th + spacing)

        frames[i] = {
            frame = { x = x, y = y, w = tw, h = th },
            duration = frame.duration * 1000  -- Convert seconds back to ms for sprite_sheet
        }
    end

    -- Build Aseprite-compatible config
    local config: table = {
        frames = frames,
        meta = {
            size = { w = imgW, h = imgH },
            frameTags = {
                {
                    name = "default",
                    from = 0,
                    to = #frames - 1,
                    direction = "forward"
                }
            },
            slices = {}
        }
    }

    local spriteSheet = sprite_sheet.SpriteSheet.fromConfig(image, config, cacheKey)
    animatedTileSpriteSheets[cacheKey] = spriteSheet
    return spriteSheet
end

-- Spawn Sprite entities for animated tiles
function chunk.spawnAnimatedTileEntities(
    world: tecs.World,
    map: TilemapData,
    baseX: number,
    baseY: number,
    baseLayer: integer
): {integer}
    local allEntities: {integer} = {}
    local tw = map.tilewidth
    local th = map.tileheight

    local mapLayers <const> = map.layers
    for layerIdx = 1, #mapLayers do
        local layer = mapLayers[layerIdx]
        if layer.type == "tilelayer" and layer.visible then
            local renderLayer = baseLayer + layer.groupIndex - 1
            local zOffset = layer.zOffset

            -- Initialize animated tile entity tracking. Keep both the flat
            -- list (for despawn-all) and a (tileY, tileX) keyed map (for
            -- O(1) lookup during runtime setTile transitions).
            layer._animatedSpriteEntities = {}
            layer._animatedSpriteEntityMap = {}

            -- Iterate over all tiles looking for animated ones
            for tileY = 1, layer.height do
                for tileX = 1, layer.width do
                    -- 0-based FFI index
                    local idx = (tileY - 1) * layer.width + (tileX - 1)
                    local gid = layer.data[idx]

                    if gid and gid > 0 then
                        local flipH, flipV, flipD, cleanGid = decodeFlipFlags(gid)
                        local tileset = getTilesetForGid(map, cleanGid)

                        if tileset and tileset.image then
                            local localId = getLocalTileId(tileset, cleanGid)
                            local tile = tileset.tiles[localId]

                            -- Only process animated tiles
                            if tile and tile.animation then
                                local entityId = spawnAnimatedSprite(
                                    world, layer, tileset, tile, localId,
                                    flipH, flipV, flipD, cleanGid,
                                    tileX, tileY, tw, th,
                                    baseX, baseY, renderLayer, zOffset
                                )

                                -- Also index by tile position for setTile lookup
                                local row = layer._animatedSpriteEntityMap[tileY]
                                if not row then
                                    row = {}
                                    layer._animatedSpriteEntityMap[tileY] = row
                                end
                                row[tileX] = entityId

                                layer._animatedSpriteEntities[#layer._animatedSpriteEntities + 1] = entityId
                                allEntities[#allEntities + 1] = entityId
                            end
                        end
                    end
                end
            end
        end
    end

    return allEntities
end

-- Despawn animated tile Sprite entities for a layer
function chunk.despawnLayerAnimatedTiles(world: tecs.World, layer: LayerData)
    if layer._animatedSpriteEntities then
        for _, entityId in ipairs(layer._animatedSpriteEntities) do
            if world:isAlive(entityId) then
                world:despawn(entityId)
            end
        end
        layer._animatedSpriteEntities = nil
        layer._animatedSpriteEntityMap = nil
    end
end

-- Spawn Sprite entities for image layers
function chunk.spawnImageLayerEntities(
    world: tecs.World,
    map: TilemapData,
    baseX: number,
    baseY: number,
    baseLayer: integer
)
    local layers <const> = map.layers

    for i = 1, #layers do
        local layer = layers[i]

        -- Only process visible image layers with loaded images
        if layer.type == "imagelayer" and layer.visible and layer._image then
            local renderLayer = baseLayer + layer.groupIndex - 1
            local zOffset = layer.zOffset

            -- Base position: tilemap position + layer offset
            local layerBaseX = baseX + layer.offsetx
            local layerBaseY = baseY + layer.offsety

            local imgW = layer.imagewidth
            local imgH = layer.imageheight

            -- Create sprite from texture (cast Image to Texture for type checker)
            local sprite = gfx.Sprite.fromTexture(layer._image as love.graphics.Texture, {
                centered = false,  -- Top-left origin like original render
                pivotX = 0,
                pivotY = 0,
            })

            -- Build component list
            local components: {tecs.Component} = {}

            -- Transform at base position
            -- Note: Parallax is handled at the layer level (configured in tiled/init.tl)
            components[#components + 1] = Transform.new({
                x = layerBaseX,
                y = layerBaseY,
                z = zOffset,
                layer = renderLayer,
            })

            -- Sprite component
            components[#components + 1] = sprite

            -- RepeatedSprite for tiling
            if layer.repeatx or layer.repeaty then
                -- For repeating, we need to set a large enough coverage area
                -- Use a generous size to cover typical viewports
                local REPEAT_SIZE <const> = 8192  -- Should cover most cases
                components[#components + 1] = gfx.RepeatedSprite.new({
                    repeatX = layer.repeatx,
                    repeatY = layer.repeaty,
                    width = layer.repeatx and REPEAT_SIZE or imgW,
                    height = layer.repeaty and REPEAT_SIZE or imgH,
                })
            end

            -- Tint color if specified
            if layer.tintcolor then
                local tint = layer.tintcolor
                components[#components + 1] = gfx.Color(tint[1], tint[2], tint[3], tint[4] or 1)
            end

            -- Spawn the entity
            local entityId = world:spawn(table.unpack(components))
            layer._imageLayerEntity = entityId
        end
    end
end

-- Despawn image layer Sprite entity for a layer
function chunk.despawnImageLayerEntity(world: tecs.World, layer: LayerData)
    if layer._imageLayerEntity and layer._imageLayerEntity ~= 0 then
        if world:isAlive(layer._imageLayerEntity) then
            world:despawn(layer._imageLayerEntity)
        end
        layer._imageLayerEntity = 0
    end
end

return chunk
