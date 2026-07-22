---
description: "The TileChunk component rendering 16x16 static tile grids per draw call, with properties and dirty marking"
---

# TileChunks

The `TileChunk` component renders 16×16 grids of **static** tiles efficiently using GPU instancing. Each chunk is a
single draw call. TileChunks do not support animation; for animated tiles, use individual
[Sprite](/tecs2d/rendering/sprites/) entities.

::: tip Automatic Creation
When using [Tiled maps](./) with `tecs2d.tiled`, `TileChunk` entities are created automatically for static tiles.
Animated tiles are automatically spawned as separate Sprite entities with synced animation.
:::

## Quick Start

```teal
local gfx = require("tecs2d.gfx")

-- Create a tile chunk
local tiles = {}
for i = 1, 256 do
    tiles[i] = math.random(1, 4)  -- Random tile IDs 1-4
end

world:spawn(
    tecs.builtins.Transform(0, 0, 3),
    gfx.TileChunk({
        tileset = love.graphics.newImage("tileset.png"),
        tileWidth = 32,
        tileHeight = 32,
        columns = 16,  -- Tileset columns for UV calculation
        tiles = tiles
    }),
    gfx.Color(1, 0.8, 0.8, 1)  -- Optional tint
)
```

## TileChunk Component

### Properties

| Property      | Type        | Default  | Description                               |
| ------------- | ----------- | -------- | ----------------------------------------- |
| `tileset`     | Texture     | required | Tileset texture atlas                     |
| `tileWidth`   | number      | 32       | Tile width in pixels                      |
| `tileHeight`  | number      | 32       | Tile height in pixels                     |
| `columns`     | integer     | 16       | Number of columns in the tileset          |
| `tiles`       | `{integer}` | `{}`     | 256 tile IDs (16×16 grid), 0 = empty      |
| `normalMap`   | Texture     | nil      | Normal map for lighting                   |
| `emissionMap` | Texture     | nil      | Emission/glow map                         |
| `specularMap` | Texture     | nil      | Specular map (RGB=intensity, A=shininess) |

### Required Components

| Component   | Description                             |
| ----------- | --------------------------------------- |
| `Transform` | Position of the chunk (top-left corner) |

## Styling and Lighting

TileChunks use a mix of ECS components and built-in properties for styling:

| Feature     | How to use                                                                  |
| ----------- | --------------------------------------------------------------------------- |
| Tint        | `Color` component (same as other renderables)                               |
| Lighting    | [Layer configuration](/tecs2d/rendering/layers#layer-lighting) (not `Unlit`)       |
| Normal maps | `normalMap` property                                                        |
| Emission    | `emissionMap` property                                                      |
| Specular    | `specularMap` property (RGB=intensity, A=shininess)                         |

::: details Limited styling support
TileChunks do not support per-entity `Unlit`, blend tags, or `Material` components.
These features are configured at the layer level instead, because chunks are batched
together for efficient rendering.
:::

## Updating Tiles

`DirtyTileChunk` is automatically added when spawning. To update tiles at runtime, modify the `tiles` array and add
`DirtyTileChunk` to trigger a GPU re-sync:

```teal
local chunk = world:get(entityId, gfx.TileChunk)
chunk.tiles[128] = 5  -- Change a tile
world:set(entityId, gfx.DirtyTileChunk)  -- Mark for GPU sync
```

::: details Why manual dirty marking?
The ECS cannot detect when you modify the internal `tiles` array since Lua tables don't have change notifications.
Adding `DirtyTileChunk` explicitly tells the render system to re-sync this chunk to the GPU. This is similar to
`world:markComponentDirty()` for other components, but uses a tag component so chunks can be batched efficiently.
:::

## Chunk Size

Chunks are fixed at 16×16 tiles (256 tiles total). This size is baked into the GPU shaders and buffer layouts and
cannot be changed. Use `gfx.TILE_CHUNK_SIZE` to reference this constant.

```teal
local CHUNK_SIZE = gfx.TILE_CHUNK_SIZE  -- 16
local worldX = chunkX * CHUNK_SIZE * tileWidth
local worldY = chunkY * CHUNK_SIZE * tileHeight
```

::: details Why 16×16?
The chunk size is fixed because GPU shader structs require fixed field counts at compile time. Tile IDs are stored as
64 uvec4 fields. 16×16 (256 tiles) also aligns well with GPU compute workgroup sizes and provides reasonable culling
granularity for tilemaps. Making this configurable would require shader variants or storing tile IDs in a separate
buffer with indirection.
:::
