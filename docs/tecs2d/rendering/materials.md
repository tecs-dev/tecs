# Materials

Materials provide GPU-batched fragment shader injection for per-entity visual effects like dissolve, glow, and
custom shading.

## Quick Start

Register a material, then attach it to entities as a component:

```teal
local gfx = require("tecs2d.gfx")

-- Register a material from a fragment shader file
local lava = gfx.newMaterial("lava", {
    fragment = "shaders/lava.glsl"
})

-- Or use inline GLSL (strings not ending in .glsl are treated as source)
local flash = gfx.newMaterial("flash", {
    fragment = [[
        MaterialOutput material(MaterialInput i) {
            MaterialOutput o = standardMaterial(i);
            o.albedo.rgb = mix(o.albedo.rgb, vec3(1.0), i.params.x);
            return o;
        }
    ]],
})

-- Use it like any other component
world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Rectangle(32, 32),
    lava
)
```

## Writing a Material Shader

A material shader is a Love2D compatible `.glsl` file containing a single function with this signature:

```glsl
MaterialOutput material(MaterialInput i) {
    MaterialOutput o = standardMaterial(i);
    // Modify o as needed
    return o;
}
```

### MaterialInput

The input struct provides context about the current fragment:

```glsl
struct MaterialInput {
    // Entity color (from Color component, post-texture for sprites)
    vec4 color;
    // Texture coordinates (sprites) or normalized local coordinates
    vec2 uv;
    // World-space position of the fragment
    vec2 worldPos;
    // Normalized 0..1 position within the shape (0,0 = top-left, 1,1 = bottom-right)
    vec2 localPos;
    // Signed distance from shape edge (shapes only; 0 at edge, negative inside)
    float sdfDist;
    // Game time in seconds (respects time scale and pause)
    float time;
    // Per-entity parameters (p0, p1, p2, p3)
    vec4 params;
};
```

#### localPos Coordinate Spaces

The `localPos` field provides normalized 0..1 coordinates within each shape type:

| Shape       | (0,0)                      | (1,1)                         | Notes                                                    |
| ----------- | -------------------------- | ----------------------------- | -------------------------------------------------------- |
| Rectangle   | Top-left                   | Bottom-right                  | Aligned with shape bounds                                |
| Circle      | Top-left of bounding box   | Bottom-right of bounding box  | Use `sdfDist` for radial effects                         |
| Ellipse     | Top-left of bounding box   | Bottom-right of bounding box  |                                                          |
| Arc         | Top-left of bounding box   | Bottom-right of bounding box  |                                                          |
| Line        | Start point                | End point                     | x = distance along line, y = across width (0.5 = center) |
| Sprite      | Top-left                   | Bottom-right                  | Matches UV coordinates                                   |

### MaterialOutput

The output struct controls what gets written to the G-buffer:

```glsl
struct MaterialOutput {
    // Color output
    vec4 albedo;
    // Surface normal, encoded 0..1 (default: 0.5, 0.5, 1.0 = flat facing camera)
    vec3 normal;
    // 1.0 = receives lighting, 0.0 = fullbright/unlit
    float lit;
    // RGB = intensity, A = shininess
    vec4 specular;
    // Emission glow (RGB = color, A = intensity)
    vec4 emission;
};
```

### standardMaterial()

Call `standardMaterial(i)` to get the same output the shape would produce without a custom material. For sprites,
this includes sampled normal, emission, and specular maps (from `_n`, `_e`, `_s` texture suffixes). For shapes,
this includes computed normals (hemisphere for circles/ellipses, flat for rectangles/lines). Then modify only what
you need:

```glsl
MaterialOutput material(MaterialInput i) {
    MaterialOutput o = standardMaterial(i);
    o.albedo.rgb *= vec3(1.0, 0.5, 0.5); // Tint red, keep normal/specular/emission maps
    return o;
}
```

This is the recommended starting point for most materials. A dissolve effect, hit flash, or color tint only needs
to modify albedo or emission while preserving the standard surface properties.

