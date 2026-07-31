--[=[
Retained UI layout for ordinary Tecs entities.

[`Style`](tealdoc:tecs.ui.Style) describes layout only. It does not replace a
rectangle, circle, sprite, image, or text component. Put an existing drawing
component on the same entity, or on a child, and add `Paint(true)` when its
transform should stretch to the computed box. Drawing remains in the existing
instanced producers and shaders.

The plugin retains one native layout tree keyed by ECS entity ID. `ChildOf` is the
layout hierarchy as well as the transform hierarchy. The layout system writes
`Layout` only when the box changes and writes `RelativeTransform` only when
layout or scrolling changes its result.

`px`, `%`, and `auto` dimension strings are parsed only when a `Style` enters or dirties the
retained tree. Unchanged frames skip layout computation, layout export, clip
reconstruction, and hit-rectangle reconstruction. A screen root installed
through `plugin(app)` follows the application's logical window size and pixel
density automatically.

`Paint(true)` centers and stretches a drawing leaf over its box. Keep
containers at unit scale and put their rectangle, circle, or image on an
absolute child with `Paint`: transform scale composes through `ChildOf`, so a
stretched container would also scale its descendants.

## Scrolling and clipping

[`Scroll`](tealdoc:tecs.ui.Scroll) turns its entity's layout box into a
viewport. Its `x` and `y` move descendants, not the viewport entity itself.
Every nested viewport is intersected before the plugin assigns the existing
`tecs.gfx.Clip` component, so each drawable still carries one clip index in the
ordinary GPU instance. `firstClip` and `lastClip` reserve which of the
renderer’s 255 clip rectangles the UI owns.

Screen roots use logical UI coordinates and multiply clips by `pixelDensity`.
World roots project viewport corners through the renderer camera. Clip
rectangles stay axis-aligned; rotating a scroll viewport therefore does not
rotate its clip.

## Interaction and navigation

Passing the application to [`plugin`](tealdoc:tecs.ui.plugin) supplies its
renderer and input, enabling clip-aware hit testing. Manual options remain
available to tests and tools. [`Interaction`](tealdoc:tecs.ui.Interaction) opts
in a layout box, and [`InteractionState`](tealdoc:tecs.ui.InteractionState)
reports hover, primary-button capture, and focus without replacing application
state.

The plugin emits one bubbling [`Event`](tealdoc:tecs.ui.Event) at entity
addresses. A primary press captures its target through release; releasing over
that target emits `"click"` and then `"activate"`. Tab and Shift-Tab traverse
visible focusable controls, and Return or Space emits `"activate"` at the
focused control. A `"wheel"` event begins at the deepest viewport under the
pointer; setting `event.consumed = true` prevents both ancestor delivery and
default scrolling.

Hit priority uses the renderer's layer-depth calculation. A depth tie prefers
the deeper UI node and then the larger entity ID. Give overlapping controls
distinct layers or Z values when their visual order must not depend on the
renderer’s exact-tie instance order.

```teal
local ui <const> = tecs.ui
local ChildOf <const> = tecs.ecs.ChildOf
local RelativeTransform <const> = tecs.ecs.RelativeTransform
local type uiTypes = require("tecs.ui")
local type UiEvent = uiTypes.Event

local function spawnInterface(world: tecs.World)
    local root <const> = world:spawn(
        ui.Style({width = "100%", height = "100%"}),
        ui.Root("screen")
    )
    local viewport <const> = world:spawn(
        ui.Style({width = "320px", height = "240px", padding = 8}),
        ui.Scroll(),
        RelativeTransform(),
        ChildOf(root)
    )

    world:spawn(
        ui.Style({width = 300, height = 600}),
        ui.Interaction(),
        RelativeTransform(),
        ChildOf(viewport)
    )

    world:observe(viewport, ui.Event, function(event: UiEvent)
        if event.kind == "activate" then
            print("activated", event.target)
        end
    end)
end
```

Install the UI from the application plugin, and let a `Startup` system invoke
the layout function:

```teal
local function gamePlugin(world: tecs.World, app: tecs.Application)
    world:addPlugin(ui.plugin(app))
    world:addSystem({
        name = "game.SpawnInterface",
        phase = tecs.ecs.phases.Startup,
        run = function()
            spawnInterface(world)
        end,
    })
end

return tecs.newApplication({plugin = gamePlugin})
```
]=]

