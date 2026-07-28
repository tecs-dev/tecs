---
description: "Distance-field text: fonts, the Text component, layout rules, and the plugin that produces glyph instances"
outline: deep
---

# tecs.text

`tecs.text` draws strings from a multi-channel signed distance field. A `Text` names a font and a
string, and it is one entity: its glyphs are not entities at all. The plugin registers an instance
producer with the [renderer](/modules/renderer) and every text owns a span of that producer's run.

A glyph is still an ordinary textured quad, with a UV rect addressing the font atlas and a material
selecting the distance-field shader, so culling, depth, layers, clip regions and the indirect draw
all apply to it exactly as they apply to an entity. What the span buys is what per-archetype dirty
tracking cannot give an entity here: glyph entities would all share one archetype, so editing one
string would rewrite every glyph in the world, and spawning or despawning a glyph would move an
archetype's length and relay the whole scene out. A producer reports the sub-ranges it changed, so
editing one string rewrites that string.

## Requiring it

```teal
local tecs <const> = require("tecs")
local text <const> = tecs.text
```

`tecs` is also set as a global, so the require line is optional, and engine modules are resolved
lazily on first field access.

## Fonts

A `Font` is metrics and an atlas path, and nothing about a device. Which texture-array layer the
atlas occupies is a renderer's answer, so the plugin holds that and one font can be shared by two
renderers. The metrics are read when the font is loaded, which is a few kilobytes of JSON; the atlas
is named rather than held, and a renderer decodes and uploads it the first frame a text needs it.

### loadFont

Loads a font's metrics and names its atlas.

```teal
function text.loadFont(options: FontOptions): Font
```

**Parameters:**

- `options.metrics`: path to the metrics JSON, resolved against the asset root unless it already
  starts with `/`. Required; the call raises without it.
- `options.atlas`: path to the atlas image. Optional; defaults to the first page the metrics name,
  resolved beside them. The metrics naming no page and no `atlas` being passed is an error.

**Returns:** the font. A metrics path already loaded answers with the font it loaded, rather than
reading the file twice, so one path means one font for the life of the process however many times it
is asked for.

The document is BMFont-shaped JSON: an `info` block, a `common` block, a `distanceField` block
carrying `distanceRange`, a `chars` list and an optional `kernings` list. A document missing any of
the first three, or listing no glyphs, is refused by name.

**Example:**

```teal
local font <const> = text.loadFont({ metrics = "fonts/inter-msdf.json" })
```

### defaultFont

The font the engine ships, loaded on first use.

```teal
function text.defaultFont(): Font
```

Equivalent to `text.loadFont({ metrics = "fonts/jetbrainsmono-extrabold-msdf.json" })`.

### fontByName

A loaded font by the metrics path it was loaded from, or nil.

```teal
function text.fontByName(name: string): Font
```

This is what a snapshot resolves a font name back through.

### reloadFont

Re-reads a font's metrics over the font already loaded from them.

```teal
function text.reloadFont(path: string): Font
```

**Parameters:**

- `path`: the metrics path the font was loaded under, or the file that path resolves to. Both
  spellings reach the same font, because a game names it the way it asked for it and a watcher names
  the file it looked at.

**Returns:** the font, which is the table it always was. Identity is the point: a `Text` names its
font by holding the table, so the metrics are read back into that table and every live text goes on
pointing at the font it was given.

Nothing can infer from identity that a re-read happened, so the texts naming that font are told
rather than left to notice, and exactly those: a text naming another font is not laid out again,
whatever archetype it shares. Metrics naming an atlas of another size are refused, because every
glyph already drawn carries UV extents measured against the size the atlas had. A malformed document
raises and leaves the font as it was.

::: tip
A font is two files and only the metrics reload as a font. The atlas is an image, was loaded as one,
and reloads as one under the rect it already occupies.
:::

### The Font record

| Field           | Type                           | What it is                                                      |
| --------------- | ------------------------------ | --------------------------------------------------------------- |
| `name`          | `string`                       | Path the metrics came from, which is the font's identity        |
| `atlas`         | `string`                       | Path the atlas image is read from, and the name it registers as |
| `size`          | `number`                       | Em size the metrics were generated at                           |
| `lineHeight`    | `number`                       | Distance from one baseline to the next                          |
| `base`          | `number`                       | Baseline offset from the top of a line box                      |
| `atlasWidth`    | `number`                       | Atlas width in pixels                                           |
| `atlasHeight`   | `number`                       | Atlas height in pixels                                          |
| `distanceRange` | `number`                       | Width of the distance field, in atlas pixels                    |
| `glyphs`        | `{integer: GlyphMetrics}`      | Metrics by codepoint                                            |
| `kernings`      | `{integer: {integer: number}}` | Kerning by leading then trailing codepoint; empty when unused   |

