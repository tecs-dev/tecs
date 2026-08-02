--[=[
Shaped text as entities in the rendered world.

A `Text` names a font and string. `Transform2D` places its top-left corner,
`Tint` colors every glyph, and `Clip` clips it like any other drawable.

```teal
world:addPlugin(tecs.gfx.textPlugin({
    renderer = app.renderer,
}))

world:spawn(
    tecs.Transform2D(24, 24),
    tecs.gfx.Tint(0.92, 0.96, 1.0, 1.0),
    tecs.gfx.Text.new({
        text = "tecs\n1200 entities",
        font = tecs.gfx.newTTF({
            source = "fonts/JetBrainsMono-ExtraBold.ttf",
        }),
        size = 28,
        align = "center",
    })
)
```

Write text fields through `world:getMut`. A direct `world:get` write leaves the
column clean and the displayed glyphs unchanged.

## Fonts and layout

`newTTF` reads source font bytes off the main thread and returns the opened
font. It transparently suspends when called by a system. SDL_ttf and HarfBuzz
shape and lay out UTF-8.
Tecs asks SDL_ttf for glyph images lazily, caches each glyph once per renderer,
and keeps its own one-instance-per-glyph producer.

The default `"sdf"` raster scales without regenerating glyphs. Choose a loaded
size near the largest ordinary on-screen size. A fixed-size UI may instead load
an `"alpha"` raster at exactly its displayed size. Alpha glyphs retain the font
rasterizer's small-size fitting and automatically snap their origin on a
screen-space layer when they are unrotated and unscaled.

Text supports explicit newlines and left, center, or right alignment. It does
not wrap to a width, anchor outside the top-left corner, or style individual
glyphs. The `glyph` material draws text unlit through the forward-blended lane
so its distance-field edge retains partial coverage.
]=]
-- Implementation details:
-- Glyphs are renderer instances rather than entities. Each text owns a span in
-- a size-bucketed producer, so changing one string dirties only that span.
-- Exact-size free lists reuse spans and may fragment when strings change
-- length.
--
-- Layout first skips clean archetypes, then compares each dirty row with the
-- authored fields and composed transform used for its previous glyphs. The
-- producer retains host copies and reports only changed contiguous ranges.

local ecs <const> = require("tecs.ecs")
local type types = require("tecs.types")
local files <const> = require("tecs.io.files")
local loader <const> = require("tecs.ffi.loader")
local assets <const> = require("tecs.assets")
local sdl <const> = require("tecs.ffi.sdl3")
local ttf <const> = require("tecs.ffi.sdl3ttf")
local components <const> = require("tecs.components")
local materials <const> = require("tecs.gpu.materials")
local instancelayout <const> = require("tecs.gpu.instancelayout")
local layersModule <const> = require("tecs.gfx.layers")
local ffi <const> = require("ffi")

local type Renderer = require("tecs.Renderer")
local type TextureArray = require("tecs.gpu.TextureArray")

local type Component = ecs.Component
local type World = types.World

local Transform2D <const> = ecs.Transform2D
local Tint <const> = components.Tint
local Clip <const> = components.Clip

local type TransformInstance = ecs.Transform2D
local type TintInstance = components.Tint

local abs <const> = math.abs
local cos <const> = math.cos
local sin <const> = math.sin

--- Material the glyph quads select, resolved by name because the numbering
--- depends on which material files exist.
local SDF_MATERIAL <const> = "glyph"
local ALPHA_MATERIAL <const> = "glyphalpha"

local C <const> = sdl.C
local TTF <const> = ttf.C
--- SDL_PIXELFORMAT_RGBA32, whose macro resolves to ABGR8888 on little-endian
--- targets. The generated constants table carries literal macros only.
local RGBA32 <const> = 0x16762004

local INSTANCE_FLOATS <const> = instancelayout.FLOATS
local INSTANCE_BYTES <const> = instancelayout.BYTES
local BOUND_FLOATS <const> = instancelayout.BOUND_FLOATS
local BOUND_BYTES <const> = instancelayout.BOUND_BYTES
local UNBOUNDED <const> = instancelayout.UNBOUNDED
local HIDDEN <const> = instancelayout.HIDDEN
local packSlot <const> = instancelayout.packSlot
local BLENDED_X <const>, BLENDED_Y <const> = instancelayout.signsOf("blended")

--- Glyph slots the producer's arrays start at, and the floor every growth
--- doubles from.
local MINIMUM_SLOTS <const> = 64

--- Selects how SDL_ttf rasterizes a font's glyph images.
local enum FontRaster
    --- Read-only. Stores a scalable signed distance field.
    "sdf"
    --- Read-only. Stores direct antialiased coverage at the loaded size.
    "alpha"
end

--- Represents a shaped TrueType or OpenType font.
---
--- A font is immutable after `newTTF` returns. Its source bytes remain
--- resident because SDL_ttf reads them lazily for the font's lifetime.
local record Font
    --- Read-only. Reports the caller-selected identity that snapshots store.
    name: string
    --- Read-only. Reports the source path passed to `newTTF`.
    source: string
    --- Read-only. Reports the point size at which SDL_ttf rasterizes glyphs.
    size: number
    --- Read-only. Reports whether glyph images contain a scalable distance
    --- field or direct alpha coverage.
    raster: FontRaster
    --- Engine-owned. Keeps the source allocation reachable. Ordinary game
    --- code should ignore this field.
    _bytes: string
    --- Engine-owned. Stores the `TTF_Font`. Ordinary game code should ignore
    --- this field.
    _font: loader.CPtr
end

--- Stores one glyph after it enters a renderer's texture array.
local record Glyph
    region: TextureArray.Region
    material: integer
end

