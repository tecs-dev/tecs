---
description: "Build retained interfaces with Taffy layout, ordinary drawing entities, scrolling, clipping, and input"
order: 40
---

# Building interfaces

A UI node is a Tecs entity. **Taffy computes its layout** from `Style` and the
`ChildOf` hierarchy; ordinary shapes, sprites and text draw the result through
the existing GPU pipeline. Physics remains Rapier's responsibility.

Run the complete example:

```bash
nupp task ui
```

Resize the window to see the layout respond. Scroll the list, drag its cyan
thumb, click a row, or use Tab and Enter. Close the window to stop.
`examples/nupp/ui.nupp` contains the full application plugin and constructor.

## Compose a screen

Call `tecs.ui.plugin(app)` from your application plugin. It installs layout,
configures the overlay layer, and connects the window's size, display density
and input. Repeated installation on the same world is harmless.

```nupp
tecs.ui.plugin(app)
const root = app.world:spawn(
    tecs.ui.Root(),
    tecs.ui.Style({width = "100%", height = "100%", padding = 24, gap = 12})
)
const button = app.world:spawn(
    tecs.ecs.ChildOf(root),
    tecs.ui.Style({width = 160, height = 48}),
    tecs.ui.Paint(true),
    tecs.ui.Interaction(),
    tecs.gfx.Tint(0.2, 0.6, 0.9, 1),
    tecs.gfx.Material(tecs.gpu.materials.id("rounded"), 0.1),
    tecs.gfx.Renderable2D
)
```

`Style` supplies the required node, layout, transform and clip components.
`Layout` reports x, y, width, height and content extents in logical units.
Read those fields; change `Style` through `world:getMut` to request a new box.
Lengths accept numbers, pixel strings such as `"24px"`, percentage strings,
and `"auto"`.

The style surface includes flex direction and wrapping, grow/shrink/basis,
width and height constraints, alignment, gaps, margin, padding, border,
absolute positioning and inset. `display` also accepts `block`, implicit
`grid`, and `none`; explicit grid track definitions are not exposed.
`order` sorts siblings before layout. `display = "none"` hides the subtree and
removes its interaction targets.

## Containers and drawing leaves

Keep layout containers at unit scale. Put `Paint(true)` on a **drawing leaf**:
it stretches the leaf's quad to its box and places the quad's center there.
A container with a background and a label uses separate children:

```nupp
const panel = world:spawn(tecs.ecs.ChildOf(root),
    tecs.ui.Style({width = 320, padding = 16, flexDirection = "column"}))
world:spawn(tecs.ecs.ChildOf(panel),
    tecs.ui.Style({position = "absolute", inset = 0}),
    tecs.ui.Paint(true), tecs.gfx.Tint(0.08, 0.12, 0.18, 1),
    tecs.gfx.Renderable2D)
```

That background is an ordinary rectangle. A circle or rounded material, a
sprite, and a glyph all retain their regular renderer behavior. Use relative
z values to choose drawing order when composing overlapping leaves.

## Intrinsic text and images

Install `tecs.gfx.text.install(world)` for text. Load a font through
`tecs.gfx.fonts.newTTF`, then let its measured content contribute to layout:

```nupp
world:spawn(tecs.ecs.ChildOf(panel),
    tecs.ui.Style({maxWidth = "100%"}),
    tecs.ui.Intrinsic({source = "text", wrap = true}),
    tecs.gfx.Text("An ordinary entity, sized by its text.", font, 16),
    tecs.gfx.Tint(0.94, 0.97, 1, 1))
```

Text wrapping follows the allocated width. Tecs measures text in Nupp,
supplies those measurements to Taffy, and refreshes glyphs after layout.
There are no native callbacks into game code. Glyphs inherit the UI clip.

For a sprite, use `Intrinsic({source = "image"})`; its UV rectangle determines
its natural dimensions. Custom drawing can supply
`Intrinsic({source = "custom", width = 80, height = 32})`. `scale` scales the
intrinsic measurements. `Paint(true)` remains an independent choice to stretch
the drawing to its resulting box.

## Scrolling and clipping

Put `Scroll()` on a container with a constrained height or width. Give content
that should overflow `flexShrink = 0`. Its descendants move with the scroll
offset and share renderer clip regions; nested scroll containers intersect
those regions.

```nupp
const list = world:spawn(tecs.ecs.ChildOf(root),
    tecs.ui.Style({height = 240, width = 320, flexDirection = "column", gap = 8}),
    tecs.ui.Scroll())
world:spawn(tecs.ecs.ChildOf(list),
    tecs.ui.Style({height = 600, width = 280, flexShrink = 0}))
world:spawn(tecs.ecs.ChildOf(list),
    tecs.ui.Scrollbar({axis = "vertical", thickness = 8}),
    tecs.gfx.Tint(0.2, 0.75, 0.85, 1), tecs.gfx.Renderable2D)
```

Wheel input scrolls the viewport under the pointer. `Scrollbar` sizes a thumb
from the visible/content ratio and dragging it changes the viewport offset.
`Scroll.x` and `.y` can also be written through `getMut`; layout clamps them to
the content bounds. `tecs.ui.reveal(world, entity, "nearest")` brings a
descendant into view; `start`, `center` and `end` choose explicit alignment.

Clip indices default to 1–255. Set `firstClip` and `lastClip` in the install
options when sharing the renderer's global clip table with another subsystem.
Exhausting that reserved range raises an error. Clips and hit bounds are
axis-aligned rectangles enclosing the projected layout boxes.

## Interaction and focus

`Interaction()` opts a box into pointer hit testing, focus and activation.
Events reach the target, bubble through its parents, then reach world address
zero. Set `event.consumed = true` to stop bubbling.

```nupp
world:observe(button, tecs.ui.Event,
    function(event: tecs.ui.Event, exclusive world: tecs.ecs.World): nil
        if event.kind == "activate" then
            world:set(button, tecs.gfx.Tint(0.3, 0.9, 0.6, 1))
        end
    end)
```

Pointer events include `pointerEnter`, `pointerLeave`, `pointerDown`,
`pointerUp`, `click`, and `activate`. `InteractionState` reports hovered,
pressed, focused and dragging state. Pointer capture keeps an active drag
with its original target; `draggable = true` enables `dragStart`, `dragMove`,
`dragEnd` and `dragCancel`. Hiding or disabling a captured target cancels it.
Touch contacts have separate pointer IDs.

Tab moves through focusable nodes in `tabIndex` order; Shift reverses it.
Enter and Space activate focus. Moving focus reveals the target inside its
scroll containers. Controller D-pad moves focus and its south
button activates. `focus`, `blur` and `focused` provide programmatic control.
A `FocusScope` entity can be pushed with `pushFocusScope` to restrict focus
and pointer targets to its subtree; `popFocusScope` restores prior focus.
The selected input layer controls whether UI may read input.

## World roots and lifecycle

`Root()` follows the screen in logical points; the overlay layer defaults to 16. For a panel in the world, use
`Root({space = "world", sizing = "manual", width = 320, height = 180})` and
place its `Transform2D` normally. `sizing = "camera"` sizes a world root from
the current viewport and camera zoom and follows the camera transform.

Without an application, call `tecs.ui.install(world, {width = 800, height = 450})`
and `tecs.ui.resize(world, width, height, pixelDensity)` when the viewport
changes. `world:update` runs layout and interaction in `RenderFirst`.
Unchanged layout avoids native synchronization; changed boxes update their
ordinary transforms. Snapshot loading rebuilds computed layout, and world
shutdown releases the native tree and allocated clips.

See [tecs.ui](tecs.ui) for the complete options and event fields.
