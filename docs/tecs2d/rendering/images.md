---
description: "Direct rendering for one-off images, canvases, and textures too large for Sprite batching"
---

# Images

`gfx.Image` draws a complete Love texture without adding it to the Sprite
texture arrays. Use it for:

- a one-off background or illustration;
- a `Canvas` or another texture created at runtime;
- a texture larger than the Sprite pipeline's 2048×2048 limit.

Use [`gfx.Sprite`](./sprites/) for ordinary game art, including static,
non-animated art. Sprites are automatically batched, so they remain the better
default when a scene may contain many instances or textures.

## Creating an Image

`Image` requires a [`Transform`](/tecs/builtins#transform-component). The
Transform position is the image's top-left corner unless a
[`Pivot`](./styling#pivot) is present.

```teal
local tecs = require("tecs")
local gfx = require("tecs2d.gfx")

local texture = love.graphics.newImage("assets/world-map.png")

world:spawn(
    tecs.builtins.Transform(0, 0),
    gfx.Image(texture)
)
```

`Image.fromTexture` is an equivalent named constructor:

```teal
local canvas = love.graphics.newCanvas(640, 360)

world:spawn(
    tecs.builtins.Transform(0, 0),
    gfx.Image.fromTexture(canvas)
)
```

Rotation and scale come from `Transform`.

## Renderer composition

Images support the same per-entity composition used by other renderables:

- [`Color`](./styling#color) tints the texture.
- [`Pivot`](./styling#pivot) changes the rotation and scale origin.
- [`Unlit`](./styling#unlit) bypasses dynamic lighting.
- [blend tags](./styling#blend-modes) select a forward blend mode.
- [`ClipBounds`](./ui/clipbounds) clips pixels to world-space bounds.
- [`Material`](./materials) applies a custom material shader.
- [`Occluder`](./lighting#shadows-and-occluders) and
  [`DropShadow`](./lighting#drop-shadows) use the texture's alpha channel as
  the shadow silhouette.

The `Transform.layer` controls ordering and visibility. Images respect layer
visibility, parallax, and each active camera's position and layer mask.

## Repeating an Image

Set `repeatX` or `repeatY` to repeat the complete texture across the visible
view. This is useful for repeating backgrounds and Tiled image layers.

```teal
world:spawn(
    tecs.builtins.Transform(0, 0),
    gfx.Image(texture, {
        repeatX = true,
    })
)
```

Each visible repeat is a direct draw. For many independent pieces of art, use
Sprites or a tilemap so Tecs can batch them.

## Snapshots

An in-memory texture has no durable source and is omitted from snapshot
serialization. Supply its asset path when the texture can be loaded again:

```teal
local path = "assets/world-map.png"
local texture = love.graphics.newImage(path)

world:spawn(
    tecs.builtins.Transform(0, 0),
    gfx.Image(texture, {
        path = path,
    })
)
```

The path must identify the texture passed to `Image`.
