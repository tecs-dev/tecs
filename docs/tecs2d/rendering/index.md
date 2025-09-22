# Rendering

Tecs provides a high-performance GPU-accelerated rendering pipeline designed for 2D games with advanced lighting and
shadow effects. The rendering system is built on a deferred G-Buffer architecture that decouples geometry rendering from
lighting calculations.

## Quick Start

```lua
local tecs = require("tecs")
local tecs2d = require("tecs2d")
local gfx = require("tecs2d.gfx")

love.run = tecs2d.run({
    fps = 60,
    game = function(world)
        -- Spawn a simple shape
        world:spawn(
            tecs.builtins.Transform(100, 100),
            gfx.Circle(20),
            gfx.Color(1, 0.5, 0, 1)
        )

        -- Spawn a sprite from Aseprite
        world:spawn(
            tecs.builtins.Transform(200, 100),
            gfx.Sprite.fromAseprite("assets/player.png", "idle")
        )
    end,
    render = {
        virtualWidth = 320,
        virtualHeight = 180,
        pixelMode = true,
    }
})
```

## Architecture Overview

The rendering pipeline consists of several passes:

1. **G-Buffer Pass**: Renders all geometry (sprites, shapes, text) to multiple render targets storing albedo, normals,
specular, and emission information.

2. **Shadow Mask Pass**: Renders occluder silhouettes to a shadow mask texture using compute shader culling.

3. **Lighting Pass**: Applies dynamic lighting using raymarched shadows and normal-based shading.

4. **Composite Pass**: Combines all passes into the final output.

## Key Features

- **GPU Instancing**: Batches thousands of entities into single draw calls
- **Compute Shader Culling**: Visibility testing runs entirely on the GPU
- **Deferred Lighting**: Decouples scene complexity from lighting cost
- **2.5D Lighting**: Height-based shading for pseudo-3D effects
- **Dynamic Shadows**: Raymarched soft shadows with height-based occlusion
- **Pixel-Perfect Rendering**: Opt-in retro mode for integer-scaled pixel art
- **Multiple Cameras**: Minimaps, split-screen, and render-to-texture via independent cameras

## Components Overview

### Drawable Components

