---
description: "Shape rendering, materials, layers, animation and text"
order: 30
---

# Graphics

Drawable entities carry components the renderer finds by query. A sprite
contributes one quad; a TileChunk contributes a grid of static tiles.

- [Shapes](shapes.md): rectangles, circles, rounded boxes, rings and the other silhouettes.
- [Materials](materials.md): shader contract, coverage, surface properties and emission.
- [Layers](layers.md): depth bands, sorting, coordinate spaces and parallax.
- [Animation](animation.md): sprite sheets, tags, fixed-step playback and pivots.
- [TileChunks](../tiled/tile-chunks.md): static 16×16 grids and chunk-local edits.
- [Text](text.md): font atlases, glyph entities and layout.
- [Rendering benchmarks](benchmarks.md): capacity and measured completed-frame costs.

Continue with [Tiled maps](../tiled/index.md), [Building interfaces](../ui/index.md),
and [the graphics API](tecs.gfx).
