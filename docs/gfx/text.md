---
description: "Shaped text as entities in the rendered world."
---

# Text

Shaped text as entities in the rendered world.

A `Text` names a font and string. `Transform2D` places its top-left corner,
`Tint` colors every glyph, and `Clip` clips it like any other drawable.

```nupp
tecs.gfx.text.install(world)
tecs.gfx.layers.configure(8, {sort = "z", screenSpace = true, unlit = true, overlay = true})
local font = assert(tecs.gfx.fonts.newTTF({
    source = tecs.files.assetPath("fonts/JetBrainsMono-ExtraBold.ttf"),
    name = "game.hud",
    size = 28,
    raster = "alpha",
}))
world:spawn(
    tecs.ecs.Transform2D(24, 24, 0, 8),
    tecs.gfx.Tint(0.92, 0.96, 1, 1),
    tecs.gfx.Text("tecs\n1200 entities", font, 28, "center")
)
```

Write text fields through `world:getMut`. A direct `world:get` write leaves the
column clean and the displayed glyphs unchanged.

## Fonts and layout

`newTTF` reads a TrueType font. Tecs rasterizes glyphs lazily, packs them into
the font atlas, and keeps one rendered instance per glyph. Reuse the same Font
object for texts sharing a font name; independently created fonts must not
overwrite one named image with different atlases.

For fixed-size UI, load an `"alpha"` raster at its displayed pixel size, as in
the example. Put labels on an unlit, screen-space overlay layer so their
antialiased edges blend. Use `tecs.gfx.text.snap` explicitly when the block's
origin needs rounding to a whole pixel. The UI examples rebuild fonts for the
window's scale factor and reuse each named atlas.

Text supports explicit newlines and left, center, or right alignment. The fifth `Text` argument sets a wrap width; zero disables wrapping. It does
not anchor outside the top-left corner or style individual glyphs. Glyphs are
sprite entities and inherit the text's layer. Missing glyphs are created in one
batch per label, with direct native-column initialization. Existing glyph IDs
are reused when text changes; shortening it releases only the surplus.
Unchanged labels do no layout or glyph-creation work. `Transform2D.scaleX` and `scaleY`
multiply the whole text block; glyph dimensions come from `Text.size`.

See [Building interfaces](../ui/index.md) for the complete screen UI and
[the text reference](tecs.gfx.text) for measurement and glyph access.
