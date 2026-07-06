# Layers

The render pipeline organizes entities into 16 layers for controlling draw order, visibility, and coordinate spaces.
Layers are rendered from 1 (back) to 16 (front).

## Using Layers

Entities are assigned to layers via the `Transform` component's `layer` field:

```teal
local tecs <const> = require("tecs")
local gfx <const> = require("tecs2d.gfx")

-- Background on layer 1
world:spawn(
    tecs.builtins.Transform(0, 0, 0, 1),  -- x, y, z, layer
    gfx.Sprite.fromAseprite("background.png")
)

-- Player on layer 5
world:spawn(
    tecs.builtins.Transform(100, 100, 0, 5),
    gfx.Sprite.fromAseprite("player.png", "idle")
)

-- UI on layer 15
world:spawn(
    tecs.builtins.Transform(10, 10, 0, 15),
    gfx.Text("fonts/ui.fnt", "Score: 0"),
    gfx.Unlit
)
```

## Layer Configuration

Configure layers with `pipeline:configureLayer()`:

```teal
local gfx = require("tecs2d.gfx")

-- Configure layers in tecs2d.run
love.run = tecs2d.run({
    fps = 60,
    game = gamePlugin,
    render = {
        layers = {
            [1] = { name = "background" },
            [5] = { name = "entities" },
            [15] = { name = "ui", space = "virtual", unlit = true },
        },
    },
})

-- Or configure at runtime via the pipeline
local pipeline = world.resources[gfx.PIPELINE]
pipeline:configureLayer(15, {
    name = "ui",
    space = "virtual",  -- Fixed to virtual resolution
    unlit = true        -- No lighting effects
})
```

### Configuration Options

| Option        | Type      | Default     | Description                                              |
| ------------- | --------- | ----------- | -------------------------------------------------------- |
| `name`        | string    | nil         | Optional layer name for debugging                        |
| `visible`     | boolean   | true        | Whether the layer is rendered                            |
| `space`       | string    | "world"     | Coordinate space: "world", "virtual", or "screen"        |
| `unlit`       | boolean   | false       | If true, entities skip lighting                          |
| `parallaxX`   | number    | 1.0         | Horizontal parallax factor (0.0 = fixed, 1.0 = normal)   |
| `parallaxY`   | number    | 1.0         | Vertical parallax factor (0.0 = fixed, 1.0 = normal)     |
| `sortMode`    | string    | "topdown"   | Depth sorting mode: "topdown", "z", or "isometric"       |

## Coordinate Spaces

Layers can use different coordinate spaces:

### World Space (Default)

Entities move with the camera. Use for game objects.

```teal
pipeline:configureLayer(5, { space = "world" })
```

- Coordinates are in world units
- Position is camera-relative
- Affected by zoom
- Supports parallax scrolling

### Virtual Space

Entities are fixed to the virtual resolution. Use for HUD elements.

```teal
pipeline:configureLayer(15, { space = "virtual" })
```

- Coordinates are in virtual pixels (e.g., 0-320 × 0-180)
- Position is screen-fixed
- Not affected by camera or zoom
- Scales with window resize
- Parallax has no effect

### Screen Space

Entities are fixed to screen pixels. Use for overlays that shouldn't scale.

```teal
pipeline:configureLayer(16, { space = "screen" })
```

- Coordinates are in screen pixels
- Position is screen-fixed
- Not affected by camera or zoom
- Does not scale with window resize
- Parallax has no effect
- Screen-space layers must have higher layer indices than all world/virtual layers
- Screen-space layers are always unlit (forced by the pipeline)
- Screen layers render at native window resolution regardless of pixel mode
- Useful for HUD/UI elements that should remain crisp at all settings

## Layer Visibility

Toggle layer visibility at runtime:

```teal
-- Hide a layer
pipeline:setLayerVisibility(1, false)
pipeline:setLayerVisibility("background", false)  -- By name

-- Show a layer
pipeline:setLayerVisibility(1, true)

-- Check visibility
if pipeline:isLayerVisible(1) then
    -- Layer is visible
end
```

**Use cases:**
- Debug visualization layers
- Optional UI elements
- Level transitions

## Layer Lighting

Control whether a layer is unlit (skips lighting effects):

```teal
-- Disable lighting on UI layer (entities render at full brightness)
pipeline:setLayerUnlit(15, true)

-- Re-enable lighting
pipeline:setLayerUnlit(15, false)

-- Check if layer is unlit
if pipeline:isLayerUnlit(5) then
    -- Layer renders at full brightness
end
```

You can also set this via configuration:

```teal
pipeline:configureLayer(15, { unlit = true })
```