| Component                       | Description                                  |
| ------------------------------- | -------------------------------------------- |
| [Sprite](./sprites/)            | Animated sprites from Aseprite sprite sheets |
| [Circle](./shapes#circle)       | Filled or outlined circles                   |
| [Ellipse](./shapes#ellipse)     | Filled or outlined ellipses                  |
| [Arc](./shapes#arc)             | Partial circles/ellipses (pie slices)        |
| [Rectangle](./shapes#rectangle) | Filled or outlined rectangles                |
| [Line](./shapes#line)           | Line segments                                |
| [Mesh](./shapes#mesh)           | Custom geometry                              |
| [Text](./text)            | Text using BMFont atlases (bitmap or MSDF)   |

### Styling Components

| Component                            | Description                              |
| ------------------------------------ | ---------------------------------------- |
| [Color](./styling#color)             | RGBA tinting                             |
| [Blend Modes](./styling#blend-modes) | Blend mode control (add, multiply, etc.) |
| [Unlit](./styling#unlit)             | Skip dynamic lighting                    |
| [Pivot](./styling#pivot)             | Custom pivot points (0-1 range)          |

### Lighting Components

| Component                                    | Description                 |
| -------------------------------------------- | --------------------------- |
| [Light](./lighting#light-component)          | Point lights and spotlights |
| [Occluder](./lighting#shadows-and-occluders) | Shadow-casting entities     |

### Special Components

| Component                                       | Description                           |
| ----------------------------------------------- | ------------------------------------- |
| [CameraTarget](./camera#cameratarget-component) | Makes camera follow an entity         |
| [Material](./materials)                         | GPU-batched fragment shader injection |

### Layer Features

| Feature                                 | Description                            |
| --------------------------------------- | -------------------------------------- |
| [Parallax](./layers#parallax-scrolling) | Layer-based parallax scrolling effects |

## Documentation

| Topic                                    | Description                                                                      |
| ---------------------------------------- | -------------------------------------------------------------------------------- |
| [Camera](./camera)                       | Camera controls, multiple cameras, minimaps, split-screen, coordinate conversion |
| [Sprites](./sprites/)                    | Sprite sheets, animation, slices, collisions                                     |
| [Shapes](./shapes)                       | Circles, rectangles, lines, and other primitives                                 |
| [Text](./text)                           | Bitmap and MSDF text rendering                                                   |
| [Styling](./styling)                     | Color, blend modes, render flags                                                 |
| [Layers](./layers)                       | Layer configuration and coordinate spaces                                        |
| [Lighting](./lighting)                   | Point lights, spotlights, shadows, and occluders                                 |
| [Custom Drawing](./custom-drawing)       | CPU drawing with depth sorting                                                   |
| [Materials](./materials)                 | GPU-batched fragment shader injection                                            |

## Performance Characteristics

The rendering system is designed to be **GPU-bound** rather than CPU-bound:

- **Zero-copy FFI buffers**: Entity data is written directly to GPU-mapped memory
- **Archetype batching**: Entities with the same components render together
- **Dirty range tracking**: Only modified buffer regions are uploaded
- **Indirect drawing**: Draw calls are issued from GPU-populated buffers

This architecture allows rendering of 100K+ entities at 60fps on modern hardware, with performance scaling based on GPU
fill rate rather than Lua interpreter speed.

## RenderConfig

The render pipeline is configured via the `render` table in [`tecs2d.run`](/tecs2d/love2d#run). All fields are optional
with sensible defaults.

```lua
love.run = tecs2d.run({
    fps = 60,
    game = gamePlugin,
    render = {
        virtualHeight = 180,
        pixelMode = true,
        lightingMode = "deferred",
        layers = {
            [10] = { name = "hud", space = "virtual", unlit = true },
        },
    },
})
```

### Fields

| Field                | Type                         | Default         | Description                                                                                                 |
| -------------------- | ---------------------------- | --------------- | ----------------------------------------------------------------------------------------------------------- |
| `virtualHeight`      | `integer`                    | window height   | Virtual resolution height. Controls camera FOV and, in retro mode, the integer scale factor                 |
| `virtualWidth`       | `integer`                    | auto            | Fixed virtual width. Auto-computed from aspect ratio (non-retro) or to fill screen at integer scale (retro) |
| `pixelMode`          | `boolean`                    | `false`         | `true` = retro (low-res + nearest-neighbor upscale). See [Camera](/tecs2d/rendering/camera#pixel-modes)            |
| `lightingMode`       | `string`                     | `"deferred"`    | `"deferred"` or `"none"` (full brightness). See [Lighting](/tecs2d/rendering/lighting)                             |
| `shadowsEnabled`     | `boolean`                    | `true`          | Whether occluders cast shadows                                                                              |
| `ambientLight`       | `{r, g, b}`                  | `{1, 1, 1}`     | Base illumination for unlit areas. See [Lighting](/tecs2d/rendering/lighting#ambient-light)                        |
| `zoom`               | `number`                     | `1.0`           | Initial camera zoom level. See [Camera](/tecs2d/rendering/camera#zoom)                                             |
| `cameraPosition`     | `{x, y}`                     | `{0, 0}`        | Initial camera position                                                                                     |
| `lerpingEnabled`     | `boolean`                    | `true`          | Enable smooth camera movement. See [Camera](/tecs2d/rendering/camera#smooth-movement)                              |
| `lerpSpeed`          | `number`                     | `8.0`           | Lerp speed factor (higher = snappier)                                                                       |
| `clampToBounds`      | `boolean`                    | `false`         | Clamp camera to world bounds                                                                                |
| `worldBounds`        | `{minX, minY, maxX, maxY}`   | none            | World bounds for clamping                                                                                   |
| `layers`             | `{integer: LayerConfig}`     | none            | Layer configurations keyed by layer number (1-16). See [Layers](/tecs2d/rendering/layers)                          |
| `sizeHints`          | `{string: integer}`          | none            | Initial GPU buffer capacities keyed by name (sprites, circles, lights, etc.). Grows automatically           |
| `dropShadowScale`    | `number`                     | `0.5`           | Drop shadow AO canvas resolution scale (0.5 = half res, 1.0 = full res)                                     |
| `bloom`              | `BloomConfig`                | none            | Bloom post-processing config: `enabled`, `intensity`, `radius`, `threshold`                                 |
