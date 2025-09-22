# Lighting

Tecs provides a GPU-accelerated 2.5D lighting system with dynamic shadows. The system supports point lights, spotlights,
and height-based shadow occlusion.

## Quick Start

```lua
local gfx = require("tecs2d.gfx")
local Transform = tecs.builtins.Transform

-- Create a point light
world:spawn(
    Transform(400, 300),
    gfx.Light.new({
        radius = 200,
        intensity = 1.0,
        height = 0.3,
        r = 1.0, g = 0.9, b = 0.8
    })
)

-- Create a shadow-casting circle
world:spawn(
    Transform(300, 250),
    gfx.Circle(50),
    gfx.Color(0.8, 0.3, 0.2),
    gfx.Occluder()  -- enables shadow casting
)
```

## Light Component

The `Light` component creates dynamic light sources. It accepts a configuration table:

```lua
gfx.Light.new({
    radius = 200,
    intensity = 1.0,
    height = 0.15,
    r = 1.0, g = 1.0, b = 1.0,
    penumbra = 0.5,
    direction = 0,
    coneAngle = 0,
    innerConeAngle = 0,
})
```

All fields are optional with sensible defaults. You can also use positional arguments for simple cases:

```lua
-- Positional: radius, intensity, height, r, g, b
gfx.Light(200, 1.0, 0.3, 1.0, 0.9, 0.8)
```

### Properties

