---
description: "Shape rendering, materials, layers, animation and text"
order: 30
---

# Graphics

A drawn quad is an entity carrying components. The renderer finds those entities
by query and sends their transforms, colors and material choices to the GPU.

- [Shapes](shapes.md): rectangles, circles, rounded boxes, rings and the other silhouettes.
- [Materials](materials.md): shader contract, coverage, surface properties and emission.
- [Layers](layers.md): depth bands, sorting, coordinate spaces and parallax.
- [Animation](animation.md): sprite sheets, tags, fixed-step playback and pivots.
- [Text](text.md): font atlases, glyph entities and layout.
- [Rendering benchmarks](benchmarks.md): capacity and measured completed-frame costs.

Continue with [Tiled maps](../tiled/index.md), [Building interfaces](../ui/index.md),
and [the graphics API](tecs.gfx).
