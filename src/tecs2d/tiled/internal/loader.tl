--- Runtime loader for Tiled maps with chunk dirty tracking.
---
--- Re-exports all parsing functions from parser.tl and adds setTile/setTileAt
--- methods that integrate with the GPU TileChunk system.

local tecs <const> = require("tecs")
local types <const> = require("tecs2d.tiled.types")
local internaltypes <const> = require("tecs2d.tiled.internal.types")
local parser <const> = require("tecs2d.tiled.internal.parser")
local chunk <const> = require("tecs2d.tiled.internal.chunk")

local type TilemapData = types.TilemapData
local type TilemapDataImpl = internaltypes.TilemapDataImpl

-- setTile with chunk dirty tracking
local function setTile(self: TilemapData, layerIndex: integer, tileX: integer, tileY: integer, gid: integer)
    local layer = self.layers[layerIndex]
    if not layer or layer.type ~= "tilelayer" then
        return
    end
    if tileX < 1 or tileX > layer.width or tileY < 1 or tileY > layer.height then
        return
    end

    -- 0-based FFI index
    local idx = (tileY - 1) * layer.width + (tileX - 1)
    local oldGid = layer.data[idx]
    if oldGid ~= gid then
        layer.data[idx] = gid
        local runtime = self as TilemapDataImpl
        -- Mark chunk dirty if world is available (set when TileChunks spawned)
        if runtime._world then
            local world = runtime._world as tecs.World
            chunk.markTileDirty(world, runtime, layerIndex, tileX, tileY, oldGid)
        end
    end
end

local function setTileAt(self: TilemapData, layerIndex: integer, worldX: number, worldY: number, gid: integer)
    local tileX, tileY = self:worldToTile(worldX, worldY)
    setTile(self, layerIndex, tileX, tileY, gid)
end

-- Attach all methods including setTile/setTileAt
local function attachMethods(map: TilemapData)
    -- Attach base read-only methods from parser
    parser.attachBaseMethods(map)
    -- Add runtime mutation methods
    map.setTile = setTile
    map.setTileAt = setTileAt
end

local record loader
    --- Parse a Tiled map JSON into TilemapData.
    --- Does NOT load tileset images; that's handled by the asset loader.
    --- @param json The parsed JSON table
    --- @return Parsed TilemapData
    parseTiledMap: function(json: {string: any}): TilemapData

    --- Parse an external tileset JSON.
    --- @param json The parsed JSON table
    --- @param firstgid The first GID assigned to this tileset
    --- @return Parsed TilesetData (without image loaded)
    parseTileset: function(json: {string: any}, firstgid: integer): types.TilesetData

    --- Parse custom properties array.
    --- @param propsArray The properties array from Tiled JSON
    --- @return Table of property name to value
    parseProperties: function(propsArray: {{string: any}}): {string: any}

    --- Resolve a relative path from a base path.
    --- @param basePath The base file path
    --- @param relativePath The relative path to resolve
    --- @return Resolved absolute path
    resolveRelativePath: function(basePath: string, relativePath: string): string

    --- Convert world coordinates to tile coordinates.
    worldToTile: function(map: TilemapData, worldX: number, worldY: number): integer, integer

    --- Convert tile coordinates to world coordinates.
    tileToWorld: function(map: TilemapData, tileX: integer, tileY: integer): number, number

    --- Get a tile GID at tile coordinates (0 for out-of-range or non-tile layers).
    getTile: function(map: TilemapData, layerIndex: integer, tileX: integer, tileY: integer): integer

    --- Get a tile GID at world coordinates.
    getTileAt: function(map: TilemapData, layerIndex: integer, worldX: number, worldY: number): integer

    -- Re-export types for convenience
    type TilemapData = types.TilemapData
    type TilesetData = types.TilesetData
    type LayerData = types.LayerData
end

-- Re-export parser functions
loader.parseProperties = parser.parseProperties
loader.resolveRelativePath = parser.resolveRelativePath
loader.parseTileset = parser.parseTileset
loader.worldToTile = parser.worldToTile
loader.tileToWorld = parser.tileToWorld
loader.getTile = parser.getTile
loader.getTileAt = parser.getTileAt

-- Wrap parseTiledMap to attach full methods including setTile
function loader.parseTiledMap(data: {string: any}): TilemapData
    local map = parser.parseTiledMap(data)
    -- Re-attach with setTile/setTileAt added
    attachMethods(map)
    return map
end

return loader
