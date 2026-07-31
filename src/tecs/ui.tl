--[=[
Retained, Taffy-backed UI layout for ordinary Tecs entities.

[`Style`](tealdoc:tecs.ui.Style) describes layout only. It does not replace a
rectangle, circle, sprite, image, or text component. Put an existing drawing
component on the same entity, or on a child, and add `Paint(true)` when its
transform should stretch to the Taffy box. Drawing remains in the existing
instanced producers and shaders.

The plugin retains one Rust Taffy tree keyed by ECS entity ID. `ChildOf` is the
layout hierarchy as well as the transform hierarchy. The layout system writes
`Layout` only when the box changes and writes `RelativeTransform` only when
layout or scrolling changes its result.

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

```teal
local ui <const> = tecs.ui
local ChildOf <const> = tecs.ecs.ChildOf
local RelativeTransform <const> = tecs.ecs.RelativeTransform

world:addPlugin(ui.plugin({ renderer = app.renderer }))

local root <const> = world:spawn(
    ui.Style({ width = 1280, height = 720 }),
    ui.Root("screen", 1280, 720, app.window:pixelDensity())
)
local viewport <const> = world:spawn(
    ui.Style({ width = 320, height = 240, padding = 8 }),
    ui.Scroll(),
    RelativeTransform(),
    ChildOf(root)
)

world:spawn(
    ui.Style({ width = 300, height = 600 }),
    RelativeTransform(),
    ChildOf(viewport)
)
```
]=]

local ecs <const> = require("tecs.ecs")
local type types = require("tecs.types")
local rust <const> = require("tecs.ffi.rust")
local type loader = require("tecs.ffi.loader")
local components <const> = require("tecs.components")
local ffi <const> = require("ffi")

local type Component = ecs.Component
local type World = types.World
local type Renderer = require("tecs.Renderer")

local C <const> = rust.C
local Transform <const> = ecs.Transform
local RelativeTransform <const> = ecs.RelativeTransform
local ChildOf <const> = ecs.ChildOf
local Clip <const> = components.Clip

--- `Style` stores the Taffy properties that place one UI entity.
local record Style is Component
    --- Caller-writable. The caller supplies a table and marks `Style` dirty
    --- after mutating it. Numeric dimensions use logical points. A
    --- `{value=number, unit="percent"}` table uses a parent-relative
    --- percentage; `{unit="points"}` is the explicit form of a number.
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
    --- Caller-writable. The caller supplies the Taffy root width and the
    --- camera projection width in logical units.
    width: number
    --- Caller-writable. The caller supplies the Taffy root height and the
    --- camera projection height in logical units.
    height: number
    --- Caller-writable. The caller supplies target pixels per logical point
    --- for a screen root. The default is one.
    pixelDensity: number
end
--- `Layout` reports the last box computed by Taffy.
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
end
--- `Options` configures one world's retained UI service.
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
    __call = function(instance: Style, style?: {string: any})
        instance.style = style or {}
    end,
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
    fields = {{"x", "float"}, {"y", "float"}},
    defaults = {0, 0},
    requires = {Style},
})

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
    clipChain: {integer}
    firstClip: integer
    lastClip: integer
end

