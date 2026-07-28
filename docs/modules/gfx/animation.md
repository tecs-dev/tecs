---
description: "Sprite sheets and the playback that reads them: frames, tags, slices and pivots, the Animation component, and where a frame is resolved"
outline: deep
---

# tecs.gfx.animation

An image divided into frames, and the playback that walks them. Both halves are here because they are one
subject: a game that draws sprite sheets builds one and plays it, and having to know that constructing and
playing lived in different modules bought it nothing.

The sheet model is Aseprite's, because that is what the art is authored in: a list of frames each holding
for its own duration, a set of named tags that play an inclusive span of them in a direction, and a set of
named slices carrying rectangles, nine-slice centers and pivots that move from frame to frame. Reading an
Aseprite JSON sidecar is one function in front of that model rather than the model itself, so another
reader for the binary format populates the same sheet without reshaping anything. `animation.grid` and
`animation.rects` are the same builder with a loop in front.

A sheet is data, not a component. A hundred entities drawing the same character share one sheet and point
at it, so what an entity carries is the sheet's id rather than a copy of its frame table. An `Animation`
says which tag of a sheet is playing, how fast, whether it repeats, whether it is running, and where in
the tag it has got to.

Playback is quantised to the fixed step, because animation is simulation. Two machines fed the same
recording have to show the same frame, and a system driven by frame time shows a different one on the
machine that drew more frames.

## Frames, tags and slices

Frames are addressed by index, counting from one, in the order the sheet lays them out: for a grid that
is left to right and then top to bottom. A tag is an inclusive span of those indices, and that is what an
animation plays. Tag zero is the whole sheet, forward, which is what an animation naming no tag plays.

Timing is per frame rather than per entity, which is the thing a single frames-per-second number cannot
express: a hold frame is a frame with a long duration, and that is how an artist writes one. Durations
are authored in milliseconds because Aseprite writes milliseconds, and converted to seconds once when the
sheet is built so playback never divides. `animation.DEFAULT_DURATION` is `100`, the milliseconds Aseprite
writes for a frame nobody retimed.

### Direction

`animation.Direction` is an enum of three strings, and it is spent when the sheet is built rather than at
every step of playback: what comes out is the frames in the order they are shown and the second each one
ends on, so finding the current frame is a scan of numbers and never a branch on direction.

| Direction    | What the tag plays                                                                                           |
| ------------ | ------------------------------------------------------------------------------------------------------------ |
| `"forward"`  | `from` to `to`, in order. The default.                                                                       |
| `"reverse"`  | `to` down to `from`.                                                                                         |
| `"pingpong"` | Forward and then back without repeating either end, so a three-frame tag is 1, 2, 3, 2 and then round again. |

### Two coordinate spaces

A frame is written in pixels, because that is how an artist cuts an image up. What a
[`Sprite`](/modules/gfx/) carries is a region of a texture-array layer, which is the fraction of
the image the frame covers scaled by the fraction of the layer the image itself covers. That second
fraction is the renderer's answer, so a sheet holds pixels until [`bind`](#bind) hands it one. Before
`bind`, a frame's region is its plain fraction of the image, which is what a sheet can say without a
renderer and what makes one testable headless.

## Constructing a sheet

### grid

A sheet whose frames are the cells of a uniform grid.

```teal
function animation.grid(options: GridOptions): Sheet
```

Margin surrounds the grid and spacing separates the cells, so a cell's left edge is
`margin + column * (frameWidth + spacing)`. Both default to zero, which is an image cut with nothing
between its cells. Frames come out in row-major order.

**Parameters:**

- `options`: raises on a missing name, a non-positive image or frame size, a grid that fits no cells, or
  a `count` past what the grid holds.

**Returns:** the finished sheet, already registered under its name and carrying an `id`.

**`GridOptions` fields:**

| Field         | Type            | Default                     | Description                                                                                                                               |
| ------------- | --------------- | --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `name`        | `string`        | required                    | Name to register the sheet under.                                                                                                         |
| `imageWidth`  | `number`        | required                    | Size of the image the grid is cut from, in pixels.                                                                                        |
| `imageHeight` | `number`        | required                    | Size of the image the grid is cut from, in pixels.                                                                                        |
| `frameWidth`  | `number`        | required                    | Size of one cell, in pixels.                                                                                                              |
| `frameHeight` | `number`        | required                    | Size of one cell, in pixels.                                                                                                              |
| `margin`      | `number`        | `0`                         | Border between the image's edge and the first cell.                                                                                       |
| `spacing`     | `number`        | `0`                         | Gap between neighboring cells.                                                                                                            |
| `columns`     | `integer`       | derived from the image size | Cells across.                                                                                                                             |
| `rows`        | `integer`       | derived from the image size | Cells down.                                                                                                                               |
| `count`       | `integer`       | `columns * rows`            | Frames to take, counting across rows. The default is wrong only for a sheet whose last row is short.                                      |
| `duration`    | `number`        | `DEFAULT_DURATION`          | Milliseconds every cell is held. A grid is one duration for every frame by construction; retime individual frames with `animation.build`. |
| `tags`        | `{string: Tag}` | none                        | Named tags over the frames.                                                                                                               |
| `slices`      | `{Slice}`       | none                        | Named slices.                                                                                                                             |

**Example:**

```teal
local walk <const> = tecs.gfx.animation.grid({
    name = "hero.png",
    imageWidth = 256,
    imageHeight = 64,
    frameWidth = 32,
    frameHeight = 32,
    tags = {
        idle = { from = 1, to = 4 },
        walk = { from = 5, to = 12, direction = "pingpong" },
    },
})
```

### rects

A sheet whose frames are listed one rect at a time.

```teal
function animation.rects(options: RectsOptions): Sheet
```

For an image no grid describes: frames of differing sizes, or an atlas whose cells a packing tool placed.

**Parameters:**

- `options`: raises on a missing name, a non-positive image size, an empty frame list, or a frame with no
  positive size. Rects are not checked against the image, so one that runs off the edge samples whatever
  the layer holds there.

**Returns:** the finished sheet, already registered under its name and carrying an `id`.

**`RectsOptions` fields:**

| Field         | Type            | Default  | Description                                             |
| ------------- | --------------- | -------- | ------------------------------------------------------- |
| `name`        | `string`        | required | Name to register the sheet under.                       |
| `imageWidth`  | `number`        | required | Size of the image the rects are cut from, in pixels.    |
| `imageHeight` | `number`        | required | Size of the image the rects are cut from, in pixels.    |
| `frames`      | `{Rect}`        | required | Frame rects in pixels, in the order they are addressed. |
| `tags`        | `{string: Tag}` | none     | Named tags over the frames.                             |
| `slices`      | `{Slice}`       | none     | Named slices.                                           |

**`Rect` fields:** `x`, `y`, `w`, `h`, and `duration` in milliseconds, which defaults to
`animation.DEFAULT_DURATION`.

**`Tag` fields:** `from` and `to`, both inclusive frame indices counting from one, and `direction`, which
defaults to `"forward"`.

### fromAseprite

A sheet read from an Aseprite JSON export.

```teal
function animation.fromAseprite(options: AsepriteOptions): Sheet
```

Frames, their durations, frame tags with their directions, and slices with their keys all land in the
sheet the builder writes. Aseprite counts frames from zero and this model counts from one, so the span
moves by one at the boundary and nowhere else.

Both of Aseprite's frame layouts are read, the array and the object keyed by frame name, the second in
sorted name order, because the names carry the frame number.

**`AsepriteOptions` fields:**

