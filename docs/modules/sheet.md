---
description: "Sprite sheets: frames, tags, slices and pivots, built from a grid, a rect list, an Aseprite export or the builder, and bound to an image"
outline: deep
---

# tecs.sheet

An image divided into frames, with tags and slices over them. The model is Aseprite's, because that is
what the art is authored in: a sheet is a list of frames each holding for its own duration, a set of
named tags that play an inclusive span of them in a direction, and a set of named slices carrying
rectangles, nine-slice centres and pivots that move from frame to frame.

Reading an Aseprite JSON sidecar is one function in front of that model rather than the model itself, so
another reader for the binary format populates the same sheet without reshaping anything. `sheet.grid`
and `sheet.rects` are the same builder with a loop in front.

A sheet is data, not a component. A hundred entities drawing the same character share one sheet and point
at it, so what an entity carries is the sheet's id rather than a copy of its frame table. Playing one
back is [animation](/modules/animation); this page is loading one and describing it.

## Frames, tags and slices

Frames are addressed by index, counting from one, in the order the sheet lays them out: for a grid that
is left to right and then top to bottom. A tag is an inclusive span of those indices, and that is what an
animation plays. Tag zero is the whole sheet, forward, which is what an animation naming no tag plays.

Timing is per frame rather than per entity, which is the thing a single frames-per-second number cannot
express: a hold frame is a frame with a long duration, and that is how an artist writes one. Durations
are authored in milliseconds because Aseprite writes milliseconds, and converted to seconds once when the
sheet is built so playback never divides. `sheet.DEFAULT_DURATION` is `100`, the milliseconds Aseprite
writes for a frame nobody retimed.

### Direction

`sheet.Direction` is an enum of three strings, and it is spent when the sheet is built rather than at
every step of playback: what comes out is the frames in the order they are shown and the second each one
ends on, so finding the current frame is a scan of numbers and never a branch on direction.

| Direction    | What the tag plays                                                                                           |
| ------------ | ------------------------------------------------------------------------------------------------------------ |
| `"forward"`  | `from` to `to`, in order. The default.                                                                       |
| `"reverse"`  | `to` down to `from`.                                                                                         |
| `"pingpong"` | Forward and then back without repeating either end, so a three-frame tag is 1, 2, 3, 2 and then round again. |

### Two coordinate spaces

A frame is written in pixels, because that is how an artist cuts an image up. What a
[`Sprite`](/modules/components) carries is a region of a texture-array layer, which is the fraction of
the image the frame covers scaled by the fraction of the layer the image itself covers. That second
fraction is the renderer's answer, so a sheet holds pixels until [`bind`](#bind) hands it one. Before
`bind`, a frame's region is its plain fraction of the image, which is what a sheet can say without a
renderer and what makes one testable headless.

## Constructing a sheet

### grid

A sheet whose frames are the cells of a uniform grid.

```teal
function sheet.grid(options: GridOptions): Sheet
```

Margin surrounds the grid and spacing separates the cells, so a cell's left edge is
`margin + column * (frameWidth + spacing)`. Both default to zero, which is an image cut with nothing
between its cells. Frames come out in row-major order.

**Parameters:**

- `options`: raises on a missing name, a non-positive image or frame size, a grid that fits no cells, or
  a `count` past what the grid holds.

**Returns:** the finished sheet, already registered under its name and carrying an `id`.

**`GridOptions` fields:**

| Field         | Type            | Default                     | Description                                                                                                                           |
| ------------- | --------------- | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `name`        | `string`        | required                    | Name to register the sheet under.                                                                                                     |
| `imageWidth`  | `number`        | required                    | Size of the image the grid is cut from, in pixels.                                                                                    |
| `imageHeight` | `number`        | required                    | Size of the image the grid is cut from, in pixels.                                                                                    |
| `frameWidth`  | `number`        | required                    | Size of one cell, in pixels.                                                                                                          |
| `frameHeight` | `number`        | required                    | Size of one cell, in pixels.                                                                                                          |
| `margin`      | `number`        | `0`                         | Border between the image's edge and the first cell.                                                                                   |
| `spacing`     | `number`        | `0`                         | Gap between neighbouring cells.                                                                                                       |
| `columns`     | `integer`       | derived from the image size | Cells across.                                                                                                                         |
| `rows`        | `integer`       | derived from the image size | Cells down.                                                                                                                           |
| `count`       | `integer`       | `columns * rows`            | Frames to take, counting across rows. The default is wrong only for a sheet whose last row is short.                                  |
| `duration`    | `number`        | `DEFAULT_DURATION`          | Milliseconds every cell is held. A grid is one duration for every frame by construction; retime individual frames with `sheet.build`. |
| `tags`        | `{string: Tag}` | none                        | Named tags over the frames.                                                                                                           |
| `slices`      | `{Slice}`       | none                        | Named slices.                                                                                                                         |

