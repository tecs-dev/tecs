--- Tileset utilities for GID lookups, quad generation, and animation state.

local types <const> = require("tecs2d.tiled.types")
local bit <const> = require("bit")

local type TilemapData = types.TilemapData
local type TilesetData = types.TilesetData
local type AnimationState = types.AnimationState

local lg_newQuad <const> = love.graphics.newQuad
local math_floor <const> = math.floor
local band <const> = bit.band as function(integer, integer): integer

-- GID flip flags (Tiled specification)
local FLIPPED_HORIZONTALLY_FLAG <const> = 0x80000000
local FLIPPED_VERTICALLY_FLAG   <const> = 0x40000000
local FLIPPED_DIAGONALLY_FLAG   <const> = 0x20000000
local GID_MASK <const> = 0x0FFFFFFF

local record tileset
    -- Constants
    FLIPPED_HORIZONTALLY_FLAG: integer
    FLIPPED_VERTICALLY_FLAG: integer
    FLIPPED_DIAGONALLY_FLAG: integer
    GID_MASK: integer

    --- Decode flip flags from a GID.
    --- @param gid The Global ID with potential flip flags
    --- @return flipH Horizontal flip
    --- @return flipV Vertical flip
    --- @return flipD Diagonal flip (rotation)
    --- @return cleanGid GID with flags removed
    decodeFlipFlags: function(gid: integer): boolean, boolean, boolean, integer

    --- Get the tileset that contains a given GID.
    --- Uses cached lookup table for performance.
    --- @param map The tilemap data
    --- @param gid The Global ID (with flags already removed)
    --- @return The tileset containing this GID, or nil if not found
    getTilesetForGid: function(map: TilemapData, gid: integer): TilesetData

    --- Get the local tile ID within a tileset.
    --- @param tileset The tileset
    --- @param gid The Global ID (with flags removed)
    --- @return Local tile ID (0-based)
    getLocalTileId: function(tileset: TilesetData, gid: integer): integer

    --- Get or create a quad for a tile.
    --- Caches quads to avoid recreation.
    --- @param tileset The tileset
    --- @param localId The local tile ID (0-based)
    --- @return The quad for rendering this tile
    getOrCreateQuad: function(tileset: TilesetData, localId: integer): love.graphics.Quad

    --- Initialize animation states for a tileset.
    --- Creates AnimationState for each animated tile.
    --- @param tileset The tileset to initialize
    initializeAnimationStates: function(tileset: TilesetData)

    --- Build the GID-to-tileset cache for a tilemap.
    --- @param map The tilemap data
    buildGidCache: function(map: TilemapData)

    --- Get a clean GID with flip flags removed.
    --- @param gid The Global ID with potential flip flags
    --- @return Clean GID without flip flags
    getCleanGid: function(gid: integer): integer
end

-- Export constants
tileset.FLIPPED_HORIZONTALLY_FLAG = FLIPPED_HORIZONTALLY_FLAG
tileset.FLIPPED_VERTICALLY_FLAG = FLIPPED_VERTICALLY_FLAG
tileset.FLIPPED_DIAGONALLY_FLAG = FLIPPED_DIAGONALLY_FLAG
tileset.GID_MASK = GID_MASK

function tileset.decodeFlipFlags(gid: integer): boolean, boolean, boolean, integer
    local flipH = band(gid, FLIPPED_HORIZONTALLY_FLAG) ~= 0
    local flipV = band(gid, FLIPPED_VERTICALLY_FLAG) ~= 0
    local flipD = band(gid, FLIPPED_DIAGONALLY_FLAG) ~= 0
    local cleanGid = band(gid, GID_MASK)
    return flipH, flipV, flipD, cleanGid
end

function tileset.getTilesetForGid(map: TilemapData, gid: integer): TilesetData
    -- Check cache first
    if map._gidToTileset then
        local cached = map._gidToTileset[gid]
        if cached then
            return cached
        end
    end

    -- Find tileset (they're sorted by firstgid)
    -- Iterate backwards to find the first tileset where gid >= firstgid
    local found: TilesetData = nil
    for i = #map.tilesets, 1, -1 do
        local ts = map.tilesets[i]
        if gid >= ts.firstgid then
            found = ts
            break
        end
    end

    -- Cache the result
    if found and map._gidToTileset then
        map._gidToTileset[gid] = found
    end

    return found
end

function tileset.getLocalTileId(ts: TilesetData, gid: integer): integer
    return gid - ts.firstgid
end

function tileset.getOrCreateQuad(ts: TilesetData, localId: integer): love.graphics.Quad
    -- Initialize cache if needed
    if not ts._quads then
        ts._quads = {}
    end

    -- Check cache
    local cached = ts._quads[localId]
    if cached then
        return cached
    end

    -- Calculate position in tileset image
    local col = localId % ts.columns
    local row = math_floor(localId / ts.columns)
    local x = ts.margin + col * (ts.tilewidth + ts.spacing)
    local y = ts.margin + row * (ts.tileheight + ts.spacing)

    -- Create and cache quad
    local quad = lg_newQuad(x, y, ts.tilewidth, ts.tileheight, ts.imagewidth, ts.imageheight)
    ts._quads[localId] = quad

    return quad
end

function tileset.initializeAnimationStates(ts: TilesetData)
    ts._animatedTiles = ts._animatedTiles or {}
    ts._animationStates = ts._animationStates or {}

    -- Iterate through tiles with animation data
    if ts.tiles then
        for localId, tile in pairs(ts.tiles) do
            if tile.animation and #tile.animation > 0 then
                -- Calculate total animation time
                local totalTime: number = 0
                local animation <const> = tile.animation
                for i = 1, #animation do
                    totalTime = totalTime + animation[i].duration
                end

                -- Skip zero-length animations (Tiled permits authoring all
                -- frame durations as 0); the update loop's time wrap would
                -- never terminate on totalTime == 0.
                if totalTime > 0 then
                    table.insert(ts._animatedTiles, localId)
                    local state: AnimationState = {
                        totalTime = totalTime,
                        time = 0,
                        currentFrame = 1
                    }
                    ts._animationStates[localId] = state
                end
            end
        end
    end
end

function tileset.buildGidCache(map: TilemapData)
    map._gidToTileset = {}
end

function tileset.getCleanGid(gid: integer): integer
    return band(gid, GID_MASK)
end

return tileset
