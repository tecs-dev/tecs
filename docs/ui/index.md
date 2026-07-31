---
description: "Compose retained layout, existing GPU drawing components, scrolling, clipping, and input"
outline: deep
---

# Building interfaces

Tecs provides retained layout without introducing a DOM or a second renderer.
A UI node is an entity. [`tecs.ecs.ChildOf`](/modules/ecs/builtins#childof)
defines both its layout hierarchy and its transform hierarchy, while the
existing rectangle, circle, image, sprite, and text producers keep drawing the
result through the normal instanced GPU pipeline.

![The Tecs UI demo with a composed panel, controls, and a clipped scrolling list](/images/ui-overview.png)

The boundary is intentionally narrow:

- [`tecs.ui.Style`](/modules/ui#tecs.ui.Style) supplies layout properties.
- [`tecs.ui.Layout`](/modules/ui#tecs.ui.Layout) reports the computed box.
- [`tecs.ui.Paint`](/modules/ui#tecs.ui.Paint) optionally stretches an existing
  drawing leaf to that box.
- [`tecs.ui.Scroll`](/modules/ui#tecs.ui.Scroll) offsets descendants and assigns
  the existing renderer clip component.
- [`tecs.ui.Interaction`](/modules/ui#tecs.ui.Interaction) opts a box into hit
  testing, focus, and activation.

Layout changes only dirty transforms whose computed results changed. Drawing
components retain their normal batching, materials, dirty tracking, and GPU
instancing.

## Define the retained layout

Keep entity creation in a function dedicated to building the interface. This
function runs once from a `Startup` system; it does not install plugins or
register systems.

```teal
local function spawnInterface(world: tecs.World)
    local ui <const> = tecs.ui

    local root <const> = world:spawn(
        ui.Style({
            width = "100%",
            height = "100%",
            padding = "24px",
        }),
        ui.Root("screen"),
        tecs.Transform(0, 0, 0, 16)
    )

    -- Spawn the panels, drawing leaves, and controls under root here.
end
```

When the plugin receives an application, it keeps every screen root's logical
size and pixel density synchronized with the window. Percentage dimensions
therefore follow a resize without a game observer or per-frame system. World
roots remain explicit and use camera coordinates instead:

```teal
ui.Root("world", cameraWidth, cameraHeight)
```

## Install from the application plugin

The application plugin configures the UI layer, installs one UI plugin in the
world, and registers the system that calls `spawnInterface`. Passing the
application supplies the renderer and folded input. A second table can
override clip allocation, the input layer, or wheel distance.

Paste this block after the `spawnInterface` function above:

```teal
local function gamePlugin(world: tecs.World, app: tecs.Application)
    tecs.gfx.layers.configure(16, {
        sort = "z",
        screenSpace = true,
        unlit = true,
    })

    world:addPlugin(tecs.ui.plugin(app, {wheelStep = 36}))
    world:addSystem({
        name = "game.SpawnInterface",
        phase = tecs.ecs.phases.Startup,
        run = function()
            spawnInterface(world)
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

## Compose visuals from ordinary entities

A container normally has `Style`, `RelativeTransform`, and `ChildOf`. Put its
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
    tecs.ecs.RelativeTransform(),
    tecs.ecs.ChildOf(root)
)

world:spawn(
    ui.Style({position = "absolute", inset = 0}),
    ui.Paint(true),
    tecs.ecs.RelativeTransform(0, 0, 0),
    tecs.gfx.Tint(0.035, 0.055, 0.09, 0.96),
    tecs.gfx.Material(tecs.gfx.materials.id("rounded"), 0.04),
    tecs.gfx.Renderable(),
    tecs.ecs.ChildOf(panel)
)
```

The same pattern works with every drawing producer. A circle keeps the circle
material, text keeps the distance-field text producer, and an image keeps its
sprite:

```teal
world:spawn(
    ui.Style({width = 32, height = 32}),
    ui.Paint(true),
    tecs.ecs.RelativeTransform(0, 0, 2),
    tecs.gfx.Tint(0.32, 0.82, 1.0, 1.0),
    tecs.gfx.Material(tecs.gfx.materials.id("circle"), 0),
    tecs.gfx.Renderable(),
    tecs.ecs.ChildOf(panel)
)

world:spawn(
    ui.Style({width = 280, height = 28}),
    tecs.ecs.RelativeTransform(0, 0, 2),
    tecs.gfx.Tint(0.94, 0.97, 1.0, 1.0),
    tecs.gfx.Text.new({
        text = "Composed, not replaced",
        font = font,
        size = 22,
    }),
    tecs.ecs.ChildOf(panel)
)
```

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

## Scroll and clip descendants

Add `Scroll` to the viewport and make the larger content entity its child.
Wheel input targets the deepest viewport under the pointer. The plugin clamps
the offset, moves descendants after layout, intersects nested viewports, and
writes ordinary `tecs.gfx.Clip` indices to drawing entities.

```teal
local viewport <const> = world:spawn(
    ui.Style({
        width = "100%",
        height = 240,
    }),
    ui.Scroll(),
    tecs.ecs.RelativeTransform(),
    tecs.ecs.ChildOf(panel)
)

local content <const> = world:spawn(
    ui.Style({
        width = "100%",
        height = 600,
        flexDirection = "column",
        gap = 8,
    }),
    tecs.ecs.RelativeTransform(),
    tecs.ecs.ChildOf(viewport)
)
```

Programmatic scrolling writes `Scroll.x` or `Scroll.y` through `getMut`.
`contentWidth` and `contentHeight` are engine-owned measurements.

## Observe clicks and keyboard activation

`Interaction` adds clip-aware hit testing and transient
`InteractionState`. A primary press captures its target through release.
Releasing over the same target emits `click` followed by `activate`. Tab and
Shift-Tab move focus; Return and Space activate the focused control.

```teal
local type uiTypes = require("tecs.ui")
local type UiEvent = uiTypes.Event

local button <const> = world:spawn(
    ui.Style({width = 180, height = 44}),
    ui.Interaction({tabIndex = 1}),
    tecs.ecs.RelativeTransform(),
    tecs.ecs.ChildOf(content)
)

world:observe(button, ui.Event, function(event: UiEvent)
    if event.kind == "activate" then
        print("activated via", event.source)
    end
end)
```

Events bubble through `ChildOf`. An observer can set `event.consumed = true`
to stop ancestor delivery. Consuming a wheel event also suppresses default
scrolling.

![The same demo after keyboard focus and activation change its retained state](/images/ui-interaction.png)

Read `InteractionState` from an update system to select hover, pressed, and
focused colors. Only call `getMut` on the visual component when the selected
color actually changes, preserving dirty-gated GPU synchronization.

## Current limits

Text and images do not yet contribute intrinsic measurements, so give those
leaves explicit dimensions. Scrolling is wheel and programmatic offset;
touch panning, kinetic motion, scrollbars, focus reveal, and nested-wheel
handoff are not implemented. Navigation is linear Tab order, and pointer input
currently models one mouse pointer and its primary button.

These limits keep the ownership boundary visible. Future controls remain
composed entities rather than a DOM, CSS cascade, or parallel widget renderer.

## Run the examples

The repository demo shows layout, rectangle and circle materials, text, an
asynchronously loaded image, nested clipping, wheel scrolling, pointer
capture, bubbling events, and keyboard navigation:

```bash
cargo xtask run
```

The smaller [standalone UI example](https://github.com/tecs-dev/tecs/blob/main/docs/examples/ui.tl)
is suitable as a project's `main.tl`.
