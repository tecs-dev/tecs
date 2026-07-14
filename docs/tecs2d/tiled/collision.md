---
description: "Auto-generating merged Box2D chain-shape collision from Tiled tile shapes via the Tilemap collision config"
---

# Tile Collision

Tecs Tiled supports automatic physics collision generation from per-tile collision shapes defined in Tiled tilesets.
The system uses polygon tracing to merge adjacent tiles into optimized
[Box2D chain shapes](https://box2d.org/documentation/md_collision.html) for high-performance static collision.

## Defining Collision Shapes in Tiled

In the Tiled editor, you can define collision shapes on individual tiles in your tileset:

1. Open your tileset in Tiled
2. Select a tile
3. Open the Tile Collision Editor (View > Views and Toolbars > Tile Collision Editor)
4. Draw collision shapes (rectangles, polygons) on the tile

These shapes are stored in the tile's `objectgroup` property and automatically parsed when the tilemap loads.

## Enabling Collision

Collision is opt-in via the Tilemap component's `collision` config:

```teal
local tiled = require("tecs2d.tiled")
local physics = require("tecs2d.physics")

-- First, initialize physics
world:addPlugin(physics.new({
    world = love.physics.newWorld(0, 300, true)
}))

-- Then load tilemap with collision enabled
world:spawn(
    tiled.Tilemap.new({
        path = "maps/level1.tmj",
        collision = {
            enabled = true,       -- Create physics bodies for tiles with collision data
            mergeShapes = true,   -- Merge adjacent shapes into chain shapes (default: true)
        }
    }),
    tecs.builtins.Transform(0, 0)
)
```

::: warning Physics Plugin Required
The physics plugin must be initialized before loading tilemaps with collision enabled. If physics is not available,
an error will be thrown.
:::

## Configuration Options

| Option          | Type                              | Default   | Description                                        |
| --------------- | --------------------------------- | --------- | -------------------------------------------------- |
| `enabled`       | `boolean`                         | `false`   | Enable collision body creation                     |
| `mergeShapes`   | `boolean`                         | `true`    | Merge adjacent shapes into chain shapes            |
| `filter`        | `function(tile, gid, x, y)`       | `nil`     | Optional filter to include/exclude specific tiles  |

### Filter Function

The filter function receives:
- `tile`: The `TileData` object with properties and collision shapes
- `gid`: The global tile ID
- `x`, `y`: Tile coordinates (1-indexed)

Return `true` to include the tile's collision, `false` to exclude:

```teal
collision = {
    enabled = true,
    filter = function(tile, gid, tileX, tileY)
        -- Only include tiles with "solid" property
        return tile.properties and tile.properties.solid == true
    end
}
```

## Performance

The collision system uses polygon tracing to minimize the number of physics bodies:

| Approach                             | Bodies Created   | Performance        |
| ------------------------------------ | ---------------- | ------------------ |
| Per-tile rectangles (naive)          | One per tile     | Poor               |
| **Chain shapes (tiled)**             | ~1-10 total      | Excellent          |
| Hybrid (chain + isolated)            | Few              | Excellent          |

Chain shapes also eliminate "ghost collisions" at tile boundaries, which is a common problem when using multiple
adjacent box colliders.

### How It Works

1. **Edge Extraction**: For each tile with collision data, extract the edges of its collision shapes
2. **Internal Edge Removal**: Remove edges shared between adjacent tiles (internal boundaries)
3. **Polygon Tracing**: Trace remaining edges to form closed polygons
4. **Chain Shape Creation**: Convert each polygon to a Box2D chain shape

## Accessing Collision Bodies

The created physics bodies are stored on the Tilemap component:

```teal
local tilemap = world:get(entityId, tiled.Tilemap)
if tilemap.collisionBodies then
    for _, body in ipairs(tilemap.collisionBodies) do
        -- Access Box2D body
        local shapes = body:getShapes()
    end
end
```

You can also access the physics state via the world resource:

```teal
local physics = require("tecs2d.physics")
local state = world.resources[physics]
local physicsWorld = state.world  -- The Box2D world
```

## Cleanup

Collision bodies are automatically destroyed when the tilemap entity is despawned. You can also manually destroy
them:

```teal
local tiled = require("tecs2d.tiled")

if tilemap.collisionBodies then
    tiled.collision.destroyColliders(tilemap.collisionBodies)
    tilemap.collisionBodies = nil
end
```

## Custom Properties

Tile properties defined in Tiled remain accessible for game-specific logic:

```teal
local tile = tilemap.data:getTileProperties(layerIndex, tileX, tileY)
if tile and tile.properties then
    local height = tile.properties.h        -- Custom height property
    local response = tile.properties.response  -- Custom collision response
end
```

The collision system doesn't interpret these properties; they're available for your game logic.

## Supported Shapes

| Shape         | Support                                          |
| ------------- | ------------------------------------------------ |
| Rectangle     | Full support, merged into chain shapes           |
| Polygon       | Full support, merged into chain shapes           |
| Ellipse       | Approximated as circle, not merged               |
| Polyline      | Not supported (open shapes can't form colliders) |

## Debug Rendering

To visualize collision shapes, use the `gfx.physicsDebug` plugin. This renders collision shapes through the
render pipeline so they respect camera zoom and position:

```teal
local gfx = require("tecs2d.gfx")
local physics = require("tecs2d.physics")

-- Initialize physics with debug enabled
world:addPlugin(physics.new({
    world = love.physics.newWorld(0, 300, true),
    debug = true,  -- Enable debug state
}))

-- Add physics debug rendering
world:addPlugin(gfx.physicsDebug.new())
```

Toggle debug rendering at runtime:

```teal
local state = world.resources[physics]
state.debug = not state.debug  -- Toggle on/off
```

## Example

```teal
local tecs = require("tecs")
local gfx = require("tecs2d.gfx")
local physics = require("tecs2d.physics")
local tiled = require("tecs2d.tiled")

local function gamePlugin(world)
    -- Initialize physics first
    world:addPlugin(physics.new({
        world = love.physics.newWorld(0, 300, true),
        debug = false,
    }))

    -- Optional: Add physics debug rendering
    world:addPlugin(gfx.physicsDebug.new())

    -- Load tilemap with collision enabled
    world:spawn(
        tiled.Tilemap.new({
            path = "maps/level.tmj",
            collision = {
                enabled = true,
                mergeShapes = true,
            }
        }),
        tecs.builtins.Transform(0, 0)
    )
end
```