local ecs <const> = require("tecs.ecs")
local events <const> = require("tecs.events")
local type types = require("tecs.types")
local rust <const> = require("tecs.ffi.rust")
local type loader = require("tecs.ffi.loader")
local components <const> = require("tecs.components")
local layers <const> = require("tecs.gfx.layers")
local ffi <const> = require("ffi")

local type Component = ecs.Component
local type World = types.World
local type Renderer = require("tecs.Renderer")

local C <const> = rust.C
local Transform <const> = ecs.Transform
local RelativeTransform <const> = ecs.RelativeTransform
local ChildOf <const> = ecs.ChildOf
local Clip <const> = components.Clip

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
    --- `rowGap`, and `inset`. Edge values accept one dimension or a table with
    --- `left`, `right`, `top`, and `bottom`.
    style: {string: any}
end
--- `Root` supplies the available space and coordinate mapping for one tree.
local record Root is Component
    --- Caller-writable. The caller chooses `"screen"` for logical screen
    --- coordinates or `"world"` for coordinates projected by the camera.
    space: string
    --- Caller-writable. The caller supplies the layout root width and the
    --- camera projection width in logical units. When `plugin` receives an
    --- application, the engine overwrites this field on screen roots with the
    --- current logical window width.
    width: number
    --- Caller-writable. The caller supplies the layout root height and the
    --- camera projection height in logical units. When `plugin` receives an
    --- application, the engine overwrites this field on screen roots with the
    --- current logical window height.
    height: number
    --- Caller-writable. The caller supplies target pixels per logical point
    --- for a screen root. The default is one. When `plugin` receives an
    --- application, the engine overwrites this field on screen roots with the
    --- window's current pixel density.
    pixelDensity: number
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
--- `Scroll` offsets descendants and clips them to this entity's layout box.
local record Scroll is Component
    --- Caller-writable. The caller supplies the horizontal scroll offset in
    --- logical units.
    x: number
    --- Caller-writable. The caller supplies the vertical scroll offset in
    --- logical units.
    y: number
    --- Engine-owned. The engine reports the horizontal extent of the direct
    --- layout children. Ordinary game code should ignore this field.
    contentWidth: number
    --- Engine-owned. The engine reports the vertical extent of the direct
    --- layout children. Ordinary game code should ignore this field.
    contentHeight: number
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
    --- first in ascending order, zero values follow in entity order, and
    --- negative values skip keyboard navigation.
    tabIndex: integer
end
--- `InteractionState` reports transient state derived by the UI plugin.
local record InteractionState is Component
    --- Engine-owned. The engine reports whether the pointer is over the
    --- entity's visible, clipped box. Ordinary game code may read this field
    --- to choose its visual state and must not write it.
    hovered: boolean
    --- Engine-owned. The engine reports whether the primary pointer button
    --- was pressed on the entity and remains captured. Ordinary game code may
    --- read this field and must not write it.
    pressed: boolean
    --- Engine-owned. The engine reports whether keyboard activation currently
    --- targets the entity. Ordinary game code may read this field and must not
    --- write it.
    focused: boolean