**Note:** Individual entities can be marked unlit with the
[`Unlit`](/tecs2d/rendering/styling#unlit) tag component, which composes with
the per-layer setting (either makes the entity unlit).

## Depth Sorting

Each layer can use a different sorting mode via the `sortMode` option. The sort mode determines how entities are ordered
within the layer.

### Sort Modes

| Mode          | Description                                                               |
| ------------- | ------------------------------------------------------------------------- |
| `"topdown"`   | Z-index primary, Y-position secondary. Lower on screen appears in front.  |
| `"z"`         | Pure Z-index sorting. Only `Transform.z` determines order.                |
| `"isometric"` | X + Y + Z sorting. Good for isometric/diamond tile layouts.               |

### TopDown Mode (Default)

The default mode uses Z-index as the primary sort and Y-position as a secondary tiebreaker, giving natural depth
ordering in 3/4 view (oblique top-down) games.

```teal
pipeline:configureLayer(5, { sortMode = "topdown" })
```

### Z-Only Mode

Use `"z"` mode when you want explicit control over draw order without Y-sorting:

```teal
pipeline:configureLayer(15, {
    name = "ui",
    space = "virtual",
    sortMode = "z"  -- Only z-index matters
})
```

### Isometric Mode

Use `"isometric"` mode for diamond-grid isometric games where depth depends on both X and Y:

```teal
pipeline:configureLayer(5, {
    name = "isometric",
    sortMode = "isometric"  -- X + Y + Z sorting
})
```

### Runtime Sort Mode Changes

You can change sort mode at runtime:

```teal
pipeline:setLayerSortMode(5, "isometric")
pipeline:setLayerSortMode("entities", "topdown")  -- By name

local mode = pipeline:getLayerSortMode(5)  -- Returns "topdown", "z", or "isometric"
```

## Parallax Scrolling

Configure parallax to make layers scroll at different rates relative to the camera:

```teal
-- Background scrolls at 10% of camera speed
pipeline:configureLayer(1, {
    name = "background",
    parallaxX = 0.1,
    parallaxY = 0.1
})

-- Midground scrolls at half speed
pipeline:configureLayer(2, {
    name = "midground",
    parallaxX = 0.5,
    parallaxY = 0.5
})

-- Foreground (default) scrolls with camera
pipeline:configureLayer(3, { name = "foreground" })
```

You can also update parallax at runtime:

```teal
pipeline:setLayerParallax(1, 0.2, 0.2)
local px, py = pipeline:getLayerParallax(1)
```

### Parallax Factors

| Factor    | Behavior                                     |
| --------- | -------------------------------------------- |
| `1.0`     | Moves with camera (default)                  |
| `0.5`     | Moves at half camera speed                   |
| `0.0`     | Stays fixed (distant background)             |
| `> 1.0`   | Moves faster than camera (near foreground)   |

::: info World Space Only
Parallax only applies to world space layers. Virtual and screen space layers are already detached from the camera, so
parallax values have no effect on them.
:::

::: tip Tiled Integration
When loading Tiled maps, layer parallax is automatically configured from `parallaxx` and `parallaxy` layer properties.
:::

## Layer Effects

Layer effects are post-processing shaders applied to rendered layers. After a layer (or group of layers) is rendered
and lit, the result is passed through one or more shader passes. Use them for per-layer blur, color grading,
desaturation, and other full-screen effects.

::: tip Materials vs Layer Effects
Layer effects operate on entire rendered layers (screen-space post-processing). For per-entity visual effects
like dissolve, glow, or tinting, use [Materials](./materials) instead, which are GPU-batched and much faster
for per-entity use.
:::

### Setting an Effect

Use `pipeline:setLayerEffect()` to apply a shader effect to a layer:

```teal
-- Single-pass effect (e.g., color inversion)
pipeline:setLayerEffect(layerNum, invertShader, nil, { singleLayer = true })

-- Single-pass effect with uniforms
pipeline:setLayerEffect(layerNum, desatShader, { strength = 0.8 }, { singleLayer = true })

-- Multi-pass effect (e.g., separable Gaussian blur)
pipeline:setLayerEffect(layerNum, {blurH, blurV}, { radius = 8.0 }, { singleLayer = true })

-- Layers can be referenced by name
pipeline:setLayerEffect("entities", invertShader)
```

Clear an effect with `pipeline:clearLayerEffect()`:

```teal
pipeline:clearLayerEffect(layerNum)
pipeline:clearLayerEffect("entities")  -- By name
```

### API Reference

```teal
pipeline:setLayerEffect(
    layer,      -- integer (1-16) or string (layer name)
    shader,     -- A single Shader or a list of Shaders for multi-pass
    uniforms,   -- Optional {name = value} table sent to all shaders
    options     -- Optional {singleLayer = boolean}
)

pipeline:clearLayerEffect(layer)  -- integer (1-16) or string (layer name)
```

### Effect Modes

The `singleLayer` option controls what the effect applies to:

#### Single Layer Mode (`singleLayer = true`)

The effect applies only to the specified layer. Other layers are unaffected.

```teal
pipeline:setLayerEffect(3, blurShader, { radius = 4.0 }, { singleLayer = true })
```

#### Layers Below Mode (`singleLayer = false`, default)

The effect applies to the specified layer **and all layers below it**. This is useful for effects like heat haze that
should distort everything underneath.

```teal
-- Blur layer 3 and everything below it (layers 1, 2, 3)
pipeline:setLayerEffect(3, blurShader, { radius = 4.0 })
```

### Layer Groups

When effects are active, the pipeline splits the 16-layer stack into **layer groups**: contiguous ranges of layers that
are rendered and composited together. The grouping is determined automatically based on which layers have effects and
what mode they use.

Without effects, all 16 layers are a single group rendered in one pass. Each effect boundary creates a new group.

#### Single Layer Mode Grouping

With `singleLayer = true`, the effect layer is isolated into its own group. Layers before and after it form separate
groups:

```
                              ┌──────────────────┐
  Effect on layer 3           │  Group 3         │
  (singleLayer = true)        │  Layers 4..16    │
                              │  No effect       │
                              ├──────────────────┤
                              │  Group 2         │
                              │  Layer 3 only    │◄── Effect applied
                              │  blur + invert   │    to this layer
                              ├──────────────────┤
                              │  Group 1         │
                              │  Layers 1..2     │
                              │  No effect       │
                              └──────────────────┘
```

The effect shader processes layer 3's rendered output before it is composited onto the accumulator. Layers 1-2 and 4-16
pass through unchanged.

#### Layers Below Mode Grouping

With `singleLayer = false` (default), the effect layer and everything below it form one group, and the effect is applied
to the composited result of all those layers together:

```
                              ┌──────────────────┐
  Effect on layer 3           │  Group 2         │
  (singleLayer = false)       │  Layers 4..16    │
                              │  No effect       │
                              ├──────────────────┤
                              │  Group 1         │
                              │  Layers 1..3     │◄── Effect applied to
                              │  blur            │    ALL layers in group
                              └──────────────────┘
```

Here the blur applies to the combined output of layers 1, 2, and 3.

#### Multiple Effects

Multiple effects on different layers create more groups. Each effect boundary splits the stack:

```
                              ┌──────────────────┐
  Effects on layers 2 and 5   │  Group 4         │
  (both singleLayer = true)   │  Layers 6..16    │
                              │  No effect       │
                              ├──────────────────┤
                              │  Group 3         │
                              │  Layer 5 only    │◄── desaturate
                              ├──────────────────┤
                              │  Group 2         │
                              │  Layers 3..4     │
                              │  No effect       │
                              ├──────────────────┤
                              │  Group 1         │
                              │  Layers 1..2     │◄── blur
                              └──────────────────┘
```

### Multi-Pass Effects

Some effects require multiple shader passes. For example, a Gaussian blur is faster as two separable passes (horizontal
then vertical) than a single 2D pass. Pass a list of shaders to `setLayerEffect`:

```teal
local BLUR_SHADER <const> = [[
extern vec2 direction;
extern number radius;

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec4 sum = vec4(0.0);
    float totalWeight = 0.0;
    vec2 texSize = vec2(textureSize(tex, 0));
    vec2 pixelDir = direction / texSize;

    for (float i = -radius; i <= radius; i += 1.0) {
        float weight = 1.0 - abs(i) / (radius + 1.0);
        weight = weight * weight;
        sum += Texel(tex, tc + pixelDir * i) * weight;
        totalWeight += weight;
    }

    return sum / totalWeight * color;
}
]]

-- Create two instances with different directions
local blurH = love.graphics.newShader(BLUR_SHADER)
local blurV = love.graphics.newShader(BLUR_SHADER)
blurH:send("direction", {1.0, 0.0})  -- Horizontal
blurV:send("direction", {0.0, 1.0})  -- Vertical

-- Apply as a 2-pass effect
pipeline:setLayerEffect(2, {blurH, blurV}, { radius = 8.0 }, { singleLayer = true })
```

Internally, multi-pass effects use **ping-pong rendering**: the output of each pass becomes the input of the next,
alternating between two canvases.

```
  Pass 1 (blurH)                        Pass 2 (blurV)
  ┌───────────┐            ┌────────────┐            ┌───────────┐
  │ litLayer  │──shader───►│ effectTemp │──shader───►│ litLayer  │
  └───────────┘            └────────────┘            └───────────┘
       src                      dst            swap       src
```

### Stacking Effects on One Layer

You can combine multiple effects on a single layer by passing all their shaders as one list. Effects are applied in
order:

```teal
-- Blur, then invert, then desaturate (all on layer 2)
local allShaders = {blurH, blurV, invertShader, desatShader}
local allUniforms = { radius = 8.0, strength = 1.0 }

pipeline:setLayerEffect(2, allShaders, allUniforms, { singleLayer = true })
```

Uniforms are shared across all shaders. Each shader only receives the uniforms it declares; uniforms not present in a
shader are silently skipped.

### Standard Uniforms

The pipeline automatically sends these uniforms to effect shaders if they are declared:

| Uniform             | Type      | Description                                                                                       |
| ------------------- | --------- | ------------------------------------------------------------------------------------------------- |
| `tecs_PassIndex`    | int       | Zero-based index of the current pass in a multi-pass effect                                       |
| `tecs_SceneBelow`   | Image     | Texture of all layers composited below the current group                                          |
| `tecs_Normal`       | Image     | G-buffer normal texture (RGBA8). RGB = world normal (encoded as `n * 0.5 + 0.5`), A = lit marker. |
| `tecs_Emission`     | Image     | G-buffer emission texture (RGBA8). RGB = emission color, applied additively after lighting.       |

Use `tecs_SceneBelow` for effects that need to reference the scene underneath, such as distortion or refraction:

```glsl
extern Image tecs_SceneBelow;

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    // Sample the current layer
    vec4 pixel = Texel(tex, tc);
    // Sample the scene below with an offset for distortion
    vec2 offset = vec2(sin(tc.y * 20.0) * 0.01, 0.0);
    vec4 below = Texel(tecs_SceneBelow, tc + offset);
    return mix(below, pixel, pixel.a) * color;
}
```

::: info G-Buffer Limitations
Forward blend shapes (particles, translucent entities) render after lighting and are not written to the G-buffer. Their
normal and emission values will be the clear defaults (normal = flat up, emission = black). Custom draws via the
G-buffer callback also use clear defaults.
:::

### Writing Effect Shaders

Effect shaders are standard LOVE2D pixel shaders. They receive the rendered layer (or accumulator) as the `tex`
parameter:

```glsl
-- Simple color inversion
vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec4 pixel = Texel(tex, tc);
    return vec4(1.0 - pixel.r, 1.0 - pixel.g, 1.0 - pixel.b, pixel.a) * color;
}
```

```glsl
-- Desaturation with configurable strength
extern number strength;

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec4 pixel = Texel(tex, tc);
    float gray = dot(pixel.rgb, vec3(0.299, 0.587, 0.114));
    vec3 desaturated = mix(pixel.rgb, vec3(gray), strength);
    return vec4(desaturated, pixel.a) * color;
}
```

Custom uniforms are passed via the `uniforms` table and sent to the shader before each pass.

### Rendering Pipeline With Effects

When no effects are active, the pipeline renders all 16 layers in a single pass. When effects are present, it switches
to a multi-pass approach:

```
  For each layer group:
  ┌─────────────────────────────────────────────────────┐
  │  1. G-buffer pass (geometry for this layer range)   │
  │  2. Shadow mask + Lighting ──► litLayer             │
  │  3. Forward blend pass (alpha shapes) ──► litLayer  │
  │  4. Apply effect (if any):                          │
  │     - Single layer: effect(litLayer) ──► accumulator│
  │     - Layers below: composite ──► effect(accum)     │
  │  5. Or no effect: litLayer ──► accumulator          │
  └─────────────────────────────────────────────────────┘

  Final: draw accumulator to screen
```

::: tip Example
See the `layer-fx` example for an interactive demo with blur, invert, and desaturation effects that can be toggled
per-layer at runtime. Run it with `make example-layer-fx`.
:::

## Performance Notes

- Layers are processed sequentially; minimize layer count for best performance
- Sparse layer usage is fine (layers 1, 5, 15 work as well as 1, 2, 3)
- Layer configuration changes are cheap; use visibility toggling freely
- Coordinate space changes per-layer have no performance cost
- Parallax is computed on the GPU during culling with zero CPU overhead
- Layer effects add a rendering pass per group; minimize the number of distinct effect boundaries
- Multi-pass effects (e.g., separable blur) add one pass per shader in the list
- Layer group computation is cached and only recalculated when effects are added or removed