| Property         | Default   | Description                                                                        |
| ---------------- | --------- | ---------------------------------------------------------------------------------- |
| `radius`         | 200       | Falloff distance in world units. Pixels beyond this receive no light               |
| `intensity`      | 1.0       | Brightness multiplier. Values above 1.0 create overbright lighting                 |
| `height`         | 0.15      | Height above the 2D plane (0-1). See [Light Height](#light-height-and-25d-shading) |
| `r`, `g`, `b`    | 1.0       | Light color (0-1 per channel)                                                      |
| `penumbra`       | 0.5       | Shadow edge softness (0-1). 0 = hard shadows, 1 = maximum softness                 |
| `direction`      | 0         | Spotlight angle in radians (0 = right, pi/2 = down). Ignored for point lights      |
| `coneAngle`      | 0         | Spotlight outer cone half-angle in radians. 0 = point light                        |
| `innerConeAngle` | 0         | Spotlight inner cone half-angle. Full intensity inside, fades to outer cone        |

### Modifying Light Properties

After spawning, you can modify light properties directly:

```lua
local light = world:get(entity, gfx.Light)
light.radius = 300
light.intensity = 1.5
light.height = 0.5
light.r, light.g, light.b = 1.0, 0.8, 0.6  -- warm color
light.penumbra = 0.5  -- harder shadow edges
```

## Point Lights vs Spotlights

By default, lights are omnidirectional point lights. Setting `coneAngle > 0` converts a light to a spotlight.

### Point Light (Default)

Point lights emit in all directions:

```lua
world:spawn(
    Transform(x, y),
    gfx.Light.new({ radius = 200, intensity = 1.0, height = 0.3 })
)
```

### Spotlight

Spotlights emit in a directional cone:

```lua
world:spawn(
    Transform(x, y),
    gfx.Light.new({
        radius = 300,
        intensity = 1.5,
        height = 0.3,
        r = 1.0, g = 1.0, b = 0.9,
        direction = math.pi / 2,      -- pointing down
        coneAngle = math.pi / 6,      -- 30 degree half-angle (60 degree cone)
        innerConeAngle = math.pi / 12 -- soft edge falloff
    })
)
```

| Property         | Description                                                          |
| ---------------- | -------------------------------------------------------------------- |
| `direction`      | Angle in radians (0 = right, pi/2 = down, pi = left)                 |
| `coneAngle`      | Outer cone half-angle. 0 = point light                               |
| `innerConeAngle` | Inner cone for soft edges. Light is full intensity inside this angle |

The light intensity falls off smoothly between `innerConeAngle` and `coneAngle`.

## Light Height and 2.5D Shading

The `height` property (0.0 - 1.0, normalized) controls how lights interact with surfaces:

- **Low height** (0-0.15): Creates dramatic side-lighting with strong shadows
- **Medium height** (0.15-0.5): Balanced lighting
- **High height** (0.5+): Even, overhead-style lighting

```lua
-- Dramatic torchlight close to the ground
gfx.Light.new({ radius = 150, intensity = 1.2, height = 0.05, r = 1.0, g = 0.6, b = 0.3 })

-- Overhead sunlight
gfx.Light.new({ radius = 500, intensity = 0.8, height = 0.8, r = 1.0, g = 1.0, b = 0.95 })
```

Height also affects normal-based shading. Low lights create more pronounced directional shading on surfaces with
normal maps.

## Specular Highlights

Sprites and tiles with specular maps (`_s.png` suffix) display shiny highlights when lit. The lighting system uses
[Blinn-Phong shading](https://en.wikipedia.org/wiki/Blinn–Phong_reflection_model) to calculate specular reflections.

### Specular Map Format

| Channel | Purpose                                           |
| ------- | ------------------------------------------------- |
| RGB     | Specular intensity/color (brighter = shinier)     |
| Alpha   | Shininess (0 = broad highlights, 1 = sharp/tight) |

### Example Uses

- **Metal armor**: Bright specular RGB, high alpha (sharp highlights)
- **Wet surfaces**: Medium specular RGB, medium alpha
- **Skin/cloth**: Zero or very low specular (matte surfaces)

Specular maps are loaded automatically when a `sprite_s.png` file exists alongside the main sprite. For tilechunks,
set the `specularMap` property directly.

::: tip Advanced Lighting Control
For per-entity control over normals, specular, and emission in the G-buffer, use [Materials](./materials). Materials let
you write custom fragment shaders that output to all G-buffer targets while staying fully GPU-batched.
:::

## Shadows and Occluders

Entities with the `Occluder` component cast shadows. Without this component, entities are lit but don't block light.

### Basic Shadow Casting

```lua
-- Circle that casts shadows
world:spawn(
    Transform(x, y),
    gfx.Circle(50),
    gfx.Color(0.5, 0.5, 0.5),
    gfx.Occluder()
)

-- Rectangle that casts shadows
world:spawn(
    Transform(x, y),
    gfx.Rectangle(100, 200),
    gfx.Color(0.4, 0.3, 0.2),
    gfx.Occluder()
)

-- Sprite that casts shadows (uses alpha channel)
world:spawn(
    Transform(x, y),
    gfx.Sprite(spriteSheet, "tree"),
    gfx.Occluder({ alphaThreshold = 0.5 })
)
```

### Occluder Configuration

The `Occluder` component accepts either a configuration table or positional arguments:

```lua
-- Table style
gfx.Occluder({
    alphaThreshold = 0.5,   -- for sprites: pixels below this alpha don't cast shadows
    height = 0.5,           -- occluder height (0-1, normalized, default: 0.5)
})

-- Positional style: height, alphaThreshold
gfx.Occluder()           -- all defaults (height = 0.5)
gfx.Occluder(0.3)        -- height = 0.3
gfx.Occluder(0.5, 0.5)   -- height = 0.5, alphaThreshold = 0.5
```

### Occluder Height

The `height` property (0.0 - 1.0) controls perspective-based shadow projection:

```lua
-- Short occluder - casts shorter shadows from high lights
world:spawn(
    Transform(x, y),
    gfx.Circle(30),
    gfx.Occluder({ height = 0.2 })
)

-- Tall occluder - casts longer shadows
world:spawn(
    Transform(x, y),
    gfx.Circle(100),
    gfx.Occluder({ height = 0.8 })
)
```

**Perspective projection:**
- Shadow reach = `occluderHeight / lightHeight`
- Higher lights cast shorter shadows from the same occluder
- Occluders close to the light cast shorter shadows than distant ones
- When `lightHeight <= occluderHeight`, full shadows are cast

### Sprite Shadows

For sprites, the alpha channel determines the shadow silhouette:

```lua
-- Tree sprite with alpha-tested shadows
world:spawn(
    Transform(x, y),
    gfx.Sprite(treeSheet, "oak"),
    gfx.Occluder({
        alphaThreshold = 0.5,  -- pixels with alpha < 0.5 don't cast shadows
        height = 0.5           -- tree is medium height
    })
)
```

### Tile Shadows

Tiles in Tiled maps can cast shadows by setting the `occluderHeight` custom property on tiles in your tileset. This
allows specific wall or obstacle tiles to block light without converting them to sprites.

**In Tiled:**
1. Open your tileset in the Tileset Editor
2. Select the tile(s) that should cast shadows
3. Add a custom property: `occluderHeight` (float) with a normalized height (0.0 - 1.0)

```
Tile Properties:
  occluderHeight: 0.3    -- This tile casts shadows at medium height
```

**How it works:**
- When a tilemap loads, Tecs extracts `occluderHeight` from each tile's properties
- During rendering, tiles with `occluderHeight > 0` are rendered to the shadow mask
- The height determines which lights the tile blocks (same as sprite/shape occluders)

**Per-chunk settings:**
If a TileChunk contains any occluding tiles, you can customize the shadow behavior by adding an `Occluder` component to
the chunk entity:

```lua
-- Custom occluder settings for a chunk (via onTilemapLoaded callback)
world:set(chunkEntity, gfx.Occluder({
    height = 0.3,           -- override default height
}))
```

**Performance note:** Tile shadows are GPU-accelerated using the same dual-write culling architecture as sprites. Only
chunks containing occluding tiles are processed in the shadow pass.

## Drop Shadows

The `DropShadow` component projects a sprite's silhouette onto the ground as a dynamic shadow, stretched away from
nearby light sources. Unlike `Occluder` shadows (which use raymarching), drop shadows are computed per-entity on the GPU
and work well for characters, trees, and other sprites that need ground-contact shadows.

### Basic Usage

```lua
-- Tree with a drop shadow
world:spawn(
    Transform(x, y, 0, 2, 0, 3, 3),
    Sprite.fromSheet(treeSheet),
    gfx.Pivot(0.5, 1.0),
    gfx.DropShadow()
)

-- Taller entity with darker shadow
world:spawn(
    Transform(x, y, 0, 2),
    Sprite.fromSheet(characterSheet),
    gfx.Pivot(0.5, 1.0),
    gfx.DropShadow({ height = 0.8, opacity = 0.5 })
)
```

### Properties

| Property   | Default   | Description                                                 |
| ---------- | --------- | ----------------------------------------------------------- |
| `height`   | 0.5       | Entity height (0-1). Taller entities cast longer shadows    |
| `opacity`  | 0.3       | Shadow darkness (0-1). Higher values produce darker shadows |

You can use either table or positional syntax:

```lua
gfx.DropShadow()                  -- defaults (height=0.5, opacity=0.3)
gfx.DropShadow(0.8)               -- height=0.8, opacity=0.3
gfx.DropShadow(0.5, 0.4)          -- height=0.5, opacity=0.4
gfx.DropShadow({ height = 0.8 })  -- table style
```

### How Drop Shadows Work

Each frame, the GPU cull shader checks every `DropShadow` sprite against nearby lights using tile-based light binning
(the same tile structure used by the lighting pass). For each light affecting the sprite:

1. The shadow is **stretched away** from the light, with length proportional to `height / lightHeight`
2. The shadow is **squashed vertically** to create a ground-contact perspective effect
3. The shadow **opacity** fades with distance from the light
4. Shadows from multiple lights accumulate (darkest wins)

The shadows render to a standalone canvas and attenuate all lighting (ambient and dynamic). Emission is unaffected, so
glowing objects shine through shadows.

### Drop Shadows vs Occluders

| Feature           | `DropShadow`                                 | `Occluder`                             |
| ----------------- | -------------------------------------------- | -------------------------------------- |
| Shadow type       | Ground-contact silhouette projection         | Raymarched volumetric shadows          |
| Light interaction | Attenuates all lighting at shadow location   | Blocks light along ray path            |
| Self-shadowing    | Automatically prevented (two-pass stamp-out) | Automatically prevented (origin check) |
| Best for          | Characters, trees, props                     | Walls, pillars, large obstacles        |
| Performance       | One extra sprite draw per light per entity   | Raymarch steps per pixel per light     |

You can combine both on the same entity: an `Occluder` blocks light rays while a `DropShadow` adds a visible ground
shadow.

### Performance

Drop shadow rendering cost scales with the number of visible drop shadow sprites multiplied by the number of affecting
lights. The system includes several optimizations:

- **Tile-based light lookup**: each sprite only considers lights in its screen tile, not all visible lights
- **Weak shadow culling**: light contributions below a threshold are skipped
- **Half-resolution canvas**: the AO canvas defaults to 50% resolution with bilinear filtering, reducing fill-rate cost
with no visible quality loss

You can adjust the canvas resolution via `dropShadowScale`:

```lua
love.run = tecs2d.run({
    render = {
        dropShadowScale = 0.5,  -- default; half resolution
        dropShadowScale = 1.0,  -- full resolution (sharper, higher cost)
        dropShadowScale = 0.25, -- quarter resolution (softer, lower cost)
    },
})
```

## Ambient Light

Set the base illumination for unlit areas:

```lua
-- Dark ambient for dramatic lighting
pipeline:setAmbientLight(0.1, 0.1, 0.15)

-- Bright ambient for daytime scenes
pipeline:setAmbientLight(0.4, 0.4, 0.45)

-- Complete darkness
pipeline:setAmbientLight(0, 0, 0)

-- Get current ambient
local r, g, b = pipeline:getAmbientLight()
```

## Controlling Lighting

Tecs provides multiple levels of control over lighting: pipeline-wide, per-layer, and per-entity.

### Pipeline Configuration

Configure lighting behavior when creating the pipeline:

```lua
love.run = tecs2d.run({
    fps = 60,
    game = gamePlugin,
    render = {
        virtualHeight = 360,
        lightingMode = "deferred",  -- "deferred" (default) or "none"
        shadowsEnabled = true,      -- enable shadow casting (default: true)
    },
})
```

| Option           | Values                 | Description                                                     |
| ---------------- | ---------------------- | --------------------------------------------------------------- |
| `lightingMode`   | `"deferred"`, `"none"` | Deferred enables full lighting; none renders at full brightness |
| `shadowsEnabled` | `true`, `false`        | Whether occluders cast shadows                                  |

### Enabling/Disabling Lighting

Toggle lighting at runtime:

```lua
-- Disable lighting (everything renders at full brightness)
pipeline:disableLighting()

-- Re-enable lighting
pipeline:enableLighting()

-- Check current state
if pipeline:isLightingEnabled() then
    -- lighting is active
end
```

### Per-Layer Lighting

Mark entire layers as unlit so all entities on that layer render at full brightness:

```lua
-- Option 1: Configure layer at setup
pipeline:configureLayer(10, {
    name = "ui",
    unlit = true  -- all entities on layer 10 ignore lighting
})

-- Option 2: Toggle at runtime
pipeline:setLayerUnlit("ui", true)   -- disable lighting for UI layer
pipeline:setLayerUnlit("ui", false)  -- re-enable lighting

-- Check if layer is unlit
if pipeline:isLayerUnlit("ui") then
    -- layer renders at full brightness
end
```

This is useful for:
- UI layers that should always be visible
- Background layers with pre-baked lighting
- Debug overlays

### Per-Entity Unlit

Mark individual entities as unlit with the `Unlit` tag component:

```lua
-- Entity renders at full brightness regardless of lighting
world:spawn(
    Transform(x, y),
    gfx.Sprite(uiTexture),
    gfx.Unlit
)
```

`Unlit` composes with the per-layer unlit mask: an entity is unlit if either
the tag is present or the layer is configured `unlit = true`.

Use this for:
- Self-illuminating objects (glowing orbs, neon signs)
- UI elements mixed with world entities
- Debug markers

### Shadow Self-Prevention and Cross-Occluder Shadows

Self-shadow prevention works automatically. The shadow mask stores both an occluder height (R channel, blurred) and
an occluder flag (G channel, preserved from center pixel through blur). When the origin pixel is on an occluder,
the raymarch skips hits until the ray exits the origin occluder (passes through empty space). This prevents
self-shadow acne while still allowing cross-occluder shadows: ball A's shadow can darken ball B.

## Querying Light at a Position

You can query how much light hits a specific world position, including shadow occlusion. This is useful for stealth
mechanics, AI awareness, or any gameplay that depends on whether a position is lit or in shadow.

```lua
-- Returns 0-1 luminance (0 = full darkness, 1 = full brightness)
local brightness = pipeline:queryLightAt(worldX, worldY)

if brightness < 0.1 then
    -- Player is hidden in shadow
end
```

The first call lazily activates an intermediate render canvas. There is zero performance cost until `queryLightAt` is
first called; after that, one extra full-screen blit per frame is added. The first frame after activation returns 0
while the canvas populates.

In retro mode, the query reads from the virtual-resolution lit canvas (no extra cost).

## Performance Considerations

### Light Count

The lighting system uses GPU compute shader culling, so off-screen lights have minimal cost. Visible lights are the
primary performance factor.

**Recommendations:**
- 1-1000 visible lights: No concerns on modern GPUs
- 1000-5000 visible lights: Still performant, monitor frame times
- 5000+ visible lights: May need optimization depending on hardware

### Shadow Quality

Shadow quality can be adjusted via pipeline configuration:

```lua
local config = {
    -- 1.0 = pixel perfect, 0.5 = 4x fewer pixels
    -- Scaling down is the fastest way to improve performance
    shadowMaskScale = 1.0,

    -- Number of raymarch steps (higher = more accurate, lower = faster)
    -- Doubled automatically in pixel-perfect mode
    shadowSteps = 32,

    -- Expansion of the culling frustum
    -- Increase if shadows "pop in" at the edge of the screen
    shadowMargin = 200,
}
```

Lower `shadowMaskScale` reduces VRAM usage and improves performance at the cost of shadow precision.

