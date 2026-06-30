# Styling

Styling components modify how entities are rendered without changing their shape or content. These components work
with sprites, shapes, and text.

## Color

The `Color` component applies RGBA tinting to sprites, shapes, and text.

```teal
gfx.Color(r?, g?, b?, a?)
```

**Parameters:**

| Parameter   | Type     | Default   | Description                |
| ----------- | -------- | --------- | -------------------------- |
| `r`         | number   | 1.0       | Red component (0.0-1.0)    |
| `g`         | number   | 1.0       | Green component (0.0-1.0)  |
| `b`         | number   | 1.0       | Blue component (0.0-1.0)   |
| `a`         | number   | 1.0       | Alpha component (0.0-1.0)  |

**Examples:**

```teal
local gfx = require("tecs2d.gfx")

-- Red tint
world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Circle(20),
    gfx.Color(1, 0, 0, 1)
)

-- Semi-transparent white
world:spawn(
    tecs.builtins.Transform(200, 100),
    gfx.Rectangle(50, 50),
    gfx.Color(1, 1, 1, 0.5)
)

-- No color component = full white (1, 1, 1, 1)
world:spawn(
    tecs.builtins.Transform(300, 100),
    gfx.Circle(20)
)
```

### Modifying Color

Tecs syncs color changes only when the `Color` component is detected as dirty. See
[Dirty Tracking](/tecs/components/dirty-tracking) for details. There are two approaches:

**Option 1: Replace the component in the archetype**

This is preferred if you have the archetype and row.

```teal
archetype:set(row, Color(r, g, b, a))
```

**Option 2: Replace the component in the world**

This is useful if you just have the entity ID.

```teal
world:set(entityId, Color(r, g, b, a))
```

**Option 3: Modify in place via getMut**

If you have an archetype and row:

```teal
local colors = archetype:getMut(Color)
local color = colors[row]
color.r = 0.5
color.g = 1.0
color.b = 0.5
color.a = 1.0
```

`getMut` flags `Color` dirty on the archetype, so the renderer
re-uploads it next frame. If you have just the entity ID:

```teal
world:markComponentDirty(entityId, Color)
```

## Blend Modes

Blend mode components control how an entity's pixels combine with the background. Each blend mode is a
separate tag component. Entities without a blend component use normal alpha blending.

Blend mode components are stored in `tecs2d.gfx.blend`:

```teal
local gfx = require("tecs2d.gfx")
local blend = gfx.blend
```

| Component                | Description                                                                       |
| ------------------------ | --------------------------------------------------------------------------------- |
| `AdditiveBlend`          | Adds source and destination colors. Use for glow, fire, light beams, particles.   |
| `AdditiveBlendPremul`    | Additive blend for pre-multiplied alpha textures.                                 |
| `MultiplyBlend`          | Multiplies source and destination colors. Use for shadows, tinting, darkening.    |
| `MultiplyBlendPremul`    | Multiply blend for pre-multiplied alpha textures.                                 |
| `ScreenBlend`            | Inverse of multiply; lightens the image. Use for soft glow and highlights.        |
| `ScreenBlendPremul`      | Screen blend for pre-multiplied alpha textures.                                   |
| `SubtractBlend`          | Subtracts source from destination. Use for color removal and special darkening.   |
| `SubtractBlendPremul`    | Subtract blend for pre-multiplied alpha textures.                                 |
| `LightenBlend`           | Takes the maximum of each color channel. Use for dodge and highlight effects.     |
| `LightenBlendPremul`     | Lighten blend for pre-multiplied alpha textures.                                  |
| `DarkenBlend`            | Takes the minimum of each color channel. Use for burn and shadow effects.         |
| `DarkenBlendPremul`      | Darken blend for pre-multiplied alpha textures.                                   |
| `ReplaceBlend`           | Overwrites the destination completely. Use when you need exact color output.      |
| `ReplaceBlendPremul`     | Replace blend for pre-multiplied alpha textures.                                  |

::: details Why 14 blend mode components?
Blend modes are tag components rather than a single component with a "mode" field. This allows the ECS to
group entities by blend mode into separate archetypes. Since all entities in an archetype share the same
blend mode, the renderer can batch them into a single draw call without state changes.
:::

### Using Blend Modes

Blend modes are **mutually exclusive**: adding a blend component automatically removes any existing blend
component from the entity.

