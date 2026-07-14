---
description: "The TileSource component exposing a tile's gid, class, and Tiled properties on animated tile entities"
---

# TileSource Component

The `TileSource` component provides access to a tile's metadata from Tiled. It is automatically added to animated tile
sprites and can be manually added to any entity derived from Tiled data.

## Overview

When a tilemap loads, tiles with animation defined in Tiled are spawned as individual Sprite entities rather than being
included in TileChunks. Each of these sprites receives a `TileSource` component that links back to the original tile
data.

You can also manually add `TileSource` to entities spawned from Tiled objects or any other entity that needs to track
its Tiled origin.

## Component Properties

| Property      | Type      | Description                              |
| ------------- | --------- | ---------------------------------------- |
| `gid`         | `integer` | Global tile ID (flip flags stripped)     |
| `localId`     | `integer` | Local tile ID within the tileset         |
| `tilesetName` | `string`  | Name of the tileset containing this tile |
| `properties`  | `table`   | Custom properties defined in Tiled       |
| `class`       | `string`  | Tile class (Tiled's "type" field)        |

## Basic Usage

```teal
local tiled = require("tecs2d.tiled")
local TileSource = tiled.TileSource
local Transform = tecs.builtins.Transform

-- Query for all animated tile sprites
local query = world:query({ include = { TileSource, Transform } })
for arch, len, ids in query:iter() do
    local tileSources = arch:get(TileSource)
    local transforms = arch:get(Transform)
    for i = 1, len do
        local source = tileSources[i]
        local t = transforms[i]
        print(source.tilesetName, source.localId, t.x, t.y)
    end
end
```

## Accessing Custom Properties

Custom properties defined on tiles in Tiled are available via `source.properties`. Use `onEntitiesAdded` to
react when animated tile entities are spawned:

```teal
local tiled = require("tecs2d.tiled")
local gfx = require("tecs2d.gfx")
local TileSource = tiled.TileSource
local Transform = tecs.builtins.Transform

-- In Tiled: set custom property "light" = true on torch tiles
-- onEntitiesAdded fires once per contiguous range of matching entities.
-- For single spawns count=1; for batch spawns count=N.
world:query({
    include = { TileSource, Transform },
    onEntitiesAdded = function(arch, firstRow, lastRow)
        local sources = arch:get(TileSource)
        local transforms = arch:get(Transform)
        for row = firstRow, lastRow do
            local source = sources[row]
            if source.properties and source.properties.light then
                -- Spawn a light at this animated torch tile
                local t = transforms[row]
                world:spawn(
                    Transform(t.x + 16, t.y + 16),
                    gfx.Light.new({ radius = 100, intensity = 1.5, height = 0.2 })
                )
            end
        end
    end,
})
```

## Filtering by Tile Class

Use the `class` property to filter specific tile types:

```teal
-- Find all animated tiles with class "hazard" and add damage zones
world:query({
    include = { TileSource },
    onEntitiesAdded = function(arch, firstRow, lastRow)
        local sources = arch:get(TileSource)
        local entities = arch.entities
        for row = firstRow, lastRow do
            if sources[row].class == "hazard" then
                world:set(entities[row], DamageZone({ damage = 10 }))
            end
        end
    end,
})
```

### Function Signature

```teal
tiled.tileSourceFromGid(map: TilemapData, gid: integer): TileSource | nil
```

- **map** - The loaded tilemap data (from `Tilemap.data` or callback)
- **gid** - Global tile ID (from `ObjectData.gid` or tile layer data)
- **Returns** - TileSource component, or `nil` if GID is invalid (0 or not found)

The function automatically:
- Strips flip flags from the GID
- Looks up the tileset containing the tile
- Extracts tile properties and class from the tileset