local function unit(value: any, output: any)
    local target = output as {string: any}
    if type(value) == "number" then
        target.value, target.unit = value, 1
    elseif type(value) == "table" then
        target.value = (value as {string: any}).value or 0
        target.unit = (value as {string: any}).unit == "percent" and 2 or ((value as {string: any}).unit == "points" and 1 or 0)
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
    out.display = value.display == "none" and 1 or (value.display == "grid" and 2 or (value.display == "block" and 3 or 0))
    out.position = value.position == "absolute" and 1 or 0
    out.flex_direction = value.flexDirection == "rowReverse" and 1 or (value.flexDirection == "column" and 2 or (value.flexDirection == "columnReverse" and 3 or 0))
    out.flex_wrap = value.flexWrap == "wrap" and 1 or 0
    out.justify_content = value.justifyContent == "center" and 1 or (value.justifyContent == "end" and 2 or (value.justifyContent == "spaceBetween" and 3 or (value.justifyContent == "spaceAround" and 4 or (value.justifyContent == "spaceEvenly" and 5 or 0))))
    out.align_items = value.alignItems == "center" and 1 or (value.alignItems == "end" and 2 or (value.alignItems == "baseline" and 3 or 0))
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
    if install.live[id] then install.children[#install.children + 1] = id end
end

local function syncChildren(world: World, install: Install, entity: integer)
    local children = install.children
    for index = #children, 1, -1 do children[index] = nil end
    world:targets(entity, ChildOf, collectChild, install)
    table.sort(children)
    local key = table.concat(children, ":")
    if install.childKeys[entity] == key then return end
    install.childKeys[entity] = key
    local ids = ffi.new("uint64_t[?]", #children) as loader.CArray
    for index = 1, #children do ids[index - 1] = children[index] end
    if not (C.tecsUiTreeSetChildren(install.tree, entity, ids, #children) as boolean) then
        error("tecs: UI child synchronization failed: " .. loader.toString(C.tecsRustError()), 2)
    end
end

local record ui
    --- Read-only. Exposes the tag that marks an entity as participating in UI
    --- layout. `Style`, `Root`, and `Scroll` add it automatically.
    Node: Component
    --- Read-only. Exposes the component that supplies Taffy layout properties
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
    --- `Options` configures the renderer and owned clip-index range.
    type Options = Options

    --- Returns a plugin that retains Taffy nodes and derives layout, transforms,
    --- scrolling, and clip indices.
    ---
    --- The plugin owns every renderer clip index from `firstClip` through
    --- `lastClip`, inclusive. Reserve a smaller range when another system also
    --- calls `Renderer:setClipRegion`. Exhausting the range raises rather than
    --- drawing unclipped content.
    ---
    --- @param options The caller supplies a renderer and may reserve an
    ---     inclusive clip range within 1 through 255.
    --- @return Returns a plugin for `world:addPlugin`. Each world receives a
    ---     separate retained tree and clip allocator.
    plugin: function(Options): function(World)
end

ui.Node = NodeComponent
ui.Style, ui.Root, ui.Layout, ui.Paint, ui.Scroll = Style, Root, Layout, Paint, Scroll

function ui.plugin(options: Options): function(World)
    if options == nil or options.renderer == nil then
        error("tecs: the UI plugin needs a `renderer`", 2)
    end
    local firstClip = options.firstClip or 1
    local lastClip = options.lastClip or 255
    if firstClip < 1 or lastClip > 255 or firstClip > lastClip then
        error("tecs: UI clip range must be within 1 through 255", 2)
    end
    local renderer <const> = options.renderer
    return function(world: World)
    local tree = C.tecsUiTreeCreate()
    if tree == nil then error("tecs: cannot create UI tree: " .. loader.toString(C.tecsRustError()), 2) end
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
        clipChain = {},
        firstClip = firstClip,
        lastClip = lastClip,
    }
    local nodes = world:newQuery({name = "tecs.UiLayout", include = {NodeComponent, Style, Layout}})
    local roots = world:newQuery({name = "tecs.UiRoots", include = {NodeComponent, Root}})
    world:addSystem({
        name = "tecs.UiLayout",
        phase = ecs.phases.PostUpdate,
        before = {"RelativeTransform"},
        run = function()
            local hierarchyDirty = false
            for entity in pairs(install.live) do install.live[entity] = nil end
            for archetype, length, entities in nodes:iter() do
                local styles = archetype:get(Style)
                local styleDirty = archetype:isComponentDirty(Style)
                hierarchyDirty = hierarchyDirty or styleDirty or archetype:isComponentDirty(ChildOf)
                for row = 1, length do
                    local entity = entities[row]
                    install.live[entity] = true
                    local style = styles[row].style
                    if not install.known[entity] then
                        if not (C.tecsUiTreeInsert(install.tree, entity, nativeStyle(style)) as boolean) then error("tecs: UI node creation failed: " .. loader.toString(C.tecsRustError()), 2) end
                        install.known[entity] = true
                        hierarchyDirty = true
                    elseif styleDirty and not (C.tecsUiTreeSetStyle(install.tree, entity, nativeStyle(style)) as boolean) then
                        error("tecs: UI style synchronization failed: " .. loader.toString(C.tecsRustError()), 2)
                    end
                end
            end
            local removed = install.removed
            for index = #removed, 1, -1 do removed[index] = nil end
            for entity in pairs(install.known) do
                if not install.live[entity] then removed[#removed + 1] = entity end
            end
            for index = 1, #removed do
                local entity = removed[index]
                if not (C.tecsUiTreeRemove(install.tree, entity) as boolean) then
                    error("tecs: UI node removal failed: " .. loader.toString(C.tecsRustError()), 2)
                end
                install.known[entity] = nil
                install.childKeys[entity] = nil
                hierarchyDirty = true
            end
            if hierarchyDirty then
                for _archetype, length, entities in nodes:iter() do
                    for row = 1, length do syncChildren(world, install, entities[row]) end
                end
            end
            if not (C.tecsUiTreeBegin(install.tree) as boolean) then
                error("tecs: UI layout reset failed: " .. loader.toString(C.tecsRustError()), 2)
            end
            for archetype, length, entities in roots:iter() do
                local rootColumn = archetype:get(Root)
                for row = 1, length do
                    local root = rootColumn[row]
                    if root.width > 0 and root.height > 0 and not (C.tecsUiTreeCompute(install.tree, entities[row], root.width, root.height) as boolean) then
                        error("tecs: UI layout failed: " .. loader.toString(C.tecsRustError()), 2)
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
                        if current.x ~= x or current.y ~= y or current.width ~= width or current.height ~= height then
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
                            local scaleX = paint ~= nil and paint.stretch and width or relative.scaleX
                            local scaleY = paint ~= nil and paint.stretch and height or relative.scaleY
                            if relative.x ~= relativeX or relative.y ~= relativeY
                                or relative.scaleX ~= scaleX or relative.scaleY ~= scaleY then
                                relative = world:getMut(entity, RelativeTransform)
                                relative.x, relative.y = relativeX, relativeY
                                relative.scaleX, relative.scaleY = scaleX, scaleY
                            end
                        end
                    end
                end
            end
        end,
    })
    local function regionFor(entity: integer): number
        local root: Root | nil = nil
        local chain = install.clipChain
        for index = #chain, 1, -1 do chain[index] = nil end
        local current: integer | nil = entity
        while current ~= nil do
            local candidate = world:get(current, Root)
            if candidate ~= nil then root = candidate end
            if world:get(current, Scroll) ~= nil then
                chain[#chain + 1] = current
            end
            local parent = world:getFirstRelationship(current, ChildOf)
            current = parent ~= nil and parent.target or nil
        end
        if #chain == 0 then return 0 end
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
                if left > minX then minX = left end
                if top > minY then minY = top end
                if right < maxX then maxX = right end
                if bottom < maxY then maxY = bottom end
            end
        end
        if not clipped then return 0 end
        if maxX < minX then maxX = minX end
        if maxY < minY then maxY = minY end
        local key = table.concat(chain, ":")
        local rectKey = ("%.3f:%.3f:%.3f:%.3f"):format(minX, minY, maxX, maxY)
        install.clipUsed[key] = true
        local index = install.clipByKey[key]
        if index == nil then
            for candidate = install.firstClip, install.lastClip do
                if install.keyByClip[candidate] == nil then index = candidate break end
            end
            if index == nil then error("tecs: UI clip range is exhausted", 2) end
            install.clipByKey[key] = index
            install.keyByClip[index] = key
        end
        if install.clipRectByKey[key] ~= rectKey then
            renderer:setClipRegion(index, {x = minX, y = minY, width = maxX - minX, height = maxY - minY})
            install.clipRectByKey[key] = rectKey
        end
        return index
    end
    world:addSystem({
        name = "tecs.UiClip",
        phase = ecs.phases.PostUpdate,
        after = {"RelativeTransform", "tecs.UiLayout"},
        before = {"tecs.TextLayout"},
        run = function()
            for key in pairs(install.clipUsed) do install.clipUsed[key] = nil end
            for archetype, length, entities in nodes:iter() do
                local clips = archetype:get(Clip)
                for row = 1, length do
                    local index = regionFor(entities[row])
                    if clips[row].index ~= index then world:getMut(entities[row], Clip).index = index end
                end
            end
            for index, key in pairs(install.keyByClip) do
                if not install.clipUsed[key] then
                    renderer:clearClipRegion(index)
                    install.keyByClip[index] = nil
                    install.clipByKey[key] = nil
                    install.clipRectByKey[key] = nil
                end
            end
        end,
    })
    end
end

return ui
