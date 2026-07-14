---
description: "BMFont bitmap and MSDF text rendering via the Text component, plus TextEffects outline, glow, and drop shadow"
---

# Text

Tecs provides GPU-accelerated text rendering using
[BMFont](https://www.angelcode.com/products/bmfont/doc/file_format.html)
format atlases. Both bitmap fonts and MSDF (multi-channel signed distance field) fonts are supported. Text is rendered
with GPU instancing for efficient batching.

## Quick Start

```teal
local tecs = require("tecs")
local gfx = require("tecs2d.gfx")

-- Load a bitmap font and create text
world:spawn(
    tecs.builtins.Transform(100, 50),
    gfx.Text("assets/fonts/pixel.fnt", "Hello World!")
)
```

## Text Component

The `Text` component renders text using a BMFont atlas. It requires a `Transform` component for positioning.

```teal
gfx.Text(fontPath, text, scaleX?, scaleY?)
```

**Parameters:**

| Parameter    | Type     | Default     | Description                                                        |
| ------------ | -------- | ----------- | ------------------------------------------------------------------ |
| `fontPath`   | string   | required    | Path to the `.fnt` or `.json` font file                            |
| `text`       | string   | required    | Text to display                                                    |
| `scaleX`     | number   | 1           | Horizontal scale factor                                            |
| `scaleY`     | number   | `scaleX`    | Vertical scale factor (defaults to `scaleX` for uniform scaling)   |

**Examples:**

```teal
-- Basic text
world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Text("fonts/pixel.fnt", "Score: 1000")
)

-- Scaled text (uniform scaling with single value)
world:spawn(
    tecs.builtins.Transform(200, 100),
    gfx.Text("fonts/pixel.fnt", "BIG TEXT", 2)
)

-- Colored text
world:spawn(
    tecs.builtins.Transform(100, 150),
    gfx.Text("fonts/pixel.fnt", "Warning!"),
    gfx.Color(1, 0.5, 0, 1)
)
```

### Updating Text

Use `setText()` to change the displayed text:

```teal
local textComp = world:get(entityId, gfx.Text)
textComp:setText("New text content")
```

Use `setScale()` to change the scale:

```teal
textComp:setScale(1.5)        -- Uniform scale
textComp:setScale(2.0, 1.0)   -- Different X and Y scale
```

Both methods automatically [mark the `Text` column dirty](/tecs/components/dirty-tracking) on the entity's
archetype so the GPU buffer is updated.

### Getting Text Properties

```teal
local textComp = world:get(entityId, gfx.Text)

-- Get current text
local currentText = textComp:getText()

-- Get dimensions (unscaled)
local offsetX, offsetY, width, height = textComp:getRect()
```

## Creating BMFont Files

Many tools can generate BMFont files. These free online tools are confirmed to work with Tecs:

- [SnowB](https://snowb.org) - Bitmap font generator
- [MSDF BMFont](https://msdf-bmfont.donmccurdy.com) - MSDF font generator

### File Requirements

Each BMFont requires two files:

- **Font definition**: `.fnt` (text format) or `.json`
- **Atlas image**: `.png` (or other image format)

The atlas image path is specified in the font definition file. Paths are relative to the font file location.

**Example directory structure:**

```
assets/
  fonts/
    pixel.fnt
    pixel.png
    fancy.json
    fancy.png
```

### Supported Font Types

| Type       | Description                      | Best For                      |
| ---------- | -------------------------------- | ----------------------------- |
| `bitmap`   | Pre-rendered at fixed size       | Pixel art, retro games        |
| `msdf`     | Multi-channel distance field     | Sharp at any scale/rotation   |

MSDF fonts are auto-detected from the font metadata (the `distanceField` field in JSON BMFont files). When an MSDF font
is loaded, text entities using it are automatically rendered with the MSDF shader pipeline, producing sharp edges at
any scale and rotation. No separate component or flag is needed; detection is automatic.

### Generating MSDF Atlases

For a quick browser-based option, use [MSDF BMFont](https://msdf-bmfont.donmccurdy.com). For more control over atlas
parameters, use the CLI tool [msdf-atlas-gen](https://github.com/Chlumsky/msdf-atlas-gen):

```bash
msdf-atlas-gen -font MyFont.ttf -type msdf -format png -size 42 \
    -pxrange 4 -json MyFont-msdf.json -imageout MyFont-msdf.png
```

The output JSON + PNG pair can be loaded directly with `Text`:

```teal
gfx.Text("fonts/MyFont-msdf.json", "Sharp at any size!", 1.0)
```

#### Atlas Parameters

| Parameter        | Flag        | Default   | Description                                                     |
| ---------------- | ----------- | --------- | --------------------------------------------------------------- |
| Font size        | `-size`     | -         | Base font size in pixels. Larger = more detail, bigger atlas    |
| Distance range   | `-pxrange`  | 2         | Atlas pixels of signed distance data around each glyph edge     |
| Font type        | `-type`     | -         | Use `msdf` for multi-channel SDF (sharp corners)                |

::: tip Distance Range and Effects
The `-pxrange` value controls how many atlas pixels of distance data are stored around each glyph edge. This directly
limits the maximum width of effects like outline and glow, since these effects can only render where SDF distance data
exists.

- **`-pxrange 4`**: Good for basic rendering and thin outlines
- **`-pxrange 8`**: Recommended when using glow or wider outlines
- **`-pxrange 16`**: Maximum effect width; produces larger atlases

A larger pxrange requires more padding between glyphs in the atlas, increasing atlas texture size. For most games,
`-pxrange 4` is sufficient for sharp text with outlines.
:::

## Preloading Fonts

To preload fonts during startup and avoid loading hitches, use the asset manager's
[`loadBMFont`](/tecs2d/assets/api#loadbmfont) method:

```teal
local tecs = require("tecs")
local assets = require("tecs2d.assets")

world:addSystem({
    phase = tecs.phases.Startup,
    run = function()
        local manager = world.resources[assets]
        manager:loadBMFont("fonts/pixel.fnt"):pin()
        manager:loadBMFont("fonts/title.fnt"):pin()
    end,
})
```

The fonts will be cached and available immediately when `Text` components reference them by path.

## Text Effects (MSDF only)

The `TextEffects` component adds outline, glow, and drop shadow effects to MSDF text. Effects are rendered entirely on
the GPU with no extra draw calls. All effects are composited back-to-front: shadow, then glow, then outline, then the
text fill.

```teal
gfx.TextEffects(config?)
```

**Config fields:**

| Field             | Type          | Description                                                                 |
| ----------------- | ------------- | --------------------------------------------------------------------------- |
| `outline.width`   | number        | Outline thickness (0.05-0.3 typical). Extends outward from the glyph edge   |
| `outline.color`   | `{r,g,b,a}`   | Outline color                                                               |
| `glow.radius`     | number        | Glow intensity/width (0.5-1.0 typical). Limited by atlas `-pxrange`         |
| `glow.color`      | `{r,g,b,a}`   | Glow color                                                                  |
| `shadow.offset`   | `{x,y}`       | Shadow offset in atlas pixels                                               |
| `shadow.blur`     | number        | Shadow blur amount (0.01-0.1 typical)                                       |
| `shadow.color`    | `{r,g,b,a}`   | Shadow color                                                                |

**Examples:**

```teal
-- Outline
world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Text("fonts/msdf.json", "Outlined", 2),
    gfx.Color(1, 1, 1, 1),
    gfx.TextEffects.new({
        outline = { width = 0.15, color = {0, 0, 0, 1} },
    })
)

-- Glow
world:spawn(
    tecs.builtins.Transform(100, 150),
    gfx.Text("fonts/msdf.json", "Glowing", 2),
    gfx.Color(1, 1, 1, 1),
    gfx.TextEffects.new({
        glow = { radius = 1.0, color = {0, 1, 0.2, 1} },
    })
)

-- Drop shadow
world:spawn(
    tecs.builtins.Transform(100, 200),
    gfx.Text("fonts/msdf.json", "Shadowed", 2),
    gfx.Color(1, 1, 1, 1),
    gfx.TextEffects.new({
        shadow = { offset = {3, 3}, blur = 0.05, color = {0, 0, 0, 0.8} },
    })
)

-- Combined effects
world:spawn(
    tecs.builtins.Transform(100, 300),
    gfx.Text("fonts/msdf.json", "All Effects", 2),
    gfx.Color(0.2, 0.6, 1, 1),
    gfx.TextEffects.new({
        outline = { width = 0.1, color = {0, 0, 0.3, 1} },
        glow = { radius = 0.5, color = {0.3, 0.5, 1, 0.8} },
        shadow = { offset = {4, 4}, blur = 0.08, color = {0, 0, 0, 0.6} },
    })
)
```

::: tip
TextEffects only works with MSDF/SDF fonts. Adding it to bitmap text entities has no visual effect.
:::

::: warning Effect Width Limits
Outline, glow, and shadow effects can only extend as far as the SDF distance data in the atlas padding. This is
determined by the `-pxrange` value used when generating the atlas. If effects appear clipped or too narrow, regenerate
the atlas with a larger `-pxrange` (e.g., 8 or 16).
:::

## Styling

Text works with these [styling components](/tecs2d/rendering/styling):

- [Color](/tecs2d/rendering/styling#color) - Tint the text
- [Pivot](/tecs2d/rendering/styling#pivot) - Change the origin point
- [Unlit](/tecs2d/rendering/styling#unlit) - Skip dynamic lighting for UI text
- [BlendMode](/tecs2d/rendering/styling#blendmode) - Control blending
- [Material](/tecs2d/rendering/materials) - Per-entity GPU shader effects
- [TextEffects](#text-effects-msdf-only) - Outline, glow, drop shadow (MSDF only)

```teal
-- Colored text
world:spawn(
    tecs.builtins.Transform(x, y),
    gfx.Text("fonts/pixel.fnt", "Colorful!"),
    gfx.Color(0.2, 0.8, 0.4, 1)
)

-- Unlit text (ignores lighting)
world:spawn(
    tecs.builtins.Transform(x, y),
    gfx.Text("fonts/pixel.fnt", "UI Text"),
    gfx.Unlit
)
```

### Materials with MSDF Text

[Materials](/tecs2d/rendering/materials) work with both bitmap and MSDF text. For MSDF text, the material input `mi.sdfDist`
contains the signed distance value, which can be used for custom effects like dissolve edges or color gradients based
on glyph shape. For bitmap text, `mi.sdfDist` is always 0.