### defaultMaterial()

Call `defaultMaterial(i)` to get flat defaults: entity color as albedo, flat normal, fully lit, no
specular/emission. Unlike `standardMaterial()`, this ignores any auto-loaded texture maps. Use this when you want
full control over every G-buffer channel:

```glsl
MaterialOutput material(MaterialInput i) {
    MaterialOutput o = standardMaterial(i);
    o.normal = vec3(0.5 + sin(i.time), 0.5, 1.0); // Custom animated normal
    return o;
}
```

### Full Template

```glsl
MaterialOutput material(MaterialInput i) {
    MaterialOutput o;
    o.albedo = i.color;
    o.normal = vec3(0.5, 0.5, 1.0);  // Flat normal
    o.lit = 1.0;
    o.specular = vec4(0.0);
    o.emission = vec4(0.0);
    return o;
}
```

### Discarding Fragments

You can use `discard` in material shaders to fully reject a fragment:

```glsl
if (someCondition) discard;
```

Setting `o.albedo.a = 0.0` also works.

## Vertex Displacement

Materials can optionally include a vertex function that offsets entity positions in world space. This is useful
for wind sway, water ripple, breathing animations, and other effects that move geometry without changing the
entity's transform.

Register a material with a vertex function. The fragment is optional; if omitted it defaults to
`standardMaterial(i)`:

```teal
local windSway = gfx.newMaterial("wind_sway", {
    vertex = "shaders/wind_sway_vert.glsl",
})
```

The vertex file contains a single `materialVertex` function:

```glsl
// shaders/wind_sway_vert.glsl
// params.x = sway amplitude
vec2 materialVertex(vec2 worldPos, float time, vec4 params) {
    float sway = sin(time * 2.0 + worldPos.y * 0.05) * params.x;
    return worldPos + vec2(sway, 0.0);
}
```

| Parameter    | Type     | Description                                                                    |
| ------------ | -------- | ------------------------------------------------------------------------------ |
| `worldPos`   | `vec2`   | World-space vertex position (after all transforms: pivot, rotation, scale)     |
| `time`       | `float`  | Game time in seconds (same as `i.time` in fragment)                            |
| `params`     | `vec4`   | Per-entity parameters (same as `i.params` in fragment)                         |

Return the modified world position. Return `worldPos` unchanged for no displacement.

The displacement applies to all vertices of the entity, so it moves the entire shape. It runs after rotation and
scale but before screen-space conversion, so the offset is in world units.

## Per-Entity Parameters

Each entity can pass 4 float parameters (p0-p3) to its material via `withParams()`:

```teal
-- All entities share the "dissolve" material but each has its own threshold
local dissolve = gfx.newMaterial("dissolve", {
    fragment = "shaders/dissolve.glsl"
})

world:spawn(
    Transform(0, 0),
    gfx.Rectangle(32, 32),
    dissolve:withParams(0.3)
)

world:spawn(
    Transform(50, 0),
    gfx.Rectangle(32, 32),
    dissolve:withParams(0.7)
)
```

Access parameters in the shader via `i.params`:

```glsl
MaterialOutput material(MaterialInput i) {
    MaterialOutput o = standardMaterial(i);
    float threshold = i.params.x;  // p0
    float noise = fract(
        sin(dot(i.localPos, vec2(12.9898, 78.233))) * 43758.5453
    );

    if (noise < threshold) {
        o.albedo.a = 0.0;  // Discard via alpha
    }

    return o;
}
```

::: tip GLSL vec4 swizzles
`i.params` is a `vec4`, so you can access its components using any GLSL swizzle: `.x`/`.y`/`.z`/`.w`,
`.r`/`.g`/`.b`/`.a`, or `.s`/`.t`/`.p`/`.q`. They all map to p0-p3 respectively.
:::

To animate parameters at runtime, get the component and set the fields:

```teal
local mat = world:get(entityId, gfx.Material)
mat.p0 = newThreshold
world:markComponentDirty(entityId, gfx.Material)  -- Trigger GPU re-sync
```

