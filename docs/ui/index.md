---
description: "Compose retained layout, existing GPU drawing components, scrolling, clipping, and input"
sidebar_order: 20
outline: deep
---

# Building interfaces

Tecs provides retained layout without introducing a DOM or a second renderer.
A UI node is an entity. [`tecs.ecs.ChildOf`](/modules/ecs/builtins#childof)
defines both its layout hierarchy and its transform hierarchy, while the
existing rectangle, circle, image, sprite, and text producers keep drawing the
result through the normal instanced GPU pipeline.

<img src="/images/ui-compose.png" alt="The Compose demo scene combining an intrinsic image, a stretched rectangle, a fixed circle, and text" />

The Compose scene shows the central rule: Taffy sizes retained ECS nodes, while
the existing image, rectangle, circle, and text producers draw their leaves.

The boundary is intentionally narrow:

- [`tecs.ui.Style`](/modules/ui#tecs.ui.Style) supplies layout properties.
- [`tecs.ui.Layout`](/modules/ui#tecs.ui.Layout) reports the computed box.
- [`tecs.ui.Paint`](/modules/ui#tecs.ui.Paint) optionally stretches an existing
  drawing leaf to that box.
- [`tecs.ui.Intrinsic`](/modules/ui#tecs.ui.Intrinsic) lets text, images, and
  custom leaves contribute their natural size.
- [`tecs.ui.Scroll`](/modules/ui#tecs.ui.Scroll) offsets descendants and assigns
  the existing renderer clip component.
- [`tecs.ui.Scrollbar`](/modules/ui#tecs.ui.Scrollbar) drives a composed thumb;
  it is not a special renderer primitive.
- [`tecs.ui.Interaction`](/modules/ui#tecs.ui.Interaction) opts a box into hit
  testing, focus, and activation.

Layout changes only dirty transforms whose computed results changed. Drawing
components retain their normal batching, materials, dirty tracking, and GPU
instancing.

## Start with a complete screen UI

These first two blocks form one complete `main.tl`. The first block contains
only imports and retained entity composition. It creates a full-window root, a
panel, an ordinary rounded rectangle behind it, and one intrinsic text leaf.
It does not install plugins or register systems.

```teal
local tecs <const> = require("tecs")
local ui <const> = tecs.ui
local ChildOf <const> = tecs.ecs.ChildOf
local RelativeTransform2D <const> = tecs.ecs.RelativeTransform2D
local Tint <const> = tecs.gfx.Tint
local Material <const> = tecs.gfx.Material
local Renderable2D <const> = tecs.gfx.Renderable2D

local function spawnInterface(
    world: tecs.World,
    app: tecs.Application,
    font: tecs.gfx.Font
)
    local materials <const> = tecs.gfx.materials

    local root <const> = world:spawn(
        ui.Style({
            width = "100%",
            height = "100%",
            justifyContent = "center",
            alignItems = "center",
            padding = "24px",
        }),
        ui.Root("screen"),
        tecs.Transform2D(0, 0, 0, 16)
    )

    local panel <const> = world:spawn(
        ui.Style({
            width = 420,
            height = 240,
            flexDirection = "column",
            padding = 20,
            gap = 12,
        }),
        RelativeTransform2D(),
        ChildOf(root)
    )

    world:spawn(
        ui.Style({position = "absolute", inset = 0}),
        ui.Paint(true),
        RelativeTransform2D(0, 0, 0),
        Tint(0.035, 0.055, 0.09, 0.96),
        Material(materials.id("rounded"), 0.05),
        Renderable2D(),
        ChildOf(panel)
    )

    world:spawn(
        ui.Style({maxWidth = "100%"}),
        ui.Intrinsic("text", {wrap = true}),
        RelativeTransform2D(0, 0, 1),
        Tint(0.94, 0.97, 1.0, 1.0),
        tecs.gfx.Text.new({
            text = "This text and its panel are ordinary ECS entities.",
            font = font,
            size = 16,
        }),
        ChildOf(panel)
    )
end
```

When the plugin receives an application, it keeps every screen root's logical
size and pixel density synchronized with the window. Percentage dimensions
therefore follow a resize without a game observer or per-frame system.

World roots have two explicit contracts. A manually sized root preserves its
authored extent for a render target or world-space panel:

```teal
ui.Root("world", layoutWidth, layoutHeight, 1, "manual")
```

A camera-sized root follows the active camera and physical viewport. Its
layout units are world units, its origin is the camera's top-left world point,
and camera zoom or rotation updates its root transform:

```teal
ui.Root("world", 0, 0, 1, "camera")
```

Camera2D sizing requires the application form of `ui.plugin`, because the
window supplies the viewport. Screen roots accept `"auto"` or `"manual"`;
world roots accept `"camera"` in addition to the manual behavior selected by
`"auto"`.

## Install from the application plugin

The application plugin configures the UI layer, installs one UI plugin in the
world, and registers the system that calls `spawnInterface`. Passing the
application supplies the renderer and folded input. A second table can
override clip allocation, the input layer, or wheel distance.

Paste this setup block after `spawnInterface`. It installs text and UI
separately, loads an exact-size alpha font for crisp fixed-size UI text, and
spawns the retained tree from `Startup`.

```teal
local function gamePlugin(world: tecs.World, app: tecs.Application)
    tecs.gfx.layers.configure(16, {
        sort = "z",
        screenSpace = true,
        unlit = true,
    })

    world:addPlugin(tecs.gfx.textPlugin({renderer = app.renderer}))
    world:addPlugin(tecs.ui.plugin(app, {wheelStep = 36}))
    world:addSystem({
        name = "game.SpawnInterface",
        phase = tecs.ecs.phases.Startup,
        run = function()
            local font <const> = tecs.gfx.newTTF({
                source = "fonts/JetBrainsMono-ExtraBold.ttf",
                name = "game-ui-16",
                size = 16,
                raster = "alpha",
            }):wait().value
            spawnInterface(world, app, font)
        end,
    })
end

return tecs.newApplication({
    window = {
        title = "My game",
        width = 1280,
        height = 720,
    },
    plugin = gamePlugin,
})
```

For UI over a 3D scene, configure the layer above with `overlay = true`. That
selects the sprite forward lane even for fully opaque UI, and the lane runs
after opaque and transparent meshes. The layer orders UI elements against one
another; Tecs does not compare a `Camera3D` distance with a 2D layer band.
Bloom is also composed before this lane, so HUD text and panels remain crisp.

Plugin setup is for composition and registration. `Startup` is for spawning
the retained entities, after all application plugins have been installed and
before the first frame.

Tests, tools, and manually constructed worlds can wire the dependencies
directly instead:

```teal
world:addPlugin(ui.plugin({
    renderer = renderer,
    input = input,
}))
```

That manual form has no window to synchronize. Give its screen roots explicit
logical dimensions and pixel density with
`ui.Root("screen", width, height, pixelDensity)`.

## Layout recipes

Every recipe below belongs inside `spawnInterface` and attaches to the `root`
created there. A layout container needs `Style`, `RelativeTransform2D`, and
`ChildOf`. It needs no drawing component unless the container itself should be
visible.

### Anchor a panel to a corner

The root is a row by default. `justifyContent` chooses the main-axis position
and `alignItems` chooses the cross-axis position. This puts a fixed-width panel
at the top right while its height follows its children:

```teal
local sidebar <const> = world:spawn(
    ui.Style({
        width = 360,
        flexDirection = "column",
        gap = 12,
        padding = 16,
        margin = {left = "auto"},
    }),
    RelativeTransform2D(),
    ChildOf(root)
)
```

For a true overlay that takes no space from siblings, use absolute positioning:

```teal
local overlay <const> = world:spawn(
    ui.Style({
        position = "absolute",
        width = 360,
        inset = {right = 24, top = 24, bottom = 24},
        flexDirection = "column",
        gap = 12,
    }),
    RelativeTransform2D(),
    ChildOf(root)
)
```

### Build a horizontal toolbar

```teal
local toolbar <const> = world:spawn(
    ui.Style({
        width = "100%",
        height = 48,
        flexDirection = "row",
        alignItems = "center",
        gap = 8,
        padding = {left = 12, right = 12},
    }),
    RelativeTransform2D(),
    ChildOf(root)
)

for index = 1, 4 do
    world:spawn(
        ui.Style({width = 96, height = 32}),
        RelativeTransform2D(),
        ChildOf(toolbar)
    )
end
```

### Divide remaining space between children

`flexGrow` consumes space left on the container's main axis. This creates a
fixed navigation column and a content area that fills the rest:

```teal
local body <const> = world:spawn(
    ui.Style({width = "100%", flexGrow = 1, flexDirection = "row", gap = 16}),
    RelativeTransform2D(),
    ChildOf(root)
)

local navigation <const> = world:spawn(
    ui.Style({width = 220, height = "100%"}),
    RelativeTransform2D(),
    ChildOf(body)
)

local contentArea <const> = world:spawn(
    ui.Style({flexGrow = 1, height = "100%"}),
    RelativeTransform2D(),
    ChildOf(body)
)
```

### Wrap cards into rows

```teal
local cards <const> = world:spawn(
    ui.Style({
        width = "100%",
        flexDirection = "row",
        flexWrap = "wrap",
        gap = 12,
    }),
    RelativeTransform2D(),
    ChildOf(root)
)

for index = 1, 12 do
    world:spawn(
        ui.Style({width = 180, height = 96}),
        RelativeTransform2D(),
        ChildOf(cards)
    )
end
```

<img src="/images/ui-flex.png" alt="The Flex demo scene comparing a fixed-width child with flex-grow children and a wrapped grid" />

The Flex scene makes both behaviors measurable: the first row compares `88px`,
`flexGrow = 1`, and `flexGrow = 2`, while the cards below wrap at the panel
edge.

### Overlay a badge without affecting layout

An absolute child is positioned relative to its retained parent and does not
consume flex space:

```teal
world:spawn(
    ui.Style({
        position = "absolute",
        width = 20,
        height = 20,
        inset = {right = -6, top = -6},
    }),
    ui.Paint(true),
    RelativeTransform2D(0, 0, 5),
    Tint(1.0, 0.25, 0.2, 1.0),
    Material(tecs.gfx.materials.id("circle"), 0),
    Renderable2D(),
    ChildOf(contentArea)
)
```

<img src="/images/ui-overlay.png" alt="The Overlay demo scene with four absolutely positioned corner cards and a centered higher-depth circle" />

The Overlay scene shows that absolute children anchor to their retained parent
without consuming flex space. The center circle and label also demonstrate
that renderer depth remains independent from layout order.

### Remove a subtree from layout

Change `display` through `getMut` so the UI plugin sees the write:

```teal
local style <const> = world:getMut(sidebar, ui.Style)
style.style.display = "none"

-- Later:
local visible <const> = world:getMut(sidebar, ui.Style)
visible.style.display = "flex"
```

`display = "none"` removes the entity and its descendants from Taffy layout.
It does not remove ordinary rectangle, image, or text instances from their GPU
producers. A component that owns a whole-screen scene should therefore pair the
layout state with its normal rendering visibility state. The repository demo's
scene selector removes `Renderable2D` from inactive drawing leaves and restores
it when their scene becomes active.

## Compose visuals from ordinary entities

A container normally has `Style`, `RelativeTransform2D`, and `ChildOf`. Put its
visual on an absolute child. `Paint(true)` centers that child and copies the
computed width and height into its relative transform scale.

The following entity snippets belong in `spawnInterface`, after the root is
created.

```teal
local panel <const> = world:spawn(
    ui.Style({
        width = 360,
        height = 520,
        flexDirection = "column",
        padding = 20,
        gap = 12,
    }),
    tecs.ecs.RelativeTransform2D(),
    tecs.ecs.ChildOf(root)
)

world:spawn(
    ui.Style({position = "absolute", inset = 0}),
    ui.Paint(true),
    tecs.ecs.RelativeTransform2D(0, 0, 0),
    tecs.gfx.Tint(0.035, 0.055, 0.09, 0.96),
    tecs.gfx.Material(tecs.gfx.materials.id("rounded"), 0.04),
    tecs.gfx.Renderable2D(),
    tecs.ecs.ChildOf(panel)
)
```

The same pattern works with every drawing producer. A circle keeps the circle
material, text keeps the glyph instance producer, and an image keeps its
sprite. Add `Intrinsic` when a leaf should size itself instead of stretching:

```teal
world:spawn(
    ui.Style({width = 32, height = 32}),
    ui.Paint(true),
    tecs.ecs.RelativeTransform2D(0, 0, 2),
    tecs.gfx.Tint(0.32, 0.82, 1.0, 1.0),
    tecs.gfx.Material(tecs.gfx.materials.id("circle"), 0),
    tecs.gfx.Renderable2D(),
    tecs.ecs.ChildOf(panel)
)

world:spawn(
    ui.Style({maxWidth = "100%"}),
    ui.Intrinsic("text", {wrap = true}),
    tecs.ecs.RelativeTransform2D(0, 0, 2),
    tecs.gfx.Tint(0.94, 0.97, 1.0, 1.0),
    tecs.gfx.Text.new({
        text = "Composed, not replaced",
        font = font,
        size = 22,
    }),
    tecs.ecs.ChildOf(panel)
)
```

### Draw a stretched rectangle

There is no UI rectangle type. This is the normal renderer quad, stretched to
the box computed for its parent:

```teal
local card <const> = world:spawn(
    ui.Style({width = 280, height = 120}),
    RelativeTransform2D(),
    ChildOf(root)
)

world:spawn(
    ui.Style({position = "absolute", inset = 0}),
    ui.Paint(true),
    RelativeTransform2D(0, 0, 0),
    Tint(0.10, 0.17, 0.27, 1.0),
    Material(tecs.gfx.materials.id("rounded"), 0.08),
    Renderable2D(),
    ChildOf(card)
)
```

### Draw a circle at a fixed size

```teal
world:spawn(
    ui.Style({width = 40, height = 40}),
    ui.Paint(true),
    RelativeTransform2D(0, 0, 1),
    Tint(0.32, 0.82, 1.0, 1.0),
    Material(tecs.gfx.materials.id("circle"), 0),
    Renderable2D(),
    ChildOf(card)
)
```

### Render crisp fixed-size UI text

Load an alpha font at the exact size used by `Text`. The same text component,
atlas, producer, clipping, and instancing are used as SDF text. Exact-size
alpha text on a screen-space layer also snaps its origin to a pixel:

```teal
local uiFont <const> = tecs.gfx.newTTF({
    source = "fonts/JetBrainsMono-ExtraBold.ttf",
    name = "settings-ui-16",
    size = 16,
    raster = "alpha",
}):wait().value

world:spawn(
    ui.Style({maxWidth = "100%"}),
    ui.Intrinsic("text"),
    RelativeTransform2D(0, 0, 2),
    Tint(0.94, 0.97, 1.0, 1.0),
    tecs.gfx.Text.new({
        text = "Video settings",
        font = uiFont,
        size = 16,
    }),
    ChildOf(card)
)
```

Use the default `raster = "sdf"` when the same font must animate through many
scales or live in the world. Use separate `name` values when loading the same
source in multiple sizes or raster modes because snapshots resolve fonts by
name.

### Wrap text to the available width

```teal
world:spawn(
    ui.Style({width = "100%", maxWidth = 320}),
    ui.Intrinsic("text", {wrap = true}),
    RelativeTransform2D(0, 0, 2),
    Tint(0.72, 0.80, 0.90, 1.0),
    tecs.gfx.Text.new({
        text = "This paragraph wraps when its parent becomes narrower.",
        font = uiFont,
        size = 16,
    }),
    ChildOf(card)
)
```

### Load an image and preserve its aspect ratio

Images remain asynchronously loaded sprites. This example fixes the height at
64 logical pixels and lets `Intrinsic("image")` derive the width from the
registered sprite region:

```teal
tecs.assets.loadImage(
    tecs.io.files.assetPath("images/portrait.png")
):map(function(image: tecs.assets.Image): tecs.gfx.Sprite
    return app.renderer.sprites:registerImage(image)
end):onSettle(function(loaded: tecs.Future<tecs.gfx.Sprite>)
    if loaded.status == "ready" then
        world:spawn(
            ui.Style({height = 64}),
            ui.Intrinsic("image"),
            ui.Paint(true),
            RelativeTransform2D(0, 0, 2),
            loaded.value,
            Tint(1, 1, 1, 1),
            Renderable2D(),
            ChildOf(card)
        )
    end
end)
```

The callback captures `world`, `app`, and `card` from the application plugin
and startup function shown earlier. It spawns only after the image has entered
the renderer, so no placeholder sprite or per-frame polling is required.

### Give another leaf a natural size

Use custom intrinsic metrics when a dedicated producer already knows its
preferred size. `Paint(true)` below makes the ordinary rectangle consume those
metrics:

```teal
world:spawn(
    ui.Style({maxWidth = "100%"}),
    ui.Intrinsic("custom", {
        width = 96,
        height = 28,
        minWidth = 48,
    }),
    ui.Paint(true),
    RelativeTransform2D(0, 0, 2),
    Tint(0.22, 0.56, 0.68, 1.0),
    Material(tecs.gfx.materials.id("rounded"), 0.12),
    Renderable2D(),
    ChildOf(card)
)
```

`ui.Intrinsic("image")` reads the selected sprite region's source dimensions
from the renderer and preserves its aspect ratio when only one axis is
constrained. `ui.Intrinsic("custom", {width = 80, height = 24})` supplies
cached metrics for another leaf producer. `scale` converts source units into
UI units.

Text wrapping is a retained convergence step. Taffy chooses the available
width, the UI plugin asks SDL_ttf for the exact wrapped height, and only that
dirty root is solved again. No native-to-Lua callback runs inside Taffy and
unchanged text is not reshaped each frame. The chosen width is retained in
`Text.wrapWidth`, so the ordinary text instance producer draws the same lines
that layout measured.

Do not stretch a container that owns layout children. Its transform scale
would compose into every descendant. Stretch a dedicated absolute drawing
child instead.

## Style values and mutation

Numbers and `px` strings are logical UI pixels; pixel density maps them to the
render target. Percent strings are parent-relative, and `auto` selects
automatic size:

```teal
ui.Style({
    width = "100%",
    minHeight = "120px",
    flexBasis = "auto",
    flexGrow = 1,
    margin = {left = "8px", right = "8px"},
})
```

Plain numbers remain the compact form of logical pixels, so `padding = 24`
and `padding = "24px"` are equivalent. The older
`{value = 100, unit = "percent"}` representation remains supported.

Strings are converted to retained typed dimensions only when a style is added
or marked dirty. Window resizing changes the root's available space without
reparsing unchanged styles. Unchanged frames also skip layout export, clipping,
and hit-rectangle reconstruction.

Supported properties are `display`, `position`, `flexDirection`, `flexWrap`,
`justifyContent`, `alignItems`, `alignContent`, `flexGrow`, `flexShrink`,
`flexBasis`, `width`, `height`, minimum and maximum dimensions, `margin`,
`padding`, `border`, `gap`, `rowGap`, and `inset`. See the
[`Style.style`](/modules/ui#tecs.ui.Style.style) contract for accepted values.

Styles are retained component data. Mutate through `getMut` so the plugin can
synchronize the changed node into the retained layout tree:

```teal
local style <const> = world:getMut(panel, ui.Style)
style.style.width = 440
```

### Switch a responsive layout at a breakpoint

Screen roots resize automatically, but a game may still want a deliberate
layout change at a logical-width breakpoint. Cache the selected direction so
`getMut` is called only when the breakpoint changes:

System recipes belong in `gamePlugin`, beside the `Startup` system, rather
than inside `spawnInterface`. Keep the entity ids in plugin-local variables,
assign them from `Startup`, and guard the first update until spawning has
finished. This abbreviated recipe assumes `root` and `body` are those retained
ids:

```teal
local narrow = false

world:addSystem({
    name = "game.ResponsiveUi",
    phase = tecs.ecs.phases.Update,
    run = function()
        if root == 0 or body == 0 then
            return
        end
        local rootValue <const> = world:get(root, ui.Root)
        local nextNarrow <const> = rootValue.width < 720
        if nextNarrow ~= narrow then
            narrow = nextNarrow
            local style <const> = world:getMut(body, ui.Style)
            style.style.flexDirection = narrow and "column" or "row"
        end
    end,
})
```

### Read a computed box

`Layout` is engine-owned output. Read it after UI layout when another system
needs the final logical dimensions:

```teal
world:addSystem({
    name = "game.ReadPanelLayout",
    phase = tecs.ecs.phases.Last,
    run = function()
        local box <const> = world:get(panel, ui.Layout)
        if box ~= nil then
            print(("panel is %.0f by %.0f"):format(box.width, box.height))
        end
    end,
})
```

Do not write `Layout`, `Transform2D`, or `RelativeTransform2D` to resize a retained
node. Change its `Style`; the plugin owns the computed outputs.

## Scroll and clip descendants

Add `Scroll` to the viewport and make the larger content entity its child.
Wheel input targets the deepest viewport under the pointer. The plugin clamps
the offset, moves descendants after layout, intersects nested viewports, and
writes ordinary `tecs.gfx.Clip` indices to drawing entities.

<img src="/images/ui-scroll.png" alt="The Scroll demo scene with a fixed clipped viewport, overflowing rows, and a composed block scrollbar" />

The Scroll scene labels the edge cases directly: fixed viewport size, clipped
descendants, nested wheel handoff, focus reveal, and a scrollbar assembled
from ordinary rectangle entities.

```teal
local viewport <const> = world:spawn(
    ui.Style({
        width = "100%",
        height = 240,
    }),
    ui.Scroll(),
    tecs.ecs.RelativeTransform2D(),
    tecs.ecs.ChildOf(panel)
)

local content <const> = world:spawn(
    ui.Style({
        width = "100%",
        height = 600,
        flexDirection = "column",
        gap = 8,
    }),
    tecs.ecs.RelativeTransform2D(),
    tecs.ecs.ChildOf(viewport)
)
```

Populate the content with ordinary retained rows. The larger authored content
height is what creates overflow:

```teal
local function spawnRow(label: string, tabIndex: integer)
    local row <const> = world:spawn(
        ui.Style({width = "100%", height = 44}),
        ui.Interaction({tabIndex = tabIndex}),
        RelativeTransform2D(),
        ChildOf(content)
    )
    world:spawn(
        ui.Style({position = "absolute", inset = 0}),
        ui.Paint(true),
        RelativeTransform2D(0, 0, 1),
        Tint(0.12, 0.20, 0.30, 1.0),
        Material(tecs.gfx.materials.id("rounded"), 0.08),
        Renderable2D(),
        ChildOf(row)
    )
    world:spawn(
        ui.Style({position = "absolute", inset = {left = 12, top = 14}}),
        ui.Intrinsic("text"),
        RelativeTransform2D(0, 0, 2),
        Tint(0.9, 0.95, 1.0, 1.0),
        tecs.gfx.Text.new({text = label, font = font, size = 16}),
        ChildOf(row)
    )
    return row
end

local lastRow = 0
for index = 1, 20 do
    lastRow = spawnRow(("Item %02d"):format(index), index)
end
```

Programmatic scrolling writes `Scroll.x` or `Scroll.y` through `getMut`.
Offsets clamp to the complete retained extent, including negative and
absolute descendants. `contentX`, `contentY`, `contentWidth`, and
`contentHeight` are engine-owned measurements. Snapshots retain `x` and `y`;
the derived content fields are rebuilt after load.

```teal
-- Scroll by a logical amount. The plugin clamps it during layout.
local scroll <const> = world:getMut(viewport, ui.Scroll)
scroll.y = scroll.y + 80

-- Or expose a particular descendant through every nested viewport.
ui.reveal(world, lastRow, "center")
```

Wheel movement starts at the deepest viewport and hands any unused distance
to its ancestors. It follows the platform's configured scroll direction while
leaving `Input.wheelX` and `Input.wheelY` available to directional gameplay
bindings with their stable sign convention. Shift converts a vertical wheel
into horizontal movement when the device reports no horizontal axis. Call
`ui.reveal(world, entity)` to expose a descendant through every ancestor
viewport. Focusing an entity does this automatically.

Taffy does not create or draw a scrollbar. It lays out the viewport and
content. The UI system turns those retained measurements and `Scroll.y` into
the thumb's `RelativeTransform2D`; the thumb itself uses the same ordinary
material and instance components used elsewhere:

```teal
world:spawn(
    ui.Scrollbar("vertical", 6, 2, 18),
    ui.Interaction({focusable = false, draggable = true, order = 100}),
    tecs.ecs.RelativeTransform2D(0, 0, 10),
    tecs.gfx.Tint(0.4, 0.7, 0.9, 0.9),
    tecs.gfx.Material(tecs.gfx.materials.id("rounded"), 0.5),
    tecs.gfx.Renderable2D(),
    tecs.ecs.ChildOf(viewport)
)
```

The thumb receives a zero length when its axis has no overflow. Horizontal
scrollbars use the same component with `"horizontal"`. A rail, border, end
blocks, arrow controls, or grip marks are optional composed entities. The
repository demo uses squared rectangles for a chunky retro skin; none of that
appearance lives in Taffy or in the scrollbar component.

Here is a complete squared, blocky scrollbar skin. Only the middle entity
carries `Scrollbar`; the track and end blocks are ordinary decoration:

```teal
world:spawn(
    ui.Style({
        position = "absolute",
        width = 14,
        inset = {right = 0, top = 0, bottom = 0},
    }),
    ui.Paint(true),
    RelativeTransform2D(0, 0, 8),
    Tint(0.05, 0.09, 0.14, 1.0),
    Material(tecs.gfx.materials.id("rounded"), 0),
    Renderable2D(),
    ChildOf(viewport)
)

world:spawn(
    ui.Scrollbar("vertical", 12, 16, 28),
    ui.Interaction({focusable = false, draggable = true, order = 100}),
    RelativeTransform2D(0, 0, 10),
    Tint(0.32, 0.82, 1.0, 1.0),
    Material(tecs.gfx.materials.id("rounded"), 0),
    Renderable2D(),
    ChildOf(viewport)
)

for _, top in ipairs({true, false}) do
    world:spawn(
        ui.Style({
            position = "absolute",
            width = 14,
            height = 14,
            inset = top and {right = 0, top = 0} or {right = 0, bottom = 0},
        }),
        ui.Paint(true),
        RelativeTransform2D(0, 0, 11),
        Tint(0.22, 0.56, 0.68, 1.0),
        Material(tecs.gfx.materials.id("rounded"), 0),
        Renderable2D(),
        ChildOf(viewport)
    )
end
```

## Observe clicks and keyboard activation

`Interaction` adds clip-aware hit testing and transient
`InteractionState`. Every mouse or touch identity captures independently.
Releasing over the same target emits `click` followed by `activate`. A
draggable interaction emits `dragStart`, `dragMove`, and `dragEnd`; losing its
input layer emits `dragCancel`. Tab and Shift-Tab move focus and repeat after a
short hold; Return and Space activate the focused control.

```teal
local type uiTypes = require("tecs.ui")
local type UiEvent = uiTypes.Event

local button <const> = world:spawn(
    ui.Style({width = 180, height = 44}),
    ui.Interaction({tabIndex = 1}),
    tecs.ecs.RelativeTransform2D(),
    tecs.ecs.ChildOf(content)
)

world:observe(button, ui.Event, function(event: UiEvent)
    if event.kind == "activate" then
        print("activated via", event.source)
    end
end)
```

`Interaction` makes the container selectable; it does not draw a button. Add
ordinary visual and text children to complete it:

```teal
local buttonVisual <const> = world:spawn(
    ui.Style({position = "absolute", inset = 0}),
    ui.Paint(true),
    RelativeTransform2D(0, 0, 1),
    Tint(0.12, 0.20, 0.30, 1.0),
    Material(tecs.gfx.materials.id("rounded"), 0.16),
    Renderable2D(),
    ChildOf(button)
)

world:spawn(
    ui.Style({position = "absolute", inset = {left = 14, top = 13}}),
    ui.Intrinsic("text"),
    RelativeTransform2D(0, 0, 2),
    Tint(0.9, 0.95, 1.0, 1.0),
    tecs.gfx.Text.new({text = "Apply", font = font, size = 16}),
    ChildOf(button)
)
```

Events bubble through `ChildOf`. An observer can set `event.consumed = true`
to stop ancestor delivery. Consuming a wheel event also suppresses default
scrolling.

```teal
world:observe(panel, ui.Event, function(event: UiEvent)
    if event.kind == "activate" then
        print("panel saw activation from", event.target)
        event.consumed = true
    elseif event.kind == "wheel" and menuIsLocked then
        event.consumed = true
    end
end)
```

`event.pointerId` distinguishes simultaneous touches and
`event.pointerType` reports `"mouse"` or `"touch"`. Pointer movement and drag
events put their movement in `deltaX` and `deltaY`.

### Update hover, press, focus, and drag colors

Keep the control and its drawing child as separate entities. The update system
reads transient state from the control and dirties the GPU tint only when the
selected color changes:

```teal
world:addSystem({
    name = "game.ButtonVisualState",
    phase = tecs.ecs.phases.Update,
    run = function()
        local state <const> = world:get(button, ui.InteractionState)
        local tint <const> = world:get(buttonVisual, Tint)
        local r, g, b = 0.12, 0.20, 0.30
        if state.dragging or state.pressed then
            r, g, b = 0.14, 0.47, 0.62
        elseif state.hovered then
            r, g, b = 0.17, 0.34, 0.48
        elseif state.focused then
            r, g, b = 0.18, 0.29, 0.46
        end
        if tint.r ~= r or tint.g ~= g or tint.b ~= b then
            local changed <const> = world:getMut(buttonVisual, Tint)
            changed.r, changed.g, changed.b = r, g, b
        end
    end,
})
```

Register update systems from `gamePlugin`, beside the `Startup` system. Keep
the spawned entity ids in plugin-local variables so those systems can read
them after startup.

### Handle dragging and simultaneous pointers

```teal
local slider <const> = world:spawn(
    ui.Style({width = 240, height = 32}),
    ui.Interaction({tabIndex = 2, draggable = true}),
    RelativeTransform2D(),
    ChildOf(panel)
)

local dragByPointer: {string: number} = {}
world:observe(slider, ui.Event, function(event: UiEvent)
    if event.kind == "dragStart" then
        dragByPointer[event.pointerId] = 0
    elseif event.kind == "dragMove" then
        dragByPointer[event.pointerId] =
            (dragByPointer[event.pointerId] or 0) + event.deltaX
    elseif event.kind == "dragEnd" or event.kind == "dragCancel" then
        dragByPointer[event.pointerId] = nil
    end
end)
```

Each touch and the mouse has its own `pointerId`, capture, and drag lifecycle.
Do not use one global dragging boolean when a control needs to distinguish
simultaneous touches.

Call `ui.focus`, `ui.blur`, and `ui.focused` for programmatic focus. A modal
panel can carry `ui.FocusScope()` and constrain navigation until popped:

```teal
ui.focus(world, firstField)
ui.pushFocusScope(world, dialog)
-- The active scope now owns Tab traversal and pointer targeting.
ui.popFocusScope(world, dialog) -- Restores the prior focus when possible.
```

This is a complete focus-scope container. Controls spawned below `dialog`
become the only Tab and pointer targets while the scope is active:

```teal
local dialog <const> = world:spawn(
    ui.Style({
        position = "absolute",
        width = 440,
        height = 260,
        inset = {left = "25%", top = "20%"},
        flexDirection = "column",
        padding = 20,
        gap = 12,
    }),
    ui.FocusScope(),
    RelativeTransform2D(0, 0, 20),
    ChildOf(root)
)

local cancelButton <const> = world:spawn(
    ui.Style({width = 120, height = 44}),
    ui.Interaction({tabIndex = 1}),
    RelativeTransform2D(),
    ChildOf(dialog)
)

ui.pushFocusScope(world, dialog)
ui.focus(world, cancelButton)

world:observe(cancelButton, ui.Event, function(event: UiEvent)
    if event.kind == "activate" then
        ui.popFocusScope(world, dialog)
        world:despawn(dialog)
    end
end)
```

### Choose deterministic overlap and navigation order

```teal
local back <const> = world:spawn(
    ui.Style({position = "absolute", width = 160, height = 48, order = 1}),
    ui.Interaction({tabIndex = 1, order = 1}),
    RelativeTransform2D(0, 0, 4),
    ChildOf(panel)
)

local front <const> = world:spawn(
    ui.Style({position = "absolute", width = 160, height = 48, order = 2}),
    ui.Interaction({tabIndex = 2, order = 2}),
    RelativeTransform2D(0, 0, 5),
    ChildOf(panel)
)
```

`Style.style.order` places siblings in layout. `Interaction.order` breaks hit
and focus ties. Transform2D Z determines renderer depth. Set all three when two
controls intentionally overlap rather than relying on entity creation order.

`Interaction.tabIndex` defines the primary navigation order.
`Interaction.order` is the explicit authorial tie-breaker for focus and hit
testing, while `Style.style.order` controls retained sibling layout order.
Equal values fall back to the order in which entities first entered the
retained tree, not to entity identity. Give overlapping controls explicit
orders when their stacking is meaningful.

Read `InteractionState` from an update system to select hover, pressed, and
focused colors. Only call `getMut` on the visual component when the selected
color actually changes, preserving dirty-gated GPU synchronization.

## Editing and accessibility boundary

The current interaction layer stops at semantic activation and dragging. Text
editing, selection, IME composition, clipboard commands, controller spatial
navigation, and platform accessibility exposure are designed but not yet
implemented. In particular, a `Text` drawing entity is not implicitly an edit
control, and an `Interaction` does not invent a role or accessible name.

Those features will remain composed ECS state: editing state beside a `Text`
leaf, platform text input entered only while that entity is focused,
controller actions routed through the input layer, and a semantic snapshot
bridged from Rust without an FFI callback into Lua. They do not require a DOM,
CSS cascade, or parallel widget renderer.

## Run the examples

The repository demo shows layout, rectangle and circle materials, text, an
asynchronously loaded image, nested clipping, wheel scrolling, pointer
capture, bubbling events, and keyboard navigation:

```bash
cargo xtask example ui-demo
```

<img src="/images/ui-example.png" alt="The standalone retained UI example with a centered panel and scrollable controls" />

The smaller [standalone UI example](https://github.com/tecs-dev/tecs/blob/main/docs/examples/ui.tl)
is suitable as a project's `main.tl`.
