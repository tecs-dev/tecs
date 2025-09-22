# Utility Functions

`TilemapData` provides methods for coordinate conversion and tile access.

## Coordinate Conversion

### worldToTile

Converts world coordinates to tile coordinates.

```lua
local tileX, tileY = tilemapData:worldToTile(worldX, worldY)
```

| Parameter   | Type     | Description        |
| ----------- | -------- | ------------------ |
| `worldX`    | `number` | World X coordinate |
| `worldY`    | `number` | World Y coordinate |

**Returns:** `integer, integer` - Tile coordinates (1-based)

### tileToWorld

Converts tile coordinates to world coordinates (top-left corner of tile).

```lua
local worldX, worldY = tilemapData:tileToWorld(tileX, tileY)
```

| Parameter   | Type      | Description                 |
| ----------- | --------- | --------------------------- |
| `tileX`     | `integer` | Tile X coordinate (1-based) |
| `tileY`     | `integer` | Tile Y coordinate (1-based) |

**Returns:** `number, number` - World coordinates

## Tile Access

### getTileAt

Gets the tile GID at a world position.

```lua
local gid = tilemapData:getTileAt(layerIndex, worldX, worldY)
```

| Parameter    | Type      | Description           |
| ------------ | --------- | --------------------- |
| `layerIndex` | `integer` | Layer index (1-based) |
| `worldX`     | `number`  | World X coordinate    |
| `worldY`     | `number`  | World Y coordinate    |

**Returns:** `integer` - Tile GID (0 if empty or out of bounds)

### getTile

Gets the tile GID at tile coordinates.

```lua
local gid = tilemapData:getTile(layerIndex, tileX, tileY)
```

| Parameter    | Type      | Description                 |
| ------------ | --------- | --------------------------- |
| `layerIndex` | `integer` | Layer index (1-based)       |
| `tileX`      | `integer` | Tile X coordinate (1-based) |
| `tileY`      | `integer` | Tile Y coordinate (1-based) |

**Returns:** `integer` - Tile GID (0 if empty or out of bounds)

### setTileAt

Sets a tile at world coordinates. Automatically marks the containing chunk as dirty.

```lua
tilemapData:setTileAt(layerIndex, worldX, worldY, gid)
```

| Parameter    | Type      | Description               |
| ------------ | --------- | ------------------------- |
| `layerIndex` | `integer` | Layer index (1-based)     |
| `worldX`     | `number`  | World X coordinate        |
| `worldY`     | `number`  | World Y coordinate        |
| `gid`        | `integer` | New tile GID (0 to clear) |

### setTile

Sets a tile at tile coordinates. Automatically marks the containing chunk as dirty.

```lua
tilemapData:setTile(layerIndex, tileX, tileY, gid)
```

| Parameter    | Type      | Description                 |
| ------------ | --------- | --------------------------- |
| `layerIndex` | `integer` | Layer index (1-based)       |
| `tileX`      | `integer` | Tile X coordinate (1-based) |
| `tileY`      | `integer` | Tile Y coordinate (1-based) |
| `gid`        | `integer` | New tile GID (0 to clear)   |

::: tip Automatic Chunk Rebuilding
When you modify a tile, only the containing chunk is marked dirty. The chunk rebuilds on the next render frame.
:::

## Property Access

### getLayer

Gets a layer by name.

```lua
local layer = tilemapData:getLayer("Ground")
```

| Parameter   | Type     | Description                    |
| ----------- | -------- | ------------------------------ |
| `name`      | `string` | Layer name as defined in Tiled |

**Returns:** `LayerData` - The layer, or `nil` if not found

### getLayerProperties

Gets custom properties for a layer.

```lua
local props = tilemapData:getLayerProperties(layerIndex)
if props.scrollSpeed then
    -- Use custom property
end
```

| Parameter    | Type      | Description           |
| ------------ | --------- | --------------------- |
| `layerIndex` | `integer` | Layer index (1-based) |

**Returns:** `{string: any}` - Custom properties table, or `nil` if layer not found

### getTileProperties

Gets tile data including custom properties for a specific tile.

```lua
local tileData = tilemapData:getTileProperties(layerIndex, tileX, tileY)
if tileData and tileData.properties then
    local damage = tileData.properties.damage
end
```

| Parameter    | Type      | Description                 |
| ------------ | --------- | --------------------------- |
| `layerIndex` | `integer` | Layer index (1-based)       |
| `tileX`      | `integer` | Tile X coordinate (1-based) |
| `tileY`      | `integer` | Tile Y coordinate (1-based) |

**Returns:** `TileData` - Tile data with `id`, `class`, `properties`, `animation`, `objectgroup` fields, or `nil`

## Working with Layers

### Layer Types

```lua
for i, layer in ipairs(tilemap.data.layers) do
    if layer.type == "tilelayer" then
        -- Has layer.data (tile GIDs)
    elseif layer.type == "objectgroup" then
        -- Has layer.objects
    elseif layer.type == "imagelayer" then
        -- Has layer.imagePath
    end
end
```

## Examples

### Collision Check

```lua
local SOLID_TILES = { [1] = true, [2] = true, [3] = true }

local function isSolid(data, worldX, worldY)
    local gid = data:getTileAt(1, worldX, worldY)
    return SOLID_TILES[gid] or false
end
```

### Remove Tile on Click

```lua
local screenX, screenY = love.mouse.getPosition()
local worldX, worldY = camera:toWorld(screenX, screenY)
tilemapData:setTileAt(1, worldX, worldY, 0)
```

## Serialization

### toJSON

Exports the tilemap to Tiled-compatible JSON.

```lua
local json = tilemapData:toJSON(pretty)
```

| Parameter   | Type      | Description                                   |
| ----------- | --------- | --------------------------------------------- |
| `pretty`    | `boolean` | If true, output is formatted with indentation |

**Returns:** `string` - JSON string compatible with Tiled editor

```lua
-- Save modified map
local json = tilemapData:toJSON(true)
love.filesystem.write("saved_map.tmj", json)
```