end
--- `Event` reports one semantic interaction at an entity address.
local record Event is events.Event
    --- Read-only. Reports `"pointerEnter"`, `"pointerLeave"`,
    --- `"pointerDown"`, `"pointerUp"`, `"click"`, `"wheel"`, `"focus"`,
    --- `"blur"`, or `"activate"`.
    kind: string
    --- Read-only. Identifies the entity where dispatch began.
    target: integer
    --- Read-only. Identifies the entity whose observers are currently
    --- receiving this bubbling event.
    currentTarget: integer
    --- Read-only. Reports the pointer's horizontal window coordinate.
    x: number
    --- Read-only. Reports the pointer's vertical window coordinate.
    y: number
    --- Read-only. Reports the mouse button, or zero when the event has no
    --- button.
    button: integer
    --- Read-only. Reports horizontal wheel movement for a `"wheel"` event.
    deltaX: number
    --- Read-only. Reports vertical wheel movement for a `"wheel"` event.
    deltaY: number
    --- Read-only. Reports `"pointer"` or `"keyboard"` as the activation
    --- source.
    source: string
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
    --- @param deltaX Horizontal wheel movement or zero.
    --- @param deltaY Vertical wheel movement or zero.
    --- @param source The activation source.
    --- @return Returns an independent event value.
    metamethod __call: function(
        self,
        kind: string,
        target: integer,
        x: number,
        y: number,
        button: integer,
        deltaX: number,
        deltaY: number,
        source: string
    ): Event
end
local interface InputReader
    mouseX: number
    mouseY: number
    wheelX: number
    wheelY: number
    canRead: function(self: InputReader, layer?: any): boolean
    mousePressed: function(self: InputReader, button: string | integer, layer?: any): boolean
    mouseReleased: function(self: InputReader, button: string | integer, layer?: any): boolean
    keyPressed: function(self: InputReader, key: string | integer, layer?: any): boolean
    modifierDown: function(self: InputReader, name: string, layer?: any): boolean
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
    fields = {"space", "width", "height", "pixelDensity"},
    defaults = {"screen", 0, 0, 1},
    requires = {Style, Transform},
})

-- Compatibility surface: snapshots and tools name this component "UiPaint".
ecs.newComponent({
    name = "UiPaint",
    container = Paint,
    fields = {"stretch"},
    defaults = {false},
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
    },
    defaults = {0, 0, 0, 0},
    requires = {Style},
})

-- Compatibility surface: snapshots and tools name this component
-- "UiInteractionState".
ecs.newFFIComponent({
    name = "UiInteractionState",
    container = InteractionState,
    fields = {{"hovered", "bool"}, {"pressed", "bool"}, {"focused", "bool"}},
    defaults = {false, false, false},
    transient = true,
})

-- Compatibility surface: snapshots and tools name this component
-- "UiInteraction".
ecs.newComponent({
    name = "UiInteraction",
    container = Interaction,
    fields = {"enabled", "focusable", "tabIndex"},
    defaults = {true, true, 0},
    requires = {Style, InteractionState},
    __call = function(instance: Interaction, value?: {string: any})
        local options = value or {}
        instance.enabled = options.enabled ~= false
        instance.focusable = options.focusable ~= false
        instance.tabIndex = options.tabIndex as integer or 0
    end,
})

Event.init = function(
    event: Event,
    kind: string,
    target: integer,
    x: number,
    y: number,
    button: integer,
    deltaX: number,
    deltaY: number,
    source: string
)
    event.kind = kind
    event.target = target
    event.currentTarget = target
    event.x, event.y = x, y
    event.button = button
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
    treeDepth: integer
end

local record Install
    tree: loader.CPtr
    output: loader.CStruct
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
    captured: integer
    focused: integer
    input: InputReader
    window: WindowReader
    layer: any
    wheelStep: number
    geometryDirty: boolean
    hasWorldRoots: boolean
    cameraX: number
    cameraY: number
    cameraZoom: number
    cameraRotation: number
end