| Field  | Type     | Default                     | Description                                                                                                                                 |
| ------ | -------- | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `name` | `string` | the export's own image name | Name to register the sheet under. Required when the export does not carry one.                                                              |
| `json` | `any`    | required                    | The export, either as the JSON text or as a table already decoded from it. A table is what an asset pipeline that decoded once should pass. |

::: warning Export with trimming off
Trimmed exports are not read: `spriteSourceSize` is ignored, so the frames land in the wrong place.
:::

**What the export has to carry:**

| Aseprite export option   | Why                                                                                                          |
| ------------------------ | ------------------------------------------------------------------------------------------------------------ |
| JSON Data, Array or Hash | Both layouts are read. A hash is put back in order by sorting the frame names, which carry the frame number. |
| Meta > Frame Tags        | Where tags come from. Without them the sheet has only tag zero, the whole sheet forward.                     |
| Meta > Slices            | Where slices and their pivots come from. Optional, and needed for `Sheet:pivot`.                             |
| Trim off                 | `spriteSourceSize` is ignored, so a trimmed frame's rect no longer describes where the drawing sits.         |

The layout itself is free: frames are read as explicit rects, so a horizontal strip, a vertical strip and a
packed sheet all read the same. The export's `meta.size` is what the sheet takes its image size from, and a
missing one raises.

Nothing else is read from the export, and nothing beside it: the sheet is one image cut into frames, and
companion textures are not part of the model.

**Example:**

```teal
local text <const> = tecs.filesystem.read("hero.json")
local hero <const> = tecs.gfx.animation.fromAseprite({ json = text })
```

### build

A builder, for a sheet no constructor above describes.

```teal
function animation.build(name: string, imageWidth: number, imageHeight: number): Builder
```

The model is what the builder writes, so an atlas from any tool reaches the same sheet an Aseprite export
does. Frames, tags and slices are added in any order and the sheet is registered by `finish`.

**Parameters:**

- `name`: name to register the finished sheet under.
- `imageWidth`: size of the image the frames are cut from, in pixels.
- `imageHeight`: size of the image the frames are cut from, in pixels.

**Returns:** a builder whose methods chain.

## Builder

### Builder:frame

Appends a frame.

```teal
function Builder:frame(x: number, y: number, w: number, h: number, duration?: number): Builder
```

**Parameters:**

- `x`: left of the frame in the image, in pixels.
- `y`: top of the frame.
- `w`: width, which must be positive.
- `h`: height, which must be positive.
- `duration`: milliseconds it is held, defaulting to `animation.DEFAULT_DURATION`.

**Returns:** the builder.

### Builder:tag

Names an inclusive span of frames and how it walks them.

```teal
function Builder:tag(name: string, from: integer, to: integer, direction?: Direction): Builder
```

**Parameters:**

- `name`: what an animation asks for.
- `from`: first frame, counting from one.
- `to`: last frame, inclusive.
- `direction`: defaults to `"forward"`.

**Returns:** the builder.

### Builder:slice

Adds a slice that never moves, with a pivot.

```teal
function Builder:slice(name: string, x: number, y: number, w: number, h: number,
                       pivotX?: number, pivotY?: number): Builder
```

**Parameters:**

- `name`: what a sprite names to take its pivot from.
- `x`: left of the slice within a frame, in pixels.
- `y`: top of the slice.
- `w`: width.
- `h`: height.
- `pivotX`, `pivotY`: pivot within the slice, in the slice's own pixels. Omitted, the slice carries no
  pivot and its middle stands in.

**Returns:** the builder.

### Builder:sliceKeys

Adds a slice with its keys written out, which is what an importer uses.

```teal
function Builder:sliceKeys(name: string, data: string, keys: {SliceKey}): Builder
```

**Parameters:**

- `name`: the slice's name.
- `data`: free text to carry alongside it, or nil for none.
- `keys`: keys in frame order, at least one.

**Returns:** the builder.

### Builder:finish

Registers the sheet and hands it back.

```teal
function Builder:finish(): Sheet
```

Raises on a sheet with no frames, and on a tag whose span falls outside them.

**Example:**

```teal
local sheet <const> = tecs.gfx.animation.build("banner.png", 128, 64)
    :frame(0, 0, 64, 64, 250)
    :frame(64, 0, 64, 64)
    :tag("flash", 1, 2, "pingpong")
    :slice("hand", 40, 12, 8, 8, 4, 4)
    :finish()
```

## The Sheet

### Fields

| Field         | Type      | Description                                                                                                                                                                                      |
| ------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `name`        | `string`  | Name the sheet is registered under, and what a snapshot writes.                                                                                                                                  |
| `id`          | `integer` | Registration index, which is what an `Animation` carries. Assigned when the sheet is built and never reused, so a second sheet built under a taken name gets a fresh id rather than the old one. |
| `count`       | `integer` | Number of frames, and so the largest index `rect`, `uv` and `sprite` accept.                                                                                                                     |
| `imageWidth`  | `number`  | Size of the image the frames are cut from, in pixels.                                                                                                                                            |
| `imageHeight` | `number`  | Size of the image the frames are cut from, in pixels.                                                                                                                                            |

::: warning
Frame rects are measured against `imageWidth` and `imageHeight`, so a sheet cut for one image and bound
to another of a different size places its frames wrongly with no complaint.
:::

### Sheet:rect

A frame's pixel rect.

```teal
function Sheet:rect(frame: integer): number, number, number, number
```

**Parameters:**

- `frame`: one to `count`. Anything else raises, since a frame index out of range is a sheet and an
  animation disagreeing rather than something to paper over.

**Returns:** the rect's left, top, width and height, in the pixels of the image the sheet was cut from.

### Sheet:duration

How long a frame is held, in seconds.

```teal
function Sheet:duration(frame: integer): number
```

**Parameters:**

- `frame`: one to `count`. Anything else raises.

**Returns:** seconds, which is the milliseconds the frame was authored with divided by a thousand.

### Sheet:uv

A frame's region.

```teal
function Sheet:uv(frame: integer): number, number, number, number
```

**Parameters:**

- `frame`: one to `count`. Anything else raises.

**Returns:** the region's left, top, right and bottom edges: fractions of the image before `bind` and of
the texture-array layer after it, which is the pair of numbers a `Sprite` wants.

### Sheet:hasTag

True when the sheet names the given tag.

```teal
function Sheet:hasTag(name: string): boolean
```

`nil` answers false rather than raising, so this is what to ask before `tag`.

### Sheet:tag

The first frame, last frame and direction of a named tag.

```teal
function Sheet:tag(name: string): integer, integer, Direction
```

Fails on a name the sheet does not carry, because the alternative is an animation silently playing the
whole sheet on a typo.

### Sheet:tagId

Index a tag name stands for, or zero when the sheet does not name it.

```teal
function Sheet:tagId(name: string): integer
```

Zero reads as the whole sheet rather than as nothing, so an animation that names no tag plays every frame
in order.

::: info Ids are this sheet's answer alone
Ids follow the tag names in sorted order, so the same name in another sheet is another number. That is
why a snapshot writes the name.
:::

### Sheet:tagName

Name a tag index stands for, or the empty string for the whole sheet.

```teal
function Sheet:tagName(id: integer): string
```

Nil, zero and anything the sheet does not carry all answer the empty string.

### Sheet:cycle

Seconds one pass through a tag's cycle takes.

```teal
function Sheet:cycle(id: integer): number
```

**Parameters:**

- `id`: a tag index, or zero for the whole sheet.

**Returns:** the sum of the durations of the frames the cycle visits, which for a pingpong tag counts the
frames it passes twice twice.

