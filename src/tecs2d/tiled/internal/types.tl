--- Private runtime extensions for public Tiled data interfaces.
---
--- These fields support rendering, animation, and collision projection. They
--- remain on the same runtime tables for allocation-free access, but are not
--- part of the supported `tecs2d.tiled` data contract.

local tecs <const> = require("tecs")
local types <const> = require("tecs2d.tiled.types")

local record internaltypes
    record TilesetDataImpl is types.TilesetData
        -- Quad cache keyed by local tile ID.
        _quads: {integer: love.graphics.Quad}

        -- Globally synchronized animation bookkeeping.
        _animatedTiles: {integer}
        _animationStates: {integer: types.AnimationState}

        -- Local tile ID to occluder height.
        _occluderHeights: {integer: number}
    end

    record LayerDataImpl is types.LayerData
        -- Narrow nested runtime layers to the private extension.
        layers: {LayerDataImpl}

        -- Anchors decompressed FFI tile data so the backing allocation lives.
        _rawTileData: love.Data

        -- Loaded image-layer texture.
        _image: love.graphics.Image

        -- Spawned TileChunk entities and per-cell lookup.
        _chunkEntities: {integer}
        _chunkEntityMap: {integer: {integer: {integer: integer}}}

        -- Projection origin used when runtime edits spawn new chunks.
        _baseX: number
        _baseY: number
        _baseLayer: integer

        -- Animated tile Sprite entities.
        _animatedSpriteEntities: {integer}
        _animatedSpriteEntityMap: {integer: {integer: integer}}

        -- Spawned image-layer entity.
        _imageLayerEntity: integer

        -- Per-chunk collision bodies and rebuild flags.
        _chunkCollisionBodies: {integer: {integer: love.physics.Body}}
        _dirtyChunkCollisions: {string: boolean}
    end

    record TilemapDataImpl is types.TilemapData
        -- Narrow loaded collections to their private runtime extensions.
        layers: {LayerDataImpl}
        tilesets: {TilesetDataImpl}

        -- GID lookup cache.
        _gidToTileset: {integer: types.TilesetData}

        -- Runtime owner used to dirty projected chunks after tile edits.
        _world: tecs.World

        -- Collision rebuild context.
        _physicsWorld: love.physics.World
        _collisionConfig: types.CollisionConfig
        _collisionOriginX: number
        _collisionOriginY: number
    end
end

return internaltypes
