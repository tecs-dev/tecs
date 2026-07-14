# Tecs2D rendering

Drawing is data — spawn a `Transform` plus a drawable (shape / text / sprite) and styling; the GPU pipeline renders it, no `love.graphics` calls.

All constructors below come from `local gfx <const> = require("tecs2d.gfx")` unless noted.

## Transform (position, from `tecs.builtins`)

```teal
local Transform <const> = tecs.builtins.Transform
Transform(x, y, z?, layer?, rotation?, scaleX?, scaleY?)
```

- `x, y` world/virtual position; `z` sorts within a layer; `layer` (>= 1) selects a render layer.
- `rotation` radians; `scaleX/scaleY` default 1 (use negative scale to mirror).
- Table form: `Transform.new({x = 1, y = 2})`.

## Drawable components

```teal
gfx.Rectangle(width, height, lineWidth?)   -- lineWidth 0 = filled (default), >0 = outline
gfx.Circle(radius, lineWidth?)
gfx.Ellipse(rx, ry, lineWidth?)
gfx.Arc(radius, angle1, angle2, lineWidth?)
gfx.Line(...)                              -- line segments
gfx.Text(fontPath, text, sx?, sy?)         -- BMFont atlas; sx/sy are scale
gfx.Sprite.fromAseprite("assets/player.png", "idle")
```

Width/height/radius must be non-negative (mirror with negative Transform scale, not negative size).
A bundled pixel font is available at `"tecs2d/assets/fonts/tiny-font.fnt"`.

Update text at runtime with `txt:setText("SCORE 5")` / `txt:setScale(sx, sy)` on the component
instance returned by `world:get(id, gfx.Text)`.

## Styling components

```teal
gfx.Color(r, g, b, a)   -- each 0..1; defaults (1,1,1,1)
gfx.Pivot(x, y)         -- 0..1 origin; (0.5,0.5) = center, (0,0) = top-left; default center
gfx.Unlit               -- tag: skip dynamic lighting
gfx.BlendMode(...)      -- add / multiply / etc.
```

## Example: a centered label on a panel

```teal
world:spawn(
    Transform(W / 2, H / 2, 0, 1),
    gfx.Rectangle(W, H),
    gfx.Color(0.08, 0.09, 0.12, 1),
    gfx.Pivot(0.5, 0.5)
)
world:spawn(
    Transform(W / 2, H / 2, 1, 2),
    gfx.Text("tecs2d/assets/fonts/tiny-font.fnt", "HELLO", 4),
    gfx.Color(0.9, 0.96, 1.0, 1),
    gfx.Pivot(0.5, 0.5)
)
```

## Layers

Configure in `render.layers` of `tecs2d.run`. Each layer has a `name` and a `space`:
`"world"` (camera-relative, default), `"virtual"` (fixed 0..virtualHeight, ignores zoom), or
`"screen"` (pixel coords). Put HUD/UI on a `"virtual"` or `"screen"` layer above gameplay.

Set `render.virtualHeight` (and optionally `virtualWidth`), `lightingMode = "none"` for flat 2D,
and `pixelMode = true` for pixel-art nearest-neighbor upscaling.

See also: `tecs docs tecs-ecs` for spawning/queries, `tecs docs tecs-gotchas`.
