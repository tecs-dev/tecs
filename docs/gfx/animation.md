---
description: "Sprite sheets, fixed-step playback, Aseprite slices, pivots, and reloads."
---

# Animation

Sprite sheets, fixed-step playback, Aseprite slices, pivots, and reloads.

A [`Sheet`](tecs.gfx.sheet.Sheet) divides one image into frames and
names frame ranges with tags. An
[`Animation`](tecs.gfx.animation.Animation) selects a sheet tag and
carries speed, loop, and playback state.

```nupp
local hero = tecs.gfx.sheet.grid({
    name = "hero",
    imageWidth = 256,
    imageHeight = 32,
    frameWidth = 32,
    frameHeight = 32,
    tags = {
        idle = {from = 1, to = 4},
        run = {from = 5, to = 8},
    },
})

hero:bind(tecs.gfx.images.id("sprites/hero"))
tecs.gfx.animation.plugin(world)

world:spawn(
    tecs.ecs.Transform2D(64, 64, 0, 1, 0, 32, 32),
    hero:sprite(),
    tecs.gfx.animation.of(hero, "run"),
    tecs.gfx.Renderable2D
)
```

Playback advances in fixed steps on the GPU. A shared sheet/tag/slice table
resolves UVs and moving pivots without rewriting every animated entity or
uploading instances each frame. Machines that replay the same simulation
therefore select the same frames. `frameOf` and `timeOf` report playback on
the same fixed-step clock.

## Sheet sources

Use `tecs.gfx.sheet.grid` for uniform cells, `rects` for an explicit frame
list, `build` for a custom sheet, or `fromAseprite` for an
Aseprite JSON export. Frames count from one. Tags name inclusive frame spans
and may play forward, reverse, or ping-pong.

Bind a sheet to a resident image ID before drawing it. Every entity playing that
sheet shares its frame and timing data.

## Slices and pivots

Aseprite slices may move between frames. Spawn `hero:pivot("feet")` with the
sprite and animation to keep the selected slice anchored at `Transform2D`.
The GPU applies each frame's pivot and culls against the full cycle's reach.
For a fixed normalized anchor, use `tecs.gfx.Pivot(x, y)`; `(0.5, 0.5)` is centered.
`sheet:pivotOf(sliceId, frame)` also returns a pivot for hands, muzzles or other
gameplay attachments.

## Reloads

`tecs.gfx.sheet.replace` can replace its frame, tag, slice, and
timing data in place. Existing entities retain the sheet id and continue from
their playback state. A replacement must preserve the bound image dimensions.

## Observing playback

`timeOf(world, entity)` and `frameOf(world, entity)` resolve the same fixed clock
as the shader. Add `AnimationEvents` only to entities whose `Looped` or
`Completed` events game code needs. Unwatched one-shots clamp to their last
frame on the GPU. Watched one-shots also clear `playing` when reporting completion.

Snapshots store live phases and sheet names, then rebuild process-local playback
IDs on load. Register sheets before restoring the world. Clean animations keep
their instance buffers even while their visible frames change.
