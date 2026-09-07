---
description: "Render static 16x16 tile grids with native TileChunk components, atlas geometry, and dirty updates"
order: 10
---

# TileChunks

The `TileChunk` component renders a 16×16 grid of **static** tiles. A chunk is
one ECS entity with a native tile-ID array. Tiled creates chunks automatically
for static atlas tiles and keeps animated tiles as separate sprite entities.
Image-collection tiles also use sprites because each tile can select a
different image.

## Quick start

```nupp
const tiles: {integer} = {}
for index = 1, 256 do
    tiles[index] = (index % 4) + 1
end

world:spawn(
    tecs.ecs.Transform2D(0, 0, 0, 3),
    tecs.gfx.TileChunk({
        tileset = image,
        tileWidth = 32,
        tileHeight = 32,
        columns = 16,
        tiles = tiles
    }),
    tecs.gfx.Tint(1, 0.8, 0.8, 1)
)
```

`image` is an image ID returned by `tecs.gfx.images.upload`. The transform names
the chunk's **top-left corner**. Its rotation and scale apply to the whole grid.
`Transform2D`, `Tint`, `Renderable2D` and `DirtyTileChunk` are required components
and are supplied automatically when omitted.

## TileChunk properties

| Property | Default | Meaning |
| --- | --- | --- |
| `tileset` | Required | Atlas image ID |
| `tileWidth`, `tileHeight` | 32 | Tile image dimensions in pixels |
| `columns` | 16 | Atlas columns for UV calculation |
| `spacing` | 0 | Pixel gap between atlas tiles |
| `margin` | 0 | Pixel inset around the atlas edge |
| `tiles` | Empty grid | Cells 1 through 256, in row order; 0 means empty |
| `cellWidth`, `cellHeight` | Tile dimensions | Grid spacing, independent of tile image size |
| `offsetX`, `offsetY` | 0 | Tile image offsets inside each cell |

Tile IDs are **one-based local atlas indices**. Tiled's zero-based tile ID 0 is
stored as 1. The high H, V and diagonal flip bits retain Tiled's encoding.
Sparse constructor tables are supported, including a table containing only
cell 256. The native array reserves element zero; game code uses 1 through 256.

Tiles align to the bottom-left of their cells, so oversized tiles extend above
and to the right just as they do in Tiled. Atlas spacing, margins and tileset
offsets are preserved. Tint, material, clipping, lighting and shadow components
apply through the same rendering path as other geometry.

## Updating tiles

Use `getMut` to mark the component dirty before changing its native array:

```nupp
const chunk = assert(world:getMut(entity, tecs.gfx.TileChunk))
unsafe do
    chunk.tiles[128] = 5
end
```

The old explicit dirty tag is also supported when editing a shared view:

```nupp
const chunk = assert(world:get(entity, tecs.gfx.TileChunk))
unsafe do
    chunk.tiles[128] = 5
end
world:set(entity, tecs.gfx.DirtyTileChunk)
```

The renderer consumes `DirtyTileChunk`. Ordinary ECS structural changes become
visible at a commit barrier. For a loaded map, use `tecs.tiled.setTile` instead
so that the map data, all live instances, and collision boundaries stay in sync.

## Automatic chunks and edits

Tiled groups static atlas tiles by **layer, 16×16 region, and tileset**. A region
containing multiple tilesets has one chunk entity per tileset. Negative tile
coordinates use the same grid division. Empty regions have no chunk entity.

An edit updates the affected chunk and rebuilds its collision boundaries when
collision is enabled. Changing a static tile to an animated one removes that
cell from the chunk and creates a sprite; changing it back returns it to a
chunk. A newly used tileset gets a chunk on demand, and clearing a chunk's last
cell removes its entity. Animated sprites retain `TileSource` metadata; static
tile metadata remains accessible through the loaded map.

## Rendering and chunk size

`tecs.gfx.TILE_CHUNK_SIZE` is 16, matching the original engine's grid convention.
Chunk tiles are expanded into retained GPU instances when their data changes.
They use the existing GPU culling, compaction and indirect draw pipeline;
compatible chunks can share a draw. There is no ECS sprite entity per static
tile and no instance upload on unchanged frames.

A same-size edit patches the changed chunk's instance range. Adding or removing
occupied cells can change the packed layout and require a full instance upload.
The GPU representation uses the shared 80-byte instance format per occupied
tile; it does not yet use the old renderer's compact tile-ID GPU buffer.

Standalone chunks preserve their tile arrays and atlas names in snapshots.
Tiled-owned chunks are regenerated from saved map data when a world is restored.
