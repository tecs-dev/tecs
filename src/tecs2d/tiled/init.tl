--- Tecs Tiled - Tiled map editor integration for Tecs ECS.
---
--- Provides tilemap loading, rendering, and object spawning from Tiled JSON exports.
--- Static tiles use GPU TileChunk entities for efficient instanced rendering.
--- Animated tiles use Sprite entities with globally-synced animations.
---
--- Usage:
---   local tiled = require("tecs2d.tiled")
---   local Transform = require("tecs").builtins.Transform
---   world:addPlugin(tiled.plugin)
---
---   -- Spawn a tilemap entity
---   world:spawn(
---       tiled.Tilemap.new({path = "maps/level1.tmj"}),
---       Transform(0, 0)
---   )

local table_clear <const> = require("table.clear")
local tecs <const> = require("tecs")
local tecs_assets <const> = require("tecs2d.assets")
local json <const> = require("tecs.utils.json")
local pipelinekey <const> = require("tecs2d.gfx.internal.pipelinekey")

local types <const> = require("tecs2d.tiled.types")
local loader <const> = require("tecs2d.tiled.internal.loader")
local chunk_utils <const> = require("tecs2d.tiled.internal.chunk")
local debug_plugin <const> = require("tecs2d.tiled.internal.debug")
local collision_module <const> = require("tecs2d.tiled.collision")
local tileset_utils <const> = require("tecs2d.tiled.internal.tileset")

local builtins <const> = tecs.builtins
local Transform <const> = builtins.Transform

local type TilemapData = types.TilemapData

-- Main module record
local record tiled is tecs_assets.AssetHandler<TilemapData>
    --- Fully parsed Tiled map data.
    type TilemapData = types.TilemapData
    --- Parsed Tiled tileset data.
    type TilesetData = types.TilesetData
    --- Parsed Tiled layer data.
    type LayerData = types.LayerData
    --- Parsed Tiled object data.
    type ObjectData = types.ObjectData
    --- Parsed per-tile metadata.
    type TileData = types.TileData
    --- Two-dimensional point from Tiled object geometry.
    type Point = types.Point

    --- Collision generation options for a tilemap.
    type CollisionConfig = collision_module.Config

    --- Loads and projects a Tiled map. Requires Transform.
    record Tilemap is tecs.Component
        --- Asset path loaded synchronously during the next First phase.
        path: string                 -- Asset path for loading
        --- Preloaded map data, or data populated from path.
        data: TilemapData | nil      -- Loaded tilemap data (nil until loaded)
        --- Optional collision-generation settings.
        collision: CollisionConfig | nil -- Optional collision configuration
        --- Runtime Box2D bodies owned by this map.
        collisionBodies: {love.physics.Body}  -- Created physics bodies (runtime)
    end

    --- Collision geometry utilities.
    collision: collision_module

    --- Associates a sprite with its source tile metadata.
    TileSource: types.TileSource

    --- Install tilemap loading, projection, animation, and collision systems.
    plugin: function(world: tecs.World)

    --- Debug visualization configuration.
    type DebugConfig = debug_plugin.DebugConfig
    --- Tag placed on debug visualization entities.
    TiledDebugShape: tecs.Component
    --- Event that toggles Tiled debug visualization.
    DebugToggle: debug_plugin.DebugToggle

    --- Debug plugin for visualizing Tiled objects.
    --- Observes DebugToggle events to spawn/despawn tagged shape entities.
    debugPlugin: function(world: tecs.World)

    --- Create a debug plugin with custom configuration.
    createDebugPlugin: function(config?: debug_plugin.DebugConfig): function(world: tecs.World)

    -- Utilities
    --- Get tile at world position
    getTileAt: function(data: TilemapData, layerIndex: integer, worldX: number, worldY: number): integer

    --- Convert world coordinates to tile coordinates
    worldToTile: function(data: TilemapData, worldX: number, worldY: number): integer, integer

    --- Convert tile coordinates to world coordinates
    tileToWorld: function(data: TilemapData, tileX: integer, tileY: integer): number, number

    --- Get a tile at tile coordinates
    getTile: function(data: TilemapData, layerIndex: integer, tileX: integer, tileY: integer): integer

    --- Parse an in-memory Tiled JSON export (already decoded to a Lua
    --- table) into TilemapData with full instance methods attached.
    --- Use this to build maps programmatically or in tests; file/asset
    --- loading goes through the `Tilemap` component instead.
    parseTiledMap: function(data: {string: any}): TilemapData

    --- Create a TileSource component from a global tile ID.
    --- Useful for manually adding TileSource to entities spawned from Tiled objects.
    --- @param map The loaded tilemap data.
    --- @param gid The global tile ID from ObjectData.gid or a tile layer.
    --- @return The TileSource component, or nil if gid is invalid.
    tileSourceFromGid: function(map: TilemapData, gid: integer): types.TileSource | nil