local function unit(value: any, output: any)
    local target = output as {string: any}
    if type(value) == "number" then
        target.value, target.unit = value, 1
    elseif type(value) == "string" then
        local text = value as string
        if text == "auto" then
            target.value, target.unit = 0, 0
            return
        end
        local amount = text:match("^([+-]?%d*%.?%d+)px$")
        if amount ~= nil then
            target.value, target.unit = tonumber(amount), 1
            return
        end
        amount = text:match("^([+-]?%d*%.?%d+)%%$")
        if amount ~= nil then
            target.value, target.unit = (tonumber(amount) as number) / 100, 2
            return
        end
        error(
            ("tecs: invalid UI dimension %q; expected a number, 'auto', '<number>px', or '<number>%%'"):format(text), 3
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

local function collectChild(id: integer, install: Install)
    if install.live[id] then
        install.children[#install.children + 1] = id
    end
end

local function syncChildren(world: World, install: Install, entity: integer)
    local children = install.children
    for index = #children, 1, -1 do
        children[index] = nil
    end
    world:targets(entity, ChildOf, collectChild, install)
    table.sort(children)
    local key = table.concat(children, ":")
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

local record BoundsContext
    world: World
    width: number
    height: number
end

local function collectBounds(entity: integer, context: BoundsContext)
    local layout = context.world:get(entity, Layout)
    if layout == nil then
        return
    end
    local right = layout.x + layout.width
    local bottom = layout.y + layout.height
    if right > context.width then
        context.width = right
    end
    if bottom > context.height then
        context.height = bottom
    end
end

local record ui
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
    --- Read-only. Exposes the component that offsets descendants and clips
    --- their existing GPU instances.
    Scroll: Scroll
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

    --- Returns a plugin that derives layout, transforms, clipping, and
    --- optional interaction from retained layout nodes.
    ---
    --- The plugin owns every renderer clip index from `firstClip` through
    --- `lastClip`, inclusive. Reserve a smaller range when another system also
    --- calls `Renderer:setClipRegion`. Exhausting the range raises rather than
    --- drawing unclipped content.
    ---
    --- Passing an [`Application`](tealdoc:tecs.Application) supplies its
    --- renderer, input, and window. The plugin then synchronizes every screen
    --- root's logical size and pixel density before layout. The optional
    --- second argument overrides clip allocation, the input layer, and wheel
    --- distance. Passing `Options` directly preserves manual wiring for tests,
    --- tools, and worlds not owned by an application. When input is present,
    --- the plugin reads its configured layer in `PreUpdate`. It uses the hit
    --- geometry derived after the previous frame's layout and clipping, which
    --- is the geometry the player was shown when the input arrived.
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
ui.Style, ui.Root, ui.Layout, ui.Paint, ui.Scroll = Style, Root, Layout, Paint, Scroll
ui.Interaction, ui.InteractionState, ui.Event = Interaction, InteractionState, Event

function ui.plugin(provider: any, overrides?: Overrides): function(World)
    local configuration <const> = provider as {string: any}
    if configuration == nil or configuration.renderer == nil then
        error("tecs: the UI plugin needs a `renderer`", 2)
    end
    local overrideValues <const> = overrides or {}
    local firstClip = (overrideValues.firstClip or configuration.firstClip or 1) as integer
    local lastClip = (overrideValues.lastClip or configuration.lastClip or 255) as integer
    local wheelStep = (overrideValues.wheelStep or configuration.wheelStep or 40) as number
    if firstClip < 1 or lastClip > 255 or firstClip > lastClip then
        error("tecs: UI clip range must be within 1 through 255", 2)
    end
    if wheelStep < 0 then
        error("tecs: UI wheelStep cannot be negative", 2)
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
            output = ffi.new("TecsUiLayout") as loader.CStruct,
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
            captured = nil,
            focused = nil,
            input = inputReader,
            window = window,
            layer = layer,
            wheelStep = wheelStep,
            geometryDirty = true,
            hasWorldRoots = false,
            cameraX = math.huge,
            cameraY = math.huge,
            cameraZoom = math.huge,
            cameraRotation = math.huge,
        }
        -- These names are compatibility surfaces exposed by the debugger.
        local nodes = world:newQuery({name = "tecs.UiLayout", include = {NodeComponent, Style, Layout}})
        local roots = world:newQuery({name = "tecs.UiRoots", include = {NodeComponent, Root}})
        local scrolls = world:newQuery({name = "tecs.UiScrolls", include = {Scroll, Layout}})
        local interactions = world:newQuery({
            name = "tecs.UiInteractions",
            include = {Interaction, InteractionState, Layout, Transform},
        })
        -- This system name is a compatibility surface exposed by the debugger.
        world:addSystem({
            name = "tecs.UiLayout",
            phase = ecs.phases.PostUpdate,
            before = {"RelativeTransform"},
            run = function()
                local layoutDirty = false
                local hierarchyDirty = false
                local transformDirty = false

                local screenWidth: number = 0
                local screenHeight: number = 0
                local screenDensity: number = 1
                local activeWindow = install.window
                if activeWindow ~= nil then
                    screenWidth, screenHeight = activeWindow:getSize()
                    screenDensity = activeWindow:pixelDensity()
                end
                install.hasWorldRoots = false
                for archetype, length, entities in roots:iter() do
                    local values = archetype:get(Root)
                    layoutDirty = layoutDirty or archetype:isComponentDirty(Root)
                    for row = 1, length do
                        local value = values[row]
                        if value.space == "world" then
                            install.hasWorldRoots = true
                        elseif
                            install.window ~= nil
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
                        end
                    end
                end

                for entity in pairs(install.live) do
                    install.live[entity] = nil
                end
                for archetype, length, entities in nodes:iter() do
                    local styles = archetype:get(Style)
                    local styleDirty = archetype:isComponentDirty(Style)
                    local childDirty = archetype:isComponentDirty(ChildOf)
                    layoutDirty = layoutDirty or styleDirty or childDirty
                    hierarchyDirty = hierarchyDirty or childDirty
                    transformDirty = transformDirty
                        or archetype:isComponentDirty(RelativeTransform)
                        or archetype:isComponentDirty(Paint)
                    for row = 1, length do
                        local entity = entities[row]
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
                            error("tecs: UI style synchronization failed: " .. loader.toString(C.tecsRustError()), 2)
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

                for archetype in scrolls:iter() do
                    if archetype:isComponentDirty(Scroll) then
                        transformDirty = true
                    end
                end

                if not layoutDirty and not transformDirty then
                    return
                end

                -- The native tree retains its last boxes. Scrolling and paint
                -- changes can reuse those boxes without recomputing layout.
                if layoutDirty then
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
                                and not (
                                    C.tecsUiTreeCompute(install.tree, entities[row], root.width, root.height) as boolean
                                )
                            then
                                error("tecs: UI layout failed: " .. loader.toString(C.tecsRustError()), 2)
                            end
                        end
                    end
                end
                for archetype, length, entities in nodes:iter() do
                    local layouts = archetype:get(Layout)
                    for row = 1, length do
                        local entity = entities[row]
                        local output = install.output
                        if C.tecsUiTreeLayout(install.tree, entity, output) as boolean then
                            local current = layouts[row]
                            local x, y = output.x as number, output.y as number
                            local width, height = output.width as number, output.height as number
                            if
                                current.x ~= x or current.y ~= y or current.width ~= width or current.height ~= height
                            then
                                local changed = world:getMut(entity, Layout)
                                changed.x, changed.y, changed.width, changed.height = x, y, width, height
                            end
                            local relative = world:get(entity, RelativeTransform)
                            if relative ~= nil then
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
                                if
                                    relative.x ~= relativeX
                                    or relative.y ~= relativeY
                                    or relative.scaleX ~= scaleX
                                    or relative.scaleY ~= scaleY
                                then
                                    relative = world:getMut(entity, RelativeTransform)
                                    relative.x, relative.y = relativeX, relativeY
                                    relative.scaleX, relative.scaleY = scaleX, scaleY
                                end
                            end
                        end
                    end
                end
                if layoutDirty then
                    local bounds: BoundsContext = {world = world, width = 0, height = 0}
                    for archetype, length, entities in scrolls:iter() do
                        local values = archetype:get(Scroll)
                        for row = 1, length do
                            bounds.width, bounds.height = 0, 0
                            world:targets(entities[row], ChildOf, collectBounds, bounds)
                            local value = values[row]
                            if value.contentWidth ~= bounds.width or value.contentHeight ~= bounds.height then
                                local changed = world:getMut(entities[row], Scroll)
                                changed.contentWidth, changed.contentHeight = bounds.width, bounds.height
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
            local rootSpace = "screen"
            local rootWidth: number = 0
            local rootHeight: number = 0
            if root ~= nil then
                local value = root as Root
                density = value.pixelDensity
                rootSpace = value.space
                rootWidth, rootHeight = value.width, value.height
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
            if transform == nil or layout == nil then
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
            if paint ~= nil and paint.stretch then
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
                ax, ay = renderer.camera:toScreen(ax, ay, rootValue.width, rootValue.height)
                bx, by = renderer.camera:toScreen(bx, by, rootValue.width, rootValue.height)
                cx, cy = renderer.camera:toScreen(cx, cy, rootValue.width, rootValue.height)
                dx, dy = renderer.camera:toScreen(dx, dy, rootValue.width, rootValue.height)
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
                -- The queries are cheap dirty gates over archetypes. The tree
                -- walks and coordinate projection below run only when their
                -- retained geometry can have changed.
                local geometryDirty = install.geometryDirty
                for archetype in nodes:iter() do
                    geometryDirty = geometryDirty
                        or archetype:isComponentDirty(Transform)
                        or archetype:isComponentDirty(ChildOf)
                        or archetype:isComponentDirty(Root)
                        or archetype:isComponentDirty(Scroll)
                        or archetype:isComponentDirty(Paint)
                end
                for archetype in interactions:iter() do
                    geometryDirty = geometryDirty or archetype:isComponentDirty(Interaction)
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
        local function targetAt(list: {Hit}, count: integer, x: number, y: number, nestedFirst: boolean): integer
            local best: Hit = nil
            for index = 1, count do
                local hit = list[index]
                if x >= hit.left and x < hit.right and y >= hit.top and y < hit.bottom then
                    if
                        best == nil
                        or (
                            nestedFirst
                            and (
                                hit.treeDepth > best.treeDepth
                                or (hit.treeDepth == best.treeDepth and hit.depth < best.depth)
                            )
                        )
                        or (
                            not nestedFirst
                            and (hit.depth < best.depth or (hit.depth == best.depth and hit.treeDepth > best.treeDepth))
                        )
                        or (hit.treeDepth == best.treeDepth and hit.depth == best.depth and hit.entity > best.entity)
                    then
                        best = hit
                    end
                end
            end
            return best ~= nil and best.entity or nil
        end

        local function dispatch(
            target: integer,
            kind: string,
            x: number,
            y: number,
            button: integer,
            deltaX: number,
            deltaY: number,
            source: string,
            bubbles: boolean
        ): Event
            local event = Event(kind, target, x, y, button, deltaX, deltaY, source)
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

        local function setHovered(entity: integer, value: boolean)
            local state = world:get(entity, InteractionState)
            if state ~= nil and state.hovered ~= value then
                world:getMut(entity, InteractionState).hovered = value
            end
        end

        local function setPressed(entity: integer, value: boolean)
            local state = world:get(entity, InteractionState)
            if state ~= nil and state.pressed ~= value then
                world:getMut(entity, InteractionState).pressed = value
            end
        end

        local function focus(entity?: integer, source?: string, x?: number, y?: number)
            local previous = install.focused
            if previous == entity then
                return
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
                local interaction = world:get(entity, Interaction)
                local state = world:get(entity, InteractionState)
                if interaction ~= nil and interaction.enabled and interaction.focusable and state ~= nil then
                    install.focused = entity
                    if not state.focused then
                        world:getMut(entity, InteractionState).focused = true
                    end
                    dispatch(entity, "focus", x or 0, y or 0, 0, 0, 0, source or "keyboard", true)
                end
            end
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
            return left.entity < right.entity
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
                    interaction ~= nil and interaction.enabled and interaction.focusable and interaction.tabIndex >= 0
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

        if install.input ~= nil then
            -- This system name is a compatibility surface exposed by the debugger.
            world:addSystem({
                name = "tecs.UiInput",
                phase = ecs.phases.PreUpdate,
                run = function()
                    local input = install.input
                    if install.focused ~= nil then
                        local interaction = world:get(install.focused, Interaction)
                        if interaction == nil or not interaction.enabled or not interaction.focusable then
                            focus(nil, "keyboard")
                        end
                    end
                    if install.captured ~= nil and world:get(install.captured, InteractionState) == nil then
                        install.captured = nil
                    end
                    local canRead = input:canRead(install.layer)
                    local x, y = input.mouseX, input.mouseY
                    local hovered = canRead and targetAt(install.hits, install.hitCount, x, y, false) or nil
                    if hovered ~= install.hovered then
                        if install.hovered ~= nil then
                            local previous = install.hovered
                            setHovered(previous, false)
                            if world:get(previous, InteractionState) ~= nil then
                                dispatch(previous, "pointerLeave", x, y, 0, 0, 0, "pointer", false)
                            end
                        end
                        install.hovered = hovered
                        if hovered ~= nil then
                            setHovered(hovered, true)
                            dispatch(hovered, "pointerEnter", x, y, 0, 0, 0, "pointer", false)
                        end
                    end

                    if not canRead then
                        return
                    end
                    if input:mousePressed("left", install.layer) then
                        install.captured = hovered
                        if hovered ~= nil then
                            setPressed(hovered, true)
                            local interaction = world:get(hovered, Interaction)
                            if interaction ~= nil and interaction.focusable then
                                focus(hovered, "pointer", x, y)
                            end
                            dispatch(hovered, "pointerDown", x, y, 1, 0, 0, "pointer", true)
                        else
                            focus(nil, "pointer", x, y)
                        end
                    end
                    if input:mouseReleased("left", install.layer) then
                        local captured = install.captured
                        install.captured = nil
                        if captured ~= nil and world:get(captured, InteractionState) ~= nil then
                            setPressed(captured, false)
                            dispatch(captured, "pointerUp", x, y, 1, 0, 0, "pointer", true)
                            if captured == hovered then
                                local clicked = dispatch(captured, "click", x, y, 1, 0, 0, "pointer", true)
                                if not clicked.consumed then
                                    dispatch(captured, "activate", x, y, 1, 0, 0, "pointer", true)
                                end
                            end
                        end
                    end

                    if input.wheelX ~= 0 or input.wheelY ~= 0 then
                        local target = targetAt(install.scrollHits, install.scrollHitCount, x, y, true)
                        if target ~= nil then
                            local wheel = dispatch(
                                target, "wheel", x, y, 0, input.wheelX, input.wheelY, "pointer", true
                            )
                            if not wheel.consumed then
                                local scroll = world:get(target, Scroll)
                                local layout = world:get(target, Layout)
                                if scroll ~= nil and layout ~= nil then
                                    local maxX = math.max(0, scroll.contentWidth - layout.width)
                                    local maxY = math.max(0, scroll.contentHeight - layout.height)
                                    local nextX = math.max(
                                        0, math.min(maxX, scroll.x - input.wheelX * install.wheelStep)
                                    )
                                    local nextY = math.max(
                                        0, math.min(maxY, scroll.y - input.wheelY * install.wheelStep)
                                    )
                                    if nextX ~= scroll.x or nextY ~= scroll.y then
                                        local changed = world:getMut(target, Scroll)
                                        changed.x, changed.y = nextX, nextY
                                    end
                                end
                            end
                        end
                    end

                    if input:keyPressed("tab", install.layer) then
                        moveFocus(input:modifierDown("shift", install.layer))
                    end
                    if
                        install.focused ~= nil
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