### Sheet:frameAt

The frame a tag is showing at a point in its cycle.

```teal
function Sheet:frameAt(id: integer, time: number): integer
```

**Parameters:**

- `id`: a tag index, or zero for the whole sheet.
- `time`: seconds into the cycle. Outside it clamps rather than wrapping, since wrapping is the caller's
  decision about looping.

**Returns:** a frame index into the whole sheet, counting from one.

## Slices and pivots

Slices are where pivots come from, rather than an origin API invented beside them. Aseprite's slices
carry hitboxes, attachment points and nine-patch borders; the engine reads pivots out of them, and
everything else is the game's to use.

A slice holds a key until the next one, so a slice that never moves is one key at frame one.

**`Slice` fields:**

| Field  | Type         | Description                                   |
| ------ | ------------ | --------------------------------------------- |
| `name` | `string`     | What a sprite names to take its pivot from.   |
| `data` | `string`     | Free text Aseprite carries alongside a slice. |
| `keys` | `{SliceKey}` | Keys in frame order, at least one.            |

**`SliceKey` fields:**

| Field                                      | Type      | Description                                                                                                                  |
| ------------------------------------------ | --------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `frame`                                    | `integer` | Frame this key takes effect from, counting from one.                                                                         |
| `x`, `y`, `w`, `h`                         | `number`  | The slice's rectangle, in the pixels of the frame it sits on.                                                                |
| `centerX`, `centerY`, `centerW`, `centerH` | `number`  | Nine-slice center, in the slice's own pixels. Nil for a slice with no center, which is every slice that is not a nine-patch. |
| `pivotX`, `pivotY`                         | `number`  | Pivot, in the slice's own pixels. Nil for a slice with no pivot.                                                             |

### Sheet:slice

A slice by name, or nil when the sheet does not carry one. The keys must not be mutated.

```teal
function Sheet:slice(name: string): Slice
```

### Sheet:sliceId

Index a slice name stands for, or zero when the sheet does not name it.

```teal
function Sheet:sliceId(name: string): integer
```

This is what a component carries in place of the name, for the reason a tag id is. Slice ids follow the
slices in the order they were given.

### Sheet:sliceName

Name a slice index stands for, or the empty string.

```teal
function Sheet:sliceName(id: integer): string
```

### Sheet:sliceKeyAt

The key of a slice that is in force on a frame, or nil.

```teal
function Sheet:sliceKeyAt(id: integer, frame: integer): SliceKey
```

A slice holds a key until the next one, so this answers the last key at or before the frame rather than
only an exact match.

**Parameters:**

- `id`: a slice index from `sliceId`. Zero answers nil.
- `frame`: a frame index.

### Sheet:pivotOf

Where a slice's pivot sits on a frame, as a fraction of that frame.

```teal
function Sheet:pivotOf(id: integer, frame: integer): number, number
```

Aseprite writes a pivot in the slice's own pixels, so this adds the slice's origin and divides by the
frame, which is the number a quad wants: nothing downstream has to know the sheet's pixel sizes.

**Returns:** the pivot's x and y as fractions of the frame, from its top left.

What is answered when the key names no pivot:

| Case                                                                       | Answer                                                                                |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| A key with a pivot                                                         | The pivot.                                                                            |
| A key with a nine-slice center but no pivot                                | The middle of that center.                                                            |
| A key with neither                                                         | The middle of the slice's rectangle.                                                  |
| Slice zero, a slice the sheet does not carry, or a frame it has no key for | `0.5, 0.5`, the middle of the frame, which is where a quad sits with no pivot at all. |

### Sheet:pivot

A `Pivot` resolved from a named slice, ready to spawn.

```teal
function Sheet:pivot(name: string, frame?: integer): Pivot
```

Bound to the slice as well as resolved from it, so playback moves the pivot as the frame changes rather
than leaving it where the frame it was built from put it.

**Parameters:**

- `name`: a slice this sheet carries. Fails on a name it does not, for the reason `tag` does: the
  alternative is a typo that silently pivots on the middle.
- `frame`: the frame to resolve it at, defaulting to the first. That is what an entity shows before its
  first step, and what a sheet with no `Animation` keeps.

**Returns:** a component value, not an entity.

## The Pivot component

`animation.Pivot` is where an entity's quad turns and scales about. A quad with no `Pivot` turns about its
center, so a character rotates about its waist and a scale grows it in both directions at once. A quad
with one turns about the point the pivot names, and the entity's `Transform` position is where that point
lands: a character pivoted at its feet stands at its position instead of hovering half a body above it.

The point is a fraction of the frame rather than a distance in pixels, because that is what an artist
places in Aseprite and what `pivotOf` answers. A frame that changes size therefore carries its pivot with
it.

The depth sort still runs on the entity's position, which is the whole reason a pivot at the feet is
worth having: two characters standing on the same line sort together however tall either drawing is.

| Field   | Type     | Default | Description                                                                                         |
| ------- | -------- | ------- | --------------------------------------------------------------------------------------------------- |
| `x`     | `number` | `0.5`   | Fraction across the frame, from its left edge. Half is the middle.                                  |
| `y`     | `number` | `0.5`   | Fraction down the frame, from its top edge. Half is the middle.                                     |
| `sheet` | `number` | `0`     | Registration index of the sheet the slice belongs to, or zero.                                      |
| `slice` | `number` | `0`     | Index of the slice within that sheet, from `Sheet:sliceId`, or zero for a pivot written directly.   |
| `halfX` | `number` | `0`     | How far the point can move over the cycle being played, as half the range, a fraction of the frame. |
| `halfY` | `number` | `0`     | The same in y.                                                                                      |

`sheet` and `slice` are what the fraction was resolved from. A slice moves from frame to frame, so
playback resolves it again on every frame change, and it only does so while the slice belongs to the
sheet the entity is playing: a frame index means nothing in another sheet's frames. Both zero is a pivot
written directly, which nothing rewrites.

