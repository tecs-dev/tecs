# Tecs Tiled

Tecs Tiled integrates the [Tiled](https://www.mapeditor.org/) map editor with Tecs ECS. It parses Tiled's JSON export
format (.tmj), renders tilemaps using the `tecs2d.gfx` pipeline, and spawns entities from Tiled objects.

- **Tiled JSON support**: Parses .tmj map files and .tsj tileset files
- **High-performance rendering**: GPU-instanced [TileChunks](./tile-chunks) for minimal draw calls
- **[Tile animations](#animated-tiles)**: Animated tiles spawn as Sprite entities with globally-synced animation
- **Object layers**: Access object data from Tiled object layers
- **Parallax layers**: Built-in parallax scrolling support
- **Image layers**: Background/foreground image layer rendering
- **[Automatic material maps](#material-maps)**: Normal, emission, and specular maps detected from tileset naming
  convention
- **[Tile modification](#tile-access)**: Runtime tile changes with automatic chunk rebuilding

## Quick Start

```teal
local tecs = require("tecs")
local tecs2d = require("tecs2d")
local tiled = require("tecs2d.tiled")

-- The render pipeline and tiled plugin are auto-installed by tecs2d.run
love.run = tecs2d.run({
    fps = 60,
    game = function(world)
        -- Spawn a tilemap entity
        world:spawn(
            tiled.Tilemap.new({ path = "maps/level1.tmj" }),
            tecs.builtins.Transform.new({ x = 0, y = 0 })
        )
    end,
    render = {
        virtualHeight = 200,
    },
})
```

## Core Concepts

### Tilemap Component

The [Tilemap Component](./tilemap) component loads and renders a Tiled map. It requires a `Transform` component for
positioning and render layer.

```teal
world:spawn(
    tiled.Tilemap.new({ path = "maps/level1.tmj" }),
    tecs.builtins.Transform.new({ x = 0, y = 0, layer = 1 })
)
```

::: tip Async Loading
For non-blocking map loading, use the asset manager's [`loadTiledMap`](/tecs2d/assets/api#loadtiledmap) method:

```teal
local assets = require("tecs2d.assets")
local manager = world.resources[assets]

manager:loadTiledMap("maps/level1.tmj")
    :observe(function(h: assets.Handle<tiled.TilemapData>)
        world:spawn(
            tiled.Tilemap.new({ data = h.value }),
            tecs.builtins.Transform.new({ x = 0, y = 0 })
        )
    end)
```

This approach is useful for loading screens or streaming levels without frame drops.
:::

### Layers

Tiled layers are logically grouped in Tecs in order to economically make use of the 16 total available layers.
The tilemap's base render layer is set by `Transform.layer`. How Tiled layers map to render layers depends on
grouping:

- **Ungrouped top-level layers** each get their own render layer, incrementing from the base value
- **Layers inside a Tiled group** share the same render layer and are sorted by z-offset within it

For example, with `Transform.layer = 1`:

| Tiled structure             | Render layer   | Z offset   |
| --------------------------- | :------------: | :--------: |
| Background (ungrouped)      | 1              | 0          |
| Group "world"               |                |            |
| &emsp; • Terrain            | 2              | 0          |
| &emsp; • Objects            | 2              | 100        |
| &emsp; • Decorations        | 2              | 200        |
| Foreground (ungrouped)      | 3              | 0          |

Layer parallax from Tiled (`parallaxx`/`parallaxy`) is automatically applied to the corresponding render layer.

### Debug Plugin

For quick object visualization, use the [debug plugin](./debug-plugin):

```teal
-- Register the debug plugin
world:addPlugin(tiled.debugPlugin)

-- Toggle debug shapes on/off via event
world:emit(0, tiled.DebugToggle)
```

### Tile Access

Access and modify tiles at runtime using `TilemapData`:

```teal
-- Get tile at world position
local gid = tilemapData:getTileAt(layerIndex, worldX, worldY)

-- Set a tile (chunk auto-rebuilds)
tilemapData:setTileAt(layerIndex, worldX, worldY, newGid)

-- Convert coordinates
local tileX, tileY = tilemapData:worldToTile(worldX, worldY)
local worldX, worldY = tilemapData:tileToWorld(tileX, tileY)
```

See [Utility Functions](./utility-functions) for detailed documentation.

### Animated Tiles

Tiles with animation defined in Tiled are automatically spawned as individual Sprite entities instead of being
included in TileChunks. Each animated tile sprite includes a [TileSource](./tile-source) component that provides
access to the tile's properties.

```teal
local tiled = require("tecs2d.tiled")
local TileSource = tiled.TileSource

-- Query for animated tile sprites
local query = world:query({ include = {TileSource, Transform} })
for arch, len, ids in query:iter() do
    local tileSources = arch:get(TileSource)
    local transforms = arch:get(Transform)
    for i = 1, len do
        local source = tileSources[i]
        -- Access custom tile properties from Tiled
        if source.properties and source.properties.light then
            -- Spawn a light at this tile's position
            local t = transforms[i]
            world:spawn(
                Transform(t.x + 16, t.y + 16),
                gfx.Light.new({ radius = 100, intensity = 1.5, height = 0.2 })
            )
        end
    end
end
```

See [TileSource Component](./tile-source) for full documentation on properties and usage patterns.

## Material Maps

Tecs automatically detects and loads normal, emission, and specular maps for tilesets using a file naming convention.
Place material map images alongside your tileset with these suffixes:

| Suffix   | Map Type     | Effect                           |
| -------- | ------------ | -------------------------------- |
| `_n`     | Normal map   | Surface lighting and depth       |
| `_e`     | Emission map | Self-illumination / glow         |
| `_s`     | Specular map | Specular intensity and shininess |

For example, if your tileset image is `dungeon.png`, Tecs looks for:

- `dungeon_n.png` - normal map
- `dungeon_e.png` - emission map
- `dungeon_s.png` - specular map

If a material map file exists, it is loaded automatically and passed to the GPU renderer. Missing maps use sensible
defaults (flat normals, no emission, no specular).

::: tip
Material maps must have the same dimensions and tile layout as the base tileset image. Each pixel in the material map
corresponds to the same pixel in the tileset.
:::

## Tile Shadows

Tiles can cast shadows in the lighting system by setting the `occluderHeight` custom property in Tiled.
`occluderHeight` is a normalized float value from 0.0 to 1.0 representing the tile's height for shadow calculations.

See [Occluder Height](/tecs2d/rendering/lighting#occluder-height) in the Lighting documentation for details on how height
affects shadow projection.

### Occluder Shape

The shadow shape follows the tile's visible pixels, not the full tile rectangle. The shader performs an alpha test
against the tile texture: only pixels above the alpha threshold (default 0.5) cast shadows. This means:

- Transparent areas of a tile don't cast shadows
- Irregular tile shapes (trees, rocks, characters) cast accurate silhouette shadows
- Fully opaque rectangular tiles cast rectangular shadows

::: info
Normal maps do not affect shadow shape. Shadows are determined purely by the tile's alpha channel. Normal maps only
affect surface lighting calculations.
:::

### Performance

Tile shadows use the same GPU-accelerated pipeline as sprite shadows:
- Only chunks containing occluding tiles are processed
- Frustum culling skips off-screen chunks entirely
- Per-tile height lookup uses a texture atlas for efficient GPU access

*See [Lighting](/tecs2d/rendering/lighting) for full shadow system documentation.*

## Supported Tiled Features

| Feature                    | Status   | Notes                                |
| :------------------------- | :------: | :----------------------------------- |
| Orthogonal maps            | ✅        |                                      |
| Tile layers                | ✅        |                                      |
| Object layers              | ✅        | Accessible on loaded TilemapData     |
| Image layers               | ✅        |                                      |
| Group layers               | ✅        | Flattened on load                    |
| Layer parallax             | ✅        |                                      |
| Layer offsets              | ✅        |                                      |
| Tile flip flags            | ✅        | Horizontal and vertical              |
| Tile rotation              | ❌        | Diagonal flip not supported          |
| Tile animations            | ✅        | Globally synced                      |
| Tile shadows               | ✅        | Via `occluderHeight` property        |
| Tile material maps         | ✅        | Auto-detected `_n` and `_e` files    |
| External tilesets (.tsj)   | ✅        |                                      |
| Custom properties          | ✅        |                                      |
| Isometric/hexagonal maps   | ❌        |                                      |
| Infinite maps              | ❌        |                                      |

## Performance

Tecs uses GPU-instanced [TileChunks](./tile-chunks) for high-performance rendering:

- Maps are divided into 16×16 tile chunks (see [TileChunks](./tile-chunks#chunk-size))
- Each chunk is rendered with a single GPU draw call
- Only visible chunks are rendered (frustum culling)
- Animated tiles spawn as individual Sprite entities
- Tile changes only mark affected chunks dirty for GPU re-sync
