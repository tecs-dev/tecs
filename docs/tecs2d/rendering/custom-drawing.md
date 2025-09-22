# Custom Drawing

While Tecs uses a deferred, GPU-accelerated render pipeline for most things you'll need like
[sprites](/tecs2d/rendering/sprites/), [shapes](/tecs2d/rendering/shapes), and [text](/tecs2d/rendering/text), you can still draw using
standard Love2D drawing calls.

## Draw Phase

The `Draw` phase lets you make custom love.graphics draw calls that participate in the world's
[lighting](/tecs2d/rendering/lighting) and depth sorting alongside GPU-rendered entities.

```lua
local tecs = require("tecs")
local gfx = require("tecs2d.gfx")

local pipeline = world.resources[gfx.PIPELINE]

world:addSystem({
    name = "custom.WorldDraw",
    phase = tecs.phases.Draw,
    run = function()
        -- Attach shader for lit drawing at layer 5
        pipeline:worldShader():at(5, 0, 100, 250):attach()

        -- Draw in world coordinates (camera transform already applied)
        love.graphics.setColor(1, 0.5, 0, 1)
        love.graphics.circle("fill", 100, 200, 30)

        pipeline:detachWorldShader()
    end
})
```

::: info Camera transforms already applied
During `Draw`, the camera's position and zoom are already applied to the Love2D graphics state. All draw calls
use **world coordinates**, the same coordinate space as GPU entities. Drawing at `(100, 200)` places your content at
world position `(100, 200)`, automatically offset and scaled by the camera.
:::

### World Shader API

To integrate with the G-buffer and lighting system, use `pipeline:worldShader()` to get a fluent configuration object.
Chain methods to set depth sorting, lighting mode, and optional shader/normal map, then call `:attach()` to apply. Call
`pipeline:detachWorldShader()` after drawing.

Draw with light with a position and layer:

```lua
pipeline:worldShader()
    :at(layer, z, x, bottomY)
    :attach()
```

Unlit draw (full brightness, no lighting):

```lua
pipeline:worldShader()
    :at(layer)
    :unlit()
    :attach()
```

Draw with custom shader and normal map:

```lua
pipeline:worldShader()
    :at(layer, z, x, bottomY)
    :shader(s)
    :normalMap(tex)
    :attach()
```

Always detach after drawing:

```lua
pipeline:detachWorldShader()
```

#### `:at(layer, z?, x?, bottomY?)`

Set the depth sorting position. Only `layer` is required; `z`, `x`, and `bottomY` default to 0.

| Parameter   | Description                                                          |
| ----------- | -------------------------------------------------------------------- |
| `layer`     | [Render layer](/tecs2d/rendering/layers) (1-16)                             |
| `z`         | Z-index within layer (default 0)                                     |
| `x`         | X coordinate for isometric depth sorting (default 0)                 |
| `bottomY`   | Bottom Y coordinate for depth sorting (default 0)                    |

#### `:unlit()`

Mark the draw as unlit. The draw will render at full brightness and not receive lighting.

#### `:shader(loveShader)`