Everything but `name` and `atlas` is in the units `size` was generated at, and scales by
`Text.size / Font.size`.

A `GlyphMetrics` is the glyph's rect within the atlas in atlas pixels (`x`, `y`, `width`, `height`),
the offset from the pen to its top-left corner (`xOffset`, `yOffset`), and how far the pen moves
after it (`xAdvance`).

### Producing a font

A font is two files: the metrics JSON and the atlas image it names. The engine generates neither, so
one is produced ahead of time by whatever tool emits that pair.

The loader reads one shape, and the fields it needs are these:

| In the document               | Becomes                          |
| ----------------------------- | -------------------------------- |
| `info.size`                   | `Font.size`                      |
| `common.lineHeight`           | `Font.lineHeight`                |
| `common.base`                 | `Font.base`                      |
| `common.scaleW`, `.scaleH`    | `Font.atlasWidth`, `atlasHeight` |
| `distanceField.distanceRange` | `Font.distanceRange`             |
| `chars`                       | `Font.glyphs`, keyed by `id`     |
| `kernings`                    | `Font.kernings`, optional        |
| `pages[1]`                    | The atlas image's path           |

A document missing `info`, `common` or `distanceField`, or listing no glyphs, is refused by name. The
`distanceField` block is not optional: the glyph material reads a multi-channel distance field, so a
plain bitmap font has nothing for it to sample.

The font the engine ships was generated like this, which is recorded in full alongside it in
`assets/fonts/JetBrainsMono-NOTICE.md`:

```bash
npx --yes msdf-bmfont-xml@2.8.0 \
    -f json \
    -o jetbrainsmono-extrabold-msdf.png \
    -s 64 \
    -m 512,512 \
    -r 8 \
    --pot \
    --square \
    JetBrainsMono-ExtraBold.ttf
```

`-s` is the em size the metrics are generated at, which arrives as `info.size` and is what
`Text.size` is scaled against. `-m` bounds the atlas, arriving as `common.scaleW` and `common.scaleH`.
`-r` is the width of the distance field in atlas pixels, arriving as `distanceField.distanceRange`;
the material scales the field by how many screen pixels that range covers, which is what keeps the
outline exact at any size, so a range too narrow for how large the text is drawn sharpens noise
rather than the edge.

The image lands beside the metrics, which is where the loader looks for it when `atlas` is not
passed. The shipped font carries printable ASCII, `U+0020` through `U+007E`; a codepoint an atlas has
no glyph for advances the pen by the width of a space and draws nothing.

## The Text component

A string laid out into glyph instances.

```teal
local record Text is Component
    text: string
    font: Font
    size: number
    align: string
    lineSpacing: number
    tracking: number

    width: number
    height: number
end
```

| Field         | Default  | What it is                                                                      |
| ------------- | -------- | ------------------------------------------------------------------------------- |
| `text`        | `""`     | The string laid out. A newline starts a line; nothing else breaks one           |
| `font`        | none     | The font the glyphs come from. Without one the text draws nothing               |
| `size`        | `16`     | Em size in world units                                                          |
| `align`       | `"left"` | `"left"`, `"centre"` or `"right"`, within the widest line of the block          |
| `lineSpacing` | `1.0`    | Multiplies the font's line height                                               |
| `tracking`    | `0.0`    | Extra advance between glyphs, in world units                                    |
| `width`       | `0.0`    | Extent of the last layout, written by the layout system; assigning does nothing |
| `height`      | `0.0`    | As `width`                                                                      |

An `align` that is none of the three raises where the component is constructed.

`Text` requires `Transform`, so one is never accidentally left off. The transform places the
top-left corner of the text block and orients and scales the whole block; a `Tint` colours every
glyph; a `Clip` keeps the glyphs inside a rectangle exactly as it would any other quad. All three
are ordinary components on an ordinary entity, so a text is moved, parented, tweened and layered
like anything else. See [components](/modules/components) for `Tint` and `Clip`.

**Constructing one**, positionally or by name:

```teal
world:spawn(
    Transform(24, 24),
    Tint(0.92, 0.96, 1.0, 1.0),
    text.Text.new({
        text = "tecs\n1200 entities",
        font = text.defaultFont(),
        size = 28,
        align = "centre",
    })
)
```

The positional form takes the authored fields in declaration order:
`text.Text(body, font, size, align, lineSpacing, tracking)`.