**Example:**

```teal
local walk <const> = tecs.sheet.grid({
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
function sheet.rects(options: RectsOptions): Sheet
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
`sheet.DEFAULT_DURATION`.

**`Tag` fields:** `from` and `to`, both inclusive frame indices counting from one, and `direction`, which
defaults to `"forward"`.

### fromAseprite

A sheet read from an Aseprite JSON export.

```teal
function sheet.fromAseprite(options: AsepriteOptions): Sheet
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
local hero <const> = tecs.sheet.fromAseprite({ json = text })
```

### build

A builder, for a sheet no constructor above describes.

```teal
function sheet.build(name: string, imageWidth: number, imageHeight: number): Builder
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
- `duration`: milliseconds it is held, defaulting to `sheet.DEFAULT_DURATION`.

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
local sheet <const> = tecs.sheet.build("banner.png", 128, 64)
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
| `centerX`, `centerY`, `centerW`, `centerH` | `number`  | Nine-slice centre, in the slice's own pixels. Nil for a slice with no centre, which is every slice that is not a nine-patch. |
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
| A key with a nine-slice centre but no pivot                                | The middle of that centre.                                                            |
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

`sheet.Pivot` is where an entity's quad turns and scales about. A quad with no `Pivot` turns about its
centre, so a character rotates about its waist and a scale grows it in both directions at once. A quad
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
be drawn. See [animation](/modules/animation#the-pivot-that-follows-a-moving-slice).

A snapshot carries the sheet's name and the slice's name alongside the fraction, and they are resolved
again on the way back in. The travel is deliberately dropped: it is playback's answer rather than the
entity's, and the first step after a load writes it from the registration this run made.

::: info Why the component lives here
A `Pivot` is resolved from a slice, and a slice index is one sheet's answer alone, so writing the name a
snapshot carries needs this module's registry. Putting the component in `tecs.components` would point
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

The whole-image sprite comes from the [Renderer](/modules/renderer).

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

### byId

The sheet a registration index stands for, or nil.

```teal
function sheet.byId(id: integer): Sheet
```

Ids are handed out in construction order, so one is only meaningful within a run.

### byName

The sheet registered under a name, or nil.

```teal
function sheet.byName(name: string): Sheet
```

Building a second sheet under a name already taken replaces what this returns, so a reload points new
entities at the new sheet. Entities already carrying the old id keep drawing the old one, which is what
stops a reload from pulling a frame out from under them.

### replace

Folds a freshly built sheet into the one already registered under its name, keeping the old sheet's id.

```teal
function sheet.replace(built: Sheet): Sheet, string
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
local rebuilt <const> = tecs.sheet.fromAseprite({ json = text })
local live <const>, why <const> = tecs.sheet.replace(rebuilt)
if live == nil then
    LOGGER:warn("sheet reload refused: %s", why)
end
```

### revision

How many times any sheet's frames have changed.

```teal
function sheet.revision(): integer
```

Bumped by registration and by `bind`, both of which move where a frame's region points. Anything holding
a copy of those regions compares this against what it copied from rather than being told, which keeps the
dependency running one way: a sheet knows nothing about who read it.

**Returns:** a number that only ever increases.
<!-- @generated by docs/scripts/reference.py from src/tecs/gfx/sheet.tl. Do not edit below this line. -->

## Reference

Every function and type this module carries, rendered from `src/tecs/gfx/sheet.tl`.

<a id="tecs.sheet.AsepriteOptions"></a>

### tecs.sheet.AsepriteOptions

<pre><code v-pre>type <a href="#tecs.sheet.AsepriteOptions">tecs.sheet.AsepriteOptions</a> = AsepriteOptions
</code></pre>

What `fromAseprite` takes.
<a id="tecs.sheet.Builder"></a>

### tecs.sheet.Builder

<pre><code v-pre>type <a href="#tecs.sheet.Builder">tecs.sheet.Builder</a> = Builder
</code></pre>

What `build` answers with.
<a id="tecs.sheet.DEFAULT_DURATION"></a>

### tecs.sheet.DEFAULT_DURATION

<pre><code v-pre><a href="#tecs.sheet.DEFAULT_DURATION">tecs.sheet.DEFAULT_DURATION</a>: number
</code></pre>

Milliseconds a frame is held when nothing says otherwise.
<a id="tecs.sheet.Direction"></a>

### tecs.sheet.Direction

<pre><code v-pre>type <a href="#tecs.sheet.Direction">tecs.sheet.Direction</a> = Direction
</code></pre>

How a tag walks its span.
<a id="tecs.sheet.GridOptions"></a>

### tecs.sheet.GridOptions

<pre><code v-pre>type <a href="#tecs.sheet.GridOptions">tecs.sheet.GridOptions</a> = GridOptions
</code></pre>

What `grid` takes.
<a id="tecs.sheet.Pivot"></a>

### tecs.sheet.Pivot

<pre><code v-pre><a href="#tecs.sheet.Pivot">tecs.sheet.Pivot</a>: Pivot
</code></pre>

Where an entity's quad turns and scales about.
<a id="tecs.sheet.Rect"></a>

### tecs.sheet.Rect

<pre><code v-pre>type <a href="#tecs.sheet.Rect">tecs.sheet.Rect</a> = Rect
</code></pre>

One frame, as `rects` and the builder take it.
<a id="tecs.sheet.RectsOptions"></a>

### tecs.sheet.RectsOptions

<pre><code v-pre>type <a href="#tecs.sheet.RectsOptions">tecs.sheet.RectsOptions</a> = RectsOptions
</code></pre>

What `rects` takes.
<a id="tecs.sheet.Sheet"></a>

### tecs.sheet.Sheet

<pre><code v-pre><a href="#tecs.sheet.Sheet">tecs.sheet.Sheet</a>: Sheet
</code></pre>

An image divided into frames.
<a id="tecs.sheet.Slice"></a>

### tecs.sheet.Slice

<pre><code v-pre>type <a href="#tecs.sheet.Slice">tecs.sheet.Slice</a> = Slice
</code></pre>

A named region that moves across the frames.
<a id="tecs.sheet.SliceKey"></a>

### tecs.sheet.SliceKey

<pre><code v-pre>type <a href="#tecs.sheet.SliceKey">tecs.sheet.SliceKey</a> = SliceKey
</code></pre>

Where a slice sits from one frame on.
<a id="tecs.sheet.Tag"></a>

### tecs.sheet.Tag

<pre><code v-pre>type <a href="#tecs.sheet.Tag">tecs.sheet.Tag</a> = Tag
</code></pre>

A named span of frames, as the constructors take it.
<a id="tecs.sheet.build"></a>

### tecs.sheet.build

<pre><code v-pre>function <a href="#tecs.sheet.build">tecs.sheet.build</a>(name: string, imageWidth: number, imageHeight: number): <a href="#tecs.sheet.Builder">Builder</a>
</code></pre>

A builder, for a sheet no constructor above describes.

The model is what the builder writes, so an atlas from any tool reaches
the same sheet an Aseprite export does. Frames, tags and slices are
added in any order and the sheet is registered by `build`.

#### Parameters

| Type                      | Name                           | Description                                           |
| ------------------------- | ------------------------------ | ----------------------------------------------------- |
| <code v-pre>string</code> | <code v-pre>name</code>        | Name to register the finished sheet under.            |
| <code v-pre>number</code> | <code v-pre>imageWidth</code>  | Size of the image the frames are cut from, in pixels. |
| <code v-pre>number</code> | <code v-pre>imageHeight</code> |                                                       |

#### Returns

| Type                                                         | Description                    |
| ------------------------------------------------------------ | ------------------------------ |
| <code v-pre><a href="#tecs.sheet.Builder">Builder</a></code> | A builder whose methods chain. |

<a id="tecs.sheet.byId"></a>

### tecs.sheet.byId

<pre><code v-pre>function <a href="#tecs.sheet.byId">tecs.sheet.byId</a>(id: integer): <a href="#tecs.sheet.Sheet">Sheet</a>
</code></pre>

The sheet a registration index stands for, or nil.

#### Parameters

| Type                       | Name                  | Description                                                                                                                |
| -------------------------- | --------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | <code v-pre>id</code> | An `id` from a sheet this process built. Ids are handed out in construction order, so one is only meaningful within a run. |

#### Returns

| Type                                                     | Description                                          |
| -------------------------------------------------------- | ---------------------------------------------------- |
| <code v-pre><a href="#tecs.sheet.Sheet">Sheet</a></code> | The sheet, or nil for an id nothing was built under. |

<a id="tecs.sheet.byName"></a>

### tecs.sheet.byName

<pre><code v-pre>function <a href="#tecs.sheet.byName">tecs.sheet.byName</a>(name: string): <a href="#tecs.sheet.Sheet">Sheet</a>
</code></pre>

The sheet registered under a name, or nil.

Building a second sheet under a name already taken replaces what this
returns, so a reload points new entities at the new sheet. Entities
already carrying the old id keep drawing the old one, which is what
stops a reload from pulling a frame out from under them.

#### Parameters

| Type                      | Name                    | Description                       |
| ------------------------- | ----------------------- | --------------------------------- |
| <code v-pre>string</code> | <code v-pre>name</code> | The name a sheet was built under. |

#### Returns

| Type                                                     | Description                                                 |
| -------------------------------------------------------- | ----------------------------------------------------------- |
| <code v-pre><a href="#tecs.sheet.Sheet">Sheet</a></code> | The sheet most recently registered under that name, or nil. |

<a id="tecs.sheet.fromAseprite"></a>

### tecs.sheet.fromAseprite

<pre><code v-pre>function <a href="#tecs.sheet.fromAseprite">tecs.sheet.fromAseprite</a>(options: <a href="#tecs.sheet.AsepriteOptions">AsepriteOptions</a>): <a href="#tecs.sheet.Sheet">Sheet</a>
</code></pre>

A sheet read from an Aseprite JSON export.

One reader in front of the model rather than a second model: frames,
their durations, frame tags with their directions, and slices with their
keys all land in the sheet the builder writes.

Both of Aseprite's frame layouts are read, the array and the object
keyed by frame name, the second in sorted name order. Trimmed exports
are not read: `spriteSourceSize` is ignored, so export with trimming
off or the frames land in the wrong place.

#### Parameters

| Type                                                                         | Name                       | Description                                   |
| ---------------------------------------------------------------------------- | -------------------------- | --------------------------------------------- |
| <code v-pre><a href="#tecs.sheet.AsepriteOptions">AsepriteOptions</a></code> | <code v-pre>options</code> | The export and the name to register it under. |

#### Returns

| Type                                                     | Description         |
| -------------------------------------------------------- | ------------------- |
| <code v-pre><a href="#tecs.sheet.Sheet">Sheet</a></code> | The finished sheet. |

<a id="tecs.sheet.grid"></a>

### tecs.sheet.grid

<pre><code v-pre>function <a href="#tecs.sheet.grid">tecs.sheet.grid</a>(options: <a href="#tecs.sheet.GridOptions">GridOptions</a>): <a href="#tecs.sheet.Sheet">Sheet</a>
</code></pre>

A sheet whose frames are the cells of a uniform grid.

Margin surrounds the grid and spacing separates the cells, so a cell's
left edge is `margin + column * (frameWidth + spacing)`. Both default to
zero, which is an image cut with nothing between its cells.

#### Parameters

| Type                                                                 | Name                       | Description                                                                                                                                                         |
| -------------------------------------------------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.sheet.GridOptions">GridOptions</a></code> | <code v-pre>options</code> | Raises on a missing name, a non-positive image or frame size, a grid that fits no cells, or a `count` past what the grid holds. Frames come out in row-major order. |

#### Returns

| Type                                                     | Description                                                                 |
| -------------------------------------------------------- | --------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.sheet.Sheet">Sheet</a></code> | The finished sheet, already registered under its name and carrying an `id`. |

<a id="tecs.sheet.rects"></a>

### tecs.sheet.rects

<pre><code v-pre>function <a href="#tecs.sheet.rects">tecs.sheet.rects</a>(options: <a href="#tecs.sheet.RectsOptions">RectsOptions</a>): <a href="#tecs.sheet.Sheet">Sheet</a>
</code></pre>

A sheet whose frames are listed one rect at a time.

For an image no grid describes: frames of differing sizes, or an atlas
whose cells a packing tool placed.

#### Parameters

| Type                                                                   | Name                       | Description                                                                                                                                                                                                                |
| ---------------------------------------------------------------------- | -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.sheet.RectsOptions">RectsOptions</a></code> | <code v-pre>options</code> | Raises on a missing name, a non-positive image size, an empty frame list, or a frame with no positive size. Rects are not checked against the image, so one that runs off the edge samples whatever the layer holds there. |

#### Returns

| Type                                                     | Description                                                                 |
| -------------------------------------------------------- | --------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.sheet.Sheet">Sheet</a></code> | The finished sheet, already registered under its name and carrying an `id`. |

<a id="tecs.sheet.replace"></a>

### tecs.sheet.replace

<pre><code v-pre>function <a href="#tecs.sheet.replace">tecs.sheet.replace</a>(built: <a href="#tecs.sheet.Sheet">Sheet</a>): <a href="#tecs.sheet.Sheet">Sheet</a>, string
</code></pre>

Folds a freshly built sheet into the one already registered under its
name, keeping the old sheet's id.

The reverse of what building under a taken name does, and it exists
because a reload wants the reverse. Building again answers new entities
with the new sheet and leaves every entity already playing on the old
one, which is right for two sheets that happen to share a name and wrong
for one file that was re-exported. This overwrites in place instead, so
an `Animation` holding the id goes on playing and shows the new frames
on its next step, with nothing in the world touched.

The refusals are the same ones a shader reload makes, for the same
reason: a component holds an index into this sheet, so anything that
renumbers one is refused rather than half applied. Tag ids follow the
tag names in sorted order and slice ids follow the slices, so adding,
removing or renaming either is a restart. Frames are free to change:
what an entity carries is a tag and a time, and the frame is resolved
from the cycle on every step.

The bind is carried over. A sheet re-exported over the same image is
already bound to the right layer, so its frames are rescaled against
the region the old sheet held rather than needing `bind` called again.

The sheet handed in is spent. Its id resolves to the live sheet rather
than to itself, because the two share their frame tables once the fold
is done and only one of them may be bound.

#### Parameters

| Type                                                     | Name                     | Description                                                                                          |
| -------------------------------------------------------- | ------------------------ | ---------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.sheet.Sheet">Sheet</a></code> | <code v-pre>built</code> | A sheet from any constructor here, registered moments ago under a name something else already holds. |

#### Returns

| Type                                                     | Description                                                    |
| -------------------------------------------------------- | -------------------------------------------------------------- |
| <code v-pre><a href="#tecs.sheet.Sheet">Sheet</a></code> | The live sheet, and nil, or nil and the reason it was refused. |
| <code v-pre>string</code>                                |                                                                |

<a id="tecs.sheet.revision"></a>

### tecs.sheet.revision

<pre><code v-pre>function <a href="#tecs.sheet.revision">tecs.sheet.revision</a>(): integer
</code></pre>

How many times any sheet's frames have changed.

Bumped by registration and by `bind`, both of which move where a frame's
region points. Anything holding a copy of those regions compares this
against what it copied from rather than being told, which keeps the
dependency running one way: a sheet knows nothing about who read it.

#### Returns

| Type                       | Description                        |
| -------------------------- | ---------------------------------- |
| <code v-pre>integer</code> | A number that only ever increases. |
