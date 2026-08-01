--[=[
Build retained interfaces from ordinary Tecs entities.

`tecs.ui` supplies responsive layout, intrinsic sizing, clipping, scrolling,
hit testing, keyboard focus, and semantic interaction events for HUDs, menus,
inspectors, inventories, and in-world panels. A UI tree is an ECS hierarchy:
spawn entities, relate them with `ChildOf`, describe their boxes with
[`Style`](tealdoc:tecs.ui.Style), and let the plugin update only the layout and
GPU instance data that changed. Screen roots follow window resizing and pixel
density automatically.

<img src="/images/ui-compose.png" alt="The Compose demo scene combining an intrinsic image, a stretched rectangle, a fixed circle, and text" />

Use the module when several visual entities must size and position one another,
when content must scroll or clip, or when pointer and keyboard input should
target the same retained boxes that were drawn. It is not a DOM or a separate
widget renderer. Existing rectangles, circles, sprites, images, and text remain
the visible pieces, with their current materials, shaders, batching, and dirty
tracking. `tecs.ui` composes those pieces and gives them layout and interaction.

[`Style`](tealdoc:tecs.ui.Style) describes layout rather than appearance. Put a
drawing component on the same entity or on a child, and add `Paint(true)` when
its transform should stretch to the computed box. Drawing remains in the
existing instanced producers and shaders.

The [complete interface guide](/ui/) contains 37 copyable recipes for layout,
visual composition, intrinsic sizing, images, scrolling, interaction, focus,
and dirty-aware updates. The examples below provide a complete starting point
without leaving this API reference.

The plugin retains one native layout tree keyed by ECS entity ID. `ChildOf` is the
layout hierarchy as well as the transform hierarchy. The layout system writes
`Layout` only when the box changes and writes `RelativeTransform` only when
layout or scrolling changes its result. Query membership observers retain
structural invalidation, the ECS dirty-archetype set gates value updates, and
the native tree computes only dirty roots before returning a compact list of
changed boxes.

`px`, `%`, and `auto` dimension strings are parsed only when a `Style` enters or dirties the
retained tree. Unchanged frames skip layout computation, layout export, clip
reconstruction, and hit-rectangle reconstruction. A screen root installed
through `plugin(app)` follows the application's logical window size and pixel
density automatically. The plugin observes viewport changes on the world's
platform event bus, so unchanged frames do not poll the window.

[`Intrinsic`](tealdoc:tecs.ui.Intrinsic) copies cached text, sprite-region, or
custom leaf metrics into Taffy when the source component dirties. Wrapping text
uses a bounded retained convergence pass: Taffy chooses its width, SDL_ttf
measures that width exactly, and no native layout callback enters Lua.

`Paint(true)` centers and stretches a drawing leaf over its box. Keep
containers at unit scale and put their rectangle, circle, or image on an
absolute child with `Paint`: transform scale composes through `ChildOf`, so a
stretched container would also scale its descendants.

## Flex sizing and wrapping

<img src="/images/ui-flex.png" alt="The Flex demo scene comparing a fixed-width child with flex-grow children and a wrapped grid" />

The first row compares a fixed `88px` child with `flexGrow` weights one and
two. The cards below use `flexWrap = "wrap"`, so the screenshot shows both
remaining-space distribution and line wrapping against one retained parent.

## Absolute positioning and depth

<img src="/images/ui-overlay.png" alt="The Overlay demo scene with four absolutely positioned corner cards and a centered higher-depth circle" />

Absolute children anchor to their retained parent without consuming flex
space. Renderer depth remains a separate concern, which is why the center
circle and its label can sit above the four anchored cards.

## Scrolling and clipping

[`Scroll`](tealdoc:tecs.ui.Scroll) turns its entity's layout box into a
viewport. Its `x` and `y` move descendants, not the viewport entity itself.
Every nested viewport is intersected before the plugin assigns the existing
`tecs.gfx.Clip` component, so each drawable still carries one clip index in the
ordinary GPU instance. `firstClip` and `lastClip` reserve which of the
renderer’s 255 clip rectangles the UI owns.

Content extent includes negative, absolute, and nested descendants. Wheel
distance that a deepest viewport cannot consume passes to its ancestors.
`reveal` exposes a descendant programmatically, and `Scrollbar` derives a
composed thumb transform without adding a renderer primitive. Snapshots retain
scroll offsets and derive content extent again after load.

<img src="/images/ui-scroll.png" alt="The Scroll demo scene with a fixed clipped viewport, overflowing rows, and a composed block scrollbar" />

Screen roots use logical UI coordinates and multiply clips by `pixelDensity`.
World roots project viewport corners through the renderer camera. Clip
rectangles stay axis-aligned; rotating a scroll viewport therefore does not
rotate its clip.

## Interaction and navigation

Passing the application to [`plugin`](tealdoc:tecs.ui.plugin) supplies its
renderer and input, enabling clip-aware hit testing. Manual options remain
available to tests and tools. [`Interaction`](tealdoc:tecs.ui.Interaction) opts
in a layout box, and [`InteractionState`](tealdoc:tecs.ui.InteractionState)
reports hover, per-pointer capture, drag, and focus without replacing
application state.

The plugin emits one bubbling [`Event`](tealdoc:tecs.ui.Event) at entity
addresses. Mouse and touch identities capture independently; releasing over a
captured target emits `"click"` and then `"activate"`, while draggable targets
emit semantic drag events. Tab and Shift-Tab traverse visible focusable
controls and repeat while held, and Return or Space emits `"activate"` at the
focused control.
Programmatic focus, focus reveal, and modal focus scopes use the same state. A
`"wheel"` event begins at the deepest viewport under the pointer; setting
`event.consumed = true` prevents both ancestor delivery and default scrolling.

Hit priority uses the renderer's layer-depth calculation. A depth tie prefers
the deeper UI node, explicit `Interaction.order`, and then stable retained
insertion order. `Style.style.order` independently orders layout siblings.
Give overlapping controls explicit orders and distinct renderer depth when
both their input and drawing order are meaningful.

## Complete application

Keep entity composition separate from plugin setup. This first block creates
a full-window root, a centered panel, an ordinary GPU-rendered background, and
intrinsically sized text:

```teal
local tecs <const> = require("tecs")
local ui <const> = tecs.ui
local ChildOf <const> = tecs.ecs.ChildOf
local RelativeTransform <const> = tecs.ecs.RelativeTransform
local Tint <const> = tecs.gfx.Tint
local Material <const> = tecs.gfx.Material
local Renderable <const> = tecs.gfx.Renderable

local function spawnInterface(
    world: tecs.World,
    app: tecs.Application,
    font: tecs.gfx.Font
)
    local root <const> = world:spawn(
        ui.Style({
            width = "100%",
            height = "100%",
            justifyContent = "center",
            alignItems = "center",
        }),
        ui.Root("screen"),
        tecs.Transform(0, 0, 0, 16)
    )

    local panel <const> = world:spawn(
        ui.Style({
            width = 420,
            height = 240,
            flexDirection = "column",
            padding = 20,
            gap = 12,
        }),
        RelativeTransform(),
        ChildOf(root)
    )

    world:spawn(
        ui.Style({position = "absolute", inset = 0}),
        ui.Paint(true),
        RelativeTransform(0, 0, 0),
        Tint(0.035, 0.055, 0.09, 0.96),
        Material(tecs.gfx.materials.id("rounded"), 0.05),
        Renderable(),
        ChildOf(panel)
    )

    world:spawn(
        ui.Style({maxWidth = "100%"}),
        ui.Intrinsic("text", {wrap = true}),
        RelativeTransform(0, 0, 1),
        Tint(0.94, 0.97, 1.0, 1.0),
        tecs.gfx.Text.new({
            text = "This text and panel are ordinary ECS entities.",
            font = font,
            size = 16,
        }),
        ChildOf(panel)
    )
end
```

The application plugin installs text and UI before a `Startup` system spawns
the retained entities. Passing `app` to `ui.plugin` supplies the renderer,
input, window size, and pixel density:

```teal
local function gamePlugin(world: tecs.World, app: tecs.Application)
    tecs.gfx.layers.configure(16, {
        sort = "z",
        screenSpace = true,
        unlit = true,
    })
    world:addPlugin(tecs.gfx.textPlugin({renderer = app.renderer}))
    world:addPlugin(ui.plugin(app))
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

return tecs.newApplication({plugin = gamePlugin})
```

The standalone [`docs/examples/ui.tl`](https://github.com/tecs-dev/tecs/blob/main/docs/examples/ui.tl)
application expands that setup into a scrollable, keyboard-navigable panel:

<img src="/images/ui-example.png" alt="The standalone retained UI example with a centered panel and scrollable controls" />

## Common recipes

### Stretch an ordinary rectangle over a layout box

Put the drawing component on an absolute child. `Paint(true)` copies the
computed width and height into its relative transform without scaling the
container's descendants:

```teal
local card <const> = world:spawn(
    ui.Style({width = 280, height = 120}),
    RelativeTransform(),
    ChildOf(panel)
)

world:spawn(
    ui.Style({position = "absolute", inset = 0}),
    ui.Paint(true),
    RelativeTransform(0, 0, 0),
    Tint(0.10, 0.17, 0.27, 1.0),
    Material(tecs.gfx.materials.id("rounded"), 0.08),
    Renderable(),
    ChildOf(card)
)
```

### Load an image and preserve its aspect ratio

The asset loader decodes pixels asynchronously. The renderer registers them
and returns the ordinary sprite consumed by `Intrinsic("image")`:

```teal
tecs.assets.loadImage(
    tecs.io.files.assetPath("images/portrait.png")
):map(function(image: tecs.assets.Image): tecs.gfx.Sprite
    return app.renderer:registerImage(image)
end):onSettle(function(loaded: tecs.Future<tecs.gfx.Sprite>)
    if loaded.status == "ready" then
        world:spawn(
            ui.Style({height = 64}),
            ui.Intrinsic("image"),
            ui.Paint(true),
            RelativeTransform(0, 0, 2),
            loaded.value,
            Tint(1, 1, 1, 1),
            Renderable(),
            ChildOf(panel)
        )
    end
end)
```

### Create a clipped scrolling list

`Scroll` belongs on the fixed viewport. Its larger child creates overflow,
and the scrollbar is an ordinary composed drawing entity rather than a Taffy
or renderer primitive:

```teal
local viewport <const> = world:spawn(
    ui.Style({width = "100%", height = 240}),
    ui.Scroll(),
    RelativeTransform(),
    ChildOf(panel)
)

local content <const> = world:spawn(
    ui.Style({
        width = "100%",
        height = 600,
        flexDirection = "column",
        gap = 8,
    }),
    RelativeTransform(),
    ChildOf(viewport)
)

world:spawn(
    ui.Scrollbar("vertical", 12, 4, 28),
    ui.Interaction({focusable = false, draggable = true, order = 100}),
    RelativeTransform(0, 0, 10),
    Tint(0.32, 0.82, 1.0, 1.0),
    Material(tecs.gfx.materials.id("rounded"), 0),
    Renderable(),
    ChildOf(viewport)
)
```

### Observe pointer and keyboard activation

`Interaction` makes the computed box selectable but draws nothing. Events
bubble through `ChildOf`, and Return or Space produces the same `activate`
event as a click:

```teal
local type uiTypes = require("tecs.ui")
local type UiEvent = uiTypes.Event

local button <const> = world:spawn(
    ui.Style({width = 180, height = 44}),
    ui.Interaction({tabIndex = 1}),
    RelativeTransform(),
    ChildOf(content)
)

world:observe(button, ui.Event, function(event: UiEvent)
    if event.kind == "activate" then
        print("activated via", event.source)
    end
end)
```

### Change a retained style

Use `getMut` only when a property actually changes. This dirties the retained
style once; unchanged frames do not parse the string or recompute the tree:

```teal
local style <const> = world:getMut(panel, ui.Style)
style.style.width = "100%"
style.style.maxWidth = "480px"
```

### Focus and reveal a control

Programmatic focus uses the same state and navigation order as Tab. Focusing a
clipped descendant reveals it through every ancestor viewport:

```teal
ui.focus(world, button)
ui.reveal(world, button, "center")

local focused <const> = ui.focused(world)
if focused == button then
    ui.blur(world)
end
```

]=]

local ecs <const> = require("tecs.ecs")
local events <const> = require("tecs.events")
local platformEvents <const> = require("tecs.platform.events")
local type platformEventTypes = require("tecs.platform.events")
local type types = require("tecs.types")
local type internal = require("tecs.internal.types")
local rust <const> = require("tecs.ffi.rust")
local type loader = require("tecs.ffi.loader")
local components <const> = require("tecs.components")
local layers <const> = require("tecs.gfx.layers")
local text <const> = require("tecs.gfx.text")
local ffi <const> = require("ffi")

local type Component = ecs.Component
local type World = types.World
local type PlatformEvent = platformEventTypes.Event
local type Renderer = require("tecs.Renderer")

local C <const> = rust.C
local Transform <const> = ecs.Transform
local RelativeTransform <const> = ecs.RelativeTransform
local ChildOf <const> = ecs.ChildOf
local Clip <const> = components.Clip

--- `RootSpace` selects whether a retained tree uses screen or world coordinates.
local enum RootSpace
    --- Read-only. Uses logical screen coordinates and a screen-space layer.
    "screen"
    --- Read-only. Uses coordinates projected through the active camera.
    "world"
end

--- `RootSizing` selects where a root receives its available dimensions.
local enum RootSizing
    --- Read-only. Follows the window for screen roots and preserves world-root dimensions.
    "auto"
    --- Read-only. Preserves the caller-authored dimensions and pixel density.
    "manual"
    --- Read-only. Derives a world root from the active camera and viewport.
    "camera"
end

--- `IntrinsicSource` selects which leaf component owns natural dimensions.
local enum IntrinsicSource
    --- Read-only. Uses the dimensions stored directly on `Intrinsic`.
    "custom"
    --- Read-only. Measures the entity's `tecs.gfx.Text` component.
    "text"
    --- Read-only. Measures the entity's registered `tecs.gfx.Sprite` region.
    "image"
end

--- `ScrollAxis` selects the dimension controlled by a scrollbar thumb.
local enum ScrollAxis
    --- Read-only. Controls the ancestor viewport's horizontal offset.
    "horizontal"
    --- Read-only. Controls the ancestor viewport's vertical offset.
    "vertical"
end

--- `EventKind` identifies one semantic UI interaction.
local enum EventKind
    --- Read-only. Reports that a pointer entered an interaction.
    "pointerEnter"
    --- Read-only. Reports that a pointer left an interaction.
    "pointerLeave"
    --- Read-only. Reports that a pointer button went down over an interaction.
    "pointerDown"
    --- Read-only. Reports pointer movement over or captured by an interaction.
    "pointerMove"
    --- Read-only. Reports that a captured pointer button went up.
    "pointerUp"
    --- Read-only. Reports a press and release over the same interaction.
    "click"
    --- Read-only. Reports wheel input over a retained viewport.
    "wheel"
    --- Read-only. Reports that an interaction received keyboard focus.
    "focus"
    --- Read-only. Reports that an interaction lost keyboard focus.
    "blur"
    --- Read-only. Reports semantic activation from pointer, keyboard, or controller input.
    "activate"
    --- Read-only. Reports that captured pointer movement crossed the drag threshold.
    "dragStart"
    --- Read-only. Reports movement during an active drag.
    "dragMove"
    --- Read-only. Reports normal completion of an active drag.
    "dragEnd"
    --- Read-only. Reports cancellation of an active drag.
    "dragCancel"
end

--- `PointerType` identifies the device associated with a UI event.
local enum PointerType
    --- Read-only. Identifies the application mouse.
    "mouse"
    --- Read-only. Identifies one touch contact.
    "touch"
    --- Read-only. Identifies one pen contact.
    "pen"
    --- Read-only. Reports that an event has no pointer device.
    "none"
end

--- `InteractionSource` identifies what initiated a semantic UI event.
local enum InteractionSource
    --- Read-only. Reports mouse, touch, pen, or wheel input.
    "pointer"
    --- Read-only. Reports keyboard navigation or activation.
    "keyboard"
    --- Read-only. Reports controller navigation or activation.
    "controller"
    --- Read-only. Reports a call made directly by game code.
    "programmatic"
end

--- `RevealAlign` selects where a revealed descendant lands in each viewport.
local enum RevealAlign
    --- Read-only. Moves only enough to expose the descendant.
    "nearest"
    --- Read-only. Places the descendant at the viewport's leading edge.
    "start"
    --- Read-only. Centers the descendant in the viewport.
    "center"
    --- Read-only. Places the descendant at the viewport's trailing edge.
    "end"
end

--- `Style` stores the layout properties that place one UI entity.
local record Style is Component
    --- Caller-writable. The caller supplies a table and marks `Style` dirty
    --- after mutating it. Numbers and `"24px"` strings use logical UI pixels,
    --- `"50%"` is parent-relative, and `"auto"` selects automatic sizing.
    --- Invalid strings raise when the plugin synchronizes the style. The
    --- older `{value=number, unit="percent"}` and `unit="points"` table forms
    --- remain supported.
    ---
    --- Supported keys are `display`, `position`, `flexDirection`, `flexWrap`,
    --- `justifyContent`, `alignItems`, `alignContent`, `flexGrow`,
    --- `flexShrink`, `flexBasis`, `width`, `height`, `minWidth`, `minHeight`,
    --- `maxWidth`, `maxHeight`, `margin`, `padding`, `border`, `gap`,
    --- `rowGap`, `inset`, and the Tecs-only integer `order` used to retain
    --- authorial sibling order. Edge values accept one dimension or a table
    --- with `left`, `right`, `top`, and `bottom`.
    style: {string: any}
end
--- `Root` supplies the available space and coordinate mapping for one tree.
local record Root is Component
    --- Caller-writable. The caller chooses `"screen"` for logical screen
    --- coordinates or `"world"` for coordinates projected by the camera.
    space: RootSpace
    --- Caller-writable. The caller supplies the layout root width. An
    --- application-backed screen root with automatic sizing follows the
    --- logical window width; a camera-sized world root derives world units
    --- from the physical viewport and camera zoom.
    width: number
    --- Caller-writable. The caller supplies the layout root height. An
    --- application-backed screen root with automatic sizing follows the
    --- logical window height; a camera-sized world root derives world units
    --- from the physical viewport and camera zoom.
    height: number
    --- Caller-writable. The caller supplies target pixels per logical point.
    --- The default is one. Automatic screen and camera-sized world roots
    --- follow the window's current pixel density.
    pixelDensity: number
    --- Caller-writable. The caller selects `"auto"` for the standard behavior,
    --- `"manual"` to preserve every authored field, or `"camera"` on a world
    --- root to derive its extent and transform from the active camera.
    --- `"auto"` follows the window for screen roots and is manual for world
    --- roots.
    sizing: RootSizing
end
--- `Layout` reports the last box computed by retained layout.
local record Layout is Component
    --- Read-only. The engine reports the box's X offset from its parent.
    x: number
    --- Read-only. The engine reports the box's Y offset from its parent.
    y: number
    --- Read-only. The engine reports the box width in logical units.
    width: number
    --- Read-only. The engine reports the box height in logical units.
    height: number
end
--- `Paint` controls how a drawing component consumes its layout box.
local record Paint is Component
    --- Caller-writable. The caller enables `stretch` to copy the layout width
    --- and height into `RelativeTransform.scaleX` and `scaleY`.
    stretch: boolean
end
--- `Intrinsic` supplies cached leaf metrics to layout without a Lua callback.
local record Intrinsic is Component
    --- Caller-writable. The caller selects `"custom"`, `"text"`, or
    --- `"image"`. Text reads `tecs.gfx.text.Text`; image reads
    --- `tecs.components.Sprite`; custom reads the dimensions below.
    source: IntrinsicSource
    --- Caller-writable. The caller supplies the preferred custom width in
    --- logical units. Text and image sources ignore this field.
    width: number
    --- Caller-writable. The caller supplies the preferred custom height in
    --- logical units. Text and image sources ignore this field.
    height: number
    --- Caller-writable. The caller supplies the custom minimum-content width.
    --- Zero uses `width`. Text derives its longest unbroken run and image
    --- sources preserve their aspect ratio instead.
    minWidth: number
    --- Caller-writable. The caller scales text or source-image units into UI
    --- units. The default is one.
    scale: number
    --- Caller-writable. The caller lets Taffy choose a text line width and
    --- lets the plugin write that result to `Text.wrapWidth`. Other sources
    --- ignore this field.
    wrap: boolean
end
--- `Scroll` offsets descendants and clips them to this entity's layout box.
local record Scroll is Component
    --- Caller-writable. The caller supplies the horizontal scroll offset in
    --- logical units.
    x: number
    --- Caller-writable. The caller supplies the vertical scroll offset in
    --- logical units.
    y: number
    --- Engine-owned. The engine reports the horizontal extent of retained
    --- content, including nested and absolute descendants. Ordinary game code
    --- should ignore this field.
    contentWidth: number
    --- Engine-owned. The engine reports the vertical extent of retained
    --- content, including nested and absolute descendants. Ordinary game code
    --- should ignore this field.
    contentHeight: number
    --- Engine-owned. The engine reports the smallest horizontal content
    --- coordinate, including negative-positioned descendants. Ordinary game
    --- code should ignore this field.
    contentX: number
    --- Engine-owned. The engine reports the smallest vertical content
    --- coordinate, including negative-positioned descendants. Ordinary game
    --- code should ignore this field.
    contentY: number
end
--- `Scrollbar` derives one composed thumb transform from an ancestor viewport.
local record Scrollbar is Component
    --- Caller-writable. The caller selects `"horizontal"` or `"vertical"`.
    axis: ScrollAxis
    --- Caller-writable. The caller sets the thumb thickness in logical units.
    thickness: number
    --- Caller-writable. The caller leaves this much room inside each end of
    --- the viewport track.
    inset: number
    --- Caller-writable. The caller sets the smallest thumb length in logical
    --- units.
    minLength: number
end
--- `FocusScope` marks an entity that may become the active navigation boundary.
local record FocusScope is Component
end
--- `Interaction` makes one computed layout box a UI input target.
local record Interaction is Component
    --- Caller-writable. The caller controls whether hit testing and navigation
    --- can select this entity. The default is true.
    enabled: boolean
    --- Caller-writable. The caller controls whether clicking or keyboard
    --- navigation can focus this entity. The default is true.
    focusable: boolean
    --- Caller-writable. The caller orders keyboard focus. Positive values come
    --- first in ascending order, zero values follow in authorial order, and
    --- negative values skip keyboard navigation.
    tabIndex: integer
    --- Caller-writable. The caller supplies an authorial tie-breaker for hit
    --- testing and focus when controls share renderer depth and tab index.
    --- Higher values hit later; lower values focus first.
    order: integer
    --- Caller-writable. The caller enables semantic drag events after pointer
    --- movement crosses the plugin's drag threshold.
    draggable: boolean
end
--- `InteractionState` reports transient state derived by the UI plugin.
local record InteractionState is Component
    --- Engine-owned. The engine reports whether the pointer is over the
    --- entity's visible, clipped box. Ordinary game code may read this field
    --- to choose its visual state and must not write it.
    hovered: boolean
    --- Engine-owned. The engine reports whether at least one pointer was
    --- pressed on the entity and remains captured. Ordinary game code may read
    --- this field and must not write it.
    pressed: boolean
    --- Engine-owned. The engine reports whether keyboard activation currently
    --- targets the entity. Ordinary game code may read this field and must not
    --- write it.
    focused: boolean
    --- Engine-owned. The engine reports whether at least one captured pointer
    --- is dragging this entity. Ordinary game code may read this field and
    --- must not write it.
    dragging: boolean
end
--- `Event` reports one semantic interaction at an entity address.
local record Event is events.Event
    --- Read-only. Reports `"pointerEnter"`, `"pointerLeave"`,
    --- `"pointerDown"`, `"pointerMove"`, `"pointerUp"`, `"click"`, `"wheel"`,
    --- `"focus"`, `"blur"`, `"activate"`, `"dragStart"`, `"dragMove"`,
    --- `"dragEnd"`, or `"dragCancel"`.
    kind: EventKind
    --- Read-only. Identifies the entity where dispatch began.
    target: integer
    --- Read-only. Identifies the entity whose observers are currently
    --- receiving this bubbling event.
    currentTarget: integer
    --- Read-only. Reports the pointer's horizontal window coordinate.
    x: number
    --- Read-only. Reports the pointer's vertical window coordinate.
    y: number
    --- Read-only. Reports the mouse button, or zero for touch and events that
    --- have no button.
    button: integer
    --- Read-only. Identifies `"mouse"` or one opaque touch identity. Keyboard,
    --- controller, and programmatic events use the empty string.
    pointerId: string
    --- Read-only. Reports `"mouse"`, `"touch"`, `"pen"`, or `"none"`.
    pointerType: PointerType
    --- Read-only. Reports horizontal movement for pointer-move, drag, and
    --- wheel events, or zero for other events.
    deltaX: number
    --- Read-only. Reports vertical movement for pointer-move, drag, and wheel
    --- events, or zero for other events.
    deltaY: number
    --- Read-only. Reports `"pointer"`, `"keyboard"`, `"controller"`, or
    --- `"programmatic"` as the activation source.
    source: InteractionSource
    --- Caller-writable. An observer may set this field to stop bubbling and
    --- suppress the default wheel scroll.
    consumed: boolean

    --- Creates an interaction event value.
    ---
    --- Ordinary game code receives these values from the world bus and does
    --- not construct them.
    ---
    --- @param self The interaction event type.
    --- @param kind The externally stable interaction kind.
    --- @param target The entity where dispatch begins.
    --- @param x The pointer's horizontal window coordinate.
    --- @param y The pointer's vertical window coordinate.
    --- @param button The mouse button or zero.
    --- @param pointerId The pointer's stable identity or the empty string.
    --- @param pointerType The pointer device kind or `"none"`.
    --- @param deltaX Horizontal pointer, drag, or wheel movement or zero.
    --- @param deltaY Vertical pointer, drag, or wheel movement or zero.
    --- @param source The activation source.
    --- @return Returns an independent event value.
    --- @local
    metamethod __call: function(
        self,
        kind: EventKind,
        target: integer,
        x: number,
        y: number,
        button: integer,
        pointerId: string,
        pointerType: PointerType,
        deltaX: number,
        deltaY: number,
        source: InteractionSource
    ): Event
end
local interface TouchReader
    device: string
    finger: string
    x: number
    y: number
    pressure: number
end
local interface InputReader
    mouseX: number
    mouseY: number
    wheelX: number
    wheelY: number
    wheelPreferredX: number
    wheelPreferredY: number
    canRead: function(self: InputReader, layer?: any): boolean
    mousePressed: function(self: InputReader, button: string | integer, layer?: any): boolean
    mouseReleased: function(self: InputReader, button: string | integer, layer?: any): boolean
    keyDown: function(self: InputReader, key: string | integer, layer?: any): boolean
    keyPressed: function(self: InputReader, key: string | integer, layer?: any): boolean
    modifierDown: function(self: InputReader, name: string, layer?: any): boolean
    touches: function(self: InputReader, layer?: any): {TouchReader}
end
local interface WindowReader
    getSize: function(self: WindowReader): integer, integer
    pixelDensity: function(self: WindowReader): number
end
--- `Options` configures one world's retained UI service through explicit dependencies.
local record Options
    --- Caller-writable. The caller supplies the renderer whose camera and GPU
    --- clip table the UI uses.
    renderer: Renderer
    --- Caller-writable. The caller reserves the first UI-owned clip index.
    --- The default is one.
    firstClip: integer
    --- Caller-writable. The caller reserves the last UI-owned clip index.
    --- The default is 255.
    lastClip: integer
    --- Caller-writable. The caller supplies the application's folded input to
    --- enable hit testing, scrolling, focus, and activation. Omitting it
    --- installs layout and clipping only.
    input: any
    --- Caller-writable. The caller supplies the input layer the UI may read.
    --- Omitting it reads the base layer.
    layer: any
    --- Caller-writable. The caller sets logical scroll units per wheel unit.
    --- The default is 40.
    wheelStep: number
    --- Caller-writable. The caller sets pointer movement in logical units
    --- before a draggable capture emits `"dragStart"`. The default is four.
    dragThreshold: number
end
--- `Overrides` changes defaults supplied by an application or explicit options.
local record Overrides
    --- Caller-writable. The caller reserves the first UI-owned clip index.
    --- The default is one.
    firstClip: integer
    --- Caller-writable. The caller reserves the last UI-owned clip index.
    --- The default is 255.
    lastClip: integer
    --- Caller-writable. The caller supplies the input layer the UI may read.
    --- Omitting it reads the base layer.
    layer: any
    --- Caller-writable. The caller sets logical scroll units per wheel unit.
    --- The default is 40.
    wheelStep: number
    --- Caller-writable. The caller sets pointer movement in logical units
    --- before a draggable capture emits `"dragStart"`. The default is four.
    dragThreshold: number
end

-- Compatibility surface: snapshots and tools name this component "UiNode".
local NodeComponent <const> = ecs.newTagComponent({name = "UiNode"})

-- Compatibility surface: snapshots and tools name this component "UiLayout".
ecs.newFFIComponent({
    name = "UiLayout",
    container = Layout,
    fields = {{"x", "float"}, {"y", "float"}, {"width", "float"}, {"height", "float"}},
    defaults = {0, 0, 0, 0},
    transient = true,
})

-- Compatibility surface: snapshots and tools name this component "UiStyle".
ecs.newComponent({
    name = "UiStyle",
    container = Style,
    fields = {"style"},
    requires = {NodeComponent, Layout, Clip},
    __call = function(instance: Style, style?: {string: any}) instance.style = style or {} end,
})

-- Compatibility surface: snapshots and tools name this component "UiRoot".
ecs.newComponent({
    name = "UiRoot",
    container = Root,
    fields = {"space", "width", "height", "pixelDensity", "sizing"},
    defaults = {"screen", 0, 0, 1, "auto"},
    requires = {Style, Transform},
})

-- Compatibility surface: snapshots and tools name this component "UiPaint".
ecs.newComponent({
    name = "UiPaint",
    container = Paint,
    fields = {"stretch"},
    defaults = {false},
})

-- Compatibility surface: snapshots and tools name this component
-- "UiIntrinsic".
ecs.newComponent({
    name = "UiIntrinsic",
    container = Intrinsic,
    fields = {"source", "width", "height", "minWidth", "scale", "wrap"},
    defaults = {"custom", 0, 0, 0, 1, false},
    requires = {Style},
    __call = function(instance: Intrinsic, source?: IntrinsicSource | {string: any}, options?: {string: any})
        local values = options or {}
        if type(source) == "table" then
            values = source as {string: any}
            source = values.source as IntrinsicSource
        end
        instance.source = source as IntrinsicSource or "custom"
        instance.width = values.width as number or 0
        instance.height = values.height as number or 0
        instance.minWidth = values.minWidth as number or 0
        instance.scale = values.scale as number or 1
        instance.wrap = values.wrap == true
        if instance.source ~= "custom" and instance.source ~= "text" and instance.source ~= "image" then
            error("tecs: Intrinsic.source must be 'custom', 'text', or 'image'", 3)
        end
        if instance.scale < 0 then
            error("tecs: Intrinsic.scale cannot be negative", 3)
        end
    end,
})

-- Compatibility surface: snapshots and tools name this component "UiScroll".
ecs.newFFIComponent({
    name = "UiScroll",
    container = Scroll,
    fields = {
        {"x", "float"},
        {"y", "float"},
        {"contentWidth", "float"},
        {"contentHeight", "float"},
        {"contentX", "float"},
        {"contentY", "float"},
    },
    defaults = {0, 0, 0, 0, 0, 0},
    requires = {Style},
    serialize = function(instance: Scroll): {string: any} return {x = instance.x, y = instance.y} end,
    deserialize = function(_world: World, stored: {string: any}): Scroll
        return Scroll(stored.x as number or 0, stored.y as number or 0)
    end,
})

-- Compatibility surface: snapshots and tools name this component
-- "UiScrollbar".
ecs.newComponent({
    name = "UiScrollbar",
    container = Scrollbar,
    fields = {"axis", "thickness", "inset", "minLength"},
    defaults = {"vertical", 6, 2, 18},
    requires = {RelativeTransform},
    init = function(instance: Scrollbar)
        if instance.axis ~= "horizontal" and instance.axis ~= "vertical" then
            error("tecs: Scrollbar.axis must be 'horizontal' or 'vertical'", 3)
        end
        if instance.thickness < 0 or instance.inset < 0 or instance.minLength < 0 then
            error("tecs: Scrollbar dimensions cannot be negative", 3)
        end
    end,
})

-- Compatibility surface: snapshots and tools name this component
-- "UiFocusScope".
ecs.newComponent({
    name = "UiFocusScope",
    container = FocusScope,
    fields = {},
})

-- Compatibility surface: snapshots and tools name this component
-- "UiInteractionState".
ecs.newFFIComponent({
    name = "UiInteractionState",
    container = InteractionState,
    fields = {{"hovered", "bool"}, {"pressed", "bool"}, {"focused", "bool"}, {"dragging", "bool"}},
    defaults = {false, false, false, false},
    transient = true,
})

-- Compatibility surface: snapshots and tools name this component
-- "UiInteraction".
ecs.newComponent({
    name = "UiInteraction",
    container = Interaction,
    fields = {"enabled", "focusable", "tabIndex", "order", "draggable"},
    defaults = {true, true, 0, 0, false},
    requires = {InteractionState},
    __call = function(instance: Interaction, value?: {string: any})
        local options = value or {}
        instance.enabled = options.enabled ~= false
        instance.focusable = options.focusable ~= false
        instance.tabIndex = options.tabIndex as integer or 0
        instance.order = options.order as integer or 0
        instance.draggable = options.draggable == true
    end,
})

Event.init = function(
    event: Event,
    kind: EventKind,
    target: integer,
    x: number,
    y: number,
    button: integer,
    pointerId: string,
    pointerType: PointerType,
    deltaX: number,
    deltaY: number,
    source: InteractionSource
)
    event.kind = kind
    event.target = target
    event.currentTarget = target
    event.x, event.y = x, y
    event.button = button
    event.pointerId = pointerId
    event.pointerType = pointerType
    event.deltaX, event.deltaY = deltaX, deltaY
    event.source = source
    event.consumed = false
end

-- Compatibility surface: Ui Event kinds are externally typed strings observed
-- by game code and tools.
events.newEvent(Event)

local record Hit
    entity: integer
    left: number
    top: number
    right: number
    bottom: number
    depth: number
    tabIndex: integer
    order: integer
    ordinal: integer
    treeDepth: integer
end

local record PointerState
    id: string
    kind: PointerType
    x: number
    y: number
    previousX: number
    previousY: number
    startX: number
    startY: number
    startScroll: number
    hovered: integer
    captured: integer
    dragging: boolean
    seen: boolean
end

local record Install
    tree: loader.CPtr
    changeCount: loader.CArray
    known: {integer: boolean}
    live: {integer: boolean}
    childKeys: {integer: string}
    children: {integer}
    removed: {integer}
    clipByKey: {string: integer}
    keyByClip: {integer: string}
    clipUsed: {string: boolean}
    clipRectByKey: {string: string}
    clipLeft: {integer: number}
    clipTop: {integer: number}
    clipRight: {integer: number}
    clipBottom: {integer: number}
    clipChain: {integer}
    firstClip: integer
    lastClip: integer
    hits: {Hit}
    hitCount: integer
    scrollHits: {Hit}
    scrollHitCount: integer
    hovered: integer
    focused: integer
    pointers: {string: PointerState}
    focusScopes: {integer}
    focusRestore: {integer: integer}
    ordinals: {integer: integer}
    nextOrdinal: integer
    focusEntity: function(entity?: integer, source?: InteractionSource, x?: number, y?: number): boolean
    revealEntity: function(entity: integer, align?: RevealAlign): boolean
    pushScope: function(entity: integer): boolean
    popScope: function(entity?: integer): boolean
    cancelPointers: function()
    input: InputReader
    window: WindowReader
    layer: any
    wheelStep: number
    dragThreshold: number
    tabRepeating: boolean
    tabRepeated: boolean
    tabRepeatElapsed: number
    geometryDirty: boolean
    hasWorldRoots: boolean
    hasCameraRoots: boolean
    cameraX: number
    cameraY: number
    cameraZoom: number
    cameraRotation: number
    layoutCameraX: number
    layoutCameraY: number
    layoutCameraZoom: number
    layoutCameraRotation: number
    screenWidth: number
    screenHeight: number
    screenDensity: number
    viewportDirty: boolean
    nodeMembershipDirty: boolean
    rootMembershipDirty: boolean
end

local installs <const>: {World: Install} = setmetatable(
    {} as {World: Install}, {__mode = "k"} as metatable<{World: Install}>
)
local noTouches <const>: {TouchReader} = {}
local TAB_REPEAT_DELAY <const> = 0.4
local TAB_REPEAT_INTERVAL <const> = 0.075

local function unit(value: any, output: any)
    local target = output as {string: any}
    if type(value) == "number" then
        target.value, target.unit = value, 1
    elseif type(value) == "string" then
        local dimensionText = value as string
        if dimensionText == "auto" then
            target.value, target.unit = 0, 0
            return
        end
        local amount = dimensionText:match("^([+-]?%d*%.?%d+)px$")
        if amount ~= nil then
            target.value, target.unit = tonumber(amount), 1
            return
        end
        amount = dimensionText:match("^([+-]?%d*%.?%d+)%%$")
        if amount ~= nil then
            target.value, target.unit = (tonumber(amount) as number) / 100, 2
            return
        end
        error(
            ("tecs: invalid UI dimension %q; expected a number, 'auto', '<number>px', or '<number>%%'"):format(
                dimensionText
            ),
            3
        )
    elseif type(value) == "table" then
        target.value = (value as {string: any}).value or 0
        target.unit = (value as {string: any}).unit == "percent" and 2
            or ((value as {string: any}).unit == "points" and 1 or 0)
    else
        target.value, target.unit = 0, 0
    end
end

local function edges(value: any, output: any)
    local target = output as {string: any}
    if type(value) == "table" then
        local source = value as {string: any}
        unit(source.left, target.left)
        unit(source.right, target.right)
        unit(source.top, target.top)
        unit(source.bottom, target.bottom)
    else
        unit(value, target.left)
        unit(value, target.right)
        unit(value, target.top)
        unit(value, target.bottom)
    end
end

local function nativeStyle(value: {string: any}): loader.CStruct
    local out = ffi.new("TecsUiStyle") as loader.CStruct
    out.display = value.display == "none" and 1
        or (value.display == "grid" and 2 or (value.display == "block" and 3 or 0))
    out.position = value.position == "absolute" and 1 or 0
    out.flex_direction = value.flexDirection == "rowReverse" and 1
        or (value.flexDirection == "column" and 2 or (value.flexDirection == "columnReverse" and 3 or 0))
    out.flex_wrap = value.flexWrap == "wrap" and 1 or 0
    out.justify_content = value.justifyContent == "center" and 1
        or (
            value.justifyContent == "end" and 2
            or (
                value.justifyContent == "spaceBetween" and 3
                or (value.justifyContent == "spaceAround" and 4 or (value.justifyContent == "spaceEvenly" and 5 or 0))
            )
        )
    out.align_items = value.alignItems == "center" and 1
        or (value.alignItems == "end" and 2 or (value.alignItems == "baseline" and 3 or 0))
    out.flex_grow, out.flex_shrink = value.flexGrow or 0, value.flexShrink or 1
    unit(value.flexBasis, out.flex_basis)
    unit(value.width, out.width)
    unit(value.height, out.height)
    unit(value.minWidth, out.min_width)
    unit(value.minHeight, out.min_height)
    unit(value.maxWidth, out.max_width)
    unit(value.maxHeight, out.max_height)
    edges(value.margin or 0, out.margin)
    edges(value.padding, out.padding)
    edges(value.border, out.border)
    unit(value.gap, out.gap_width)
    unit(value.rowGap or value.gap, out.gap_height)
    edges(value.inset, out.inset)
    return out
end

local function nativeMeasure(world: World, renderer: Renderer, entity: integer, value: Intrinsic): loader.CStruct
    local out = ffi.new("TecsUiMeasure") as loader.CStruct
    local scale = value.scale
    if scale < 0 then
        error("tecs: Intrinsic.scale cannot be negative", 3)
    end
    if value.source == "custom" then
        out.kind = 1
        out.width, out.height = value.width, value.height
        out.min_width = value.minWidth > 0 and value.minWidth or value.width
        out.measured_width, out.measured_height = value.width, value.height
    elseif value.source == "image" then
        local sprite = world:get(entity, components.Sprite)
        if sprite == nil then
            error("tecs: an image Intrinsic requires tecs.components.Sprite", 3)
        end
        local width, height = renderer:spriteSize(sprite)
        out.kind = 2
        out.width, out.height = width * scale, height * scale
        out.min_width = out.width
        out.measured_width, out.measured_height = out.width, out.height
    elseif value.source == "text" then
        local item = world:get(entity, text.Text)
        if item == nil then
            error("tecs: a text Intrinsic requires tecs.gfx.text.Text", 3)
        end
        local width, height, minWidth = text.measureIntrinsic(item)
        local measuredWidth = item.wrapWidth > 0 and item.wrapWidth or width
        local _, measuredHeight = text.measureText(item)
        out.kind = 3
        out.width, out.height = width * scale, height * scale
        out.min_width = minWidth * scale
        out.measured_width, out.measured_height = measuredWidth * scale, measuredHeight * scale
    else
        error("tecs: Intrinsic.source must be 'custom', 'text', or 'image'", 3)
    end
    return out
end

local function collectChild(id: integer, install: Install)
    if install.live[id] then
        install.children[#install.children + 1] = id
    end
end

local function ensureOrdinal(install: Install, entity: integer): integer
    local ordinal = install.ordinals[entity]
    if ordinal == nil then
        ordinal = install.nextOrdinal
        install.nextOrdinal = ordinal + 1
        install.ordinals[entity] = ordinal
    end
    return ordinal
end

local function syncChildren(world: World, install: Install, entity: integer)
    local children = install.children
    for index = #children, 1, -1 do
        children[index] = nil
    end
    world:targets(entity, ChildOf, collectChild, install)
    local function orderOf(id: integer): integer
        local value = world:get(id, Style)
        return value ~= nil and value.style.order as integer or 0
    end
    table.sort(
        children,
        function(left: integer, right: integer): boolean
            local leftOrder, rightOrder = orderOf(left), orderOf(right)
            return leftOrder ~= rightOrder and leftOrder < rightOrder
                or (leftOrder == rightOrder and ensureOrdinal(install, left) < ensureOrdinal(install, right))
        end
    )
    local key = ""
    for index = 1, #children do
        key = key .. children[index] .. "@" .. orderOf(children[index]) .. ":"
    end
    if install.childKeys[entity] == key then
        return
    end
    install.childKeys[entity] = key
    local ids = ffi.new("uint64_t[?]", #children) as loader.CArray
    for index = 1, #children do
        ids[index - 1] = children[index]
    end
    if not (C.tecsUiTreeSetChildren(install.tree, entity, ids, #children) as boolean) then
        error("tecs: UI child synchronization failed: " .. loader.toString(C.tecsRustError()), 2)
    end
end

local record ContentContext
    world: World
    viewport: integer
    x: number
    y: number
    minX: number
    minY: number
end

local function collectContentMinimum(entity: integer, context: ContentContext)
    local layout = context.world:get(entity, Layout)
    if layout == nil then
        return
    end
    local previousX, previousY = context.x, context.y
    context.x, context.y = previousX + layout.x, previousY + layout.y
    if context.x < context.minX then
        context.minX = context.x
    end
    if context.y < context.minY then
        context.minY = context.y
    end
    if context.world:get(entity, Scroll) == nil then
        context.world:targets(entity, ChildOf, collectContentMinimum, context)
    end
    context.x, context.y = previousX, previousY
end

local function applyLayoutTransform(world: World, entity: integer, x: number, y: number, width: number, height: number)
    local relative = world:get(entity, RelativeTransform)
    if relative == nil then
        return
    end
    local parent = world:getFirstRelationship(entity, ChildOf)
    local scroll = parent ~= nil and world:get(parent.target, Scroll) or nil
    local relativeX = x - (scroll ~= nil and scroll.x or 0)
    local relativeY = y - (scroll ~= nil and scroll.y or 0)
    local paint = world:get(entity, Paint)
    if paint ~= nil and paint.stretch then
        relativeX = relativeX + width * 0.5
        relativeY = relativeY + height * 0.5
    end
    local scaleX = paint ~= nil and paint.stretch and width or relative.scaleX
    local scaleY = paint ~= nil and paint.stretch and height or relative.scaleY
    if relative.x ~= relativeX or relative.y ~= relativeY or relative.scaleX ~= scaleX or relative.scaleY ~= scaleY then
        relative = world:getMut(entity, RelativeTransform)
        relative.x, relative.y = relativeX, relativeY
        relative.scaleX, relative.scaleY = scaleX, scaleY
    end
end

local function applyCurrentLayout(entity: integer, world: World)
    local layout = world:get(entity, Layout)
    if layout ~= nil then
        applyLayoutTransform(world, entity, layout.x, layout.y, layout.width, layout.height)
    end
end

local record ui
    --- Selects whether a root uses screen or world coordinates.
    type RootSpace = RootSpace
    --- Selects where a root receives its available dimensions.
    type RootSizing = RootSizing
    --- Selects which leaf component owns natural dimensions.
    type IntrinsicSource = IntrinsicSource
    --- Selects the dimension controlled by a scrollbar thumb.
    type ScrollAxis = ScrollAxis
    --- Identifies one semantic UI interaction.
    type EventKind = EventKind
    --- Identifies the pointer device associated with an event.
    type PointerType = PointerType
    --- Identifies what initiated a semantic UI event.
    type InteractionSource = InteractionSource
    --- Selects where `reveal` places a descendant in each viewport.
    type RevealAlign = RevealAlign
    --- Read-only. Exposes the tag that marks an entity as participating in UI
    --- layout. `Style`, `Root`, and `Scroll` add it automatically.
    Node: Component
    --- Read-only. Exposes the component that supplies retained layout properties
    --- and adds `Layout` and `tecs.gfx.Clip`.
    Style: Style
    --- Read-only. Exposes the component that gives a retained UI tree its
    --- available size and coordinate space.
    Root: Root
    --- Read-only. Exposes the component that reports a computed box without
    --- becoming a drawing primitive.
    Layout: Layout
    --- Read-only. Exposes the component that optionally stretches an existing
    --- primitive to its computed box.
    Paint: Paint
    --- Read-only. Exposes cached custom, text, or image leaf measurement.
    Intrinsic: Intrinsic
    --- Read-only. Exposes the component that offsets descendants and clips
    --- their existing GPU instances.
    Scroll: Scroll
    --- Read-only. Exposes a composed scrollbar thumb driven by its parent
    --- viewport.
    Scrollbar: Scrollbar
    --- Read-only. Exposes the marker used by `pushFocusScope`.
    FocusScope: FocusScope
    --- Read-only. Exposes the component that admits a layout box to hit
    --- testing and keyboard navigation.
    Interaction: Interaction
    --- Read-only. Exposes transient hover, press, and focus state.
    InteractionState: InteractionState
    --- Read-only. Exposes the event type delivered to an interaction target
    --- and its `ChildOf` ancestors.
    Event: Event
    --- `Options` configures rendering, input, scrolling, and the owned
    --- clip-index range.
    type Options = Options
    --- `Overrides` changes scrolling and clip allocation without repeating an
    --- application's renderer and input.
    type Overrides = Overrides

    --- Moves focus to one enabled, focusable interaction.
    --- @param world The caller supplies a world with the UI plugin.
    --- @param entity The caller supplies the interaction to focus.
    --- @return Returns false when the plugin is missing or the entity cannot
    ---     receive focus.
    focus: function(world: World, entity: integer): boolean
    --- Clears the world's focused interaction.
    --- @param world The caller supplies a world with the UI plugin.
    --- @return Returns false when the plugin is missing.
    blur: function(world: World): boolean
    --- Returns the world's focused interaction.
    --- @param world The caller supplies a world with or without the UI plugin.
    --- @return Returns the focused entity, or nil when nothing is focused.
    focused: function(world: World): integer
    --- Scrolls every ancestor viewport enough to expose one descendant.
    --- @param world The caller supplies a world with the UI plugin.
    --- @param entity The caller supplies a retained UI descendant.
    --- @param align The caller selects `"nearest"`, `"start"`, `"center"`, or
    ---     `"end"`; omission selects `"nearest"`.
    --- @return Returns false when the plugin or layout is missing.
    reveal: function(world: World, entity: integer, align?: RevealAlign): boolean
    --- Pushes one modal navigation boundary and remembers the current focus.
    --- @param world The caller supplies a world with the UI plugin.
    --- @param scope The caller supplies an entity carrying `FocusScope`.
    --- @return Returns false when the plugin or scope is missing.
    pushFocusScope: function(world: World, scope: integer): boolean
    --- Pops the active navigation boundary and restores its saved focus.
    --- @param world The caller supplies a world with the UI plugin.
    --- @param scope The caller may require a particular active scope.
    --- @return Returns false when the plugin is missing or the requested scope
    ---     is not active.
    popFocusScope: function(world: World, scope?: integer): boolean

    --- Returns a plugin that derives layout, transforms, clipping, and
    --- optional interaction from retained layout nodes.
    ---
    --- The plugin owns every renderer clip index from `firstClip` through
    --- `lastClip`, inclusive. Reserve a smaller range when another system also
    --- calls `Renderer:setClipRegion`. Exhausting the range raises rather than
    --- drawing unclipped content.
    ---
    --- Passing an [`Application`](tealdoc:tecs.Application) supplies its
    --- renderer, input, and window. The plugin samples the viewport initially,
    --- then observes platform resize, pixel-size, display, and display-scale
    --- events at world address zero. It coalesces them and refreshes automatic
    --- roots before layout without polling the window on unchanged frames. The
    --- optional second argument overrides clip allocation, the input layer,
    --- and wheel distance. Passing `Options` directly preserves manual wiring
    --- for tests, tools, and worlds not owned by an application. When input is
    --- present, the plugin reads its configured layer in `PreUpdate`. It uses
    --- the hit geometry derived after the previous frame's layout and
    --- clipping, which is the geometry the player was shown when the input
    --- arrived.
    ---
    --- @param source The caller supplies an application or manually wired
    ---     options containing a renderer.
    --- @param overrides The caller may override source defaults without
    ---     repeating its renderer and input.
    --- @return Returns a plugin for `world:addPlugin`. Each world receives a
    ---     separate retained tree and clip allocator.
    plugin: function(source: any, overrides?: Overrides): function(World)
end

ui.Node = NodeComponent
ui.Style, ui.Root, ui.Layout, ui.Paint = Style, Root, Layout, Paint
ui.Intrinsic, ui.Scroll, ui.Scrollbar = Intrinsic, Scroll, Scrollbar
ui.FocusScope = FocusScope
ui.Interaction, ui.InteractionState, ui.Event = Interaction, InteractionState, Event

function ui.focus(world: World, entity: integer): boolean
    local install = installs[world]
    return install ~= nil and install.focusEntity(entity, "programmatic") or false
end

function ui.blur(world: World): boolean
    local install = installs[world]
    return install ~= nil and install.focusEntity(nil, "programmatic") or false
end

function ui.focused(world: World): integer
    local install = installs[world]
    return install ~= nil and install.focused or nil
end

function ui.reveal(world: World, entity: integer, align?: RevealAlign): boolean
    local install = installs[world]
    return install ~= nil and install.revealEntity(entity, align) or false
end

function ui.pushFocusScope(world: World, scope: integer): boolean
    local install = installs[world]
    return install ~= nil and install.pushScope(scope) or false
end

function ui.popFocusScope(world: World, scope?: integer): boolean
    local install = installs[world]
    return install ~= nil and install.popScope(scope) or false
end

function ui.plugin(provider: any, overrides?: Overrides): function(World)
    local configuration <const> = provider as {string: any}
    if configuration == nil or configuration.renderer == nil then
        error("tecs: the UI plugin needs a `renderer`", 2)
    end
    local overrideValues <const> = overrides or {}
    local firstClip = (overrideValues.firstClip or configuration.firstClip or 1) as integer
    local lastClip = (overrideValues.lastClip or configuration.lastClip or 255) as integer
    local wheelStep = (overrideValues.wheelStep or configuration.wheelStep or 40) as number
    local dragThreshold = (overrideValues.dragThreshold or configuration.dragThreshold or 4) as number
    if firstClip < 1 or lastClip > 255 or firstClip > lastClip then
        error("tecs: UI clip range must be within 1 through 255", 2)
    end
    if wheelStep < 0 then
        error("tecs: UI wheelStep cannot be negative", 2)
    end
    if dragThreshold < 0 then
        error("tecs: UI dragThreshold cannot be negative", 2)
    end
    local renderer <const> = configuration.renderer as Renderer
    local inputReader <const> = configuration.input as InputReader
    local window = configuration.window as WindowReader
    if window ~= nil and (type(window.getSize) ~= "function" or type(window.pixelDensity) ~= "function") then
        window = nil
    end
    local layer <const> = overrideValues.layer or configuration.layer
    return function(world: World)
        local tree = C.tecsUiTreeCreate()
        if tree == nil then
            error("tecs: cannot create UI tree: " .. loader.toString(C.tecsRustError()), 2)
        end
        tree = ffi.gc(tree as ffi.CData, C.tecsUiTreeDestroy as function(ffi.CData)) as loader.CPtr
        local install: Install = {
            tree = tree,
            changeCount = ffi.new("size_t[1]") as loader.CArray,
            known = {},
            live = {},
            childKeys = {},
            children = {},
            removed = {},
            clipByKey = {},
            keyByClip = {},
            clipUsed = {},
            clipRectByKey = {},
            clipLeft = {},
            clipTop = {},
            clipRight = {},
            clipBottom = {},
            clipChain = {},
            firstClip = firstClip,
            lastClip = lastClip,
            hits = {},
            hitCount = 0,
            scrollHits = {},
            scrollHitCount = 0,
            hovered = nil,
            focused = nil,
            pointers = {},
            focusScopes = {},
            focusRestore = {},
            ordinals = {},
            nextOrdinal = 1,
            focusEntity = function(_entity?: integer, _source?: InteractionSource, _x?: number, _y?: number): boolean
                return false
            end,
            revealEntity = function(_entity: integer, _align?: RevealAlign): boolean return false end,
            pushScope = function(_entity: integer): boolean return false end,
            popScope = function(_entity?: integer): boolean return false end,
            cancelPointers = function() end,
            input = inputReader,
            window = window,
            layer = layer,
            wheelStep = wheelStep,
            dragThreshold = dragThreshold,
            tabRepeating = false,
            tabRepeated = false,
            tabRepeatElapsed = 0,
            geometryDirty = true,
            hasWorldRoots = false,
            hasCameraRoots = false,
            cameraX = math.huge,
            cameraY = math.huge,
            cameraZoom = math.huge,
            cameraRotation = math.huge,
            layoutCameraX = math.huge,
            layoutCameraY = math.huge,
            layoutCameraZoom = math.huge,
            layoutCameraRotation = math.huge,
            screenWidth = math.huge,
            screenHeight = math.huge,
            screenDensity = math.huge,
            viewportDirty = true,
            nodeMembershipDirty = true,
            rootMembershipDirty = true,
        }
        installs[world] = install
        local worldImpl <const> = world as internal.WorldImpl
        if window ~= nil then
            local function invalidateViewport(_event: PlatformEvent)
                install.viewportDirty = true
            end
            world:observe(0, platformEvents.on.windowResized, invalidateViewport)
            world:observe(0, platformEvents.on.windowPixelSizeChanged, invalidateViewport)
            world:observe(0, platformEvents.on.windowDisplayChanged, invalidateViewport)
            world:observe(0, platformEvents.on.windowDisplayScaleChanged, invalidateViewport)
        end
        -- These names are compatibility surfaces exposed by the debugger.
        local function invalidateNodes()
            install.nodeMembershipDirty = true
            install.geometryDirty = true
        end
        local function invalidateRoots()
            install.rootMembershipDirty = true
            install.geometryDirty = true
        end
        local function invalidateGeometry()
            install.geometryDirty = true
        end
        local nodes = world:newQuery({
            name = "tecs.UiLayout",
            include = {NodeComponent, Style, Layout},
            onEntitiesAdded = invalidateNodes,
            onEntitiesRemoved = invalidateNodes,
        })
        local roots = world:newQuery({
            name = "tecs.UiRoots",
            include = {NodeComponent, Root},
            onEntitiesAdded = invalidateRoots,
            onEntitiesRemoved = invalidateRoots,
        })
        local intrinsics = world:newQuery({
            name = "tecs.UiIntrinsics",
            include = {NodeComponent, Intrinsic},
            onEntitiesAdded = invalidateNodes,
            onEntitiesRemoved = invalidateNodes,
        })
        local scrolls = world:newQuery({
            name = "tecs.UiScrolls",
            include = {Scroll, Layout},
            onEntitiesAdded = invalidateGeometry,
            onEntitiesRemoved = invalidateGeometry,
        })
        local scrollbars = world:newQuery({
            name = "tecs.UiScrollbars",
            include = {Scrollbar, RelativeTransform},
            onEntitiesAdded = invalidateGeometry,
            onEntitiesRemoved = invalidateGeometry,
        })
        local interactions = world:newQuery({
            name = "tecs.UiInteractions",
            include = {Interaction, InteractionState, Transform},
            onEntitiesAdded = invalidateGeometry,
            onEntitiesRemoved = invalidateGeometry,
        })
        local noMeasure <const> = ffi.new("TecsUiMeasure") as loader.CStruct
        local function computeLayoutPass()
            if not (C.tecsUiTreeBegin(install.tree) as boolean) then
                error("tecs: UI layout reset failed: " .. loader.toString(C.tecsRustError()), 2)
            end
            for archetype, length, entities in roots:iter() do
                local rootColumn = archetype:get(Root)
                for row = 1, length do
                    local root = rootColumn[row]
                    if
                        root.width > 0
                        and root.height > 0
                        and not (C.tecsUiTreeCompute(install.tree, entities[row], root.width, root.height) as boolean)
                    then
                        error("tecs: UI layout failed: " .. loader.toString(C.tecsRustError()), 2)
                    end
                end
            end
            local changes = C.tecsUiTreeChanges(install.tree, install.changeCount) as loader.CArray
            local changeCount = tonumber(install.changeCount[0]) as integer
            if changeCount > 0 and changes == nil then
                error("tecs: UI layout export failed: " .. loader.toString(C.tecsRustError()), 2)
            end
            for index = 0, changeCount - 1 do
                local output = changes[index] as loader.CStruct
                local entity = tonumber(output.entity) as integer
                local x, y = output.x as number, output.y as number
                local width, height = output.width as number, output.height as number
                local current = world:get(entity, Layout)
                if
                    current ~= nil
                    and (current.x ~= x or current.y ~= y or current.width ~= width or current.height ~= height)
                then
                    local changed = world:getMut(entity, Layout)
                    changed.x, changed.y, changed.width, changed.height = x, y, width, height
                end
                local scroll = world:get(entity, Scroll)
                if scroll ~= nil then
                    local contentWidth = math.max(width, output.content_width as number)
                    local contentHeight = math.max(height, output.content_height as number)
                    if scroll.contentWidth ~= contentWidth or scroll.contentHeight ~= contentHeight then
                        scroll = world:getMut(entity, Scroll)
                        scroll.contentWidth, scroll.contentHeight = contentWidth, contentHeight
                    end
                end
                applyLayoutTransform(world, entity, x, y, width, height)
            end
        end

        local function synchronizeTextWrapping(): boolean
            local changed = false
            for archetype, length, entities in intrinsics:iter() do
                local values = archetype:get(Intrinsic)
                local texts = archetype:get(text.Text)
                if texts ~= nil then
                    for row = 1, length do
                        local value = values[row]
                        if value.source == "text" and value.wrap then
                            local layout = world:get(entities[row], Layout)
                            local item = texts[row]
                            local scale = value.scale
                            local wrapWidth = layout ~= nil and scale > 0 and layout.width / scale or 0
                            if math.abs(item.wrapWidth - wrapWidth) > 0.01 then
                                item = world:getMut(entities[row], text.Text)
                                item.wrapWidth = wrapWidth
                                if not (
                                    C.tecsUiTreeSetMeasure(
                                        install.tree,
                                        entities[row],
                                        nativeMeasure(world, renderer, entities[row], value)
                                    ) as boolean
                                ) then
                                    error(
                                        "tecs: wrapped UI text synchronization failed: "
                                            .. loader.toString(C.tecsRustError()),
                                        2
                                    )
                                end
                                changed = true
                            end
                        end
                    end
                end
            end
            return changed
        end
        -- This system name is a compatibility surface exposed by the debugger.
        world:addSystem({
            name = "tecs.UiLayout",
            phase = ecs.phases.PostUpdate,
            before = {"RelativeTransform"},
            run = function()
                local layoutDirty = install.nodeMembershipDirty or install.rootMembershipDirty
                local hierarchyDirty = install.nodeMembershipDirty
                local transformDirty = false
                local nodeStateDirty = install.nodeMembershipDirty
                local rootStateDirty = install.rootMembershipDirty
                local scrollDirty = false
                local scrollbarDirty = false
                local intrinsicDirty = install.nodeMembershipDirty

                -- Query observers carry structural membership changes even
                -- when an empty ephemeral archetype is destroyed and leaves
                -- the dirty set. Value changes cost a walk over dirty
                -- archetypes, not a walk over every UI archetype.
                for archetype in pairs(worldImpl._dirtyArchetypes) do
                    local columns = archetype.columns
                    if columns[Style] then
                        local styleDirty = archetype:isComponentDirty(Style)
                        local childDirty = archetype:isComponentDirty(ChildOf)
                        local rootDirty = archetype:isComponentDirty(Root)
                        local relativeDirty = archetype:isComponentDirty(RelativeTransform)
                        local paintDirty = archetype:isComponentDirty(Paint)
                        local viewportDirty = archetype:isComponentDirty(Scroll)
                        local measureDirty = columns[Intrinsic] ~= nil
                            and (
                                archetype:isComponentDirty(Intrinsic)
                                or archetype:isComponentDirty(text.Text)
                                or archetype:isComponentDirty(components.Sprite)
                            )
                        nodeStateDirty = nodeStateDirty or styleDirty or childDirty
                        rootStateDirty = rootStateDirty or rootDirty
                        hierarchyDirty = hierarchyDirty or childDirty or styleDirty
                        intrinsicDirty = intrinsicDirty or measureDirty
                        layoutDirty = layoutDirty or styleDirty or childDirty or rootDirty or measureDirty
                        transformDirty = transformDirty or relativeDirty or paintDirty
                        scrollDirty = scrollDirty or viewportDirty
                    end
                    if columns[Scrollbar] and archetype:isComponentDirty(Scrollbar) then
                        scrollbarDirty = true
                    end
                end

                local screenWidth: number = 0
                local screenHeight: number = 0
                local screenDensity: number = 1
                local activeWindow = install.window
                local windowDirty = false
                if activeWindow ~= nil and install.viewportDirty then
                    local width, height = activeWindow:getSize()
                    local density = activeWindow:pixelDensity()
                    install.viewportDirty = false
                    windowDirty = install.screenWidth ~= width
                        or install.screenHeight ~= height
                        or install.screenDensity ~= density
                    install.screenWidth, install.screenHeight = width, height
                    install.screenDensity = density
                end
                if activeWindow ~= nil then
                    screenWidth, screenHeight = install.screenWidth, install.screenHeight
                    screenDensity = install.screenDensity
                end
                local camera = renderer.camera
                local cameraSizingDirty = install.hasCameraRoots
                    and (
                        install.layoutCameraX ~= camera.x
                        or install.layoutCameraY ~= camera.y
                        or install.layoutCameraZoom ~= camera.zoom
                        or install.layoutCameraRotation ~= camera.rotation
                    )
                if
                    not layoutDirty
                    and not transformDirty
                    and not scrollDirty
                    and not scrollbarDirty
                    and not windowDirty
                    and not cameraSizingDirty
                then
                    return
                end

                if rootStateDirty or windowDirty or cameraSizingDirty then
                    install.hasWorldRoots = false
                    install.hasCameraRoots = false
                    for _archetype, length, entities in roots:iter() do
                        local values = _archetype:get(Root)
                        for row = 1, length do
                            if
                                install.rootMembershipDirty
                                and not (C.tecsUiTreeInvalidateRoot(install.tree, entities[row]) as boolean)
                            then
                                error("tecs: UI root invalidation failed: " .. loader.toString(C.tecsRustError()), 2)
                            end
                            local value = values[row]
                            if value.space == "world" then
                                install.hasWorldRoots = true
                                if value.sizing == "camera" then
                                    if activeWindow == nil then
                                        error("tecs: a camera-sized UI root requires a window", 2)
                                    end
                                    if camera.zoom <= 0 then
                                        error("tecs: a camera-sized UI root requires positive camera zoom", 2)
                                    end
                                    install.hasCameraRoots = true
                                    local viewportWidth = screenWidth * screenDensity
                                    local viewportHeight = screenHeight * screenDensity
                                    local width = viewportWidth / camera.zoom
                                    local height = viewportHeight / camera.zoom
                                    local rootChanged = value.width ~= width
                                        or value.height ~= height
                                        or value.pixelDensity ~= screenDensity
                                    if rootChanged then
                                        local changed = world:getMut(entities[row], Root)
                                        changed.width, changed.height = width, height
                                        changed.pixelDensity = screenDensity
                                        layoutDirty = true
                                    end
                                    local x, y = camera:toWorld(0, 0, viewportWidth, viewportHeight)
                                    local transform = world:get(entities[row], Transform)
                                    if
                                        transform.x ~= x
                                        or transform.y ~= y
                                        or transform.rotation ~= camera.rotation
                                        or transform.scaleX ~= 1
                                        or transform.scaleY ~= 1
                                    then
                                        transform = world:getMut(entities[row], Transform)
                                        transform.x, transform.y = x, y
                                        transform.rotation = camera.rotation
                                        transform.scaleX, transform.scaleY = 1, 1
                                        transformDirty = true
                                    end
                                elseif value.sizing ~= "auto" and value.sizing ~= "manual" then
                                    error("tecs: Root.sizing must be 'auto', 'manual', or 'camera'", 2)
                                end
                            elseif
                                activeWindow ~= nil
                                and value.sizing ~= "manual"
                                and (
                                    value.width ~= screenWidth
                                    or value.height ~= screenHeight
                                    or value.pixelDensity ~= screenDensity
                                )
                            then
                                local changed = world:getMut(entities[row], Root)
                                changed.width, changed.height = screenWidth, screenHeight
                                changed.pixelDensity = screenDensity
                                layoutDirty = true
                            elseif value.sizing ~= "auto" and value.sizing ~= "manual" then
                                error("tecs: a screen Root.sizing must be 'auto' or 'manual'", 2)
                            end
                        end
                    end
                    install.layoutCameraX, install.layoutCameraY = camera.x, camera.y
                    install.layoutCameraZoom, install.layoutCameraRotation = camera.zoom, camera.rotation
                end

                if nodeStateDirty then
                    for entity in pairs(install.live) do
                        install.live[entity] = nil
                    end
                    for archetype, length, entities in nodes:iter() do
                        local styles = archetype:get(Style)
                        local styleDirty = archetype:isComponentDirty(Style)
                        for row = 1, length do
                            local entity = entities[row]
                            ensureOrdinal(install, entity)
                            install.live[entity] = true
                            local style = styles[row].style
                            if not install.known[entity] then
                                if not (C.tecsUiTreeInsert(install.tree, entity, nativeStyle(style)) as boolean) then
                                    error("tecs: UI node creation failed: " .. loader.toString(C.tecsRustError()), 2)
                                end
                                install.known[entity] = true
                                layoutDirty = true
                                hierarchyDirty = true
                            elseif
                                styleDirty
                                and not (C.tecsUiTreeSetStyle(install.tree, entity, nativeStyle(style)) as boolean)
                            then
                                error(
                                    "tecs: UI style synchronization failed: " .. loader.toString(C.tecsRustError()), 2
                                )
                            end
                        end
                    end
                    local removed = install.removed
                    for index = #removed, 1, -1 do
                        removed[index] = nil
                    end
                    for entity in pairs(install.known) do
                        if not install.live[entity] then
                            removed[#removed + 1] = entity
                        end
                    end
                    for index = 1, #removed do
                        local entity = removed[index]
                        if not (C.tecsUiTreeRemove(install.tree, entity) as boolean) then
                            error("tecs: UI node removal failed: " .. loader.toString(C.tecsRustError()), 2)
                        end
                        install.known[entity] = nil
                        install.childKeys[entity] = nil
                        install.ordinals[entity] = nil
                        layoutDirty = true
                        hierarchyDirty = true
                    end
                    if hierarchyDirty then
                        for _archetype, length, entities in nodes:iter() do
                            for row = 1, length do
                                syncChildren(world, install, entities[row])
                            end
                        end
                    end
                    install.nodeMembershipDirty = false
                end
                if intrinsicDirty then
                    for _archetype, length, entities in nodes:iter() do
                        for row = 1, length do
                            local entity = entities[row]
                            if
                                world:get(entity, Intrinsic) == nil
                                and not (C.tecsUiTreeSetMeasure(install.tree, entity, noMeasure) as boolean)
                            then
                                error("tecs: UI measurement removal failed: " .. loader.toString(C.tecsRustError()), 2)
                            end
                        end
                    end
                    for archetype, length, entities in intrinsics:iter() do
                        local values = archetype:get(Intrinsic)
                        for row = 1, length do
                            if not (
                                C.tecsUiTreeSetMeasure(
                                    install.tree,
                                    entities[row],
                                    nativeMeasure(world, renderer, entities[row], values[row])
                                ) as boolean
                            ) then
                                error(
                                    "tecs: UI measurement synchronization failed: "
                                        .. loader.toString(C.tecsRustError()),
                                    2
                                )
                            end
                        end
                    end
                end
                install.rootMembershipDirty = false

                -- The native tree retains its last boxes. Scrolling and paint
                -- changes can reuse those boxes without recomputing layout.
                if layoutDirty then
                    computeLayoutPass()
                    local pass = 1
                    while synchronizeTextWrapping() do
                        pass = pass + 1
                        if pass > 4 then
                            error("tecs: intrinsic text layout did not converge after four passes", 2)
                        end
                        computeLayoutPass()
                    end
                end

                -- Paint and direct RelativeTransform writes are uncommon and
                -- may affect any row in their dirty archetype. They reuse ECS
                -- layout boxes and never enter Taffy.
                if transformDirty then
                    for _archetype, length, entities in nodes:iter() do
                        for row = 1, length do
                            applyCurrentLayout(entities[row], world)
                        end
                    end
                end

                if layoutDirty then
                    local content: ContentContext = {
                        world = world,
                        viewport = 0,
                        x = 0,
                        y = 0,
                        minX = 0,
                        minY = 0,
                    }
                    for archetype, length, entities in scrolls:iter() do
                        local values = archetype:get(Scroll)
                        for row = 1, length do
                            local entity = entities[row]
                            content.viewport = entity
                            content.x, content.y = 0, 0
                            content.minX, content.minY = 0, 0
                            world:targets(entity, ChildOf, collectContentMinimum, content)
                            local value = values[row]
                            local right = value.contentWidth
                            local bottom = value.contentHeight
                            local contentWidth = right - content.minX
                            local contentHeight = bottom - content.minY
                            local viewport = world:get(entity, Layout)
                            local minX, minY = content.minX, content.minY
                            local maxX = math.max(minX, minX + contentWidth - viewport.width)
                            local maxY = math.max(minY, minY + contentHeight - viewport.height)
                            local nextX = math.max(minX, math.min(maxX, value.x))
                            local nextY = math.max(minY, math.min(maxY, value.y))
                            if
                                value.contentX ~= minX
                                or value.contentY ~= minY
                                or value.contentWidth ~= contentWidth
                                or value.contentHeight ~= contentHeight
                                or value.x ~= nextX
                                or value.y ~= nextY
                            then
                                local changed = world:getMut(entity, Scroll)
                                changed.contentX, changed.contentY = minX, minY
                                changed.contentWidth, changed.contentHeight = contentWidth, contentHeight
                                changed.x, changed.y = nextX, nextY
                                scrollDirty = true
                            end
                        end
                    end
                end

                if scrollDirty then
                    for archetype, length, entities in scrolls:iter() do
                        if layoutDirty or archetype:isComponentDirty(Scroll) then
                            local values = archetype:get(Scroll)
                            local layouts = archetype:get(Layout)
                            for row = 1, length do
                                local value, viewport = values[row], layouts[row]
                                local maxX = math.max(
                                    value.contentX, value.contentX + value.contentWidth - viewport.width
                                )
                                local maxY = math.max(
                                    value.contentY, value.contentY + value.contentHeight - viewport.height
                                )
                                local x = math.max(value.contentX, math.min(maxX, value.x))
                                local y = math.max(value.contentY, math.min(maxY, value.y))
                                if x ~= value.x or y ~= value.y then
                                    local changed = world:getMut(entities[row], Scroll)
                                    changed.x, changed.y = x, y
                                end
                            end
                        end
                    end
                end

                -- A viewport offset affects only its direct children's local
                -- transforms. Descendant world transforms follow through the
                -- ordinary ChildOf hierarchy.
                if scrollDirty then
                    for archetype, length, entities in scrolls:iter() do
                        if layoutDirty or archetype:isComponentDirty(Scroll) then
                            for row = 1, length do
                                world:targets(entities[row], ChildOf, applyCurrentLayout, world)
                            end
                        end
                    end
                end

                if layoutDirty or scrollDirty or scrollbarDirty then
                    for archetype, length, entities in scrollbars:iter() do
                        local bars = archetype:get(Scrollbar)
                        local relatives = archetype:get(RelativeTransform)
                        for row = 1, length do
                            local parent = world:getFirstRelationship(entities[row], ChildOf)
                            local viewport = parent ~= nil and world:get(parent.target, Scroll) or nil
                            local layout = parent ~= nil and world:get(parent.target, Layout) or nil
                            if viewport ~= nil and layout ~= nil then
                                local bar = bars[row]
                                local vertical = bar.axis == "vertical"
                                local viewportLength = vertical and layout.height or layout.width
                                local contentLength = vertical and viewport.contentHeight or viewport.contentWidth
                                local contentStart = vertical and viewport.contentY or viewport.contentX
                                local offset = vertical and viewport.y or viewport.x
                                local track = math.max(0, viewportLength - bar.inset * 2)
                                local thumb = contentLength > viewportLength
                                    and math.max(bar.minLength, track * viewportLength / contentLength) or 0
                                if thumb > track then
                                    thumb = track
                                end
                                local range = math.max(0, contentLength - viewportLength)
                                local position = range > 0 and (offset - contentStart) / range * (track - thumb) or 0
                                local x, y, scaleX, scaleY: number, number, number, number
                                if vertical then
                                    x = layout.width - bar.inset - bar.thickness * 0.5
                                    y = bar.inset + position + thumb * 0.5
                                    scaleX, scaleY = bar.thickness, thumb
                                else
                                    x = bar.inset + position + thumb * 0.5
                                    y = layout.height - bar.inset - bar.thickness * 0.5
                                    scaleX, scaleY = thumb, bar.thickness
                                end
                                local relative = relatives[row]
                                if
                                    relative.x ~= x
                                    or relative.y ~= y
                                    or relative.scaleX ~= scaleX
                                    or relative.scaleY ~= scaleY
                                then
                                    relative = world:getMut(entities[row], RelativeTransform)
                                    relative.x, relative.y = x, y
                                    relative.scaleX, relative.scaleY = scaleX, scaleY
                                end
                            end
                        end
                    end
                end
                install.geometryDirty = true
            end,
        })
        local function regionFor(entity: integer): number
            local root: Root | nil = nil
            local chain = install.clipChain
            for index = #chain, 1, -1 do
                chain[index] = nil
            end
            local current: integer | nil = entity
            while current ~= nil do
                local candidate = world:get(current, Root)
                if candidate ~= nil then
                    root = candidate
                end
                if world:get(current, Scroll) ~= nil then
                    chain[#chain + 1] = current
                end
                local parent = world:getFirstRelationship(current, ChildOf)
                current = parent ~= nil and parent.target or nil
            end
            if #chain == 0 then
                return 0
            end
            local density: number = 1
            local rootSpace: RootSpace = "screen"
            local rootWidth: number = 0
            local rootHeight: number = 0
            if root ~= nil then
                local value = root as Root
                density = value.pixelDensity
                rootSpace = value.space
                rootWidth, rootHeight = value.width, value.height
                if rootSpace == "world" and install.window ~= nil then
                    rootWidth = install.screenWidth * install.screenDensity
                    rootHeight = install.screenHeight * install.screenDensity
                end
            end
            local minX, minY = -math.huge, -math.huge
            local maxX, maxY = math.huge, math.huge
            local clipped = false
            for chainIndex = 1, #chain do
                local viewport = chain[chainIndex]
                local transform = world:get(viewport, Transform)
                local layout = world:get(viewport, Layout)
                if transform ~= nil and layout ~= nil then
                    clipped = true
                    local left, top = transform.x, transform.y
                    local right, bottom = left + layout.width, top + layout.height
                    if rootSpace == "world" then
                        local x1, y1 = renderer.camera:toScreen(left, top, rootWidth, rootHeight)
                        local x2, y2 = renderer.camera:toScreen(right, top, rootWidth, rootHeight)
                        local x3, y3 = renderer.camera:toScreen(left, bottom, rootWidth, rootHeight)
                        local x4, y4 = renderer.camera:toScreen(right, bottom, rootWidth, rootHeight)
                        left, top = math.min(x1, x2, x3, x4), math.min(y1, y2, y3, y4)
                        right, bottom = math.max(x1, x2, x3, x4), math.max(y1, y2, y3, y4)
                    else
                        left, top, right, bottom = left * density, top * density, right * density, bottom * density
                    end
                    if left > minX then
                        minX = left
                    end
                    if top > minY then
                        minY = top
                    end
                    if right < maxX then
                        maxX = right
                    end
                    if bottom < maxY then
                        maxY = bottom
                    end
                end
            end
            if not clipped then
                return 0
            end
            if maxX < minX then
                maxX = minX
            end
            if maxY < minY then
                maxY = minY
            end
            local key = table.concat(chain, ":")
            local rectKey = ("%.3f:%.3f:%.3f:%.3f"):format(minX, minY, maxX, maxY)
            install.clipUsed[key] = true
            local index = install.clipByKey[key]
            if index == nil then
                for candidate = install.firstClip, install.lastClip do
                    if install.keyByClip[candidate] == nil then
                        index = candidate
                        break
                    end
                end
                if index == nil then
                    error("tecs: UI clip range is exhausted", 2)
                end
                install.clipByKey[key] = index
                install.keyByClip[index] = key
            end
            if install.clipRectByKey[key] ~= rectKey then
                renderer:setClipRegion(index, {x = minX, y = minY, width = maxX - minX, height = maxY - minY})
                install.clipRectByKey[key] = rectKey
            end
            install.clipLeft[index], install.clipTop[index] = minX, minY
            install.clipRight[index], install.clipBottom[index] = maxX, maxY
            return index
        end

        local function screenRectFor(entity: integer): number, number, number, number, number, integer
            local transform = world:get(entity, Transform)
            local layout = world:get(entity, Layout)
            local scrollbar = world:get(entity, Scrollbar)
            if transform == nil or (layout == nil and scrollbar == nil) then
                return nil
            end

            local root: Root | nil = nil
            local treeDepth = 0
            local current: integer | nil = entity
            while current ~= nil do
                local candidate = world:get(current, Root)
                if candidate ~= nil then
                    root = candidate
                end
                local parent = world:getFirstRelationship(current, ChildOf)
                current = parent ~= nil and parent.target or nil
                if current ~= nil then
                    treeDepth = treeDepth + 1
                end
            end
            if root == nil then
                return nil
            end

            local angle = transform.rotation
            local cosine, sine = math.cos(angle), math.sin(angle)
            local ax, ay = transform.x, transform.y
            local bx, by: number, number
            local cx, cy: number, number
            local dx, dy: number, number
            local paint = world:get(entity, Paint)
            if scrollbar ~= nil or (paint ~= nil and paint.stretch) then
                local halfX, halfY = transform.scaleX * 0.5, transform.scaleY * 0.5
                local xx, xy = cosine * halfX, sine * halfX
                local yx, yy = -sine * halfY, cosine * halfY
                ax, ay = transform.x - xx - yx, transform.y - xy - yy
                bx, by = transform.x + xx - yx, transform.y + xy - yy
                cx, cy = transform.x - xx + yx, transform.y - xy + yy
                dx, dy = transform.x + xx + yx, transform.y + xy + yy
            else
                local xx, xy = cosine * layout.width * transform.scaleX, sine * layout.width * transform.scaleX
                local yx, yy = -sine * layout.height * transform.scaleY, cosine * layout.height * transform.scaleY
                bx, by = ax + xx, ay + xy
                cx, cy = ax + yx, ay + yy
                dx, dy = ax + xx + yx, ay + xy + yy
            end

            local rootValue = root as Root
            local density = rootValue.pixelDensity
            if density <= 0 then
                density = 1
            end
            if rootValue.space == "world" then
                local viewportWidth, viewportHeight = rootValue.width, rootValue.height
                if install.window ~= nil then
                    viewportWidth = install.screenWidth * install.screenDensity
                    viewportHeight = install.screenHeight * install.screenDensity
                end
                ax, ay = renderer.camera:toScreen(ax, ay, viewportWidth, viewportHeight)
                bx, by = renderer.camera:toScreen(bx, by, viewportWidth, viewportHeight)
                cx, cy = renderer.camera:toScreen(cx, cy, viewportWidth, viewportHeight)
                dx, dy = renderer.camera:toScreen(dx, dy, viewportWidth, viewportHeight)
                ax, ay, bx, by = ax / density, ay / density, bx / density, by / density
                cx, cy, dx, dy = cx / density, cy / density, dx / density, dy / density
            end

            local left = math.min(ax, bx, cx, dx)
            local top = math.min(ay, by, cy, dy)
            local right = math.max(ax, bx, cx, dx)
            local bottom = math.max(ay, by, cy, dy)
            local clip = world:get(entity, Clip)
            local clipIndex = clip ~= nil and clip.index as integer or 0
            if clipIndex ~= 0 and install.clipLeft[clipIndex] ~= nil then
                local clipLeft = install.clipLeft[clipIndex] / density
                local clipTop = install.clipTop[clipIndex] / density
                local clipRight = install.clipRight[clipIndex] / density
                local clipBottom = install.clipBottom[clipIndex] / density
                if clipLeft > left then
                    left = clipLeft
                end
                if clipTop > top then
                    top = clipTop
                end
                if clipRight < right then
                    right = clipRight
                end
                if clipBottom < bottom then
                    bottom = clipBottom
                end
            end
            if right <= left or bottom <= top then
                return nil
            end
            return left,
                top,
                right,
                bottom,
                layers.depthOf(transform.layer as integer, transform.z, transform.x, transform.y),
                treeDepth
        end

        local function writeHit(
            list: {Hit},
            index: integer,
            entity: integer,
            tabIndex: integer,
            order: integer,
            left: number,
            top: number,
            right: number,
            bottom: number,
            depth: number,
            treeDepth: integer
        )
            local hit = list[index]
            if hit == nil then
                hit = {} as Hit
                list[index] = hit
            end
            hit.entity = entity
            hit.tabIndex = tabIndex
            hit.order = order
            hit.ordinal = ensureOrdinal(install, entity)
            hit.left, hit.top, hit.right, hit.bottom = left, top, right, bottom
            hit.depth, hit.treeDepth = depth, treeDepth
        end

        -- This system name is a compatibility surface exposed by the debugger.
        world:addSystem({
            name = "tecs.UiClip",
            phase = ecs.phases.PostUpdate,
            after = {"RelativeTransform", "tecs.UiLayout"},
            before = {"tecs.TextLayout"},
            run = function()
                -- Keep the static-frame gate proportional to changed
                -- archetypes. The query walks below are the work this gate
                -- protects, not part of deciding whether to do it.
                local geometryDirty = install.geometryDirty
                if not geometryDirty then
                    for archetype in pairs(worldImpl._dirtyArchetypes) do
                        if archetype.columns[Style] or archetype.columns[Scrollbar] then
                            geometryDirty = archetype:isComponentDirty(Transform)
                                or archetype:isComponentDirty(ChildOf)
                                or archetype:isComponentDirty(Root)
                                or archetype:isComponentDirty(Scroll)
                                or archetype:isComponentDirty(Paint)
                                or archetype:isComponentDirty(Interaction)
                            if geometryDirty then
                                break
                            end
                        end
                    end
                end

                local camera = renderer.camera
                local cameraX = camera.x or 0
                local cameraY = camera.y or 0
                local cameraZoom = camera.zoom or 1
                local cameraRotation = camera.rotation or 0
                if
                    install.hasWorldRoots
                    and (
                        cameraX ~= install.cameraX
                        or cameraY ~= install.cameraY
                        or cameraZoom ~= install.cameraZoom
                        or cameraRotation ~= install.cameraRotation
                    )
                then
                    geometryDirty = true
                end
                install.cameraX, install.cameraY = cameraX, cameraY
                install.cameraZoom, install.cameraRotation = cameraZoom, cameraRotation
                if not geometryDirty then
                    return
                end

                for key in pairs(install.clipUsed) do
                    install.clipUsed[key] = nil
                end
                for archetype, length, entities in nodes:iter() do
                    local clips = archetype:get(Clip)
                    for row = 1, length do
                        local index = regionFor(entities[row])
                        if clips[row].index ~= index then
                            world:getMut(entities[row], Clip).index = index
                        end
                    end
                end
                local hitCount = 0
                for archetype, length, entities in interactions:iter() do
                    local values = archetype:get(Interaction)
                    for row = 1, length do
                        local value = values[row]
                        if value.enabled then
                            local left, top, right, bottom, depth, treeDepth = screenRectFor(entities[row])
                            if left ~= nil then
                                hitCount = hitCount + 1
                                writeHit(
                                    install.hits,
                                    hitCount,
                                    entities[row],
                                    value.tabIndex,
                                    value.order,
                                    left,
                                    top,
                                    right,
                                    bottom,
                                    depth,
                                    treeDepth
                                )
                            end
                        end
                    end
                end
                install.hitCount = hitCount
                local scrollHitCount = 0
                for _archetype, length, entities in scrolls:iter() do
                    for row = 1, length do
                        local left, top, right, bottom, depth, treeDepth = screenRectFor(entities[row])
                        if left ~= nil then
                            scrollHitCount = scrollHitCount + 1
                            writeHit(
                                install.scrollHits,
                                scrollHitCount,
                                entities[row],
                                -1,
                                0,
                                left,
                                top,
                                right,
                                bottom,
                                depth,
                                treeDepth
                            )
                        end
                    end
                end
                install.scrollHitCount = scrollHitCount
                for index, key in pairs(install.keyByClip) do
                    if not install.clipUsed[key] then
                        renderer:clearClipRegion(index)
                        install.keyByClip[index] = nil
                        install.clipByKey[key] = nil
                        install.clipRectByKey[key] = nil
                        install.clipLeft[index], install.clipTop[index] = nil, nil
                        install.clipRight[index], install.clipBottom[index] = nil, nil
                    end
                end
                install.geometryDirty = false
            end,
        })
        local function withinActiveScope(entity: integer): boolean
            local scopes = install.focusScopes
            local scope = scopes[#scopes]
            if scope == nil then
                return true
            end
            local current: integer | nil = entity
            while current ~= nil do
                if current == scope then
                    return true
                end
                local parent = world:getFirstRelationship(current, ChildOf)
                current = parent ~= nil and parent.target or nil
            end
            return false
        end

        local function targetAt(list: {Hit}, count: integer, x: number, y: number, nestedFirst: boolean): integer
            local best: Hit = nil
            for index = 1, count do
                local hit = list[index]
                if
                    withinActiveScope(hit.entity)
                    and x >= hit.left
                    and x < hit.right
                    and y >= hit.top
                    and y < hit.bottom
                then
                    if
                        best == nil
                        or (
                            nestedFirst
                            and (
                                hit.treeDepth > best.treeDepth
                                or (hit.treeDepth == best.treeDepth and hit.depth < best.depth)
                                or (
                                    hit.treeDepth == best.treeDepth
                                    and hit.depth == best.depth
                                    and hit.ordinal > best.ordinal
                                )
                            )
                        )
                        or (
                            not nestedFirst
                            and (
                                hit.depth < best.depth
                                or (hit.depth == best.depth and hit.treeDepth > best.treeDepth)
                                or (
                                    hit.depth == best.depth
                                    and hit.treeDepth == best.treeDepth
                                    and (
                                        hit.order > best.order
                                        or (hit.order == best.order and hit.ordinal > best.ordinal)
                                    )
                                )
                            )
                        )
                    then
                        best = hit
                    end
                end
            end
            return best ~= nil and best.entity or nil
        end

        local function dispatch(
            target: integer,
            kind: EventKind,
            x: number,
            y: number,
            button: integer,
            deltaX: number,
            deltaY: number,
            source: InteractionSource,
            bubbles: boolean,
            pointerId?: string,
            pointerType?: PointerType
        ): Event
            local event = Event(
                kind, target, x, y, button, pointerId or "", pointerType or "none", deltaX, deltaY, source
            )
            local current: integer | nil = target
            while current ~= nil do
                event.currentTarget = current
                world:emit(current, event)
                if event.consumed or not bubbles then
                    break
                end
                local parent = world:getFirstRelationship(current, ChildOf)
                current = parent ~= nil and parent.target or nil
            end
            return event
        end

        local function refreshInteractionState(entity?: integer)
            if entity == nil then
                return
            end
            local state = world:get(entity, InteractionState)
            if state == nil then
                return
            end
            local hovered, pressed, dragging = false, false, false
            for _, pointer in pairs(install.pointers) do
                hovered = hovered or pointer.hovered == entity
                pressed = pressed or pointer.captured == entity
                dragging = dragging or (pointer.captured == entity and pointer.dragging)
            end
            if state.hovered ~= hovered or state.pressed ~= pressed or state.dragging ~= dragging then
                state = world:getMut(entity, InteractionState)
                state.hovered, state.pressed, state.dragging = hovered, pressed, dragging
            end
        end

        local function reveal(entity: integer, align?: RevealAlign): boolean
            local layout = world:get(entity, Layout)
            if layout == nil then
                return false
            end
            align = align or "nearest"
            if align ~= "nearest" and align ~= "start" and align ~= "center" and align ~= "end" then
                error("tecs: reveal alignment must be 'nearest', 'start', 'center', or 'end'", 3)
            end
            local left, top = layout.x, layout.y
            local right, bottom = left + layout.width, top + layout.height
            local current = entity
            while true do
                local relationship = world:getFirstRelationship(current, ChildOf)
                if relationship == nil then
                    break
                end
                local parent = relationship.target
                local scroll = world:get(parent, Scroll)
                local parentLayout = world:get(parent, Layout)
                if scroll ~= nil and parentLayout ~= nil then
                    local function revealAxis(start: number, finish: number, offset: number, viewport: number): number
                        if align == "start" then
                            return start
                        elseif align == "center" then
                            return (start + finish - viewport) * 0.5
                        elseif align == "end" then
                            return finish - viewport
                        elseif start < offset then
                            return start
                        elseif finish > offset + viewport then
                            return finish - viewport
                        end
                        return offset
                    end
                    local x = revealAxis(left, right, scroll.x, parentLayout.width)
                    local y = revealAxis(top, bottom, scroll.y, parentLayout.height)
                    local maxX = math.max(scroll.contentX, scroll.contentX + scroll.contentWidth - parentLayout.width)
                    local maxY = math.max(scroll.contentY, scroll.contentY + scroll.contentHeight - parentLayout.height)
                    x = math.max(scroll.contentX, math.min(maxX, x))
                    y = math.max(scroll.contentY, math.min(maxY, y))
                    if x ~= scroll.x or y ~= scroll.y then
                        local changed = world:getMut(parent, Scroll)
                        changed.x, changed.y = x, y
                    end
                    left, right = left - x, right - x
                    top, bottom = top - y, bottom - y
                end
                if parentLayout ~= nil then
                    left, right = left + parentLayout.x, right + parentLayout.x
                    top, bottom = top + parentLayout.y, bottom + parentLayout.y
                end
                current = parent
            end
            return true
        end

        local function focus(entity?: integer, source?: InteractionSource, x?: number, y?: number): boolean
            local previous = install.focused
            if previous == entity then
                return true
            end
            if entity ~= nil and not withinActiveScope(entity) then
                return false
            end
            if entity ~= nil then
                local interaction = world:get(entity, Interaction)
                local state = world:get(entity, InteractionState)
                if interaction == nil or not interaction.enabled or not interaction.focusable or state == nil then
                    return false
                end
            end
            if previous ~= nil then
                local state = world:get(previous, InteractionState)
                if state ~= nil and state.focused then
                    world:getMut(previous, InteractionState).focused = false
                    dispatch(previous, "blur", x or 0, y or 0, 0, 0, 0, source or "keyboard", true)
                end
            end
            install.focused = nil
            if entity ~= nil then
                local state = world:get(entity, InteractionState)
                install.focused = entity
                if not state.focused then
                    world:getMut(entity, InteractionState).focused = true
                end
                dispatch(entity, "focus", x or 0, y or 0, 0, 0, 0, source or "keyboard", true)
                reveal(entity, "nearest")
            end
            return true
        end

        local function focusBefore(left: Hit, right: Hit): boolean
            local leftPositive = left.tabIndex > 0
            local rightPositive = right.tabIndex > 0
            if leftPositive ~= rightPositive then
                return leftPositive
            end
            if left.tabIndex ~= right.tabIndex then
                return left.tabIndex < right.tabIndex
            end
            if left.order ~= right.order then
                return left.order < right.order
            end
            if left.top ~= right.top then
                return left.top < right.top
            end
            if left.left ~= right.left then
                return left.left < right.left
            end
            return left.ordinal < right.ordinal
        end

        local function moveFocus(backward: boolean)
            local first: Hit = nil
            local last: Hit = nil
            local before: Hit = nil
            local after: Hit = nil
            local current: Hit = nil
            for index = 1, install.hitCount do
                local hit = install.hits[index]
                local interaction = world:get(hit.entity, Interaction)
                if
                    interaction ~= nil
                    and interaction.enabled
                    and interaction.focusable
                    and interaction.tabIndex >= 0
                    and withinActiveScope(hit.entity)
                then
                    if first == nil or focusBefore(hit, first) then
                        first = hit
                    end
                    if last == nil or focusBefore(last, hit) then
                        last = hit
                    end
                    if hit.entity == install.focused then
                        current = hit
                    end
                end
            end
            if current ~= nil then
                for index = 1, install.hitCount do
                    local hit = install.hits[index]
                    local interaction = world:get(hit.entity, Interaction)
                    if
                        interaction ~= nil
                        and interaction.enabled
                        and interaction.focusable
                        and interaction.tabIndex >= 0
                        and withinActiveScope(hit.entity)
                    then
                        if focusBefore(hit, current) and (before == nil or focusBefore(before, hit)) then
                            before = hit
                        elseif focusBefore(current, hit) and (after == nil or focusBefore(hit, after)) then
                            after = hit
                        end
                    end
                end
            end
            local nextHit = backward and (before or last) or (after or first)
            focus(nextHit ~= nil and nextHit.entity or nil, "keyboard")
        end

        install.revealEntity = reveal
        install.focusEntity = focus
        install.pushScope = function(scope: integer): boolean
            if world:get(scope, FocusScope) == nil then
                return false
            end
            for index = 1, #install.focusScopes do
                if install.focusScopes[index] == scope then
                    return index == #install.focusScopes
                end
            end
            install.focusRestore[scope] = install.focused
            install.cancelPointers()
            install.focusScopes[#install.focusScopes + 1] = scope
            focus(nil, "programmatic")
            moveFocus(false)
            return true
        end
        install.popScope = function(scope?: integer): boolean
            local scopes = install.focusScopes
            local active = scopes[#scopes]
            if active == nil or (scope ~= nil and scope ~= active) then
                return false
            end
            install.cancelPointers()
            scopes[#scopes] = nil
            local restore = install.focusRestore[active]
            install.focusRestore[active] = nil
            if restore ~= nil and world:get(restore, Interaction) ~= nil and withinActiveScope(restore) then
                focus(restore, "programmatic")
            else
                focus(nil, "programmatic")
                moveFocus(false)
            end
            return true
        end

        local function scrollBy(entity: integer, deltaX: number, deltaY: number)
            local current: integer | nil = entity
            while current ~= nil and (math.abs(deltaX) > 0.001 or math.abs(deltaY) > 0.001) do
                local scroll = world:get(current, Scroll)
                local layout = world:get(current, Layout)
                if scroll ~= nil and layout ~= nil then
                    local maxX = math.max(scroll.contentX, scroll.contentX + scroll.contentWidth - layout.width)
                    local maxY = math.max(scroll.contentY, scroll.contentY + scroll.contentHeight - layout.height)
                    local x = math.max(scroll.contentX, math.min(maxX, scroll.x + deltaX))
                    local y = math.max(scroll.contentY, math.min(maxY, scroll.y + deltaY))
                    local consumedX, consumedY = x - scroll.x, y - scroll.y
                    if consumedX ~= 0 or consumedY ~= 0 then
                        local changed = world:getMut(current, Scroll)
                        changed.x, changed.y = x, y
                        deltaX, deltaY = deltaX - consumedX, deltaY - consumedY
                    end
                end
                local parent = world:getFirstRelationship(current, ChildOf)
                current = parent ~= nil and parent.target or nil
            end
        end

        if install.input ~= nil then
            local endedPointers: {string} = {}

            local function updatePointerHover(pointer: PointerState, canRead: boolean)
                local previous = pointer.hovered
                local hovered = canRead and targetAt(install.hits, install.hitCount, pointer.x, pointer.y, false) or nil
                if previous == hovered then
                    return
                end
                pointer.hovered = hovered
                if pointer.kind == "mouse" then
                    install.hovered = hovered
                end
                refreshInteractionState(previous)
                if previous ~= nil and world:get(previous, InteractionState) ~= nil then
                    dispatch(
                        previous,
                        "pointerLeave",
                        pointer.x,
                        pointer.y,
                        0,
                        0,
                        0,
                        "pointer",
                        false,
                        pointer.id,
                        pointer.kind
                    )
                end
                refreshInteractionState(hovered)
                if hovered ~= nil then
                    dispatch(
                        hovered,
                        "pointerEnter",
                        pointer.x,
                        pointer.y,
                        0,
                        0,
                        0,
                        "pointer",
                        false,
                        pointer.id,
                        pointer.kind
                    )
                end
            end

            local function beginPointer(pointer: PointerState)
                local target = pointer.hovered
                pointer.startX, pointer.startY = pointer.x, pointer.y
                pointer.dragging = false
                pointer.captured = target
                pointer.startScroll = 0
                if target ~= nil then
                    local bar = world:get(target, Scrollbar)
                    local parent = world:getFirstRelationship(target, ChildOf)
                    local scroll = parent ~= nil and world:get(parent.target, Scroll) or nil
                    if bar ~= nil and scroll ~= nil then
                        pointer.startScroll = bar.axis == "vertical" and scroll.y or scroll.x
                    end
                    refreshInteractionState(target)
                    local interaction = world:get(target, Interaction)
                    if interaction ~= nil and interaction.focusable then
                        focus(target, "pointer", pointer.x, pointer.y)
                    end
                    dispatch(
                        target, "pointerDown", pointer.x, pointer.y, 1, 0, 0, "pointer", true, pointer.id, pointer.kind
                    )
                else
                    focus(nil, "pointer", pointer.x, pointer.y)
                end
            end

            local function moveScrollbar(pointer: PointerState)
                local target = pointer.captured
                local bar = target ~= nil and world:get(target, Scrollbar) or nil
                local relationship = target ~= nil and world:getFirstRelationship(target, ChildOf) or nil
                local scroll = relationship ~= nil and world:get(relationship.target, Scroll) or nil
                local layout = relationship ~= nil and world:get(relationship.target, Layout) or nil
                if bar == nil or scroll == nil or layout == nil then
                    return
                end
                local vertical = bar.axis == "vertical"
                local viewportLength = vertical and layout.height or layout.width
                local contentLength = vertical and scroll.contentHeight or scroll.contentWidth
                local contentStart = vertical and scroll.contentY or scroll.contentX
                local track = math.max(0, viewportLength - bar.inset * 2)
                local thumb = math.min(
                    track, math.max(bar.minLength, track * viewportLength / math.max(viewportLength, contentLength))
                )
                local travel = track - thumb
                local range = math.max(0, contentLength - viewportLength)
                if travel <= 0 or range <= 0 then
                    return
                end
                local delta = vertical and (pointer.y - pointer.startY) or (pointer.x - pointer.startX)
                local value = math.max(
                    contentStart, math.min(contentStart + range, pointer.startScroll + delta / travel * range)
                )
                if vertical then
                    if value ~= scroll.y then
                        world:getMut(relationship.target, Scroll).y = value
                    end
                else
                    if value ~= scroll.x then
                        world:getMut(relationship.target, Scroll).x = value
                    end
                end
            end

            local function movePointer(pointer: PointerState)
                local dx, dy = pointer.x - pointer.previousX, pointer.y - pointer.previousY
                if dx == 0 and dy == 0 then
                    return
                end
                local target = pointer.captured or pointer.hovered
                if target ~= nil and world:get(target, InteractionState) ~= nil then
                    dispatch(
                        target,
                        "pointerMove",
                        pointer.x,
                        pointer.y,
                        0,
                        dx,
                        dy,
                        "pointer",
                        true,
                        pointer.id,
                        pointer.kind
                    )
                end
                local captured = pointer.captured
                local interaction = captured ~= nil and world:get(captured, Interaction) or nil
                if interaction ~= nil and interaction.draggable then
                    if not pointer.dragging then
                        local totalX, totalY = pointer.x - pointer.startX, pointer.y - pointer.startY
                        if totalX * totalX + totalY * totalY >= install.dragThreshold * install.dragThreshold then
                            pointer.dragging = true
                            refreshInteractionState(captured)
                            dispatch(
                                captured,
                                "dragStart",
                                pointer.x,
                                pointer.y,
                                1,
                                totalX,
                                totalY,
                                "pointer",
                                true,
                                pointer.id,
                                pointer.kind
                            )
                        end
                    end
                    if pointer.dragging then
                        dispatch(
                            captured,
                            "dragMove",
                            pointer.x,
                            pointer.y,
                            1,
                            dx,
                            dy,
                            "pointer",
                            true,
                            pointer.id,
                            pointer.kind
                        )
                        moveScrollbar(pointer)
                    end
                end
            end

            local function endPointer(pointer: PointerState, canceled: boolean)
                local captured = pointer.captured
                pointer.captured = nil
                if captured == nil then
                    return
                end
                if world:get(captured, InteractionState) ~= nil then
                    dispatch(
                        captured, "pointerUp", pointer.x, pointer.y, 1, 0, 0, "pointer", true, pointer.id, pointer.kind
                    )
                    if pointer.dragging then
                        dispatch(
                            captured,
                            (canceled and "dragCancel" or "dragEnd") as EventKind,
                            pointer.x,
                            pointer.y,
                            1,
                            pointer.x - pointer.startX,
                            pointer.y - pointer.startY,
                            "pointer",
                            true,
                            pointer.id,
                            pointer.kind
                        )
                    elseif not canceled and captured == pointer.hovered then
                        local clicked = dispatch(
                            captured, "click", pointer.x, pointer.y, 1, 0, 0, "pointer", true, pointer.id, pointer.kind
                        )
                        if not clicked.consumed then
                            dispatch(
                                captured,
                                "activate",
                                pointer.x,
                                pointer.y,
                                1,
                                0,
                                0,
                                "pointer",
                                true,
                                pointer.id,
                                pointer.kind
                            )
                        end
                    end
                end
                pointer.dragging = false
                refreshInteractionState(captured)
            end

            install.cancelPointers = function()
                for _, pointer in pairs(install.pointers) do
                    if pointer.captured ~= nil then
                        endPointer(pointer, true)
                    end
                end
            end

            -- This system name is a compatibility surface exposed by the debugger.
            world:addSystem({
                name = "tecs.UiInput",
                phase = ecs.phases.PreUpdate,
                run = function(dt: number)
                    local input = install.input
                    while
                        #install.focusScopes > 0
                        and world:get(install.focusScopes[#install.focusScopes], FocusScope) == nil
                    do
                        install.popScope()
                    end
                    if install.focused ~= nil then
                        local interaction = world:get(install.focused, Interaction)
                        if
                            interaction == nil
                            or not interaction.enabled
                            or not interaction.focusable
                            or not withinActiveScope(install.focused)
                        then
                            focus(nil, "keyboard")
                        end
                    end

                    local canRead = input:canRead(install.layer)
                    local mouse = install.pointers.mouse
                    if mouse == nil then
                        mouse = {
                            id = "mouse",
                            kind = "mouse",
                            x = input.mouseX,
                            y = input.mouseY,
                            previousX = input.mouseX,
                            previousY = input.mouseY,
                            startX = input.mouseX,
                            startY = input.mouseY,
                            startScroll = 0,
                            seen = true,
                        } as PointerState
                        install.pointers.mouse = mouse
                    end
                    mouse.previousX, mouse.previousY = mouse.x, mouse.y
                    mouse.x, mouse.y = input.mouseX, input.mouseY
                    updatePointerHover(mouse, canRead)
                    if not canRead then
                        endPointer(mouse, true)
                    else
                        movePointer(mouse)
                        if input:mousePressed("left", install.layer) then
                            beginPointer(mouse)
                        end
                        if input:mouseReleased("left", install.layer) then
                            endPointer(mouse, false)
                        end
                    end

                    for _, pointer in pairs(install.pointers) do
                        if pointer.kind == "touch" then
                            pointer.seen = false
                        end
                    end
                    local touches = noTouches
                    if canRead and type((input as {string: any}).touches) == "function" then
                        touches = input:touches(install.layer)
                    end
                    for index = 1, #touches do
                        local touch = touches[index]
                        local id = touch.device .. ":" .. touch.finger
                        local pointer = install.pointers[id]
                        local began = pointer == nil
                        if pointer == nil then
                            pointer = {
                                id = id,
                                kind = "touch",
                                x = touch.x,
                                y = touch.y,
                                previousX = touch.x,
                                previousY = touch.y,
                                startX = touch.x,
                                startY = touch.y,
                                startScroll = 0,
                            } as PointerState
                            install.pointers[id] = pointer
                        else
                            pointer.previousX, pointer.previousY = pointer.x, pointer.y
                            pointer.x, pointer.y = touch.x, touch.y
                        end
                        pointer.seen = true
                        updatePointerHover(pointer, true)
                        if began then
                            beginPointer(pointer)
                        else
                            movePointer(pointer)
                        end
                    end
                    for index = #endedPointers, 1, -1 do
                        endedPointers[index] = nil
                    end
                    for id, pointer in pairs(install.pointers) do
                        if pointer.kind == "touch" and not pointer.seen then
                            endedPointers[#endedPointers + 1] = id
                        end
                    end
                    for index = 1, #endedPointers do
                        local id = endedPointers[index]
                        local pointer = install.pointers[id]
                        endPointer(pointer, not canRead)
                        local hovered = pointer.hovered
                        pointer.hovered = nil
                        install.pointers[id] = nil
                        refreshInteractionState(hovered)
                    end

                    local x, y = mouse.x, mouse.y
                    local preferredWheelX = input.wheelPreferredX
                    local preferredWheelY = input.wheelPreferredY
                    if preferredWheelX == nil then
                        preferredWheelX = input.wheelX
                    end
                    if preferredWheelY == nil then
                        preferredWheelY = input.wheelY
                    end
                    if canRead and (preferredWheelX ~= 0 or preferredWheelY ~= 0) then
                        local target = targetAt(install.scrollHits, install.scrollHitCount, x, y, true)
                        if target ~= nil then
                            local wheelX, wheelY = preferredWheelX, preferredWheelY
                            if input:modifierDown("shift", install.layer) and wheelX == 0 then
                                wheelX, wheelY = wheelY, 0
                            end
                            local wheel = dispatch(
                                target, "wheel", x, y, 0, wheelX, wheelY, "pointer", true, mouse.id, mouse.kind
                            )
                            if not wheel.consumed then
                                scrollBy(target, -wheelX * install.wheelStep, -wheelY * install.wheelStep)
                            end
                        end
                    end

                    local tabPressed = canRead and input:keyPressed("tab", install.layer)
                    local tabDown = canRead and input:keyDown("tab", install.layer)
                    if tabPressed then
                        moveFocus(input:modifierDown("shift", install.layer))
                        install.tabRepeating = true
                        install.tabRepeated = false
                        install.tabRepeatElapsed = 0
                    elseif not tabDown then
                        install.tabRepeating = false
                        install.tabRepeated = false
                        install.tabRepeatElapsed = 0
                    elseif install.tabRepeating then
                        local threshold = install.tabRepeated and TAB_REPEAT_INTERVAL or TAB_REPEAT_DELAY
                        install.tabRepeatElapsed = install.tabRepeatElapsed + dt
                        if install.tabRepeatElapsed >= threshold then
                            install.tabRepeatElapsed = install.tabRepeatElapsed - threshold
                            install.tabRepeated = true
                            moveFocus(input:modifierDown("shift", install.layer))
                        end
                    end
                    if
                        canRead
                        and install.focused ~= nil
                        and (input:keyPressed("return", install.layer) or input:keyPressed("space", install.layer))
                    then
                        dispatch(install.focused, "activate", x, y, 0, 0, 0, "keyboard", true)
                    end
                end,
            })
        end
    end
end

return ui