end

local Tilemap <const> = tiled.Tilemap

-- Export collision module
tiled.collision = collision_module

-- Export debugger markers as ordinary typed runtime values.
tiled.TiledDebugShape = debug_plugin.TiledDebugShape
tiled.DebugToggle = debug_plugin.DebugToggle

-- Debug plugin: observes DebugToggle events to spawn/despawn tagged debug shapes.
function tiled.createDebugPlugin(config?: debug_plugin.DebugConfig): function(world: tecs.World)
    local cfg = config or debug_plugin.defaultConfig
    return function(world: tecs.World)
        local tilemapQuery = world:query({
            name = "tiled.DebugTilemapQuery",
            include = {Tilemap, Transform}
        })

        local tagQuery = world:query({
            name = "tiled.DebugTagQuery",
            include = {debug_plugin.TiledDebugShape}
        })

        local enabled = false

        world:observe(0, debug_plugin.DebugToggle, function()
            if enabled then
                -- Despawn all debug shapes
                local toRemove: {integer} = {}
                for _, len, ids in tagQuery:iter() do
                    for i = 1, len do
                        toRemove[#toRemove + 1] = ids[i]
                    end
                end
                for i = 1, #toRemove do
                    world:despawn(toRemove[i])
                end
                enabled = false
            else
                -- Spawn debug shapes for all loaded tilemaps
                for archetype, len in tilemapQuery:iter() do
                    local tilemaps = archetype:get(Tilemap)
                    local transforms = archetype:get(Transform)
                    for i = 1, len do
                        local tilemap = tilemaps[i]
                        local data = tilemap.data
                        if data and (data as TilemapData)._world then
                            local transform = transforms[i]
                            debug_plugin.spawnDebugShapes(
                                world, cfg, data as TilemapData,
                                transform.x, transform.y
                            )
                        end
                    end
                end
                enabled = true
            end
        end)
    end
end

function tiled.debugPlugin(world: tecs.World)
    tiled.createDebugPlugin()(world)
end

-- Component registration
tecs.newComponent({
    name = "Tilemap",
    container = Tilemap,
    new = function(data: {string: any}): tiled.Tilemap
        return data as tiled.Tilemap
    end,
    -- Tilemap teardown (collision bodies, TileChunk / animated Sprite /
    -- image layer entities) is handled by the `tiled.TilemapLifecycle`
    -- query observer registered in `tiled.plugin`.
    serialize = function(t: tiled.Tilemap): {string: any}
        local result: {string: any} = {
            path = t.path,
        }
        local collision = t.collision
        if collision then
            result.collision = {
                enabled = (collision as collision_module.Config).enabled,
            }
        end
        return result
    end,
    deserialize = function(_world: tecs.World, data: {string: any}): tiled.Tilemap
        local tilemap = Tilemap.new({
            path = data.path as string,
        } as tiled.Tilemap)
        if data.collision then
            local collisionData = data.collision as {string: any}
            tilemap.collision = {
                enabled = collisionData.enabled as boolean,
            }
        end
        return tilemap
    end
})

-- TileSource is registered in types.tl (must be registered before chunk.tl uses it)
tiled.TileSource = types.TileSource

function tiled.tileSourceFromGid(
    map: types.TilemapData,
    gid: integer
): types.TileSource | nil
    if gid == 0 then return nil end

    -- Strip flip flags (4th return value is the clean GID)
    local _, _, _, cleanGid = tileset_utils.decodeFlipFlags(gid)

    -- Find the tileset
    local tileset = tileset_utils.getTilesetForGid(map, cleanGid)
    if not tileset then return nil end

    -- Get local tile ID
    local localId = cleanGid - tileset.firstgid

    -- Get tile properties and class from tileset
    local tileData = tileset.tiles and tileset.tiles[localId]
    local properties: {string: any} = tileData and tileData.properties or {}
    local class: string = tileData and tileData.class or ""

    return types.TileSource.new({
        gid = cleanGid,
        localId = localId,
        tilesetName = tileset.name,
        properties = properties,
        class = class,
    })
end

-- Utility functions: shared with the TilemapData instance methods that
-- loader.parseTiledMap attaches.
tiled.worldToTile = loader.worldToTile
tiled.tileToWorld = loader.tileToWorld
tiled.getTileAt = loader.getTileAt
tiled.getTile = loader.getTile
tiled.parseTiledMap = loader.parseTiledMap

-- Plugin implementation
function tiled.plugin(world: tecs.World)

    -- Get dependencies
    local assetManager = assert(tecs_assets.manager, "tecs2d.tiled requires the global asset manager")
    local pipelineInstance = world.resources[pipelinekey.PIPELINE]

    if not pipelineInstance then
        error("tecs2d.tiled requires tecs2d.gfx pipeline to be registered")
    end

    -- Query for tilemaps
    local tilemapQuery = world:query({
        name = "tiled.Query",
        include = {Tilemap}
    })

    local tilemapTransformQuery = world:query({
        name = "tiled.TransformQuery",
        include = {Tilemap, Transform}
    })

    -- Per-entity Tilemap teardown: free collision bodies and recursively
    -- despawn derived layer entities. Fires when Tilemap leaves an arch.
    world:query({
        name = "tiled.TilemapLifecycle",
        include = {Tilemap},
        onEntitiesRemoved = function(archetype: tecs.Archetype, firstRow: integer, lastRow: integer, _count: integer)
            local tilemaps = archetype:getMut(Tilemap) as {tiled.Tilemap}
            for row = firstRow, lastRow do
                local tilemap = tilemaps[row]
                if not tilemap then goto continue end
                if tilemap.collisionBodies then
                    collision_module.destroyColliders(tilemap.collisionBodies)
                    tilemap.collisionBodies = nil
                end
                local data = tilemap.data
                if data then
                    local mapLayers <const> = (data as TilemapData).layers
                    for li = 1, #mapLayers do
                        local layer = mapLayers[li]
                        if layer.type == "tilelayer" then
                            chunk_utils.despawnLayerChunks(world, layer)
                            chunk_utils.despawnLayerAnimatedTiles(world, layer)
                        elseif layer.type == "imagelayer" then
                            chunk_utils.despawnImageLayerEntity(world, layer)
                        end
                    end
                end
                ::continue::
            end
        end,
    })

    -- Snapshot integration: TileChunk, DirtyTileChunk, and TileSource
    -- entities are *derived* projections of Tilemap. Don't save them; the
    -- AssetLoader system below re-spawns them on load when it sees a
    -- restored Tilemap whose data._world is nil (always true post-load
    -- since `_world` is a runtime field that doesn't survive serialize).
    local tilechunk_module <const> = require("tecs2d.gfx.internal.tilechunk")
    world:observe(0, builtins.OnSnapshotSave, function(ev: builtins.OnSnapshotSave)
        ev:exclude(tilechunk_module.TileChunk as tecs.Component)
        ev:exclude(tilechunk_module.DirtyTileChunk)
        ev:exclude(types.TileSource as tecs.Component)
    end)

    -- Collision rebuild system: rebuilds dirty chunk collisions
    world:addSystem({
        name = "tiled.CollisionRebuild",
        phase = tecs.phases.First,
        run = function()
            for archetype, len in tilemapQuery:iter() do
                local tilemaps = archetype:get(Tilemap)
                for i = 1, len do
                    local tilemap = tilemaps[i]
                    local optionalData = tilemap.data
                    if optionalData then
                        local data = optionalData as TilemapData
                        if not data._collisionConfig or not data._physicsWorld then
                            goto continueCollisionMap
                        end
                        local collisionConfig = data._collisionConfig
                        local physicsWorld = data._physicsWorld

                        -- Check each tile layer for dirty chunks
                        local dataLayers <const> = data.layers
                        for li = 1, #dataLayers do
                            local layer = dataLayers[li]
                            if layer.type == "tilelayer" and layer._dirtyChunkCollisions then
                                -- Collect dirty chunks first (can't modify table during next() iteration)
                                local dirtyList: {{integer, integer}} = {}
                                for chunkX, chunkY in chunk_utils.getDirtyChunkCollisions(data, li) do
                                    table.insert(dirtyList, {chunkX, chunkY})
                                end

                                -- Clear all dirty flags at once
                                table_clear(layer._dirtyChunkCollisions)

                                -- Process each dirty chunk
                                for _, coords in ipairs(dirtyList) do
                                    local chunkX, chunkY = coords[1], coords[2]

                                    -- Destroy old collision body if it exists
                                    if layer._chunkCollisionBodies and layer._chunkCollisionBodies[chunkY] then
                                        local oldBody = layer._chunkCollisionBodies[chunkY][chunkX]
                                        if oldBody then
                                            collision_module.destroyCollider(oldBody)
                                            layer._chunkCollisionBodies[chunkY][chunkX] = nil

                                            -- Remove from tilemap.collisionBodies array
                                            if tilemap.collisionBodies then
                                                for bi = #tilemap.collisionBodies, 1, -1 do
                                                    if tilemap.collisionBodies[bi] == oldBody then
                                                        table.remove(tilemap.collisionBodies, bi)
                                                        break
                                                    end
                                                end
                                            end
                                        end
                                    end

                                    -- Create new collision body for this chunk
                                    local newBody = collision_module.createChunkCollider(
                                        data,
                                        physicsWorld,
                                        collisionConfig,
                                        li,
                                        chunkX,
                                        chunkY,
                                        data._collisionOriginX,
                                        data._collisionOriginY
                                    )

                                    if newBody then
                                        -- Initialize tracking if needed
                                        if not layer._chunkCollisionBodies then
                                            layer._chunkCollisionBodies = {}
                                        end
                                        if not layer._chunkCollisionBodies[chunkY] then
                                            layer._chunkCollisionBodies[chunkY] = {}
                                        end
                                        layer._chunkCollisionBodies[chunkY][chunkX] = newBody

                                        -- Add to tilemap.collisionBodies array
                                        if not tilemap.collisionBodies then
                                            tilemap.collisionBodies = {}
                                        end
                                        table.insert(tilemap.collisionBodies, newBody)
                                    end
                                end
                            end
                        end
                    end
                    ::continueCollisionMap::
                end
            end
        end
    })

    -- Synchronous loading function (avoids async handle issues)
    local function loadTilemapSync(path: string): TilemapData
        -- Use asset manager to resolve path
        local resolvedPath = assetManager:resolvePath(path)
        local jsonStr = love.filesystem.read(resolvedPath)
        if not jsonStr then
            error("Failed to load tilemap: " .. resolvedPath)
        end
        local parsed = json.parse(jsonStr) as {string: any}

        -- Parse the map
        local map = loader.parseTiledMap(parsed)

        -- Load tileset images
        -- Note: love.filesystem.read needs full path (resolvedPath), but assetManager:loadImage adds root automatically
        local syncTilesets <const> = map.tilesets
        for ti = 1, #syncTilesets do
            local ts = syncTilesets[ti]
            if ts.imagePath then
                -- .tsx is the XML tileset format; only JSON (.tsj) is supported.
                if ts.imagePath:match("%.tsx$") then
                    error("External .tsx (XML) tilesets are not supported; export as .tsj (JSON): " .. ts.imagePath)
                end

                -- Check if this is an external tileset reference. The
                -- external tileset's image path is relative to the .tsj
                -- file's directory, not the map's, so remember the
                -- asset-relative .tsj location to resolve against.
                local externalBase: string = nil
                if ts.imagePath:match("%.tsj$") then
                    externalBase = loader.resolveRelativePath(path, ts.imagePath)
                    local tsjPath = loader.resolveRelativePath(resolvedPath, ts.imagePath)
                    local tsjData = love.filesystem.read(tsjPath)
                    if not tsjData then
                        error("Failed to read external tileset '" .. tsjPath .. "' referenced by " .. path)
                    end
                    local tsjParsed = json.parse(tsjData) as {string: any}
                    local externalTs = loader.parseTileset(tsjParsed, ts.firstgid)
                    ts.name = externalTs.name
                    ts.tilewidth = externalTs.tilewidth
                    ts.tileheight = externalTs.tileheight
                    ts.tilecount = externalTs.tilecount
                    ts.columns = externalTs.columns
                    ts.spacing = externalTs.spacing
                    ts.margin = externalTs.margin
                    ts.imagePath = externalTs.imagePath
                    ts.imagewidth = externalTs.imagewidth
                    ts.imageheight = externalTs.imageheight
                    ts.tiles = externalTs.tiles
                    ts._animatedTiles = externalTs._animatedTiles
                    ts._animationStates = externalTs._animationStates
                    ts._occluderHeights = externalTs._occluderHeights
                end

                -- Load the image and optional material maps
                if ts.imagePath and not ts.imagePath:match("%.tsj$") then
                    local imgPath = loader.resolveRelativePath(externalBase or path, ts.imagePath)
                    local imgHandle = assetManager:loadImage(imgPath)
                    local tilesetImage <const> = imgHandle.value  -- Block until loaded
                    ts.image = tilesetImage
                    -- Use nearest-neighbor filtering to avoid tile bleeding
                    tilesetImage:setFilter("nearest", "nearest")

                    -- Try to load optional material maps (_n.png, _e.png, _orm.png)
                    local basePath = imgPath:gsub("%.png$", "")
                    local normalPath = basePath .. "_n.png"
                    local emissionPath = basePath .. "_e.png"
                    local ormPath = basePath .. "_orm.png"

                    if love.filesystem.getInfo(normalPath) then
                        local normalHandle = assetManager:loadImage(normalPath)
                        local normalImage <const> = normalHandle.value
                        ts.normalImage = normalImage
                        normalImage:setFilter("nearest", "nearest")
                    end

                    if love.filesystem.getInfo(emissionPath) then
                        local emissionHandle = assetManager:loadImage(emissionPath)
                        local emissionImage <const> = emissionHandle.value
                        ts.emissionImage = emissionImage
                        emissionImage:setFilter("nearest", "nearest")
                    end

                    if love.filesystem.getInfo(ormPath) then
                        local ormHandle = assetManager:loadImage(ormPath)
                        local ormImage <const> = ormHandle.value
                        ts.ormImage = ormImage
                        ormImage:setFilter("nearest", "nearest")
                    end
                end
            end
        end

        -- Load image layer images
        local syncLayers <const> = map.layers
        for li = 1, #syncLayers do
            local layer = syncLayers[li]
            if layer.type == "imagelayer" and layer.imagePath then
                local imgPath = loader.resolveRelativePath(path, layer.imagePath)
                local imgHandle = assetManager:loadImage(imgPath)
                local layerImage <const> = imgHandle.value  -- Block until loaded
                layer._image = layerImage
                layerImage:setFilter("nearest", "nearest")
                if layer.imagewidth == 0 then
                    layer.imagewidth = layerImage:getWidth() as integer
                end
                if layer.imageheight == 0 then
                    layer.imageheight = layerImage:getHeight() as integer
                end
            end
        end

        return map
    end

    -- Asset loading system (loads tilemaps when component is added)
    world:addSystem({
        name = "tiled.AssetLoader",
        phase = tecs.phases.First,
        run = function()
            for archetype, len in tilemapTransformQuery:iter() do
                local tilemaps = archetype:get(Tilemap)
                local mutTilemaps: {tiled.Tilemap} = nil
                local transforms = archetype:get(Transform)

                for i = 1, len do
                    local tilemap = tilemaps[i]

                    -- Skip already-processed tilemaps
                    local existingData = tilemap.data
                    if existingData and (existingData as TilemapData)._world then
                        goto continue
                    end

                    -- Loading and projection are one-time transitions. Defer
                    -- getMut until a row actually needs processing so settled
                    -- maps do not keep their component column dirty forever.
                    if not mutTilemaps then
                        mutTilemaps = archetype:getMut(Tilemap)
                    end
                    tilemap = mutTilemaps[i]

                    if not tilemap.data and tilemap.path then
                        -- Load tilemap synchronously
                        tilemap.data = loadTilemapSync(tilemap.path)
                    end

                    if not tilemap.data then goto continue end
                    local data = tilemap.data as TilemapData

                    -- Set world reference for setTile dirty marking
                    data._world = world

                    -- Create per-chunk collision bodies if configured
                    local collision = tilemap.collision
                    if collision and (collision as collision_module.Config).enabled then
                        local collisionConfig = collision as collision_module.Config
                        local physics = require("tecs2d.physics")
                        local physicsState = world.resources[physics]
                        if physicsState and physicsState.world then
                            local physicsWorld = physicsState.world

                            -- Store collision config, physics world, and the
                            -- tilemap's Transform origin on tilemap data so
                            -- rebuilds place bodies where the map renders.
                            local tilemapTransform = transforms[i]
                            data._collisionConfig = collisionConfig
                            data._physicsWorld = physicsWorld
                            data._collisionOriginX = tilemapTransform.x
                            data._collisionOriginY = tilemapTransform.y

                            -- Create per-chunk collision bodies for each tile layer
                            tilemap.collisionBodies = {}
                            local dataLayers <const> = data.layers
                            for li = 1, #dataLayers do
                                local layer = dataLayers[li]
                                if layer.type == "tilelayer" then
                                    -- Initialize per-chunk collision tracking
                                    layer._chunkCollisionBodies = {}

                                    -- Calculate number of chunks
                                    local chunksX = math.ceil(layer.width / collision_module.CHUNK_SIZE)
                                    local chunksY = math.ceil(layer.height / collision_module.CHUNK_SIZE)

                                    for cy = 0, chunksY - 1 do
                                        layer._chunkCollisionBodies[cy] = {}
                                        for cx = 0, chunksX - 1 do
                                            local body = collision_module.createChunkCollider(
                                                data,
                                                physicsWorld,
                                                collisionConfig,
                                                li,
                                                cx,
                                                cy,
                                                tilemapTransform.x,
                                                tilemapTransform.y
                                            )
                                            if body then
                                                layer._chunkCollisionBodies[cy][cx] = body
                                                table.insert(tilemap.collisionBodies, body)
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end

                    -- Spawn GPU TileChunk entities for tile layers
                    local transform = transforms[i]
                    chunk_utils.spawnTileChunkEntities(
                        world,
                        data,
                        transform.x,
                        transform.y,
                        transform.layer
                    )

                    -- Spawn Sprite entities for animated tiles
                    chunk_utils.spawnAnimatedTileEntities(
                        world,
                        data,
                        transform.x,
                        transform.y,
                        transform.layer
                    )

                    -- Spawn Sprite entities for image layers (GPU-driven parallax/tiling)
                    chunk_utils.spawnImageLayerEntities(
                        world,
                        data,
                        transform.x,
                        transform.y,
                        transform.layer
                    )

                    -- Configure layer parallax from Tiled layer settings
                    local dataLayers <const> = data.layers
                    for li = 1, #dataLayers do
                        local layer = dataLayers[li]
                        local renderLayer = transform.layer + layer.groupIndex - 1
                        if layer.parallaxx ~= 1.0 or layer.parallaxy ~= 1.0 then
                            pipelineInstance:setLayerParallax(renderLayer, layer.parallaxx, layer.parallaxy)
                        end
                    end


                    ::continue::
                end
            end
        end
    })
end

return tiled