**Adding a blend mode** when spawning:

```teal
world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Circle(30),
    gfx.Color(1, 0.8, 0.2, 0.9),
    blend.AdditiveBlend()
)
```

**Changing a blend mode** on an existing entity (the old blend component is removed automatically):

```teal
world:set(id, blend.MultiplyBlend())
```

**Removing a blend mode** to return to normal alpha blending:

```teal
world:remove(id, blend.MultiplyBlend)
```

::: warning Materials
Blend mode components are **not compatible with [Materials](./materials)**. Materials render through
the deferred G-buffer pipeline, while blend modes use a forward pass after lighting. Entities with
both a Material and a blend mode component will not render.
:::

## Unlit

The `Unlit` tag component opts an entity out of dynamic lighting. Entities with
`Unlit` render at full brightness regardless of nearby light sources or ambient
light. Use it for UI elements, light emitters that already encode their own
brightness in their color, and any entity where shading would be wrong.

```teal
world:spawn(
    tecs.builtins.Transform(10, 10),
    gfx.Rectangle(200, 50),
    gfx.Color(0.2, 0.2, 0.2, 0.9),
    gfx.Unlit
)
```

`Unlit` carries no data, so adding it is a single argument. To toggle at runtime:

```teal
world:add(entityId, gfx.Unlit)     -- make unlit
world:remove(entityId, gfx.Unlit)  -- restore normal lighting
```

`Unlit` composes with the per-layer unlit mask
(`pipeline:setLayerUnlit(layer, true)`): an entity is unlit if **either** the
tag is on the entity **or** the layer is unlit.

## Geometry style

SDF shapes (`Circle`, `Rectangle`, `Ellipse`, `Arc`, `Line`) render with
anti-aliased edges by default. The pipeline-level `roughGeometry` flag flips
the entire scene to hard pixel cutoffs, suitable for pixel-art aesthetics
where AA gradients would soften the look.

```teal
local pipeline = gfx.newPipeline({
    world = world,
    roughGeometry = true,  -- hard pixel edges
})
```

Toggle at runtime:

```teal
pipeline:setRoughGeometry(true)
local rough = pipeline:getRoughGeometry()
```

`roughGeometry` is independent of `pixelMode` (the integer-scale upscale).
Combine them for retro pixel-art, or use either alone.

## Pivot

The `Pivot` component controls the origin point for rendering and rotation. Values are normalized (0-1 range).

```teal
gfx.Pivot(x?, y?)
```

**Parameters:**

| Parameter   | Type     | Default   | Description                                      |
| ----------- | -------- | --------- | ------------------------------------------------ |
| `x`         | number   | 0.5       | Horizontal pivot (0=left, 0.5=center, 1=right)   |
| `y`         | number   | 0.5       | Vertical pivot (0=top, 0.5=center, 1=bottom)     |

**Examples:**

```teal
-- Rectangle anchored at top-left
world:spawn(
    tecs.builtins.Transform(0, 0),
    gfx.Rectangle(100, 50),
    gfx.Pivot(0, 0)
)

-- Sprite rotating around its feet
world:spawn(
    tecs.builtins.Transform(200, 300, 0, 1, { rotation = math.pi / 4 }),
    gfx.Sprite.fromAseprite("character.png", "idle"),
    gfx.Pivot(0.5, 1)  -- Bottom-center
)
```

::: warning Dirty Tracking
Changing `Pivot` at runtime requires [dirty tracking](/tecs/components/dirty-tracking) to take effect.
:::

::: info Aseprite Slices
Sprites loaded with `pivotSlice` option use per-frame pivot points from Aseprite slices, which
override the Pivot component.
:::

## Combining Styling Components

Styling components can be combined freely:

```teal
-- Glowing additive circle
world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Circle(30),
    gfx.Color(1, 0.8, 0.2, 0.9),
    gfx.blend.AdditiveBlend()
)

-- UI button (unlit, rounded, with custom pivot)
world:spawn(
    tecs.builtins.Transform(400, 20),
    gfx.Rectangle(120, 40),
    gfx.RoundedCorners(8),
    gfx.Color(0.3, 0.5, 0.9, 1),
    gfx.Unlit,
    gfx.Pivot(1, 0)  -- Anchor top-right
)
```

## See Also

- [Materials](./materials) - GPU-batched fragment shader injection for per-entity visual effects
  (dissolve, glow, tinting)