## Material Textures

Materials can bind up to 4 custom textures:

```teal
local frost = gfx.newMaterial("frost", {
    fragment = "shaders/frost.glsl",
    textures = {
        frostPattern = "textures/frost_noise.png",
        iceNormal = "textures/ice_normal.png",
    }
})
```

Access them in the shader as uniforms:

```glsl
uniform Image frostPattern;
uniform Image iceNormal;

MaterialOutput material(MaterialInput i) {
    MaterialOutput o = standardMaterial(i);
    vec4 pattern = Texel(frostPattern, i.localPos);
    o.albedo = mix(i.color, vec4(0.8, 0.9, 1.0, 1.0), pattern.r);
    o.normal = Texel(iceNormal, i.localPos).rgb;
    return o;
}
```

## Supported Systems

Materials work with all shape types and sprites:

- Rectangle, Circle, Ellipse, Arc, Line
- Sprites (animated and static)
- Text

Materials integrate with:
- **UI clipping** (`ClipBounds`) - clipped fragments are discarded before the material runs
- **Deferred lighting** - material output feeds the G-buffer; specular, normals, and emission all work

::: info Blend Modes
Blend mode components (`BlendAdd`, `BlendMultiply`, etc.) are ignored on entities that have a Material, because
materials render through the deferred G-buffer rather than the forward blend pass. True blend modes composite
against what's already on screen, which isn't possible in the G-buffer. For glow effects, `o.emission` is a good
alternative but won't behave identically to additive blending.
:::

## Examples

### Dissolve Effect

::: code-group

```teal [Usage]
local dissolve = gfx.newMaterial("dissolve", {
    fragment = "shaders/dissolve.glsl"
})

world:spawn(
    Transform(0, 0),
    gfx.Rectangle(32, 32),
    dissolve:withParams(0.3) -- p0 = dissolve threshold
)
```

```glsl [dissolve.glsl]
// p0 = threshold (0.0 = solid, 1.0 = fully dissolved)
MaterialOutput material(MaterialInput i) {
    MaterialOutput o = standardMaterial(i);
    float noise = fract(sin(dot(i.localPos, vec2(12.9898, 78.233))) * 43758.5453);
    float threshold = i.params.x;
    if (noise < threshold) {
        o.albedo.a = 0.0;
    }
    // Orange glow at dissolve edge
    float edge = smoothstep(threshold - 0.05, threshold, noise);
    o.albedo.rgb = mix(vec3(1.0, 0.5, 0.0), o.albedo.rgb, edge);
    return o;
}
```

:::

### Flash White (Hit Effect)

::: code-group

```teal [Usage]
local flash = gfx.newMaterial("flash", {
    fragment = "shaders/flash.glsl"
})

world:spawn(
    Transform(0, 0),
    gfx.Sprite(sheet),
    -- p0 = flash amount (0.0 = normal, 1.0 = fully white)
    flash:withParams(0.5)
)
```

```glsl [flash.glsl]
// p0 = flash amount (0.0 = normal, 1.0 = fully white)
MaterialOutput material(MaterialInput i) {
    MaterialOutput o = standardMaterial(i);
    o.albedo.rgb = mix(o.albedo.rgb, vec3(1.0), i.params.x);
    return o;
}
```

:::

### Wind Sway (Vertex Displacement)

::: code-group

```teal [Usage]
-- Vertex-only material (fragment defaults to standardMaterial)
local windGrass = gfx.newMaterial("wind_grass", {
    vertex = "shaders/wind_vert.glsl",
})

world:spawn(
    Transform(100, 200),
    gfx.Sprite(grassSheet),
    windGrass:withParams(8.0) -- p0 = sway amplitude in pixels
)
```

```glsl [wind_vert.glsl]
// p0 = sway amplitude
vec2 materialVertex(vec2 worldPos, float time, vec4 params) {
    float sway = sin(time * 1.5 + worldPos.x * 0.02) * params.x;
    return worldPos + vec2(sway, 0.0);
}
```
:::