Set a raw `love.graphics.Shader` for custom MRT-aware rendering. See [Custom Shader
Requirements](#custom-shader-requirements) below.

#### `:normalMap(texture)`

Set a normal map texture for per-pixel lighting.

#### `:attach()`

Apply the world shader with the accumulated settings. Draw after this call.

### Custom Shader Requirements

Custom shaders passed to `:shader()` must be **MRT-aware** to receive lighting (Multiple Render Targets).

::: warning MRT Output Required
Custom shaders that don't output to `love_Canvases[1]` (the normal buffer) will not receive lighting. The entity will
appear black or only show ambient light.
:::

::: tip Materials vs World Shaders
For per-entity visual effects (dissolve, tint, glow), use [Materials](/tecs2d/rendering/materials) instead. Materials are
GPU-batched and much faster. The `:shader()` API here is for manual CPU draws only (particles, physics debug, custom
procedural rendering).
:::

#### Tecs Uniforms

When a custom shader is set via `:shader()`, Tecs automatically sends values for these uniforms if they are declared:

| Uniform          | Type   | Description                                          |
| ---------------- | ------ | ---------------------------------------------------- |
| `tecs_Depth`     | float  | Depth value for z-sorting (0-1, lower = closer)      |
| `tecs_NormalMap` | Image  | Normal map texture (or flat normal fallback)         |
| `tecs_Lit`       | float  | 1.0 = receives lighting, 0.0 = unlit/fullbright      |
| `tecs_Time`      | float  | Game time in seconds (respects time scale and pause) |

#### MRT Shader Template

A complete shader for use with `:shader()`:

```glsl
#pragma language glsl4

uniform Image MainTex;
uniform float tecs_Depth;
uniform Image tecs_NormalMap;
uniform float tecs_Lit;
uniform float tecs_Time;

#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertex_position) {
    vec4 result = transform_projection * vertex_position;
    result.z = tecs_Depth * result.w;
    return result;
}
#endif

#ifdef PIXEL
void effect() {
    vec4 albedo = Texel(MainTex, VaryingTexCoord.xy) * VaryingColor;
    if (albedo.a < 0.01) discard;
    vec3 normal = Texel(tecs_NormalMap, VaryingTexCoord.xy).rgb * 2.0 - 1.0;
    love_Canvases[0] = albedo;
    love_Canvases[1] = vec4(normal * 0.5 + 0.5, tecs_Lit);
}
#endif
```

When you call `:attach()` without `:shader()`, the built-in world shader is used. This shader:
- Outputs to the G-buffer (albedo + normals)
- Respects `:unlit()` for lit/unlit rendering
- Applies the normal map if provided via `:normalMap()`
- Sets depth for correct sorting with GPU entities

### Unlit Drawing

For draws that should ignore lighting (full brightness):

```lua
pipeline:worldShader()
    :at(layer, z, x, bottomY)
    :unlit()
    :attach()

love.graphics.rectangle("fill", x, y, w, h)
pipeline:detachWorldShader()
```

### Visibility Culling

For performance, cull draws outside the visible area using the camera's `isVisible` method:

```lua
local cam = pipeline:getCamera()

world:addSystem({
    name = "custom.CulledDraw",
    phase = tecs.phases.Draw,
    run = function()
        for _, obj in ipairs(objects) do
            if cam:isVisible(obj.x, obj.y, obj.w, obj.h) then
                pipeline:worldShader()
                    :at(obj.layer, 0, obj.x, obj.y + obj.h)
                    :attach()
                love.graphics.setColor(obj.r, obj.g, obj.b, 1)
                love.graphics.rectangle("fill", obj.x, obj.y, obj.w, obj.h)
                pipeline:detachWorldShader()
            end
        end
    end
})
```

## PostRender Phase

Use `PostRender` for screen-space overlays that render after the entire GPU pipeline (no lighting, no depth sorting
with world entities).

```lua
world:addSystem({
    name = "ui.Overlay",
    phase = tecs.phases.PostRender,
    run = function()
        -- Screen coordinates (no camera transform)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.print("FPS: " .. love.timer.getFPS(), 10, 10)
    end
})
```

## UI in World Space

For UI that should use the [layer system](/tecs2d/rendering/layers) but not receive lighting, configure a layer as virtual
space and unlit:

```lua
pipeline:configureLayer(15, {
    name = "ui",
    space = "virtual",
    unlit = true
})

-- Then in the Draw phase, draw to that layer
world:addSystem({
    name = "ui.HUD",
    phase = tecs.phases.Draw,
    run = function()
        pipeline:worldShader()
            :at(15)
            :unlit()
            :attach()

        -- Virtual coordinates (e.g., 0-320 x 0-180)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.rectangle("fill", 10, 10, 100, 20)

        pipeline:detachWorldShader()
    end
})
```

## Depth Calculation

The pipeline computes depth using a consistent formula for both GPU and CPU draws:

```lua
local depth = pipeline:computeDepth(layer, z, x, bottomY)
```

Lower depth values render in front of higher values. The formula depends on the layer's
[sort mode](/tecs2d/rendering/layers):

- **topdown** (default): Layer, then Z-index, then Y position
- **z**: Layer, then Z-index only (no spatial sorting)
- **isometric**: Layer, then X + Y + Z combined

## Camera State

During `Draw`, access camera state if needed:

```lua
local camX = pipeline.drawCamX
local camY = pipeline.drawCamY
local zoom = pipeline.drawZoom
```

## Performance Notes

- CPU draws described on this page are slower than GPU-instanced rendering
- Batch similar draws together when possible
- Consider using the [Mesh component](/tecs2d/rendering/shapes#mesh) for custom geometry instead