::: warning Write through getMut
Write through `world:getMut(entity, text.Text)`. A write through `world:get` leaves the column clean
and the glyphs stale.
:::

**Snapshots** carry the authored fields and the font by name. The span is one process's answer and
the font is a shared table, so neither is written. A font that was never loaded in this process
leaves the restored text without one, which lays out nothing rather than failing the load.

## What layout does

Layout is advances, kerning where the metrics carry it, explicit newlines and an alignment within
the block. Alignment moves whole lines within the widest line of the block, which is why it is
applied once the block width is known. A codepoint the font has no metrics for still takes the width
of a space rather than disappearing, and a byte that is not valid UTF-8 is laid out as itself, so a
string that is not UTF-8 renders as Latin-1 rather than failing.

Glyph positions are absolute, so a text composes its own transform: its position, rotation and scale
are applied to the glyph offsets. A text whose `Transform` moved is therefore as stale as one whose
string changed.

What layout does not do: wrapping to a width, anchoring anywhere but the block's top-left corner,
per-glyph styling, right-to-left or complex shaping, and any effect around the outline. Each of
those is a decision rather than an omission of effort.

Glyphs are drawn by the `glyph` material, which is unlit: text draws at its own colour rather than
taking whatever the scene's lights leave it in. A label that should take the light is a material of
its own; see [materials](/modules/materials).

### measure

Extent of a `Text` in world units, without touching any entity.

```teal
function text.measure(item: Text): number, number
```

**Returns:** width, then height. Zero and zero when the item, its font or its string is nil.

This runs the same layout the system runs, so a caller sizing a panel around a string gets the
number the glyphs will occupy.

**Example:**

```teal
local width, height = text.measure(world:get(entity, text.Text))
```

## The plugin

```teal
function text.plugin(options: TextOptions): function(World)
```

**Parameters:**

- `options.renderer`: the [renderer](/modules/renderer) the font atlases upload into and the glyph
  instances are produced for. Required; the call raises without it.

**Example:**

```teal
world:addPlugin(text.plugin({ renderer = app.renderer }))
```

The plugin registers the producer on the renderer and adds one system, `tecs.TextLayout`, in
`PostUpdate` after `RelativeTransform`. That ordering is load-bearing: `RelativeTransform` composes a
parented text's own world transform in the same phase, and glyph positions are absolute, so a text
laid out before that composition would use the transform the previous frame left.

Layout runs every frame and almost no text changes, so it is gated twice. An archetype whose `Text`,
`Tint`, `Clip` and `Transform` columns are all clean is skipped whole, and within a dirty archetype a
row whose authored fields and transform match what its glyphs were built from is skipped too. A font
whose atlas has not finished decoding holds the gate open until it arrives.

The plugin also observes two events: `OnDespawn`, so a despawned text hands its span back, and
`FinishSnapshotLoad`, which gives up the whole run, because a load replaces the world in place rather
than despawning what was in it.

::: info Spans and fragmentation
Spans come from a size-bucketed free list. Allocating takes an exact-size span off the free list when
one is there and extends the high-water mark otherwise, so short strings appearing and disappearing
reuse each other's spans exactly and the run's length stops moving after warmup. The tradeoff is
fragmentation: a text that grows past its span leaves a hole that only a text of that exact length
reclaims. There is no compaction, and there will not be one until a measurement asks for it.
:::

## Introspection

### layouts

How many texts have been laid out in a world since it was created.

```teal
function text.layouts(world: World): integer
```

Laying out a string that did not change is the cost the dirty gates exist to avoid, and this is how
that is asserted rather than assumed.

**Example:**

```teal
local before <const> = text.layouts(world)
world:update(1 / 60)
assert(text.layouts(world) == before, "an unchanged string must not be laid out again")
```

### glyphAt

Where a text's `index`th glyph landed.

```teal
function text.glyphAt(world: World, entity: integer,
                      index: integer): number, number, number, number
```

**Returns:** world x, y, width and height, read back out of the instance the producer wrote, so this
is where the glyph is drawn rather than where a layout intended it. Nothing when the world has no
text plugin installed or the text has no such glyph.

## Design record

- [Text is a producer's run](https://github.com/tecs-dev/tecs/blob/main/README.md#text-is-a-producers-run)
- [The shader pipeline](https://github.com/tecs-dev/tecs/blob/main/README.md#the-shader-pipeline)
- [Shapes are materials](https://github.com/tecs-dev/tecs/blob/main/README.md#shapes-are-materials)
- [GPU-driven by default](https://github.com/tecs-dev/tecs/blob/main/README.md#gpu-driven-by-default)
