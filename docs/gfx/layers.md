---
description: "Depth bands, sorting, coordinate spaces, parallax, and lighting."
---

# Layers

Depth bands, sorting, coordinate spaces, parallax, and lighting.

A layer occupies one of sixteen depth bands. Entities sort inside their band
and never against another band. Higher layer numbers draw nearer, so a HUD on
layer 8 covers a world on layer 1.

```nupp
tecs.gfx.layers.configure(1, {sort = "topdown", parallax = 0.4})
tecs.gfx.layers.configure(8, {
    sort = "z",
    screenSpace = true,
    unlit = true,
    overlay = true,
})

world:spawn(
    tecs.ecs.Transform2D(16, 16, 0, 8, 0, 96, 24),
    tecs.gfx.Tint(1.0, 1.0, 1.0, 1.0),
    tecs.gfx.Renderable2D
)
```

The fourth [`Transform2D`](tecs.ecs.Transform2D) argument selects the layer.

## Sort modes

`"topdown"` sorts by Y with Z for height. `"z"` ignores position.
`"isometric"` combines X, Y, and Z for a diamond grid. Equal depths retain
instance order.

`setExtents(maxZ, maxY)` defines the authored extents that each sort maps into its
band. Values past an extent clamp to its edge. They still draw, but clamped
entities no longer sort against one another. Reduce an extent if nearby depths collapse together in the target depth format.

## Coordinate spaces

World coordinates form the default. `screenSpace` uses target pixels and
ignores the camera. `virtualCoords` stretches one
`virtualWidth` by `virtualHeight` coordinate system to the target.
`ignoreZoom` follows camera position while preserving drawn size. `parallax`
scales camera movement.

One layer cannot combine `screenSpace` and `virtualCoords`. Virtual coordinates
preserve the authored coordinate system but do not letterbox or preserve
square pixels.

`unlit` bypasses scene lighting for UI, debug overlays, and other content that
must retain its own color.

Put a HUD on a high screen-space, unlit overlay layer. `overlay` selects the
forward lane even for opaque content. The layer still orders the HUD internally.

`configure` replaces the complete layer configuration. Any omitted option
returns to its default.
