--- Shared type definitions for the tecs2d.tiled module.
---
--- Defines records for Tiled map data structures: tilemaps, layers, tilesets,
--- tiles, objects, and the chunking system for efficient rendering.

local tecs <const> = require("tecs")

local record types
    --- Animation frame within a tile animation.
    record Frame
        tileid: integer      -- Local tile ID for this frame
        duration: number     -- Duration in seconds
    end

    --- Animation state for a globally-synced tile animation.
    record AnimationState
        totalTime: number    -- Total animation duration in seconds
        time: number         -- Current time (loops at totalTime)
        currentFrame: integer -- Current frame index (1-based)
    end

    --- Individual tile data within a tileset.
    record TileData
        id: integer              -- Local tile ID within tileset
        class: string            -- Tiled "type" field (tile class)
        properties: {string: any}
        animation: {Frame}       -- Animation frames if animated (nil if static)
        objectgroup: types.LayerData -- Collision shapes for physics integration
    end

    --- A loaded tileset with texture and tile metadata.
    record TilesetData
        firstgid: integer        -- First Global ID in this tileset
        name: string
        tilewidth: integer
        tileheight: integer
        tilecount: integer
        columns: integer
        spacing: integer
        margin: integer
        imagePath: string        -- Original path (for debugging/reloading)
        image: love.graphics.Image -- Loaded texture
        normalImage: love.graphics.Image  -- Normal map (from _n.png), optional
        emissionImage: love.graphics.Image -- Emission map (from _e.png), optional
        ormImage: love.graphics.Image -- ORM map (from _orm.png), optional
        imagewidth: integer
        imageheight: integer
        transparentcolor: string -- Hex color for transparency (optional)

        -- Tile-specific data (sparse table, keyed by local ID)
        tiles: {integer: TileData}

        -- Quad cache (keyed by local tile ID)
        _quads: {integer: love.graphics.Quad}

        -- Animation state
        _animatedTiles: {integer}  -- Local IDs that have animations
        _animationStates: {integer: AnimationState}  -- Global sync states

        -- Occluder data (sparse table, keyed by local ID)
        -- Maps local tile ID to occluder height (nil or 0 = not an occluder)
        _occluderHeights: {integer: number}
    end

    --- Point structure for polygons/polylines.
    record Point
        x: number
        y: number
    end

    --- Object data from Tiled object layers.
    record ObjectData
        id: integer
        name: string
        class: string            -- Tiled "type" field in JSON
        x: number                -- Position in pixels
        y: number
        width: number
        height: number
        rotation: number         -- Degrees clockwise
        visible: boolean
        gid: integer             -- For tile objects (0 if not a tile object)
        properties: {string: any}

        -- Shape data
        shape: string            -- "rectangle" | "ellipse" | "polygon" | "polyline" | "point"
        polygon: {Point}
        polyline: {Point}
    end

    --- Layer data from Tiled.
    record LayerData
        id: integer
        name: string
        type: string             -- "tilelayer" | "objectgroup" | "imagelayer" | "group"
        visible: boolean
        opacity: number
        offsetx: number
        offsety: number
        parallaxx: number        -- Parallax factor (1.0 = normal, <1 = slower)
        parallaxy: number
        tintcolor: {number, number, number, number}  -- RGBA (0-1)
        properties: {string: any}  -- Custom properties from Tiled

        -- For tile layers (0-indexed FFI array for memory efficiency)
        data: {integer}          -- GID array (0-indexed FFI, cast from uint32_t*)
        width: integer           -- Layer width in tiles
        height: integer          -- Layer height in tiles
        _rawTileData: love.Data  -- Anchors decompressed data (prevents GC)

        -- For object layers
        objects: {ObjectData}

        -- For image layers
        imagePath: string        -- Path to image file
        imagewidth: integer      -- Image width in pixels
        imageheight: integer     -- Image height in pixels
        repeatx: boolean         -- Tile horizontally
        repeaty: boolean         -- Tile vertically
        _image: love.graphics.Image  -- Loaded image (runtime)

        -- For group layers (flattened on load, so rarely used)
        layers: {LayerData}

        -- Runtime state for GPU TileChunk mode.
        -- A single (cy, cx) chunk can contain tiles from multiple tilesets;
        -- each one becomes its own per-tileset TileChunk entity, keyed by
        -- the tileset's firstgid so setTile can find the right one to update.
        _chunkEntities: {integer}  -- Spawned TileChunk entity IDs (flat list, for despawn)
        _chunkEntityMap: {integer: {integer: {integer: integer}}}  -- [cy][cx][firstgid] -> entityId

        -- Per-layer spawn parameters captured at load time so setTile can
        -- spawn a new per-tileset chunk entity on demand when a tile is set
        -- to a tileset that didn't yet have a chunk entity at this position.
        _baseX: number
        _baseY: number
        _baseLayer: integer

        -- Runtime state for animated tile Sprite entities.
        _animatedSpriteEntities: {integer}  -- Flat list (for despawn)
        _animatedSpriteEntityMap: {integer: {integer: integer}}  -- [tileY][tileX] -> entityId

        -- Runtime state for image layer sprite entity
        _imageLayerEntity: integer  -- Spawned Sprite entity ID for image layer (0 if none)

        -- Runtime state for per-chunk collision bodies
        _chunkCollisionBodies: {integer: {integer: love.physics.Body}}  -- [chunkY][chunkX] -> body
        _dirtyChunkCollisions: {string: boolean}  -- "chunkY,chunkX" -> true if needs rebuild

        -- Render grouping (assigned during loading based on Tiled groups)
        -- groupIndex determines which render layer this Tiled layer belongs to.
        -- All layers with the same groupIndex render on the same render layer.
        groupIndex: integer
        -- Z offset for sorting within the render layer (0, 100, 200, ...).
        zOffset: number
    end

    --- A fully loaded tilemap.
    record TilemapData
        -- Map dimensions
        width: integer           -- Map width in tiles
        height: integer          -- Map height in tiles
        tilewidth: integer       -- Tile width in pixels
        tileheight: integer      -- Tile height in pixels

        -- Loaded data
        layers: {LayerData}      -- Ordered array of layers
        tilesets: {TilesetData}  -- Loaded tilesets (sorted by firstgid)
        properties: {string: any}

        -- Runtime state
        _animatedTilesets: {TilesetData}  -- Subset with animations
        _gidToTileset: {integer: TilesetData}  -- Cache for GID lookups
        _world: any  -- ECS world reference for TileChunk dirty marking
        _physicsWorld: any  -- Box2D physics world for collision rebuild
        _collisionConfig: any  -- Collision config for rebuild
        -- Tilemap entity Transform position at load time; collision
        -- bodies are created at this origin so physics geometry lands
        -- where the map renders.
        _collisionOriginX: number
        _collisionOriginY: number

        -- Chunk configuration
        chunkSize: integer       -- Tiles per chunk side (default 32)

        -- Methods
        worldToTile: function(self, worldX: number, worldY: number): integer, integer
        tileToWorld: function(self, tileX: integer, tileY: integer): number, number
        getTile: function(self, layerIndex: integer, tileX: integer, tileY: integer): integer
        getTileAt: function(self, layerIndex: integer, worldX: number, worldY: number): integer
        setTile: function(self, layerIndex: integer, tileX: integer, tileY: integer, gid: integer)
        setTileAt: function(self, layerIndex: integer, worldX: number, worldY: number, gid: integer)
        toJSON: function(self, pretty: boolean): string

        -- Property access methods
        getTileProperties: function(self, layerIndex: integer, tileX: integer, tileY: integer): TileData
        getLayerProperties: function(self, layerIndex: integer): {string: any}
        getLayer: function(self, name: string): LayerData
    end

    --- Component that associates a sprite with its source tile data.
    --- Added to animated tile sprites spawned from tilemaps.
    record TileSource is tecs.Component
        gid: integer                 -- Global tile ID (with flip flags stripped)
        localId: integer             -- Local tile ID within the tileset
        tilesetName: string          -- Name of the tileset this tile belongs to
        properties: {string: any}    -- Custom tile properties from Tiled
        class: string                -- Tiled "type" field (tile class)
    end
end

-- Create local reference for component registration
local TileSource <const> = types.TileSource

-- Register TileSource component (must be registered before use in chunk.tl)
tecs.newComponent({
    name = "TileSource",
    container = TileSource,
    new = function(data: {string: any}): types.TileSource
        return {
            gid = data.gid as integer,
            localId = data.localId as integer,
            tilesetName = data.tilesetName as string,
            properties = data.properties as {string: any},
            class = data.class as string,
        }
    end,
    serialize = function(t: types.TileSource): {string: any}
        return {
            gid = t.gid,
            localId = t.localId,
            tilesetName = t.tilesetName,
            properties = t.properties,
            class = t.class,
        }
    end,
})

return types