--- Lays a string out into glyph instances.
---
--- The entity's Transform2D places the top-left corner of the text block and
--- orients and scales the whole block, and its Tint, if it has one, colors
--- every glyph. Both are ordinary components on an ordinary entity, so a text
--- moves, parents, tweens, and layers like anything else, and a `Clip`
--- keeps its glyphs inside a rectangle exactly as it would any other quad.
---
--- Write through `world:getMut(entity, Text)`. A write through `world:get`
--- leaves the column clean and the glyphs stale.
local record Text is Component
    --- Caller-writable. Sets the laid-out string. A newline starts a line and
    --- `wrapWidth` may introduce additional line breaks.
    text: string
    --- Caller-writable. Selects the font that supplies the glyphs. Without one,
    --- the text draws nothing.
    font: Font
    --- Caller-writable. Sets the em size in world units.
    size: number
    --- Caller-writable. Selects `"left"`, `"center"`, or `"right"` alignment
    --- within the block's widest line.
    align: string
    --- Caller-writable. Sets the maximum line width in world units. Zero
    --- disables wrapping. Retained UI writes this field for a wrapping
    --- intrinsic text leaf after Taffy chooses its available width.
    wrapWidth: number

    --- Engine-owned. Reports the width of the last layout in world units.
    --- Assigning it has no effect.
    width: number
    --- Engine-owned. Reports the height of the last layout in world units.
    --- Assigning it has no effect.
    height: number

    --- Engine-owned. Stores the first producer slot owned by this text.
    --- Ordinary game code should ignore this field.
    _span: integer
    --- Engine-owned. Stores how many producer slots this text owns. Ordinary
    --- game code should ignore this field.
    _spanCount: integer

    --- Engine-owned. Stores the last laid-out string. Ordinary game code
    --- should ignore this field.
    _builtText: string
    --- Engine-owned. Stores the last laid-out font. Ordinary game code should
    --- ignore this field.
    _builtFont: Font
    --- Engine-owned. Stores the last laid-out em size. Ordinary game code
    --- should ignore this field.
    _builtSize: number
    --- Engine-owned. Stores the last laid-out alignment. Ordinary game code
    --- should ignore this field.
    _builtAlign: string
    --- Engine-owned. Stores the last laid-out wrapping width. Ordinary game
    --- code should ignore this field.
    _builtWrapWidth: number
    --- Engine-owned. Stores SDL_ttf's reusable shaped text. Ordinary game
    --- code should ignore this field.
    _native: loader.CPtr
    --- Engine-owned. Stores the font used by `_native`. Ordinary game code
    --- should ignore this field.
    _nativeFont: Font
    --- Engine-owned. Stores the string used by `_native`. Ordinary game code
    --- should ignore this field.
    _nativeText: string
    --- Engine-owned. Stores the native wrapping width in source-font pixels.
    --- Ordinary game code should ignore this field.
    _nativeWrapWidth: integer
    --- Engine-owned. Stores the last laid-out red channel. Ordinary game code
    --- should ignore this field.
    _builtR: number
    --- Engine-owned. Stores the last laid-out green channel. Ordinary game
    --- code should ignore this field.
    _builtG: number
    --- Engine-owned. Stores the last laid-out blue channel. Ordinary game code
    --- should ignore this field.
    _builtB: number
    --- Engine-owned. Stores the last laid-out alpha channel. Ordinary game
    --- code should ignore this field.
    _builtA: number
    --- Engine-owned. Stores the last laid-out horizontal position. Ordinary
    --- game code should ignore this field.
    _builtX: number
    --- Engine-owned. Stores the last laid-out vertical position. Ordinary game
    --- code should ignore this field.
    _builtY: number
    --- Engine-owned. Stores the last laid-out depth. Ordinary game code should
    --- ignore this field.
    _builtZ: number
    --- Engine-owned. Stores the last laid-out layer. Ordinary game code should
    --- ignore this field.
    _builtLayer: integer
    --- Engine-owned. Stores the last laid-out rotation. Ordinary game code
    --- should ignore this field.
    _builtRotation: number
    --- Engine-owned. Stores the last laid-out horizontal scale. Ordinary game
    --- code should ignore this field.
    _builtScaleX: number
    --- Engine-owned. Stores the last laid-out vertical scale. Ordinary game
    --- code should ignore this field.
    _builtScaleY: number
    --- Engine-owned. Stores the last laid-out clip index. Ordinary game code
    --- should ignore this field.
    _builtClip: integer
end

--- Configures a source font loaded by SDL_ttf.
local record TTFOptions
    --- Caller-writable. Sets a TrueType or OpenType path. Relative paths are
    --- resolved against the asset root.
    source: string
    --- Caller-writable. Sets the snapshot identity. It defaults to `source`.
    name: string
    --- Caller-writable. Sets the glyph raster point size. It defaults to 48.
    size: number
    --- Caller-writable. Selects `"sdf"` for scalable text or `"alpha"` for
    --- crisp text drawn at the loaded size. It defaults to `"sdf"`.
    raster: FontRaster
end

--- Configures the text layout plugin.
local record TextOptions
    --- Caller-writable. Selects the renderer that receives glyph images and
    --- instances.
    renderer: Renderer
end