`halfX` and `halfY` are zero for a pivot written directly and for a slice with a single key, which is
nearly every one of them, and the cull bound is then exactly the quad's own. Playback on the GPU resolves
the frame after the bound is written, so a slice that genuinely moves has to have its travel covered: `x`
and `y` are then the middle of where it goes and the halves are how far either side of that the quad can
be drawn. See [animation](/modules/gfx/animation#the-pivot-that-follows-a-moving-slice).

A snapshot carries the sheet's name and the slice's name alongside the fraction, and they are resolved
again on the way back in. The travel is deliberately dropped: it is playback's answer rather than the
entity's, and the first step after a load writes it from the registration this run made.

::: info Why the component lives here
A `Pivot` is resolved from a slice, and a slice index is one sheet's answer alone, so writing the name a
snapshot carries needs this module's registry. Putting the component in `tecs.gfx` would point
that module at this one, which already points the other way.
:::

## Binding to an image

### bind

Resolves the sheet's frames against a registered image.

```teal
function Sheet:bind(sprite: Sprite): Sheet
```

**Parameters:**

- `sprite`: a whole image. Its `u1` and `v1` are the fractions of the texture-array layer that image
  occupies, and a frame's fraction of the image has to be scaled by them before it names a region of the
  layer. Pass a sub-rect and the frames land inside that sub-rect, which is not what the sheet describes.

**Returns:** the sheet, so a bind can be chained onto the construction.

Binding again rescales from the pixel rects rather than from the last result, so a sheet survives its
image being registered a second time. Entities already carrying regions from an earlier bind keep them: a
rebind moves nothing that has already been written into a `Sprite`.

The whole-image sprite comes from the [Renderer](/modules/gfx/).

### Sheet:sprite

A `Sprite` showing one frame, ready to spawn.

```teal
function Sheet:sprite(frame?: integer): Sprite
```

**Parameters:**

- `frame`: one to `count`, defaulting to one. Anything else raises.

**Returns:** a fresh `Sprite`, which is a value the caller owns rather than a view onto the sheet.

Meaningful after `bind`, since before it the sheet names no image and the quad has no layer to sample.

## The registry

Every constructor registers the sheet it builds, under its name and under a fresh id.

### findSheetById

The sheet a registration index stands for, or nil.

```teal
function animation.findSheetById(id: integer): Sheet
```

Ids are handed out in construction order, so one is only meaningful within a run.

### findSheetByName

The sheet registered under a name, or nil.

```teal
function animation.findSheetByName(name: string): Sheet
```

Building a second sheet under a name already taken replaces what this returns, so a reload points new
entities at the new sheet. Entities already carrying the old id keep drawing the old one, which is what
stops a reload from pulling a frame out from under them.

### replace

Folds a freshly built sheet into the one already registered under its name, keeping the old sheet's id.

```teal
function animation.replace(built: Sheet): Sheet, string
```

The reverse of what building under a taken name does, and it exists because a reload wants the reverse.
Building again answers new entities with the new sheet and leaves every entity already playing on the old
one, which is right for two sheets that happen to share a name and wrong for one file that was
re-exported. This overwrites in place instead, so an `Animation` holding the id goes on playing and shows
the new frames on its next step, with nothing in the world touched.

**Parameters:**

- `built`: a sheet from any constructor here, registered moments ago under a name something else already
  holds.

**Returns:** the live sheet and nil, or nil and the reason it was refused.

The refusals are the same ones a shader reload makes, for the same reason: a component holds an index
into this sheet, so anything that renumbers one is refused rather than half applied. Tag ids follow the
tag names in sorted order and slice ids follow the slices, so adding, removing or renaming either is a
restart. Frames are free to change: what an entity carries is a tag and a time, and the frame is resolved
from the cycle on every step.

The bind is carried over. A sheet re-exported over the same image is already bound to the right layer, so
its frames are rescaled against the region the old sheet held rather than needing `bind` called again.

::: warning The sheet handed in is spent
Its id resolves to the live sheet rather than to itself, because the two share their frame tables once
the fold is done and only one of them may be bound.
:::

**Example:**

```teal
local rebuilt <const> = tecs.gfx.animation.fromAseprite({ json = text })
local live <const>, why <const> = tecs.gfx.animation.replace(rebuilt)
if live == nil then
    LOGGER:warn("sheet reload refused: %s", why)
end
```

### sheetRevision

How many times any sheet's frames have changed.

```teal
function animation.sheetRevision(): integer
```

Bumped by registration and by `bind`, both of which move where a frame's region points. Anything holding
a copy of those regions compares this against what it copied from rather than being told, which keeps the
dependency running one way: a sheet knows nothing about who read it.

**Returns:** a number that only ever increases.

## Installing the systems

### plugin

Adds the system that advances playback.

```teal
function animation.plugin(world: World)
```

Not installed for you, so a world that draws no sprite sheets pays nothing for the query. Call it once; a
second call on the same world is ignored, because adding a system twice under one name is an error.

**Parameters:**

- `world`: the world to add the system to.

**Example:**

```teal
local world <const> = tecs.ecs.newWorld()
world:addPlugin(tecs.gfx.animation.plugin)
```

Which systems this installs depends on [`useGPU`](#usegpu):

| Path         | Systems                                             | Phase             |
| ------------ | --------------------------------------------------- | ----------------- |
| GPU, default | `tecs.EncodeAnimation`, then `tecs.ReportAnimation` | `PostUpdate`      |
| Host         | `tecs.AdvanceAnimation`                             | `FixedPostUpdate` |

`tecs.EncodeAnimation` writes nothing on a step where nothing changed what is playing.
`tecs.ReportAnimation` derives `Completed` and `Looped` for the entities carrying `AnimationEvents` and
writes nothing at all beyond the flag a finished one-shot parks behind. `tecs.AdvanceAnimation` runs on a
logic query, so a paused entity holds the frame it is on, and `FixedPostUpdate` is late enough that
gameplay logic in `FixedUpdate` has already chosen what should be playing.

## The Animation component

An entity also needs a [`Sprite`](/modules/gfx/), which is what the query matches on and what
playback writes into. An `Animation` on its own advances nothing.

| Field     | Type      | Default | Description                                                                                                                                                                                                   |
| --------- | --------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sheet`   | `number`  | `0`     | Registration index of the sheet, from `Sheet.id`. Zero plays nothing.                                                                                                                                         |
| `tag`     | `number`  | `0`     | Index of the tag within that sheet, from `Sheet:tagId`. Zero plays the whole sheet in order.                                                                                                                  |
| `speed`   | `number`  | `1`     | Multiplier on the timing the sheet carries. One is the timing as authored, two is twice as fast. Zero or less holds the current frame and stops time advancing, which is a pause that leaves `playing` alone. |
| `time`    | `number`  | `0`     | Seconds into the cycle, which is the sum of the durations of the frames the tag visits.                                                                                                                       |
| `frame`   | `number`  | `0`     | Frame the `Sprite` currently shows, or zero for none yet.                                                                                                                                                     |
| `loop`    | `boolean` | `true`  | Whether the tag restarts after its last frame.                                                                                                                                                                |
| `playing` | `boolean` | `true`  | Whether time advances.                                                                                                                                                                                        |

How long each frame is held is the sheet's answer and not an entity's, because that is where an artist
sets it: a hold frame is a frame with a long duration, which no single rate can express. Changing `speed`
leaves `time` where it is, so playback carries on from the frame it was showing rather than jumping.

`time` stays inside the cycle: a looping animation wraps and a one-shot parks at the end, so it never
grows without bound and never loses precision to its own age.

`frame` is the frame the `Sprite` was last written from, as an index into the whole sheet rather than
into the tag. Zero means nothing has been written yet, which is how a fresh or restored `Animation` gets
its region on the first step it runs instead of drawing whatever the `Sprite` held.

::: info With playback on the GPU
`frame` stops being an index and keeps only the zero: the encoder writes a value no sheet numbers a frame
to say the `Sprite` carries a live playback, and zero still means the entity is to start its cycle again.
`time` stops being written too. Which frame is showing is [`frameOf`](#frameof) on either path.
:::

A snapshot carries the sheet's name and the tag's name rather than their indices, and resolves them again
on the way back in. The frame is deliberately dropped: zero makes the first step rewrite the region, so a
restored entity does not depend on the region its `Sprite` was saved holding.

## Authoring

### of

An `Animation` playing a named tag of a sheet, ready to spawn.

```teal
function animation.of(source: Sheet, tag?: string, options?: PlayOptions): Animation
```

**Parameters:**

- `source`: the sheet to play. Nil raises.
- `tag`: a tag the sheet names, or nil for the whole sheet in order. Fails on a tag the sheet does not
  carry, since the alternative is a typo that plays every frame.
- `options`: defaults are the sheet's own timing, looping, and playing.

**Returns:** a component value, not an entity: pass it to `world:spawn` or `world:set` yourself.

**`PlayOptions` fields:**

| Field     | Type      | Default | Description                                    |
| --------- | --------- | ------- | ---------------------------------------------- |
| `speed`   | `number`  | `1`     | Multiplier on the sheet's own timing.          |
| `loop`    | `boolean` | `true`  | Whether the tag restarts after its last frame. |
| `playing` | `boolean` | `true`  | Whether it starts running.                     |

**Example:**

```teal
local animation <const> = tecs.gfx.animation
local gfx <const> = tecs.gfx

local hero <const> = world:spawn(
    tecs.Transform(200, 140),
    gfx.Renderable,
    heroSheet:sprite(),
    animation.of(heroSheet, "walk"),
    heroSheet:pivot("feet")
)
```

### play

Points a live entity at a tag and restarts it there.

```teal
function animation.play(world: World, entity: integer, source: Sheet, tag?: string, options?: PlayOptions)
```

Restarting is the point: time and frame both reset, so the next step writes the tag's first frame whatever
the entity was showing. An entity carrying no `Animation` gets one.

**Parameters:**

- `world`: the world the entity lives in.
- `entity`: a live entity, which needs a `Sprite` for playback to reach it.
- `source`: the sheet to play. Nil raises.
- `tag`: a tag the sheet names, or nil for the whole sheet.
- `options`: defaults are the sheet's own timing, looping, and playing.

**Example:**

```teal
tecs.gfx.animation.play(world, hero, heroSheet, "attack", { loop = false })
```

### restart

Plays an entity's animation again from the start of its tag.

```teal
function animation.restart(world: World, entity: integer): boolean
```

The sheet, tag, speed and loop flag are left as they are; what resets is where in the cycle playback has
got to and whether it is running. For replaying a one-shot that has finished, and for rewinding one that
has not.

**Returns:** whether there was an `Animation` to restart. False leaves the entity untouched, since there
is nothing to say what it would play.

### Finding a parked one-shot playing

A tag that does not loop parks at the end of its cycle and stops. Finding one there and playing means
something set `playing` back to true, which reads as asking for the animation again, so it starts over.
Advancing from the end instead would park it again on that step and on every step after it, emitting
`Completed` each time. Both paths behave this way.

## Events

`animation.Completed` is emitted on the step a tag that does not loop runs past its last frame. The
animation stops and holds that frame, so it fires once per playthrough and never again until something
restarts it.

`animation.Looped` is emitted on the step a looping tag passes its last frame and restarts. Once per step
at most, not once per cycle: a step long enough to cover several cycles wraps the time once and reports
one loop, so counting these is not a way to count playthroughs.

Both are emitted at address zero, with these fields:

| Field    | Type      | Description                                             |
| -------- | --------- | ------------------------------------------------------- |
| `entity` | `integer` | The entity whose animation finished or wrapped.         |
| `sheet`  | `Sheet`   | The sheet it is playing.                                |
| `tag`    | `string`  | Name of the tag, or the empty string for a whole sheet. |

**Example:**

```teal
local animation <const> = tecs.gfx.animation

world:observe(0, animation.Completed, function(event: animation.Completed)
    if event.tag == "attack" then
        animation.play(world, event.entity, heroSheet, "idle")
    end
end)
```

### AnimationEvents

`animation.AnimationEvents` is a marker component that asks for `Completed` and `Looped` on an entity
when playback resolves on the GPU. Nothing is emitted for an entity that does not carry it, and the
reason is the archetype: a crowd of animating entities is visited by no query at all while the handful a
game listens to sit together and are walked on their own. Adding it costs an archetype move once and
nothing per step.

With playback resolved on the host the events are emitted whether or not this is carried, since the
system that advances the frame is already looking at the row when it wraps.

::: warning A one-shot only parks if something asked
On the GPU path, `playing` is what parks a finished one-shot and `Completed` is what clears `playing`.
With no `AnimationEvents` on the entity it stays true, so past its end and playing reads as asked-again
and the entity starts over. Carrying `AnimationEvents` parks it and holds it on the last frame.
:::

## Asking what an entity is showing

Both queries recompute on the call, against the same tick tables the shader reads, through the
`Sheet:frameAt` that already exists. No walk, no column and no readback. Keeping the answer in a column
instead means writing every animating entity on every step, and that is the cost the GPU path exists to
remove.

A few hundred calls a step is free; it stops being free somewhere in the tens of thousands, which is a
game asking a question this is the wrong shape for.

### frameOf

The sheet frame an entity's animation is showing.

```teal
function animation.frameOf(world: World, entity: integer): integer
```

**Returns:** a frame index into the whole sheet, counting from one, or zero for an entity with nothing to
play.

The same answer the vertex shader draws, because both are `frameAt` over the same tag: the shader reads a
table built from it and this calls it. What a hitbox on frame five, a footstep on frame three or a muzzle
on an animated hand asks for.

**Example:**

```teal
if tecs.gfx.animation.frameOf(world, hero) == 3 then
    footstep()
end
```

### timeOf

How far into its tag's cycle an entity's animation has got, in seconds.

```teal
function animation.timeOf(world: World, entity: integer): number
```

**Returns:** seconds into the cycle, wrapped for a looping tag and clamped at the end for a one-shot.
Zero for an entity carrying no `Animation` and for one whose sheet this run does not have.

## Where the frame is resolved

There are two paths from an `Animation` to a picture and `useGPU` chooses between them. They agree on the
frame and differ on what they write to reach it, and `frameOf` is what answers either way.

**On, which is the default.** `tecs.EncodeAnimation` writes which playback the entity is on into its
`Sprite`, and the vertex shader resolves the frame from a shared table and the world's count of fixed
steps. A frame changing then writes nothing at all, so what a step costs is what actually changed rather
than what is shaped like it.

**Off.** `tecs.AdvanceAnimation` walks every playing animation on every fixed step. A row that lands on
the frame it was already showing writes nothing, so an archetype whose frames all stood still this step
leaves its `Sprite` column clean and the frame skips it. A row whose frame changed has the region written
into its `Sprite`, which marks the column dirty and has extraction rewrite every instance in the
archetype. So the walk is cheap and the rewrite is not: one animating sprite costs a rewrite of
everything structurally like it, which is what stops a large animated scene being affordable.

### useGPU

Chooses whether playback is resolved on the GPU.

```teal
function animation.useGPU(enabled: boolean)
```

**Parameters:**

- `enabled`: false puts playback back on the host, for a world that wants events and frame queries
  without opting in or recomputing and is small enough to pay a walk of every animation on every step.

::: warning Set it before `plugin`
It decides which systems that installs, and worlds already carrying them keep them.
:::

Three things read differently with this on:

- `Animation.frame` and `Animation.time` stop being written, and `frameOf` and `timeOf` answer from the
  clock instead.
- `Completed` and `Looped` reach only the entities carrying `AnimationEvents`, and a one-shot that
  finishes leaves `playing` alone unless something is listening for it.
- The `Sprite` carries a playback rather than a region, so its layer and image stop following the sheet:
  the frame table carries both and the shader reads them there.

The two paths anchor a fresh entity's cycle to the same step and agree frame for frame, except within a
millisecond of a boundary, which is a display difference of well under a fixed step.

### usesGPU

Whether playback resolves on the GPU.

```teal
function animation.usesGPU(): boolean
```

## Pausing

Time advances only while `playing` is true and `speed` is above zero, and the ECS builtin `Paused` holds
an entity too.

On the host path the advance runs on a logic query, so a paused entity is not visited and holds the frame
it is on. On the GPU path the world's clock does not stop for one entity, so holding is said rather than
assumed: the encoding carries a rate of zero and the tick to hold. `Paused` moves an entity to another
archetype, and a move marks every component on the destination dirty, so the freeze and the thaw both
reach the encoder without anything having to notice them.

The same re-encode is what makes a speed change hold its position: a new rate is applied from where the
cycle is rather than from where it began.

## The pivot that follows a moving slice

An entity carrying a [`Pivot`](#the-pivot-component) bound to one of the sheet's slices has
it follow the slice, because an Aseprite slice moves from frame to frame and a pivot that did not follow
it would drift off the part of the drawing it names.

On the host that is a fresh resolve on every frame the sprite changes. On the GPU the entity carries the
middle of where the slice goes over the cycle and the frame table carries each step's offset from it, so
a frame changing still writes nothing; `Pivot.halfX` and `halfY` are how far either side of that middle
the quad can be drawn, and the cull bound grows by exactly that travel.

A pivot written directly and a slice with a single key offset nothing on every frame, so their bound is
exactly the quad's own. A slice bound to another sheet is left where it is: a frame index counts through
one sheet's frames and means something else in another's.

Because two playbacks of one tag bound to two slices want different offsets for the same frame, the slice
is part of a playback's key alongside the sheet and the tag, and the `Pivot` column joins the encoder's
gate: pointing an entity at another slice changes which playback it is on and nothing about its
`Animation` moved to say so.
<!-- @generated by docs/scripts/reference.py from src/tecs/gfx/animation.tl. Do not edit below this line. -->

## Reference

Every function and type this module carries, rendered from `src/tecs/gfx/animation.tl`.

<a id="tecs.gfx.animation.Animation"></a>

### tecs.gfx.animation.Animation

<pre><code v-pre><a href="#tecs.gfx.animation.Animation">tecs.gfx.animation.Animation</a>: Animation
</code></pre>

Playback state for one entity.
<a id="tecs.gfx.animation.AnimationEvents"></a>

### tecs.gfx.animation.AnimationEvents

<pre><code v-pre><a href="#tecs.gfx.animation.AnimationEvents">tecs.gfx.animation.AnimationEvents</a>: AnimationEvents
</code></pre>

Asks for `Completed` and `Looped` on an entity.
<a id="tecs.gfx.animation.AsepriteOptions"></a>

### tecs.gfx.animation.AsepriteOptions

<pre><code v-pre>type <a href="#tecs.gfx.animation.AsepriteOptions">tecs.gfx.animation.AsepriteOptions</a> = sheet.AsepriteOptions
</code></pre>

What `fromAseprite` takes.
<a id="tecs.gfx.animation.Builder"></a>

### tecs.gfx.animation.Builder

<pre><code v-pre>type <a href="#tecs.gfx.animation.Builder">tecs.gfx.animation.Builder</a> = sheet.Builder
</code></pre>

What `build` answers with.
<a id="tecs.gfx.animation.Completed"></a>

### tecs.gfx.animation.Completed

<pre><code v-pre><a href="#tecs.gfx.animation.Completed">tecs.gfx.animation.Completed</a>: Completed
</code></pre>

Emitted when a tag that does not loop runs past its last frame.
<a id="tecs.gfx.animation.DEFAULT_DURATION"></a>

### tecs.gfx.animation.DEFAULT_DURATION

<pre><code v-pre><a href="#tecs.gfx.animation.DEFAULT_DURATION">tecs.gfx.animation.DEFAULT_DURATION</a>: number
</code></pre>

Milliseconds a frame is held when nothing says otherwise.
<a id="tecs.gfx.animation.Direction"></a>

### tecs.gfx.animation.Direction

<pre><code v-pre>type <a href="#tecs.gfx.animation.Direction">tecs.gfx.animation.Direction</a> = sheet.Direction
</code></pre>

How a tag walks its span.
<a id="tecs.gfx.animation.GridOptions"></a>

### tecs.gfx.animation.GridOptions

<pre><code v-pre>type <a href="#tecs.gfx.animation.GridOptions">tecs.gfx.animation.GridOptions</a> = sheet.GridOptions
</code></pre>

What `grid` takes.
<a id="tecs.gfx.animation.Looped"></a>

### tecs.gfx.animation.Looped

<pre><code v-pre><a href="#tecs.gfx.animation.Looped">tecs.gfx.animation.Looped</a>: Looped
</code></pre>

Emitted when a looping tag passes its last frame and restarts.
<a id="tecs.gfx.animation.Pivot"></a>

### tecs.gfx.animation.Pivot

<pre><code v-pre><a href="#tecs.gfx.animation.Pivot">tecs.gfx.animation.Pivot</a>: sheet.Pivot
</code></pre>

Where an entity's quad turns and scales about.
<a id="tecs.gfx.animation.PlayOptions"></a>

### tecs.gfx.animation.PlayOptions

<pre><code v-pre>type <a href="#tecs.gfx.animation.PlayOptions">tecs.gfx.animation.PlayOptions</a> = PlayOptions
</code></pre>

What `of` and `play` take.
<a id="tecs.gfx.animation.Rect"></a>

### tecs.gfx.animation.Rect

<pre><code v-pre>type <a href="#tecs.gfx.animation.Rect">tecs.gfx.animation.Rect</a> = sheet.Rect
</code></pre>

One frame, as `rects` and the builder take it.
<a id="tecs.gfx.animation.RectsOptions"></a>

### tecs.gfx.animation.RectsOptions

<pre><code v-pre>type <a href="#tecs.gfx.animation.RectsOptions">tecs.gfx.animation.RectsOptions</a> = sheet.RectsOptions
</code></pre>

What `rects` takes.
<a id="tecs.gfx.animation.Sheet"></a>

### tecs.gfx.animation.Sheet

<pre><code v-pre><a href="#tecs.gfx.animation.Sheet">tecs.gfx.animation.Sheet</a>: sheet.Sheet
</code></pre>

An image divided into frames.
<a id="tecs.gfx.animation.Slice"></a>

### tecs.gfx.animation.Slice

<pre><code v-pre>type <a href="#tecs.gfx.animation.Slice">tecs.gfx.animation.Slice</a> = sheet.Slice
</code></pre>

A named region that moves across the frames.
<a id="tecs.gfx.animation.SliceKey"></a>

### tecs.gfx.animation.SliceKey

<pre><code v-pre>type <a href="#tecs.gfx.animation.SliceKey">tecs.gfx.animation.SliceKey</a> = sheet.SliceKey
</code></pre>

Where a slice sits from one frame on.
<a id="tecs.gfx.animation.Tag"></a>

### tecs.gfx.animation.Tag

<pre><code v-pre>type <a href="#tecs.gfx.animation.Tag">tecs.gfx.animation.Tag</a> = sheet.Tag
</code></pre>

A named span of frames, as the constructors take it.
<a id="tecs.gfx.animation.build"></a>

### tecs.gfx.animation.build

<pre><code v-pre>function <a href="#tecs.gfx.animation.build">tecs.gfx.animation.build</a>(name: string, imageWidth: number, imageHeight: number): sheet.Builder
</code></pre>

A builder, for a sheet no constructor above describes.

#### Parameters

| Type                      | Name                           | Description                                           |
| ------------------------- | ------------------------------ | ----------------------------------------------------- |
| <code v-pre>string</code> | <code v-pre>name</code>        | Name to register the finished sheet under.            |
| <code v-pre>number</code> | <code v-pre>imageWidth</code>  | Size of the image the frames are cut from, in pixels. |
| <code v-pre>number</code> | <code v-pre>imageHeight</code> | The other size, in pixels.                            |

#### Returns

| Type                             | Description                                                   |
| -------------------------------- | ------------------------------------------------------------- |
| <code v-pre>sheet.Builder</code> | A builder, which registers the sheet when `finish` is called. |

<a id="tecs.gfx.animation.findSheetById"></a>

### tecs.gfx.animation.findSheetById

<pre><code v-pre>function <a href="#tecs.gfx.animation.findSheetById">tecs.gfx.animation.findSheetById</a>(id: integer): sheet.Sheet
</code></pre>

The sheet a process-wide id names.

#### Parameters

| Type                       | Name                  | Description                     |
| -------------------------- | --------------------- | ------------------------------- |
| <code v-pre>integer</code> | <code v-pre>id</code> | An id a constructor handed out. |

#### Returns

| Type                           | Description                               |
| ------------------------------ | ----------------------------------------- |
| <code v-pre>sheet.Sheet</code> | The sheet, or nil when the id names none. |

<a id="tecs.gfx.animation.findSheetByName"></a>

### tecs.gfx.animation.findSheetByName

<pre><code v-pre>function <a href="#tecs.gfx.animation.findSheetByName">tecs.gfx.animation.findSheetByName</a>(name: string): sheet.Sheet
</code></pre>

The sheet a name was registered under.

#### Parameters

| Type                      | Name                    | Description                        |
| ------------------------- | ----------------------- | ---------------------------------- |
| <code v-pre>string</code> | <code v-pre>name</code> | The name a constructor registered. |

#### Returns

| Type                           | Description                                 |
| ------------------------------ | ------------------------------------------- |
| <code v-pre>sheet.Sheet</code> | The sheet, or nil when the name names none. |

<a id="tecs.gfx.animation.frameOf"></a>

### tecs.gfx.animation.frameOf

<pre><code v-pre>function <a href="#tecs.gfx.animation.frameOf">tecs.gfx.animation.frameOf</a>(world: World, entity: integer): integer
</code></pre>

The sheet frame an entity's animation is showing.

The same answer the vertex shader draws, because both are `frameAt` over
the same tag: the shader reads a table built from it and this calls it.
What a hitbox on frame five, a footstep on frame three or a muzzle on an
animated hand asks for.

#### Parameters

| Type                       | Name                      | Description                    |
| -------------------------- | ------------------------- | ------------------------------ |
| <code v-pre>World</code>   | <code v-pre>world</code>  | The world the entity lives in. |
| <code v-pre>integer</code> | <code v-pre>entity</code> | A live entity.                 |

#### Returns

| Type                       | Description                                                                                        |
| -------------------------- | -------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | A frame index into the whole sheet, counting from one, or zero for an entity with nothing to play. |

<a id="tecs.gfx.animation.fromAseprite"></a>

### tecs.gfx.animation.fromAseprite

<pre><code v-pre>function <a href="#tecs.gfx.animation.fromAseprite">tecs.gfx.animation.fromAseprite</a>(options: sheet.AsepriteOptions): sheet.Sheet
</code></pre>

A sheet from an Aseprite JSON export.

#### Parameters

| Type                                     | Name                       | Description                                                                  |
| ---------------------------------------- | -------------------------- | ---------------------------------------------------------------------------- |
| <code v-pre>sheet.AsepriteOptions</code> | <code v-pre>options</code> | Raises on a missing name or an export the reader cannot make a sheet out of. |

#### Returns

| Type                           | Description                             |
| ------------------------------ | --------------------------------------- |
| <code v-pre>sheet.Sheet</code> | The finished sheet, already registered. |

<a id="tecs.gfx.animation.grid"></a>

### tecs.gfx.animation.grid

<pre><code v-pre>function <a href="#tecs.gfx.animation.grid">tecs.gfx.animation.grid</a>(options: sheet.GridOptions): sheet.Sheet
</code></pre>

A sheet whose frames are the cells of a uniform grid.

#### Parameters

| Type                                 | Name                       | Description                                                                                                                                                         |
| ------------------------------------ | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>sheet.GridOptions</code> | <code v-pre>options</code> | Raises on a missing name, a non-positive image or frame size, a grid that fits no cells, or a `count` past what the grid holds. Frames come out in row-major order. |

#### Returns

| Type                           | Description                                                                 |
| ------------------------------ | --------------------------------------------------------------------------- |
| <code v-pre>sheet.Sheet</code> | The finished sheet, already registered under its name and carrying an `id`. |

<a id="tecs.gfx.animation.of"></a>

### tecs.gfx.animation.of

<pre><code v-pre>function <a href="#tecs.gfx.animation.of">tecs.gfx.animation.of</a>(source: <a href="#tecs.gfx.animation.Sheet">Sheet</a>, tag: string, options: <a href="#tecs.gfx.animation.PlayOptions">PlayOptions</a>): <a href="#tecs.gfx.animation.Animation">Animation</a>
</code></pre>

An Animation playing a named tag of a sheet, ready to spawn.

Omit the tag to play the whole sheet in order. Fails on a tag the sheet
does not carry, since the alternative is a typo that plays every
frame.

The entity also needs a `Sprite`, which is what the query matches on and
what playback writes the frame's region into. An Animation on its own
advances nothing.

#### Parameters

| Type                                                                         | Name                       | Description                                                |
| ---------------------------------------------------------------------------- | -------------------------- | ---------------------------------------------------------- |
| <code v-pre><a href="#tecs.gfx.animation.Sheet">Sheet</a></code>             | <code v-pre>source</code>  | The sheet to play. Nil raises.                             |
| <code v-pre>string</code>                                                    | <code v-pre>tag</code>     | A tag the sheet names, or nil for the whole sheet.         |
| <code v-pre><a href="#tecs.gfx.animation.PlayOptions">PlayOptions</a></code> | <code v-pre>options</code> | Defaults are the sheet's own timing, looping, and playing. |

#### Returns

| Type                                                                     | Description                                                                         |
| ------------------------------------------------------------------------ | ----------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.gfx.animation.Animation">Animation</a></code> | A component value, not an entity: pass it to `world:spawn` or `world:set` yourself. |

<a id="tecs.gfx.animation.play"></a>

### tecs.gfx.animation.play

<pre><code v-pre>function <a href="#tecs.gfx.animation.play">tecs.gfx.animation.play</a>(world: World, entity: integer, source: <a href="#tecs.gfx.animation.Sheet">Sheet</a>, tag: string, options: <a href="#tecs.gfx.animation.PlayOptions">PlayOptions</a>)
</code></pre>

Points a live entity at a tag and restarts it there.

Restarting is the point: time and frame both reset, so the next step
writes the tag's first frame whatever the entity was showing. An entity
carrying no Animation gets one.

#### Parameters

| Type                                                                         | Name                       | Description                                                     |
| ---------------------------------------------------------------------------- | -------------------------- | --------------------------------------------------------------- |
| <code v-pre>World</code>                                                     | <code v-pre>world</code>   | The world the entity lives in.                                  |
| <code v-pre>integer</code>                                                   | <code v-pre>entity</code>  | A live entity, which needs a `Sprite` for playback to reach it. |
| <code v-pre><a href="#tecs.gfx.animation.Sheet">Sheet</a></code>             | <code v-pre>source</code>  | The sheet to play. Nil raises.                                  |
| <code v-pre>string</code>                                                    | <code v-pre>tag</code>     | A tag the sheet names, or nil for the whole sheet.              |
| <code v-pre><a href="#tecs.gfx.animation.PlayOptions">PlayOptions</a></code> | <code v-pre>options</code> | Defaults are the sheet's own timing, looping, and playing.      |

<a id="tecs.gfx.animation.plugin"></a>

### tecs.gfx.animation.plugin

<pre><code v-pre>function <a href="#tecs.gfx.animation.plugin">tecs.gfx.animation.plugin</a>(world: World)
</code></pre>

Adds the system that advances playback.

Not installed for you, so a world that draws no sprite sheets pays
nothing for the query. Call it once; a second call on the same world is
ignored, because adding a system twice under one name is an error.

Which system depends on `useGPU`. On the host it is
`tecs.AdvanceAnimation` in `FixedPostUpdate`, whose query is a logic
query, so a paused entity holds the frame it is on. On the GPU it is
`tecs.EncodeAnimation` in `PostUpdate`, which writes nothing on a step
where nothing changed what is playing, followed by
`tecs.ReportAnimation`, which derives `Completed` and `Looped` for the
entities carrying `AnimationEvents` and writes nothing at all.

#### Parameters

| Type                     | Name                     | Description                     |
| ------------------------ | ------------------------ | ------------------------------- |
| <code v-pre>World</code> | <code v-pre>world</code> | The world to add the system to. |

<a id="tecs.gfx.animation.rects"></a>

### tecs.gfx.animation.rects

<pre><code v-pre>function <a href="#tecs.gfx.animation.rects">tecs.gfx.animation.rects</a>(options: sheet.RectsOptions): sheet.Sheet
</code></pre>

A sheet whose frames are listed one rect at a time.

#### Parameters

| Type                                  | Name                       | Description                                                                                                 |
| ------------------------------------- | -------------------------- | ----------------------------------------------------------------------------------------------------------- |
| <code v-pre>sheet.RectsOptions</code> | <code v-pre>options</code> | Raises on a missing name, a non-positive image size, an empty frame list, or a frame with no positive size. |

#### Returns

| Type                           | Description                                                                 |
| ------------------------------ | --------------------------------------------------------------------------- |
| <code v-pre>sheet.Sheet</code> | The finished sheet, already registered under its name and carrying an `id`. |

<a id="tecs.gfx.animation.replace"></a>

### tecs.gfx.animation.replace

<pre><code v-pre>function <a href="#tecs.gfx.animation.replace">tecs.gfx.animation.replace</a>(built: sheet.Sheet): sheet.Sheet, string
</code></pre>

Folds a re-exported sheet into the one already registered under its
name, in place, so an entity playing the old id shows the new frames.

#### Parameters

| Type                           | Name                     | Description                                                                                          |
| ------------------------------ | ------------------------ | ---------------------------------------------------------------------------------------------------- |
| <code v-pre>sheet.Sheet</code> | <code v-pre>built</code> | A sheet from any constructor here, registered moments ago under a name something else already holds. |

#### Returns

| Type                           | Description                                                    |
| ------------------------------ | -------------------------------------------------------------- |
| <code v-pre>sheet.Sheet</code> | The live sheet, and nil, or nil and the reason it was refused. |
| <code v-pre>string</code>      |                                                                |

<a id="tecs.gfx.animation.restart"></a>

### tecs.gfx.animation.restart

<pre><code v-pre>function <a href="#tecs.gfx.animation.restart">tecs.gfx.animation.restart</a>(world: World, entity: integer): boolean
</code></pre>

Plays an entity's animation again from the start of its tag.

The sheet, tag, speed and loop flag are left as they are; what resets
is where in the cycle playback has got to and whether it is running. For
replaying a one-shot that has finished, and for rewinding one that has
not.

#### Parameters

| Type                       | Name                      | Description                    |
| -------------------------- | ------------------------- | ------------------------------ |
| <code v-pre>World</code>   | <code v-pre>world</code>  | The world the entity lives in. |
| <code v-pre>integer</code> | <code v-pre>entity</code> | A live entity.                 |

#### Returns

| Type                       | Description                                                                                                                     |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | Whether there was an Animation to restart. False leaves the entity untouched, since there is nothing to say what it would play. |

<a id="tecs.gfx.animation.sheetRevision"></a>

### tecs.gfx.animation.sheetRevision

<pre><code v-pre>function <a href="#tecs.gfx.animation.sheetRevision">tecs.gfx.animation.sheetRevision</a>(): integer
</code></pre>

How many times any sheet's frames have changed.

What a cache of anything derived from a sheet compares against, so a
sheet replaced or rebound under a running game invalidates it.

#### Returns

| Type                       | Description                        |
| -------------------------- | ---------------------------------- |
| <code v-pre>integer</code> | A number that only ever increases. |

<a id="tecs.gfx.animation.timeOf"></a>

### tecs.gfx.animation.timeOf

<pre><code v-pre>function <a href="#tecs.gfx.animation.timeOf">tecs.gfx.animation.timeOf</a>(world: World, entity: integer): number
</code></pre>

How far into its tag's cycle an entity's animation has got, in seconds.

Recomputed on the call rather than kept in a column, because keeping it
means writing every animating entity on every step and that is the cost
the GPU path exists to remove. A few hundred calls a step is free; it
stops being free somewhere in the tens of thousands, which is a game
asking a question this is the wrong shape for.

#### Parameters

| Type                       | Name                      | Description                    |
| -------------------------- | ------------------------- | ------------------------------ |
| <code v-pre>World</code>   | <code v-pre>world</code>  | The world the entity lives in. |
| <code v-pre>integer</code> | <code v-pre>entity</code> | A live entity.                 |

#### Returns

| Type                      | Description                                                                                                                                                                       |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>number</code> | Seconds into the cycle, wrapped for a looping tag and clamped at the end for a one-shot. Zero for an entity carrying no Animation and for one whose sheet this run does not have. |

<a id="tecs.gfx.animation.useGPU"></a>

### tecs.gfx.animation.useGPU

<pre><code v-pre>function <a href="#tecs.gfx.animation.useGPU">tecs.gfx.animation.useGPU</a>(enabled: boolean)
</code></pre>

Chooses whether playback is resolved on the GPU.

Off, a system walks every playing animation on every fixed step and
writes the frame's region into the entity's `Sprite`, which marks that
column dirty and has extraction rewrite every instance in the
archetype. One animating sprite therefore costs a rewrite of everything
structurally like it, which is what stops a large animated scene being
affordable.

On, the `Sprite` carries which animation is playing rather than the
region it resolved to, and the vertex shader works the region out from
a shared table and a clock. A frame changing then writes nothing at all,
so what a step costs is what actually changed rather than what is
shaped like it.

Three things read differently with this on. `Animation.frame` and
`Animation.time` stop being written, and `frameOf` and `timeOf` answer
from the clock instead. `Completed` and `Looped` reach only the entities
carrying `AnimationEvents`, and a one-shot that finishes leaves `playing`
alone unless something is listening for it. And the `Sprite` carries a
playback rather than a region, so its layer and image stop following the
sheet: the frame table carries both and the shader reads them there.

On is the default. Set this before `plugin`, since it decides which
systems that installs, and worlds already carrying them keep them.

#### Parameters

| Type                       | Name                       | Description                                                                                                                                                                                                                                                                                                               |
| -------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | <code v-pre>enabled</code> | False puts playback back on the host, for a world that wants events and frame queries without opting in or recomputing and is small enough to pay a frame lookup and a Sprite write per playing animation on every step. A parked one costs the row it sits in and nothing more, so what a step costs is what is running. |

<a id="tecs.gfx.animation.usesGPU"></a>

### tecs.gfx.animation.usesGPU

<pre><code v-pre>function <a href="#tecs.gfx.animation.usesGPU">tecs.gfx.animation.usesGPU</a>(): boolean
</code></pre>

Whether playback resolves on the GPU.

#### Returns

| Type                       | Description                                                                                                                                                                                         |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | The setting as it stands now, which decides what the next world to install the plugin gets. Worlds already carrying the systems keep the ones they were built with, so this does not describe them. |
