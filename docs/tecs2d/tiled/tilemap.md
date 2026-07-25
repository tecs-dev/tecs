---
description: "The Tilemap component loading and rendering a Tiled map, its properties, TilemapData structure, and parallax"
---

# Tilemap Component

The `Tilemap` component loads and renders a Tiled map.

## Basic Usage

```teal
world:spawn(
    tiled.Tilemap.new({ path = "maps/level1.tmj" }),
    tecs.builtins.Transform.new({ x = 0, y = 0 })
)
```

## Component Properties

| Property   | Type          | Default   | Description                                  |
| ---------- | ------------- | --------- | -------------------------------------------- |
| `path`     | `string`      | -         | Asset path to the .tmj file (sync loading)   |
| `data`     | `TilemapData` | `nil`     | Pre-loaded tilemap data (from async loading) |

Either `path` or `data` should be provided:

- **`path`**: The component loads the map synchronously during its first `First` phase update. Simple but may cause
  frame drops.
- **`data`**: Use pre-loaded data from [`loadTiledMap`](/tecs2d/assets/api#loadtiledmap). No loading delay.

## Required Components

- **Transform** - Position in world space. The `layer` field controls which render layer the tilemap renders to.

### Render Layer Mapping

Each Tiled layer renders at an incrementing layer number starting from `Transform.layer`.

## TilemapData Structure

After loading, `tilemap.data` contains:

```teal
interface TilemapData
    width: integer           -- Map width in tiles
    height: integer          -- Map height in tiles
    tilewidth: integer       -- Tile width in pixels
    tileheight: integer      -- Tile height in pixels
    layers: {LayerData}      -- Array of layers
    tilesets: {TilesetData}  -- Loaded tilesets
    properties: {string: any} -- Custom properties from Tiled

    -- Methods (see Utility Functions)
    worldToTile(worldX, worldY): integer, integer
    tileToWorld(tileX, tileY): number, number
    getTile(layerIndex, tileX, tileY): integer
    getTileAt(layerIndex, worldX, worldY): integer
    setTile(layerIndex, tileX, tileY, gid)
    setTileAt(layerIndex, worldX, worldY, gid)
    getLayer(name): LayerData
    getLayerProperties(layerIndex): {string: any}
    getTileProperties(layerIndex, tileX, tileY): TileData
    toJSON(pretty): string
end
```

::: tip Chunk Size
Static tiles are rendered using 16×16 [TileChunks](./tile-chunks). This is handled automatically by the tiled plugin.
:::

## Parallax Support

Tiled's parallax settings are automatically applied:

- `parallax = 1.0`: Normal movement (moves with camera)
- `parallax = 0.5`: Half-speed (appears further away)
- `parallax = 0.0`: Static (doesn't move with camera)
