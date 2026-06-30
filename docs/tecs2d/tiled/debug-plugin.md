# Debug Plugin

The debug plugin visualizes Tiled objects by spawning colored shapes (rectangles, ellipses, circles) for each object
in the tilemap's object layers. Useful for debugging collision shapes, spawn points, and object placement.

Debug shapes are toggled on and off at runtime via the `DebugToggle` event.

## Usage

```teal
local tiled = require("tecs2d.tiled")

-- Register the debug plugin (no shapes are spawned yet)
world:addPlugin(tiled.debugPlugin)

-- Toggle debug shapes on
world:emit(0, tiled.DebugToggle)

-- Toggle debug shapes off
world:emit(0, tiled.DebugToggle)
```

The plugin can be registered before or after tilemaps are loaded. When toggled on, it spawns shapes for all currently
loaded tilemaps.

### Custom Configuration

```teal
world:addPlugin(tiled.createDebugPlugin({
    renderLayer = 15,
    color = {1, 0, 0, 1},
    filled = true,
    lineWidth = 2,
}))
```

## How It Works

The debug plugin observes `DebugToggle` events emitted to address 0 (world-level). Each toggle:

1. **On**: Iterates all loaded tilemaps, finds object layers, and spawns shape entities tagged with `TiledDebugShape`
2. **Off**: Queries all `TiledDebugShape` entities and despawns them

This makes it easy to bind to a key press:

```teal
local input = require("tecs2d.input")
local tiled = require("tecs2d.tiled")

world:observe(0, input.KeyPressed, function(e)
    if e.key == "f3" then
        world:emit(0, tiled.DebugToggle)
    end
end)
```

### Supported Shapes

| Tiled Shape   | Rendered As                                     |
| ------------- | ----------------------------------------------- |
| Rectangle     | `Rectangle` entity centered on object bounds    |
| Ellipse       | `Ellipse` entity centered on object bounds      |
| Point         | `Circle` entity (radius 6) at point position    |
| Polygon       | Not yet supported                               |
| Polyline      | Not yet supported                               |

Object world positions are computed from the tilemap transform, layer offset, and object position.

## DebugConfig

All fields are optional. Pass a `DebugConfig` table to `createDebugPlugin` to customize the visualization.

| Field           | Type                                  | Default                | Description                                              |
| --------------- | ------------------------------------- | ---------------------- | -------------------------------------------------------- |
| `renderLayer`   | `integer`                             | `15`                   | Render layer for debug shapes (high to draw on top)      |
| `color`         | `{number, number, number, number}`    | `{0, 1, 0.5, 0.6}`     | RGBA color for debug shapes                              |
| `filled`        | `boolean`                             | `false`                | Draw filled shapes instead of outlines                   |
| `lineWidth`     | `number`                              | `2.0`                  | Outline width in pixels (ignored when `filled = true`)   |
| `layerFilter`   | `{string}`                            | `nil` (show all)       | Only show objects from layers with these names           |
| `classFilter`   | `{string}`                            | `nil` (show all)       | Only show objects with these Tiled class names           |

## API

### `tiled.debugPlugin`

```teal
world:addPlugin(tiled.debugPlugin)
```

Plugin function with default configuration. Equivalent to `tiled.createDebugPlugin()`.

### `tiled.createDebugPlugin`

```teal
local plugin = tiled.createDebugPlugin(config?: DebugConfig)
world:addPlugin(plugin)
```

Creates a debug plugin with custom configuration. Returns a plugin function.

### `tiled.DebugToggle`

```teal
world:emit(0, tiled.DebugToggle)
```

Event that toggles debug shape visibility. First emit spawns shapes, next emit despawns them.

### `tiled.TiledDebugShape`

Tag component present on all spawned debug shape entities. Can be used in queries to find or filter debug shapes.
