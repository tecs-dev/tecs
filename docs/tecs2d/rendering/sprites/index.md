---
description: "Overview of the sprite system, creating sprites from sheets or textures, Sprite methods, and GPU rendering buckets"
---

# Sprites

Tecs provides a complete sprite system with animated sprites from Aseprite, per-frame collision boxes, animation
events, and [material](../materials) maps for advanced lighting. Sprites are rendered using GPU instancing for maximum
performance.

## Quick Start

```teal
local assets = require("tecs2d.assets")

-- Load sprite sheet (async, returns handle, caches asset)
local handle = assets.loadSpriteSheet("player.png")

-- Create sprite from loaded sheet
world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Sprite.fromSheet(handle.value, "walk")
)
```

## Creating Sprites

### From Asset Manager (Recommended)

Use [`loadSpriteSheet`](/tecs2d/assets/api#loadspritesheet) for async loading with automatic caching.

```teal
local assets = require("tecs2d.assets")

-- Load sprite sheet (async, returns handle)
local handle = assets.loadSpriteSheet("player.png")

-- Spawn a Sprite and pass in option configuration
world:spawn(
    tecs.builtins.Transform(200, 100),
    gfx.Sprite.fromSheet(handle.value, "attack", {
        speed = 1.5,         -- 1.5x playback speed
        centered = true,     -- Center on transform (default)
        pivotSlice = "feet", -- Use "feet" slice for pivot
        startTime = 0        -- Animation start time
    })
)
```

For static images without animation, use [`loadStaticSheet`](/tecs2d/assets/api#loadstaticsheet):

```teal
local bgHandle = manager:loadStaticSheet("background.png")
world:spawn(
    tecs.builtins.Transform(0, 0),
    gfx.Sprite.fromSheet(bgHandle.value)
)
```

### Convenience Shorthand (Sync)

`fromAseprite` combines loading and sprite creation in one call. Useful for prototyping, but blocks the main thread:

```teal
-- Loads sheet synchronously and creates sprite
gfx.Sprite.fromAseprite("player.png", "walk")

-- With options
gfx.Sprite.fromAseprite("player.png", "attack", {
    speed = 1.5,
    pivotSlice = "feet"
})
```

### From SpriteSheet (Sync)

For loading a sheet once and creating multiple sprites:

```teal
-- Load sheet synchronously (blocks main thread)
local sheet = gfx.SpriteSheet.fromFile("enemies.png")

-- Create multiple sprites from the same sheet
local goblin = gfx.Sprite.fromSheet(sheet, "goblin_idle")
local orc = gfx.Sprite.fromSheet(sheet, "orc_idle")
```

### From Texture (Single Frame)

For simple textures without animation:

```teal
local texture = love.graphics.newImage("bullet.png")
gfx.Sprite.fromTexture(texture)
```

## Sprite Options

| Option         | Type      | Default   | Description                                                         |
| -------------- | --------- | --------- | ------------------------------------------------------------------- |
| `speed`        | number    | 1.0       | Animation speed multiplier                                          |
| `centered`     | boolean   | true      | Center sprite on transform position                                 |
| `pivotSlice`   | string    | nil       | Name of Aseprite slice to use as pivot                              |
| `startTime`    | number    | 0         | Animation start time (for staggering)                               |
| `path`         | string    | nil       | `fromTexture` only: durable source used to reconstruct the snapshot |

When supplying `path` to `fromTexture`, the caller is responsible for ensuring that the texture came from that path.
In-memory textures without a durable path are omitted from snapshot serialization.

## Sprite Methods

```teal
local sprite = world:get(entityId, gfx.Sprite)

-- Animation control
sprite:setTag("run")           -- Change animation tag
sprite:playOnce("attack")      -- Play a tag once, then freeze on the last frame
sprite:pause()                 -- Pause at current frame
sprite:resume()                -- Resume from pause
sprite:pauseAtEnd()            -- Jump to last frame and pause
sprite:pauseAtStart()          -- Jump to first frame and pause
sprite:gotoFrame(3)            -- Jump to specific frame (0-indexed)

-- Query state
local tag = sprite:getTag()              -- Current tag name
local frame = sprite:getFrame()          -- Current frame (0-indexed within tag)
local absFrame = sprite:getAbsoluteFrame() -- Absolute frame (1-indexed in sheet)
local w, h = sprite:getDimensions()      -- Sprite dimensions
local px, py = sprite:getPivot()         -- Current pivot point
local cx, cy = sprite:getCenter()        -- Center point (0.5, 0.5)
```

## Combining with Other Components

Sprites work with [styling components](../styling):

| Component                               | Description                                            |
| --------------------------------------- | ------------------------------------------------------ |
| [`Color`](../styling#color)             | RGBA tint applied to the sprite                        |
| [Blend tags](../styling#blend-modes)    | Controls pixel blending (add, multiply, etc.)          |
| [`Unlit`](../styling#unlit)             | Skip dynamic lighting (use for UI sprites)             |
| [`Pivot`](../styling#pivot)             | Custom origin point (overrides `pivotSlice` option)    |
| [`Material`](../materials)              | Per-entity GPU shader effects (dissolve, glow, etc.)   |

```teal
local sheet = manager:loadSpriteSheet("player.png").value

world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Sprite.fromSheet(sheet, "idle"),
    gfx.Color(1, 0.8, 0.8, 1),           -- Tint
    gfx.Unlit,                           -- Skip lighting
    gfx.Pivot(0.5, 1.0)                  -- Custom pivot (overrides pivotSlice)
)
```

## GPU Rendering Architecture

Sprites are rendered using a high-performance GPU pipeline that can handle millions of sprites efficiently.

### Texture Buckets

Sprite textures are automatically grouped into size-bucketed texture arrays:

| Bucket   | Max Size    | Layers per Array   |
| -------- | ----------- | ------------------ |
| Tiny     | 16×16       | 512                |
| Small    | 64×64       | 256                |
| Medium   | 256×256     | 128                |
| Large    | 512×512     | 64                 |
| XL       | 1024×1024   | 32                 |
| XXL      | 2048×2048   | 4                  |

The XXL bucket is intentionally shallow because each 2048×2048 layer reserves albedo, normal, emission, and ORM
surfaces. Additional XXL sheets spill into another texture array and render as another bucket.

This architecture enables:
- **Single draw call per bucket** - All sprites using textures in the same size bucket and texture array are batched together
- **Automatic allocation** - Textures are assigned to buckets based on their dimensions
- **GPU culling** - Visibility culling runs entirely on the GPU via compute shaders

### Large Textures

`Sprite` textures have a maximum size of 2048×2048 because every sprite is
stored in a GPU texture-array bucket. Larger textures are not rendered by the
Sprite pipeline. Use [`gfx.Image`](../images) for a one-off or very large
texture:

```teal
world:spawn(
    tecs.builtins.Transform(0, 0),
    gfx.Image(hugeBackgroundTexture)
)
```

Keep using `Sprite` for ordinary static art. It is the default batched path;
`Image` is intentionally unbatched.

## Documentation

| Topic                                      | Description                                                    |
| ------------------------------------------ | -------------------------------------------------------------- |
| [Sheets](./sheets)                         | Loading sprite sheets, Aseprite export settings, material maps |
| [Animation](./animation)                   | Tags, playback control, timing, directions                     |
| [Slices](./slices)                         | Pivot points, per-frame pivots                                 |
| [Collisions](./collisions)                 | Physics integration from slices                                |
| [Events](./events)                         | ChangeTag events                                               |
| [Tiling](./tiling)                         | RepeatedSprite for tiling                                      |
