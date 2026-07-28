---
description: "Turns a world into a frame, through an extractor that builds a frame packet and a backend that draws it"
outline: deep
---

# Renderer

`tecs.Renderer` is the path from a world to the GPU. It owns two halves that never see each other's concerns: an
extractor, which is world-facing and turns a world into a frame packet, and a backend, which is device-facing and
turns that packet into a frame. The packet is the only thing that crosses between them.

Rendering is deferred and GPU-driven. A compute pass culls and compacts a visible list, one indirect draw consumes
it, and the material dispatch is compiled into a single fragment shader. Compaction is an ordered three-pass scan
rather than an atomic append, because draw order has to be deterministic.

::: warning This page is pending
A post-compose seam has just landed and views are being designed. Writing the reference today would mean writing
it twice, so this page carries the shape of the module and nothing that is about to move.

Read `src/tecs/Renderer.tl`, `src/tecs/Extractor.tl`, `src/tecs/Backend.tl` and `src/tecs/FramePacket.tl` for the
current surface.
:::

## Requiring it

```teal
local tecs <const> = require("tecs")
```

## What feeds it

Everything the renderer draws is an entity in a world. The components it reads are documented at
[`/modules/components`](/modules/components), and the modules that produce them have their own pages:

- [`Camera`](/modules/Camera), the view it draws from
- [`layers`](/modules/layers), z-ordering and per-layer behaviour
- [`sheet`](/modules/sheet) and [`animation`](/modules/animation), sprite sheets and playback
- [`text`](/modules/text), distance-field text drawn through an instance producer
- [`particles`](/modules/particles), emitters
- [`materials`](/modules/materials), the material a draw dispatches to

## Also pending here

Transform interpolation between fixed simulation samples is live (the `PreviousTransform` component and the
extractor's alpha), but the surface that exposes it is part of the same rework. It will be documented here once
the seam settles.

## Design record

- [GPU-driven by default](https://github.com/tecs-dev/tecs/blob/main/README.md#gpu-driven-by-default)
- [The pass graph](https://github.com/tecs-dev/tecs/blob/main/README.md#the-pass-graph)
- [The seam between composite and present](https://github.com/tecs-dev/tecs/blob/main/README.md#the-seam-between-composite-and-present)
- [Buffer writes](https://github.com/tecs-dev/tecs/blob/main/README.md#buffer-writes)
- [The shader pipeline](https://github.com/tecs-dev/tecs/blob/main/README.md#the-shader-pipeline)