## API Reference

### `gfx.newMaterial(name, opts)`

Register a material and return a `Material` component value.

| Parameter         | Type        | Description                                                                                               |
| ----------------- | ----------- | --------------------------------------------------------------------------------------------------------- |
| `name`            | `string`    | Unique material name                                                                                      |
| `opts.fragment`   | `string`    | Path to `.glsl` file or inline GLSL source for `material()`. Defaults to `standardMaterial(i)` if omitted |
| `opts.vertex`     | `string`    | Optional. Path to `.glsl` file or inline GLSL source for `materialVertex()`                               |
| `opts.textures`   | `table`     | Optional. Map of uniform name to texture path (up to 4)                                                   |
| `opts.unlit`      | `boolean`   | Optional. Force unlit rendering (default: false)                                                          |

At least one of `fragment` or `vertex` must be provided. Strings ending in `.glsl` are loaded from file; all
other strings are treated as inline GLSL source.

Returns a `Material` component that can be added to entities.

### `Material:withParams(p0, p1?, p2?, p3?)`

Returns a new `Material` value with the same `materialId` but different parameters.

| Parameter   | Type       | Description                                                  |
| ----------- | ---------- | ------------------------------------------------------------ |
| `p0`        | `number`   | First parameter (accessed as `i.params.x` in shader)         |
| `p1`        | `number`   | Second parameter (accessed as `i.params.y`). Default: 0      |
| `p2`        | `number`   | Third parameter (accessed as `i.params.z`). Default: 0       |
| `p3`        | `number`   | Fourth parameter (accessed as `i.params.w`). Default: 0      |

```teal
local dissolve = gfx.newMaterial("dissolve", {
    fragment = "shaders/dissolve.glsl"
})

-- Each entity gets its own threshold (p0) and edge width (p1)
world:spawn(
    Transform(0, 0),
    gfx.Rectangle(32, 32),
    dissolve:withParams(0.3, 0.05)
)

world:spawn(
    Transform(50, 0),
    gfx.Rectangle(32, 32),
    dissolve:withParams(0.7, 0.1)
)
```

See [MaterialInput](#materialinput) and [MaterialOutput](#materialoutput) for struct definitions.

::: info It's all a single Material component
This does not create a new component type: all materials share the single `Material` component. Querying for `Material`
matches all entities regardless of which material or params they use.
:::

## Custom Shaders vs Materials vs Layer Effects

Materials are an optimal approach to applying per-entity shaders. Tecs also supports applying post-processing
shaders to layers and groups of layers via [Layer Effects](/tecs2d/rendering/layers#layer-effects). And if that isn't
enough, you can always fall back to [Custom Drawing](/tecs2d/rendering/custom-drawing) with Love2D for full control over
how an entity is rendered and the shader to apply.

### Precompiling Shaders

A **shader variant** is the compiled GPU shader for a specific (material, shape type) pair. Each material needs a
separate variant for each shape type it's used with (rectangle, circle, sprite, etc.) because each shape type has
a different base shader that the material function is injected into.

Variants are compiled on first use, which can cause a brief hitch on the first frame a material appears. To avoid
this, call `precompileMaterials()` during a loading screen:

```teal
local gfx = require("tecs2d.gfx")

-- Register materials
local lava = gfx.newMaterial("lava", { fragment = "shaders/lava.glsl" })
local frost = gfx.newMaterial("frost", { fragment = "shaders/frost.glsl" })

-- Compile all variants upfront (7 shape types per material)
gfx.precompileMaterials()
```

## Performance Notes

- Materials are batched by ID: all entities sharing the same material are drawn in a single `drawIndirect` call.
  Each unique materialId adds one draw call per shape type that uses it.
- Shader variants are compiled lazily on first use, which can cause a brief hitch.
  [Precompile](#precompiling-shaders) during a loading screen to avoid this.
- Per-entity parameters use 16 bytes (4 floats) per entity in the GPU buffer
- Maximum 255 unique materials per application