local record text
    --- Represents a loaded font named by `Text`.
    type Font = Font
    --- Selects a font's glyph raster representation.
    type FontRaster = FontRaster
    --- Configures `newTTF`.
    type TTFOptions = TTFOptions
    --- Configures `textPlugin`.
    type TextOptions = TextOptions

    --- Read-only. Exposes the text component.
    Text: Text

    --- Loads and opens a source font with SDL_ttf.
    ---
    --- The file read happens on the asset worker. The call suspends its system
    --- until SDL_ttf has opened the bytes, selected the raster mode, and
    --- verified the requested point size.
    --- @param options The caller must set `source`. `name` defaults to that
    ---     path, `size` defaults to 48 points, and `raster` defaults to
    ---     `"sdf"`.
    --- @return Returns an immutable [`Font`](tealdoc:tecs.gfx.text.Font).
    newTTF: function(options: TTFOptions): Font
    --- Returns a text item's width and height in world units.
    ---
    --- Uses the same layout as the plugin without adding or changing an
    --- entity.
    --- @param item A [`Text`](tealdoc:tecs.gfx.text.Text) value to read. It need
    ---     not belong to an entity.
    --- @param wrapWidth The caller may override `item.wrapWidth` for this
    ---     measurement without changing the retained authored value.
    --- @return Width at `item.size`, before
    ---     [`Transform2D`](/modules/ecs/#tecs.ecs.Transform2D) scale. Returns zero for a missing
    ---     item, font, or string.
    --- @return Height on the same terms, counting complete line boxes.
    measureText: function(item: Text, wrapWidth?: number): number, number
    --- Returns the preferred and minimum-content metrics for a text item.
    ---
    --- The minimum-content width is the widest whitespace-delimited run. The
    --- function shapes only while called and does not change authored fields.
    --- Retained UI calls it only when the text or its intrinsic settings are
    --- dirty.
    --- @param item A [`Text`](tealdoc:tecs.gfx.text.Text) value with a font.
    --- @return Preferred width with wrapping disabled.
    --- @return Preferred height with wrapping disabled.
    --- @return Minimum-content width of the widest unbroken run.
    measureIntrinsic: function(item: Text): number, number, number
    --- Creates the plugin that lays out text for a renderer.
    --- @param options Requires `renderer`.
    --- @return A world plugin. Each world gets its own producer run while
    ---     sharing process-wide fonts.
    textPlugin: function(options: TextOptions): function(World)
    --- Returns how many texts the world has laid out.
    --- @param world A world with or without the text plugin.
    --- @return A count that only increases, or zero before plugin installation.
    ---     The count measures rows laid out rather than frames.
    textLayouts: function(world: World): integer
    --- Returns a glyph's world x, y, width, and height.
    ---
    --- Reads the instance produced for rendering, so it reports the drawn
    --- placement.
    --- @param world The world that contains the text entity.
    --- @param entity An entity carrying [`Text`](tealdoc:tecs.gfx.text.Text).
    --- @param index A one-based produced-glyph index. Layout operations with
    ---     no drawable rectangle, including spaces and newlines, take no index.
    --- @return World x of the glyph center, or nil when no glyph exists.
    --- @return World y of the glyph center, or nil with the first return.
    --- @return Glyph width in world units, or nil with the first return.
    --- @return Glyph height in world units, or nil with the first return.
    glyphAt: function(world: World, entity: integer, index: integer): number, number, number, number
end

-------------------------------------------------------------------------------
-- Fonts
-------------------------------------------------------------------------------

--- Every loaded font by snapshot identity. A later font with the same name is
--- the one a snapshot restores, while existing Text values keep their font.
local fontsByName <const>: {string: Font} = {}

--- Resolves a path against the asset root unless it already names one.
local function resolve(path: string): string
    if path:sub(1, 1) == "/" then
        return path
    end
    return files.assetPath(path)
end

--- Opens bytes only after the worker has delivered the complete source.
local function openFont(bytes: string, options: TTFOptions): Font
    if not ttf.init() then
        sdl.fail("TTF_Init")
    end

    local stream = C.SDL_IOFromConstMem(bytes, #bytes)
    if stream == nil then
        sdl.fail("SDL_IOFromConstMem")
    end
    local handle = TTF.TTF_OpenFontIO(stream, true, options.size)
    if handle == nil then
        -- TTF_OpenFontIO owns the stream when closeio is true, including on a
        -- failed open.
        sdl.fail("TTF_OpenFontIO")
    end
    handle = ffi.gc(handle as ffi.CData, TTF.TTF_CloseFont as function(ffi.CData)) as loader.CPtr

    if not TTF.TTF_SetFontSDF(handle, options.raster == "sdf") then
        ffi.gc(handle as ffi.CData, nil)
        TTF.TTF_CloseFont(handle)
        sdl.fail("TTF_SetFontSDF")
    end

    local font <const>: Font = {
        name = options.name,
        source = options.source,
        size = options.size,
        raster = options.raster,
        _bytes = bytes,
        _font = handle,
    }
    fontsByName[font.name] = font
    return font
end

function text.newTTF(options: TTFOptions): Font
    if options == nil or options.source == nil or options.source == "" then
        error("tecs: a TTF font needs a `source` path", 2)
    end
    local requested <const>: TTFOptions = {
        source = options.source,
        name = options.name or options.source,
        size = options.size or 48.0,
        raster = options.raster or "sdf",
    }
    if requested.size <= 0.0 then
        error("tecs: a TTF font `size` must be greater than zero", 2)
    end
    if requested.raster ~= "sdf" and requested.raster ~= "alpha" then
        error("tecs: a TTF font `raster` must be 'sdf' or 'alpha'", 2)
    end

    if not assets.installed() then
        assets.install()
    end
    return openFont(assets.loadString(resolve(requested.source), "font"), requested)
end

-------------------------------------------------------------------------------
-- The producer
-------------------------------------------------------------------------------

--- Every text's glyph instances in one world, as one run of the renderer's
--- instance buffer.
---
--- Holds its own copy of what it produces. A text writes glyphs here whenever
--- it changes and the renderer copies the ranges that moved, so a layout costs
--- what the text costs rather than what the frame's timing decides.
local record Glyphs
    --- Instance floats, sixteen per slot, and cull bounds, four per slot.
    instances: loader.CArray
    bounds: loader.CArray
    --- Byte views of both, so a copy can be offset into them exactly.
    _instanceBytes: loader.BytePointer
    _boundBytes: loader.BytePointer
    --- Slots the arrays hold.
    capacity: integer
    --- Slots handed out. The run is this long, and a slot above it is not
    --- drawn because it is not in the run.
    high: integer
    --- Freed spans, keyed by their length. A text takes an exact-size span
    --- back off this before the mark is extended, which is what lets short
    --- strings appearing and disappearing keep the run's length still.
    ---
    --- Fragmentation is the tradeoff: a span freed at one length is only ever
    --- reclaimed at that length, so a scene whose string lengths keep changing
    --- leaves holes. Compaction is the answer if a measurement shows it
    --- mattering; there is none here until one does.
    _free: {integer: {integer}}
    --- The text holding each span, by entity, and how many entries that is.
    --- A span is reachable from its `Text` and from nowhere else, so this is
    --- what lets a text that lost its component be noticed at all.
    _owners: {integer: Text}
    _ownerCount: integer
    --- The two counts the last sweep compared, so a scene that is merely
    --- holding spans a query cannot see is swept once rather than every frame.
    _sweptOwners: integer
    _sweptLive: integer
    --- Sub-ranges written since the last sync, as flat one-based inclusive
    --- pairs, and how many entries are in use.
    _dirty: {integer}
    _dirtyCount: integer
    --- Whether the last sync took those ranges. They are dropped at the first
    --- write after that rather than on the way out, so the table handed over
    --- stays valid while the renderer is reading it.
    _taken: boolean
    --- Releases resources retained by the install that owns this producer.
    destroy: function(self: Glyphs)
end

local GlyphsMT <const>: metatable<Glyphs> = {__index = Glyphs}

--- Grows the arrays to hold at least `slots`, preserving what is in them.
local function reserveCapacity(self: Glyphs, slots: integer)
    if slots <= self.capacity then
        return
    end

    local capacity = self.capacity
    if capacity < MINIMUM_SLOTS then
        capacity = MINIMUM_SLOTS
    end
    while capacity < slots do
        capacity = capacity * 2
    end

    local instances = loader.newArray("float[?]", capacity * INSTANCE_FLOATS)
    local bounds = loader.newArray("float[?]", capacity * BOUND_FLOATS)
    if self.high > 0 then
        loader.copyBytes(instances, self.instances as loader.CValue, self.high * INSTANCE_BYTES)
        loader.copyBytes(bounds, self.bounds as loader.CValue, self.high * BOUND_BYTES)
    end

    self.instances = instances
    self.bounds = bounds
    self._instanceBytes = loader.bytePointer(instances as loader.CValue)
    self._boundBytes = loader.bytePointer(bounds as loader.CValue)
    self.capacity = capacity
end

local function clearDirty(self: Glyphs)
    local ranges = self._dirty
    for index = self._dirtyCount, 1, -1 do
        ranges[index] = nil
    end
    self._dirtyCount = 0
    self._taken = false
end

--- Drops the ranges the last sync consumed.
local function settle(self: Glyphs)
    if not self._taken then
        return
    end
    clearDirty(self)
end

--- Hands every span back at once.
---
--- For a world replaced wholesale, where the texts that owned the spans are
--- gone without anything having been despawned.
local function reset(self: Glyphs)
    self.high = 0
    local free = self._free
    for size in pairs(free) do
        free[size] = nil
    end
    local owners = self._owners
    for entity in pairs(owners) do
        owners[entity] = nil
    end
    self._ownerCount = 0
    self._sweptOwners = 0
    self._sweptLive = 0
    clearDirty(self)
end

--- Records that slots `first` through `last` were written.
---
--- Coalesces with the range recorded before it when the two touch, which is
--- what keeps a burst of consecutive spans one entry rather than one each.
local function mark(self: Glyphs, first: integer, last: integer)
    settle(self)
    local ranges = self._dirty
    local count = self._dirtyCount
    if count > 0 then
        local previousFirst = ranges[count - 1]
        local previousLast = ranges[count]
        if first >= previousFirst and first <= previousLast + 1 then
            if last > previousLast then
                ranges[count] = last
            end
            return
        end
    end
    ranges[count + 1] = first
    ranges[count + 2] = last
    self._dirtyCount = count + 2
end

--- Puts `count` slots from `first` where no view can see them.
local function hide(self: Glyphs, first: integer, count: integer)
    local instances = self.instances
    local bounds = self.bounds
    for slot = first, first + count - 1 do
        local base = (slot - 1) * INSTANCE_FLOATS
        for offset = 0, INSTANCE_FLOATS - 1 do
            instances[base + offset] = 0.0
        end
        -- Farthest depth the band allows, so nothing that reaches the draw can
        -- occlude what is in front of it.
        instances[base + 3] = 0.999

        local bound = (slot - 1) * BOUND_FLOATS
        bounds[bound] = HIDDEN
        bounds[bound + 1] = HIDDEN
        bounds[bound + 2] = 0.0
        bounds[bound + 3] = 0.0
    end
    mark(self, first, first + count - 1)
end

--- Hands `count` slots back.
---
--- A span at the top of the mark shrinks the mark instead of joining the free
--- list, so the last text on screen going away leaves the run empty rather
--- than leaving a hole the length of it.
local function release(self: Glyphs, first: integer, count: integer)
    if count <= 0 then
        return
    end
    if first + count - 1 == self.high then
        self.high = first - 1
        return
    end

    local bucket = self._free[count]
    if bucket == nil then
        bucket = {}
        self._free[count] = bucket
    end
    bucket[#bucket + 1] = first
    hide(self, first, count)
end

--- Takes `count` slots, from the free list when it has an exact fit.
local function allocate(self: Glyphs, count: integer): integer
    local bucket = self._free[count]
    if bucket ~= nil then
        local top = #bucket
        if top > 0 then
            local first = bucket[top]
            bucket[top] = nil
            return first
        end
    end

    local first = self.high + 1
    reserveCapacity(self, self.high + count)
    self.high = self.high + count
    return first
end

--- Gives `item` a span of exactly `count` slots.
---
--- A text whose glyph count did not change keeps the span it has, which is the
--- case that costs nothing. A shorter string keeps its span's front and hands
--- the difference back, and a longer one extends the mark when it is already
--- at the top of it and takes a fresh span otherwise.
local function reserve(self: Glyphs, item: Text, count: integer)
    local first = item._span
    local held = item._spanCount
    if count == held then
        return
    end

    if held == 0 then
        item._span = allocate(self, count)
        item._spanCount = count
        return
    end

    if count == 0 then
        release(self, first, held)
        item._span = 0
        item._spanCount = 0
        return
    end

    if count < held then
        release(self, first + count, held - count)
        item._spanCount = count
        return
    end

    if first + held - 1 == self.high then
        reserveCapacity(self, first + count - 1)
        self.high = first + count - 1
        item._spanCount = count
        return
    end

    release(self, first, held)
    item._span = allocate(self, count)
    item._spanCount = count
end

--- Drops the record of `entity` holding a span.
local function disown(self: Glyphs, entity: integer)
    if self._owners[entity] == nil then
        return
    end
    self._owners[entity] = nil
    self._ownerCount = self._ownerCount - 1
end

--- Records that `entity`'s text holds the span it was just given.
---
--- A text that lost its component and was given another one arrives here as a
--- different table under the same entity, and the span the first one held is
--- reachable through nothing else, so it goes back before the record moves.
local function own(self: Glyphs, entity: integer, item: Text)
    local owners = self._owners
    local held = owners[entity]
    if held ~= nil and held ~= item then
        reserve(self, held, 0)
    end

    if item._spanCount == 0 then
        disown(self, entity)
        return
    end
    if held == nil then
        self._ownerCount = self._ownerCount + 1
    end
    owners[entity] = item
end

--- Hands back every span whose text is gone.
---
--- Despawning is observed and removing a component is not, so a text that lost
--- its `Text` leaves a span allocated with nothing pointing at it: the slots
--- never rejoin the free list and the high-water mark never comes back down.
--- Walking the owners is what finds those, and identity is what it compares,
--- so a component replaced rather than removed is caught too.
local function sweepOwners(self: Glyphs, world: World)
    local owners = self._owners
    for entity, item in pairs(owners) do
        if world:get(entity, text.Text) ~= item then
            reserve(self, item, 0)
            owners[entity] = nil
            self._ownerCount = self._ownerCount - 1
        end
    end
end

--- Slots the run reserves, which is the high-water mark rather than the number
--- of slots in use: a freed span keeps its place so the run's length stops
--- moving once the scene settles.
function Glyphs:count(): integer
    return self.high
end

function Glyphs:takeDirty(): {integer}
    settle(self)
    self._taken = true
    return self._dirty
end

--- Every resident slot may reach the forward lane. Even a glyph with full tint
--- alpha has partial distance-field coverage at its edge, so the opaque
--- G-buffer would turn that edge into a hard, uneven contour. The high-water
--- mark is the safe upper bound expected by a producer.
function Glyphs:blended(): integer
    return self.high
end

--- Text never writes caster lane signs into its bounds.
function Glyphs:casting(): integer
    return 0
end

function Glyphs:write(floats: loader.CArray, bounds: loader.CArray, base: integer, first: integer, last: integer)
    local count = last - first + 1
    if count <= 0 then
        return
    end

    loader.copyTo(
        loader.bytePointer(floats as loader.CValue) + (base + first - 1) * INSTANCE_BYTES,
        (self._instanceBytes + (first - 1) * INSTANCE_BYTES) as loader.CValue,
        count * INSTANCE_BYTES
    )
    loader.copyTo(
        loader.bytePointer(bounds as loader.CValue) + (base + first - 1) * BOUND_BYTES,
        (self._boundBytes + (first - 1) * BOUND_BYTES) as loader.CValue,
        count * BOUND_BYTES
    )
end

local function newGlyphs(): Glyphs
    local self = setmetatable({} as Glyphs, GlyphsMT)
    self.capacity = 0
    self.high = 0
    self._free = {}
    self._owners = {}
    self._ownerCount = 0
    self._sweptOwners = 0
    self._sweptLive = 0
    self._dirty = {}
    self._dirtyCount = 0
    self._taken = false
    reserveCapacity(self, MINIMUM_SLOTS)
    return self
end

-------------------------------------------------------------------------------
-- Layout
-------------------------------------------------------------------------------

--- The laid-out glyphs, four numbers each: center x and y, then width and
--- height, all in loaded-font pixels. Reused across every text.
local placements <const>: {number} = {}
--- Native copy operation index per placement.
local operations <const>: {integer} = {}
--- Global UTF-8 byte offset and top edge per line. SDL_ttf reports copy
--- operation offsets relative to their line, including after explicit
--- newlines, while its line substrings retain the offset into the whole text.
local lineOffset <const>: {integer: integer} = {}
local lineTop <const>: {integer: number} = {}
local lineShift <const>: {integer: number} = {}
local lineRect <const> = loader.newArray("TTF_SubString[1]")

--- How far a line moves within the block, as a fraction of the room left over.
local ALIGNMENTS <const>: {string: number} = {
    left = 0.0,
    center = 0.5,
    right = 1.0,
}

--- Returns whether one shaped operation begins at ASCII whitespace.
---
--- SDL_ttf may emit a drawable copy operation for a space even though the
--- glyph has no ink. Its tiny empty SDF region can sample a neighboring atlas
--- texel, so whitespace advances through native layout but never becomes an
--- instance.
local function whitespaceAt(value: string, offset: integer): boolean
    local byte <const> = value:byte(offset + 1)
    return byte == 32 or (byte ~= nil and byte >= 9 and byte <= 13)
end

--- Creates or updates SDL_ttf's reusable shaped text.
local function updateNative(item: Text): loader.CPtr
    local native = item._native
    local changed = false
    if native == nil or item._nativeFont ~= item.font then
        if native ~= nil then
            ffi.gc(native as ffi.CData, nil)
            TTF.TTF_DestroyText(native)
        end
        native = TTF.TTF_CreateText(nil, item.font._font, item.text, #item.text)
        if native == nil then
            sdl.fail("TTF_CreateText")
        end
        item._native = ffi.gc(native as ffi.CData, TTF.TTF_DestroyText as function(ffi.CData)) as loader.CPtr
        item._nativeFont = item.font
        item._nativeText = item.text
        item._nativeWrapWidth = -1
        changed = true
    elseif item._nativeText ~= item.text then
        if not TTF.TTF_SetTextString(native, item.text, #item.text) then
            sdl.fail("TTF_SetTextString")
        end
        item._nativeText = item.text
        changed = true
    end
    local wrapWidth = 0
    if item.wrapWidth > 0 and item.size > 0 then
        wrapWidth = math.max(1, math.floor(item.wrapWidth / item.size * item.font.size + 0.5))
    end
    if item._nativeWrapWidth ~= wrapWidth then
        if not TTF.TTF_SetTextWrapWidth(native, wrapWidth) then
            sdl.fail("TTF_SetTextWrapWidth")
        end
        item._nativeWrapWidth = wrapWidth
        changed = true
    end
    if changed and not TTF.TTF_UpdateText(item._native) then
        sdl.fail("TTF_UpdateText")
    end
    return item._native
end

--- Reads shaped copy operations into the reusable placement arrays.
local function layout(item: Text): integer, number, number
    local native <const> = updateNative(item) as loader.CStruct
    local internal <const> = native.internal as loader.CStruct
    local scale <const> = item.size / item.font.size

    for line in pairs(lineOffset) do
        lineOffset[line] = nil
    end
    for line in pairs(lineTop) do
        lineTop[line] = nil
    end
    for line in pairs(lineShift) do
        lineShift[line] = nil
    end
    local weight <const> = ALIGNMENTS[item.align] or 0.0
    local lineCount <const> = native.num_lines as integer
    for line = 0, lineCount - 1 do
        if not TTF.TTF_GetTextSubStringForLine(item._native, line, lineRect) then
            sdl.fail("TTF_GetTextSubStringForLine")
        end
        local substring <const> = lineRect[0] as loader.CStruct
        local rect <const> = substring.rect as loader.CStruct
        lineOffset[line] = substring.offset as integer
        lineTop[line] = rect.y as number
        if weight ~= 0.0 then
            lineShift[line] = ((internal.w as number) - (rect.w as number)) * weight - (rect.x as number)
        else
            lineShift[line] = 0.0
        end
    end

    local count = 0
    local line = 0
    local ops <const> = internal.ops as loader.CArray
    for index = 0, (internal.num_ops as integer) - 1 do
        local op <const> = ops[index] as loader.CStruct
        if op.cmd == 2 then
            local copy <const> = op.copy as loader.CStruct
            local dst <const> = copy.dst as loader.CStruct
            local centerY <const> = (dst.y as number) + (dst.h as number) * 0.5
            while line + 1 < lineCount do
                local nextTop <const> = lineTop[line + 1]
                if nextTop == nil or centerY < nextTop then
                    break
                end
                line = line + 1
            end
            local offset <const> = (lineOffset[line] or 0) + (copy.text_offset as integer)
            if not whitespaceAt(item.text, offset) and (dst.w as number) > 0 and (dst.h as number) > 0 then
                local shift <const> = lineShift[line] or 0.0
                local base <const> = count * 4
                count = count + 1
                placements[base + 1] = ((dst.x as number) + (dst.w as number) * 0.5 + shift) * scale
                placements[base + 2] = ((dst.y as number) + (dst.h as number) * 0.5) * scale
                placements[base + 3] = (dst.w as number) * scale
                placements[base + 4] = (dst.h as number) * scale
                operations[count] = index
            end
        end
    end

    return count, (internal.w as number) * scale, (internal.h as number) * scale
end

-- This calls the same layout routine as the plugin, without producing
-- instances or touching an entity.
function text.measureText(item: Text, wrapWidth?: number): number, number
    if item == nil or item.font == nil or item.text == nil then
        return 0.0, 0.0
    end
    local previous = item.wrapWidth
    if wrapWidth ~= nil then
        item.wrapWidth = wrapWidth
    end
    local _, width, height = layout(item)
    if wrapWidth ~= nil then
        item.wrapWidth = previous
    end
    return width, height
end

local intrinsicProbe: Text = {
    text = "",
    size = 16,
    align = "left",
    wrapWidth = 0,
} as Text

function text.measureIntrinsic(item: Text): number, number, number
    if item == nil or item.font == nil or item.text == nil then
        return 0.0, 0.0, 0.0
    end
    local width, height = text.measureText(item, 0)
    local probe = intrinsicProbe
    probe.font, probe.size, probe.align = item.font, item.size, "left"
    probe.wrapWidth = 0
    local minWidth = 0.0
    for run in item.text:gmatch("%S+") do
        probe.text = run
        local runWidth = text.measureText(probe, 0)
        if runWidth > minWidth then
            minWidth = runWidth
        end
    end
    return width, height, minWidth
end

-------------------------------------------------------------------------------
-- The glyph instances
-------------------------------------------------------------------------------

--- Layouts run, by world, for a test or a tool that wants to see the gate
--- working. Weak keys, so a discarded world is not held alive by its count.
local layoutCounts <const>: {World: integer} = setmetatable(
    {} as {World: integer}, {__mode = "k"} as metatable<{World: integer}>
)

--- What the plugin holds for one world and renderer.
local record Install
    glyphs: Glyphs
    --- Cached glyph regions by native font address then glyph index. Fonts are
    --- immutable, so their generation cannot invalidate a cache entry.
    known: {number: {integer: Glyph}}
end

local installs <const>: {World: Install} = setmetatable(
    {} as {World: Install}, {__mode = "k"} as metatable<{World: Install}>
)

-------------------------------------------------------------------------------
-- Resolving glyphs
-------------------------------------------------------------------------------

--- Material ids, resolved on first use: reading material files needs an asset
--- root, and module load is too early to have one.
local materialId = -1
local alphaMaterialId = -1

local function glyphMaterial(): integer
    if materialId < 0 then
        materialId = materials.id(SDF_MATERIAL)
    end
    return materialId
end

local function alphaGlyphMaterial(): integer
    if alphaMaterialId < 0 then
        alphaMaterialId = materials.id(ALPHA_MATERIAL)
    end
    return alphaMaterialId
end

--- Returns one renderer-resident glyph, rasterizing and uploading it once.
local function residency(install: Install, renderer: Renderer, copy: loader.CStruct): Glyph
    local address <const> = tonumber(ffi.cast("uintptr_t", copy.glyph_font)) as number
    local fontGlyphs = install.known[address]
    if fontGlyphs == nil then
        fontGlyphs = {}
        install.known[address] = fontGlyphs
    end

    local index <const> = copy.glyph_index as integer
    local glyph = fontGlyphs[index]
    if glyph ~= nil then
        return glyph
    end

    local material = alphaGlyphMaterial()
    if TTF.TTF_GetFontSDF(copy.glyph_font) then
        material = glyphMaterial()
    end
    local surface = TTF.TTF_GetGlyphImageForIndex(copy.glyph_font, index, nil)
    if surface == nil then
        sdl.fail("TTF_GetGlyphImageForIndex")
    end
    local converted = C.SDL_ConvertSurface(surface, RGBA32)
    if converted == nil then
        sdl.fail("SDL_ConvertSurface")
    end
    local pixels <const> = converted as loader.CStruct
    local region <const> = renderer.sprites.images:addPacked(
        pixels.pixels as loader.CValue, pixels.w as integer, pixels.h as integer, pixels.pitch as integer
    )
    C.SDL_DestroySurface(converted)

    glyph = {region = region, material = material}
    fontGlyphs[index] = glyph
    return glyph
end

-- This diagnostic counter verifies that clean text rows skip layout work.
function text.textLayouts(world: World): integer
    return layoutCounts[world] or 0
end

-- Read from the produced instance rather than recalculating layout so the
-- answer matches what rendering consumes.
function text.glyphAt(world: World, entity: integer, index: integer): number, number, number, number
    local install = installs[world]
    if install == nil then
        return nil
    end
    local glyphs = install.glyphs
    local item = world:get(entity, text.Text)
    if item == nil or index < 1 or index > item._spanCount then
        return nil
    end

    local base = (item._span + index - 2) * INSTANCE_FLOATS
    local instances = glyphs.instances
    local x <const> = instances[base + 4] as number
    local y <const> = instances[base + 5] as number
    local width <const> = instances[base + 1] as number
    local height <const> = instances[base + 2] as number
    return x, y, width, height
end

--- Rewrites one text's glyph instances, or empties them without a font.
---
--- A text with no font remains empty until game code writes one through the
--- component's mutation path.
local function build(
    renderer: Renderer,
    install: Install,
    glyphs: Glyphs,
    item: Text,
    transform: TransformInstance,
    tint: TintInstance,
    clip: integer
)
    local font = item.font
    if font == nil then
        reserve(glyphs, item, 0)
        item.width = 0.0
        item.height = 0.0
        return
    end

    local r, g, b, a = 1.0, 1.0, 1.0, 1.0
    if tint ~= nil then
        r, g, b, a = tint.r, tint.g, tint.b, tint.a
    end

    local count, width, height = layout(item)
    item.width = width
    item.height = height
    reserve(glyphs, item, count)

    local instances <const> = glyphs.instances
    local bounds <const> = glyphs.bounds
    local span <const> = item._span

    -- The text's own transform, composed into every glyph here because a
    -- producer has no entities for a hierarchy to compose.
    local rotation <const> = transform.rotation
    local turnX <const> = cos(rotation)
    local turnY <const> = sin(rotation)
    local blockX <const> = transform.scaleX
    local blockY <const> = transform.scaleY
    local originX = transform.x
    local originY = transform.y
    local z <const> = transform.z
    local layer <const> = transform.layer as integer
    local viewCulled <const> = layersModule.viewCulled(layer)
    if
        font.raster == "alpha"
        and item.size == font.size
        and rotation == 0.0
        and blockX == 1.0
        and blockY == 1.0
        and layersModule.isScreenSpace(layer)
    then
        originX = math.floor(originX + 0.5)
        originY = math.floor(originY + 0.5)
    end
    -- Every glyph sits on the text's own layer, so the band is the block's and
    -- not the glyph's: resolved here and spent per glyph below.
    local bandBase <const>, bandSort <const> = layersModule.bandOf(layer)

    local native <const> = item._native as loader.CStruct
    local ops <const> = (native.internal as loader.CStruct).ops as loader.CArray

    for index = 1, count do
        local copy <const> = (ops[operations[index]] as loader.CStruct).copy as loader.CStruct
        local source <const> = copy.src as loader.CStruct
        local glyph <const> = residency(install, renderer, copy)
        local region <const> = glyph.region
        local place = (index - 1) * 4
        local offsetX = placements[place + 1] * blockX
        local offsetY = placements[place + 2] * blockY
        local x = originX + offsetX * turnX - offsetY * turnY
        local y = originY + offsetX * turnY + offsetY * turnX
        local scaleX = placements[place + 3] * blockX
        local scaleY = placements[place + 4] * blockY

        local u <const> = (region.u1 - region.u0) / region.width
        local v <const> = (region.v1 - region.v0) / region.height
        local u0 <const> = region.u0 + (source.x as number) * u
        local v0 <const> = region.v0 + (source.y as number) * v
        local u1 <const> = u0 + (source.w as number) * u
        local v1 <const> = v0 + (source.h as number) * v
        -- The clip region rides above the texture-array layer in one float.
        local slot <const> = packSlot(clip, region.layer)

        local base = (span + index - 2) * INSTANCE_FLOATS
        instances[base] = rotation
        instances[base + 1] = scaleX
        instances[base + 2] = scaleY
        instances[base + 3] = layersModule.depthIn(bandBase, bandSort, z, x, y)

        instances[base + 4] = x
        instances[base + 5] = y
        instances[base + 6] = slot
        instances[base + 7] = glyph.material

        instances[base + 8] = r
        instances[base + 9] = g
        instances[base + 10] = b
        instances[base + 11] = a

        instances[base + 12] = u0
        instances[base + 13] = v0
        instances[base + 14] = u1
        instances[base + 15] = v1

        -- Extents without a trigonometric call. Unrotated, each axis is its
        -- own scale. Rotated, half the sum of both scales covers every angle,
        -- which is looser than the true extent but never smaller, so the cull
        -- can only ever keep something it might have dropped.
        local ex: number
        local ey: number
        if not viewCulled then
            ex = UNBOUNDED
            ey = UNBOUNDED
        elseif rotation == 0.0 then
            ex = 0.5 * abs(scaleX)
            ey = 0.5 * abs(scaleY)
        else
            ex = 0.5 * (abs(scaleX) + abs(scaleY))
            ey = ex
        end

        local bound = (span + index - 2) * BOUND_FLOATS
        bounds[bound] = x
        bounds[bound + 1] = y
        bounds[bound + 2] = ex * BLENDED_X
        bounds[bound + 3] = ey * BLENDED_Y
    end

    if count > 0 then
        mark(glyphs, span, span + count - 1)
    end

    item._builtText = item.text
    item._builtFont = font
    item._builtSize = item.size
    item._builtAlign = item.align
    item._builtWrapWidth = item.wrapWidth
    item._builtR, item._builtG = r, g
    item._builtB, item._builtA = b, a
    item._builtX, item._builtY, item._builtZ = originX, originY, z
    item._builtLayer = layer
    item._builtRotation = rotation
    item._builtScaleX, item._builtScaleY = blockX, blockY
    item._builtClip = clip
end

--- Whether `item` differs from what its glyphs were built from.
local function stale(item: Text, transform: TransformInstance, tint: TintInstance, clip: integer): boolean
    if item._builtClip ~= clip then
        return true
    end

    if
        item._builtText ~= item.text
        or item._builtFont ~= item.font
        or item._builtSize ~= item.size
        or item._builtAlign ~= item.align
        or item._builtWrapWidth ~= item.wrapWidth
    then
        return true
    end

    -- A glyph carries an absolute position, so the transform the text was laid
    -- out at is part of what its glyphs were built from.
    if
        item._builtX ~= transform.x
        or item._builtY ~= transform.y
        or item._builtZ ~= transform.z
        or item._builtLayer ~= transform.layer
        or item._builtRotation ~= transform.rotation
        or item._builtScaleX ~= transform.scaleX
        or item._builtScaleY ~= transform.scaleY
    then
        return true
    end

    if tint == nil then
        return item._builtR ~= 1.0 or item._builtG ~= 1.0 or item._builtB ~= 1.0 or item._builtA ~= 1.0
    end
    return item._builtR ~= tint.r or item._builtG ~= tint.g or item._builtB ~= tint.b or item._builtA ~= tint.a
end

-- Run after RelativeTransform2D because glyph instances use absolute positions;
-- running before parent composition would consume the previous frame's
-- transform.
function text.textPlugin(options: TextOptions): function(World)
    if options == nil or options.renderer == nil then
        error("tecs: the text plugin needs a `renderer`", 2)
    end
    local renderer <const> = options.renderer

    return function(world: World)
        local texts <const> = world:newQuery({
            name = "tecs.Text",
            include = {text.Text, Transform2D},
        })
        local install <const>: Install = {
            glyphs = newGlyphs(),
            known = {},
        }
        local glyphs <const> = install.glyphs
        glyphs.destroy = function() end

        installs[world] = install
        renderer.sprites:addProducer(glyphs as Renderer.SpriteInstanceProducer)

        world:addSystem({
            name = "tecs.TextLayout",
            phase = ecs.phases.PostUpdate,
            after = {"RelativeTransform2D"},
            run = function()
                local built = 0
                local live = 0
                for archetype, length, entities in texts:iter() do
                    live = live + length
                    if
                        archetype:isComponentDirty(text.Text)
                        or archetype:isComponentDirty(Tint)
                        or archetype:isComponentDirty(Clip)
                        or archetype:isComponentDirty(Transform2D)
                    then
                        local column = archetype:get(text.Text)
                        local transforms = archetype:get(Transform2D)
                        local tints = archetype:get(Tint)
                        -- Absent on a text nobody clips, which is the common
                        -- case and costs one test for the whole archetype.
                        local clips = archetype:get(Clip)
                        for row = 1, length do
                            local item = column[row]
                            local transform = transforms[row]
                            local tint = tints ~= nil and tints[row] or nil
                            local clip = 0
                            if clips ~= nil then
                                clip = clips[row].index as integer
                            end
                            if stale(item, transform, tint, clip) then
                                built = built + 1
                                build(renderer, install, glyphs, item, transform, tint, clip)
                                own(glyphs, entities[row] as integer, item)
                            end
                        end
                    end
                end

                -- More spans held than there are texts to hold them means at
                -- least one lost its component, which nothing reports. The
                -- counts the last sweep saw are remembered so a scene that
                -- keeps texts out of this query, by disabling them, is walked
                -- once rather than every frame.
                if
                    glyphs._ownerCount > live
                    and (glyphs._ownerCount ~= glyphs._sweptOwners or live ~= glyphs._sweptLive)
                then
                    sweepOwners(glyphs, world)
                    glyphs._sweptOwners = glyphs._ownerCount
                    glyphs._sweptLive = live
                end

                if built > 0 then
                    layoutCounts[world] = (layoutCounts[world] or 0) + built
                end
            end,
        })

        -- A span outlives its text otherwise: nothing else knows the slots are
        -- free, and the glyphs in them keep being drawn.
        world:observe(
            0,
            ecs.OnDespawn,
            function(event: ecs.OnDespawn)
                local item = world:get(event.entity, text.Text)
                if item == nil then
                    return
                end
                disown(glyphs, event.entity)
                if item._spanCount == 0 then
                    return
                end
                reserve(glyphs, item, 0)
            end
        )

        -- A load replaces the world in place rather than despawning what was
        -- in it, so the observer above never hears about the texts it removed
        -- and the run has to be given up whole.
        world:observe(0, ecs.FinishSnapshotLoad, function(_event: ecs.FinishSnapshotLoad) reset(glyphs) end)
    end
end

-------------------------------------------------------------------------------
-- The component
-------------------------------------------------------------------------------

text.Text = ecs.newComponent({
    name = "Text",
    container = Text,
    -- A text is a position and a string. Requiring the position means one is
    -- never accidentally left off, which would make the text quietly not
    -- appear rather than fail.
    requires = {Transform2D},
    fields = {
        "text",
        "font",
        "size",
        "align",
        "wrapWidth",
    },
    init = function(item: Text)
        if item.text == nil then
            item.text = ""
        end
        if item.size == nil then
            item.size = 16
        end
        if item.align == nil then
            item.align = "left"
        end
        if item.wrapWidth == nil then
            item.wrapWidth = 0
        elseif item.wrapWidth < 0 then
            error("tecs: Text.wrapWidth cannot be negative", 3)
        end
        if ALIGNMENTS[item.align] == nil then
            error(("tecs: '%s' is not an alignment; use left, center or right"):format(tostring(item.align)), 3)
        end
        item.width = 0.0
        item.height = 0.0
        item._span = 0
        item._spanCount = 0
    end,
    serialize = function(item: Text): {string: any}
        -- The authored fields and the font by name. The span is one process's
        -- answer and the font is a shared table; neither belongs in a save.
        return {
            text = item.text,
            font = item.font ~= nil and item.font.name or nil,
            size = item.size,
            align = item.align,
            wrapWidth = item.wrapWidth,
        }
    end,
    deserialize = function(_world: World, stored: {string: any}): Text
        -- A font that was never loaded in this process leaves the text
        -- without one, which lays out nothing rather than failing a load.
        local name = stored.font as string
        local font = name ~= nil and fontsByName[name] or nil
        return text.Text(
            stored.text as string, font, stored.size as number, stored.align as string, stored.wrapWidth as number or 0
        )
    end,
})

return text
