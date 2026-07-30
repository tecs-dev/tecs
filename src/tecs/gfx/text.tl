--[=[
Distance-field text as entities in the rendered world.

A `Text` names a font and string. `Transform` places its top-left corner,
`Tint` colors every glyph, and `Clip` clips it like any other drawable.

```teal
world:addPlugin(tecs.gfx.textPlugin({
    renderer = app.renderer,
}))

world:spawn(
    tecs.Transform(24, 24),
    tecs.gfx.Tint(0.92, 0.96, 1.0, 1.0),
    tecs.gfx.Text.new({
        text = "tecs\n1200 entities",
        font = tecs.gfx.defaultFont():wait().value,
        size = 28,
        align = "center",
    })
)
```

Write text fields through `world:getMut`. A direct `world:get` write leaves the
column clean and the displayed glyphs unchanged.

## Fonts and layout

A `Font` holds metrics and an atlas path. `loadFont` returns a
[`Future`](tealdoc:tecs.Future) that reads BMFont-style JSON metrics off the
main thread. `defaultFont` loads the bundled font on the same terms. The metrics
path gives each font its snapshot identity. Worlds and renderers may share a
font.

Layout applies glyph advances, kerning, explicit newlines, line spacing,
tracking, and left, center, or right alignment within the widest line.
`measureText` returns the same extent without touching an entity.

Text does not wrap to a width, shape complex scripts, anchor outside the
top-left corner, or style individual glyphs. The `glyph` material draws text
unlit.
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
local filesystem <const> = require("tecs.platform.filesystem")
local loader <const> = require("tecs.ffi.loader")
local assets <const> = require("tecs.assets")
local components <const> = require("tecs.components")
local materials <const> = require("tecs.gpu.materials")
local instancelayout <const> = require("tecs.gpu.instancelayout")
local layersModule <const> = require("tecs.gfx.layers")
local data <const> = require("tecs.data")
local log <const> = require("tecs.log")

local type Renderer = require("tecs.Renderer")
local Future <const> = require("tecs.Future")

local type Component = ecs.Component
local type World = types.World

local Transform <const> = ecs.Transform
local Tint <const> = components.Tint
local Clip <const> = components.Clip

local type TransformInstance = ecs.Transform
local type TintInstance = components.Tint

local byte <const> = string.byte
local abs <const> = math.abs
local cos <const> = math.cos
local sin <const> = math.sin

--- Material the glyph quads select, resolved by name because the numbering
--- depends on which material files exist.
local MATERIAL <const> = "glyph"

--- The font the engine ships, relative to the asset root.
local DEFAULT_METRICS <const> = "fonts/jetbrainsmono-extrabold-msdf.json"

local INSTANCE_FLOATS <const> = instancelayout.FLOATS
local INSTANCE_BYTES <const> = instancelayout.BYTES
local BOUND_FLOATS <const> = instancelayout.BOUND_FLOATS
local BOUND_BYTES <const> = instancelayout.BOUND_BYTES
local UNBOUNDED <const> = instancelayout.UNBOUNDED
local HIDDEN <const> = instancelayout.HIDDEN
local packSlot <const> = instancelayout.packSlot

--- Glyph slots the producer's arrays start at, and the floor every growth
--- doubles from.
local MINIMUM_SLOTS <const> = 64

--- The logger name is a compatibility surface rather than an identifier, and
--- it stays what it is now that a game reaches this module as `tecs.gfx`. A
--- logger name is what `SDL_SetLogPriority` filters on, so it is configuration
--- a developer types into a shell rather than a name this tree can rename in
--- one commit.
local logger <const> = log.get("tecs.text")

--- Describes one glyph in the units used to generate its atlas.
local record GlyphMetrics
    --- Read-only. Reports the glyph rectangle's left edge in atlas pixels.
    x: number
    --- Read-only. Reports the glyph rectangle's top edge in atlas pixels.
    y: number
    --- Read-only. Reports the glyph rectangle's width in atlas pixels.
    width: number
    --- Read-only. Reports the glyph rectangle's height in atlas pixels.
    height: number
    --- Read-only. Reports the horizontal offset from the pen to the glyph's
    --- top-left corner.
    xOffset: number
    --- Read-only. Reports the vertical offset from the pen to the glyph's
    --- top-left corner.
    yOffset: number
    --- Read-only. Reports how far the pen moves after this glyph.
    xAdvance: number
end

--- Represents a distance-field font through its atlas image and metrics.
---
--- Data only. The metrics are read when the font is loaded, which is a few
--- kilobytes of JSON; the atlas is named rather than held, and a renderer
--- decodes and uploads it the first frame a text needs it.
local record Font
    --- Read-only. Reports the path from which metrics were read. It provides
    --- the font's identity and the value
    --- a snapshot writes.
    name: string
    --- Read-only. Reports the path from which the atlas image is read. The
    --- renderer also uses it as the name
    --- registered under.
    atlas: string
    --- Read-only. Reports the em size at which the metrics were generated.
    --- Every other metric uses the
    --- same units and scales by `Text.size / size`.
    size: number
    --- Read-only. Reports the distance from one baseline to the next.
    lineHeight: number
    --- Read-only. Reports the baseline offset from the top of a line box.
    base: number
    --- Read-only. Reports the atlas width in pixels.
    atlasWidth: number
    --- Read-only. Reports the atlas height in pixels.
    atlasHeight: number
    --- Read-only. Reports the width of the distance field in atlas pixels.
    distanceRange: number
    --- Read-only. Provides glyph metrics by codepoint.
    glyphs: {integer: GlyphMetrics}
    --- Read-only. Provides kerning by leading then trailing codepoint in font
    --- units. The table remains empty when
    --- the metrics carry none.
    kernings: {integer: {integer: number}}

    --- Engine-owned. Stores the fallback advance for codepoints without
    --- metrics. Ordinary game code should ignore this field.
    _fallbackAdvance: number
end

--- Tracks where a font atlas sits on one renderer.
local record Atlas
    --- Engine-owned. Stores the interned atlas image index. Ordinary game code
    --- should ignore this field.
    image: number
    --- Engine-owned. Stores the texture-array layer occupied by the atlas.
    --- Ordinary game code should ignore this field.
    slot: number
    --- Engine-owned. Stores the horizontal fraction of a cell covered by the
    --- atlas. Ordinary game code should ignore this field.
    u: number
    --- Engine-owned. Stores the vertical fraction of a cell covered by the
    --- atlas. Ordinary game code should ignore this field.
    v: number
    --- Engine-owned. Stores the distance-field range as a fraction of a cell,
    --- which the material
    --- reads from its parameter.
    param: number
    --- Engine-owned. Holds the decode and the upload that consumes it, and it is
    --- nil only for an atlas the renderer already had. The fields above are
    --- meaningless until it reports `"ready"`, and it stays `"failed"` for a page
    --- that would not decode, which is what reports a broken path once rather
    --- than every frame. Ordinary game code should ignore this field.
    pending: Future<components.Sprite>
end

--- Lays a string out into glyph instances.
---
--- The entity's Transform places the top-left corner of the text block and
--- orients and scales the whole block, and its Tint, if it has one, colors
--- every glyph. Both are ordinary components on an ordinary entity, so a text
--- moves, parents, tweens, and layers like anything else, and a `Clip`
--- keeps its glyphs inside a rectangle exactly as it would any other quad.
---
--- Write through `world:getMut(entity, Text)`. A write through `world:get`
--- leaves the column clean and the glyphs stale.
local record Text is Component
    --- Caller-writable. Sets the laid-out string. A newline starts a line;
    --- nothing else breaks one.
    text: string
    --- Caller-writable. Selects the font that supplies the glyphs. Without one,
    --- the text draws nothing.
    font: Font
    --- Caller-writable. Sets the em size in world units.
    size: number
    --- Caller-writable. Selects `"left"`, `"center"`, or `"right"` alignment
    --- within the block's widest line.
    align: string
    --- Caller-writable. Multiplies the font's line height.
    lineSpacing: number
    --- Caller-writable. Adds advance between glyphs in world units.
    tracking: number

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
    --- Engine-owned. Stores the last laid-out line spacing. Ordinary game code
    --- should ignore this field.
    _builtSpacing: number
    --- Engine-owned. Stores the last laid-out tracking. Ordinary game code
    --- should ignore this field.
    _builtTracking: number
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

--- Configures a font loaded from metrics and an atlas.
local record FontOptions
    --- Caller-writable. Sets the path to the metrics JSON. Tecs resolves it
    --- against the asset root when it is
    --- not absolute.
    metrics: string
    --- Caller-writable. Sets the atlas image path. It defaults to the page
    --- named in the metrics, resolved beside them.
    atlas: string
end

--- Configures the text layout plugin.
local record TextOptions
    --- Caller-writable. Selects the renderer that receives font atlases and
    --- glyph instances.
    renderer: Renderer
end

local record text
    --- Represents a loaded font named by `Text`.
    type Font = Font
    --- Describes one entry of a font's `glyphs` in the units used to generate
    --- the atlas.
    type GlyphMetrics = GlyphMetrics
    --- Configures `loadFont`.
    type FontOptions = FontOptions
    --- Configures `textPlugin`.
    type TextOptions = TextOptions

    --- Read-only. Exposes the text component.
    Text: Text

    --- Starts loading a font's metrics and names its atlas.
    ---
    --- Concurrent calls under the same metrics path share one read and parse
    --- while receiving futures of their own, so canceling one does not cancel
    --- the others. A call after settlement returns an already-ready future for
    --- the shared font. The call reads `options` before returning.
    --- @param options The caller must set `metrics`. `atlas` defaults to the
    ---     first page in the metrics, resolved beside the metrics file, and
    ---     applies only on the first load of a path.
    --- @return Returns a [`Future`](tealdoc:tecs.Future) for the shared
    ---     [`Font`](tealdoc:tecs.gfx.text.Font) for that path. A missing or
    ---     malformed metrics document fails the future. The renderer still
    ---     loads its atlas when a text first needs it.
    loadFont: function(options: FontOptions): Future<Font>
    --- Starts loading the bundled default font.
    --- @return Returns a future for the same shared
    ---     [`Font`](tealdoc:tecs.gfx.text.Font) on every call.
    defaultFont: function(): Future<Font>
    --- Returns a loaded font by its metrics path, or nil.
    --- @param name The path exactly as passed to `loadFont`, before asset-root
    ---     resolution.
    --- @return The shared [`Font`](tealdoc:tecs.gfx.text.Font), or nil before a
    ---     load of that path has settled successfully.
    findFont: function(name: string): Font
    --- Starts reloading a font's metrics while preserving the Font value.
    ---
    --- Existing [`Text`](tealdoc:tecs.gfx.text.Text) components keep the same
    --- table and lay themselves out again. Reloading rejects metrics that
    --- change the atlas dimensions.
    --- @param path The metrics path passed to `loadFont`, or its resolved file
    ---     path.
    --- @return Returns a future for the same
    ---     [`Font`](tealdoc:tecs.gfx.text.Font) table with its metrics updated.
    ---     A read or parse failure fails the future and leaves the font
    ---     unchanged.
    reloadFont: function(path: string): Future<Font>
    --- Returns a text item's width and height in world units.
    ---
    --- Uses the same layout as the plugin without adding or changing an
    --- entity.
    --- @param item A [`Text`](tealdoc:tecs.gfx.text.Text) value to read. It need
    ---     not belong to an entity.
    --- @return Width at `item.size`, before
    ---     [`Transform`](/modules/ecs/#tecs.ecs.Transform) scale. Returns zero for a missing
    ---     item, font, or string.
    --- @return Height on the same terms, counting complete line boxes.
    measureText: function(item: Text): number, number
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
    --- @param index A one-based produced-glyph index. Newlines, spaces, and
    ---     missing codepoints move the pen without taking an index.
    --- @return World x of the glyph center, or nil when no glyph exists.
    --- @return World y of the glyph center, or nil with the first return.
    --- @return Glyph width in world units, or nil with the first return.
    --- @return Glyph height in world units, or nil with the first return.
    glyphAt: function(world: World, entity: integer, index: integer): number, number, number, number
end

-------------------------------------------------------------------------------
-- Fonts
-------------------------------------------------------------------------------

--- Every font loaded in this process, by the path its metrics came from. A
--- snapshot writes a name, so this is what one is resolved back through.
local fontsByName <const>: {string: Font} = {}
--- Loads still reading or parsing, by the same identity. The root belongs to
--- this module and callers receive derived links, so one caller's cancellation
--- is invisible to every other caller sharing the work.
local fontLoads <const>: {string: Future<Font>} = {}

--- Resolves a path against the asset root unless it already names one.
local function resolve(path: string): string
    if path:sub(1, 1) == "/" then
        return path
    end
    return filesystem.assetPath(path)
end

--- Everything up to and including the final separator, or the empty string.
local function directoryOf(path: string): string
    local cut = path:match("^.*()/")
    if cut == nil then
        return ""
    end
    return path:sub(1, cut as integer)
end

--- The metrics document as a table, or an error naming the font.
---
--- The decoder raises on malformed input, and its message says where in the
--- text it gave up rather than which font asked. The name is the part a caller
--- can act on, so the raise is caught and replaced. Level zero because the
--- message locates itself and the frame that called this does not.
local function decodeMetrics(document: string, name: string): {string: any}
    local ok, root = pcall(data.decodeJSON, document)
    if not ok or type(root) ~= "table" then
        error(("tecs: '%s' is not a font metrics document"):format(name), 0)
    end
    return root as {string: any}
end

--- Reads a BMFont-style metrics document into a Font.
local function parseMetrics(document: string, name: string, atlas: string): Font
    local root = decodeMetrics(document, name)

    local info = root.info as {string: any}
    local common = root.common as {string: any}
    if info == nil or common == nil then
        error(("tecs: '%s' carries no font metrics"):format(name), 0)
    end

    local field = root.distanceField as {string: any}
    if field == nil then
        error(("tecs: '%s' is not a distance-field font"):format(name), 0)
    end

    local self: Font = {
        name = name,
        atlas = atlas,
        size = info.size as number,
        lineHeight = common.lineHeight as number,
        base = common.base as number,
        atlasWidth = common.scaleW as number,
        atlasHeight = common.scaleH as number,
        distanceRange = field.distanceRange as number,
        glyphs = {},
        kernings = {},
        _fallbackAdvance = 0,
    }

    local chars = root.chars as {{string: any}}
    if chars == nil then
        error(("tecs: '%s' lists no glyphs"):format(name), 0)
    end
    for index = 1, #chars do
        local entry = chars[index]
        self.glyphs[entry.id as integer] = {
            x = entry.x as number,
            y = entry.y as number,
            width = entry.width as number,
            height = entry.height as number,
            xOffset = entry.xoffset as number,
            yOffset = entry.yoffset as number,
            xAdvance = entry.xadvance as number,
        }
    end

    local kernings = root.kernings as {{string: any}}
    if kernings ~= nil then
        for index = 1, #kernings do
            local entry = kernings[index]
            local first = entry.first as integer
            local trailing = self.kernings[first]
            if trailing == nil then
                trailing = {}
                self.kernings[first] = trailing
            end
            trailing[entry.second as integer] = entry.amount as number
        end
    end

    -- A codepoint the font has no metrics for still takes up room, and the
    -- space is the least surprising width to give it.
    local space = self.glyphs[32]
    self._fallbackAdvance = space ~= nil and space.xAdvance or self.size * 0.5

    return self
end

--- Turns one metrics document into the process-wide font it describes.
local function loadDocument(options: FontOptions, metricsPath: string, document: string): Font
    local atlas = options.atlas
    if atlas == nil then
        local root = decodeMetrics(document, metricsPath)
        local pages = root.pages as {string}
        if pages == nil or pages[1] == nil then
            error(("tecs: '%s' names no atlas page; pass `atlas`"):format(metricsPath), 0)
        end
        atlas = directoryOf(options.metrics) .. pages[1]
    end
    return parseMetrics(document, options.metrics, resolve(atlas))
end

--- A caller's own link to one shared font load.
local function linkFont(loading: Future<Font>): Future<Font>
    return loading:map(function(font: Font): Font return font end)
end

-- A metrics path identifies one process-wide font. Reusing the same path
-- returns a future for the existing table, and the renderer loads the named
-- atlas only when text first needs it.
function text.loadFont(options: FontOptions): Future<Font>
    if options == nil or options.metrics == nil then
        error("tecs: a font needs a `metrics` path", 2)
    end

    local existing = fontsByName[options.metrics]
    if existing ~= nil then
        return Future.settled(existing)
    end

    local loading = fontLoads[options.metrics]
    if loading ~= nil then
        return linkFont(loading)
    end

    if not assets.installed() then
        assets.install()
    end

    local name <const> = options.metrics
    local metricsPath <const> = resolve(name)
    local requested <const>: FontOptions = {
        metrics = name,
        atlas = options.atlas,
    }
    -- Named as a font, because the bytes are a document like any other and the
    -- only thing that knows they are a font's metrics is the call that asked
    -- for them. A watcher routes a change by that name.
    loading = assets.loadBytes(metricsPath, "font"):map(function(document: string): Font
        return loadDocument(requested, metricsPath, document)
    end)
    fontLoads[name] = loading
    loading:onSettle(function(settled: Future<Font>)
        if fontLoads[name] == settled then
            fontLoads[name] = nil
        end
        if settled.status == "ready" and fontsByName[name] == nil then
            fontsByName[name] = settled.value
        end
    end)
    return linkFont(loading)
end

function text.defaultFont(): Future<Font>
    return text.loadFont({metrics = DEFAULT_METRICS})
end

function text.findFont(name: string): Font
    return fontsByName[name]
end

--- The font loaded from `path`, by the name it was loaded under or by the file
--- that name resolves to.
---
--- Two spellings reach the same font. A game names it the way it asked for it,
--- which is commonly relative to the content root; a watcher names the file it
--- looked at, which is that name resolved. Both have to find the one font.
local function fontAt(path: string): Font
    local named = fontsByName[path]
    if named ~= nil then
        return named
    end
    for _, font in pairs(fontsByName) do
        if resolve(font.name) == path then
            return font
        end
    end
    return nil
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
    --- Cancels atlas loads retained by the install that owns this producer.
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

--- None, because a glyph is drawn in the G-buffer lane whatever its alpha is.
---
--- The distance field resolves its own edge and the material puts that edge in
--- alpha, so a glyph does not need the forward pass to look right; routing text
--- there instead would take it out of the G-buffer and out of everything that
--- reads one, which is a change to how text is drawn rather than to how it is
--- counted.
function Glyphs:blended(): integer
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

--- Decodes one UTF-8 codepoint, answering it and the index after it.
---
--- A malformed byte is answered as itself, so a string that is not UTF-8 lays
--- out as Latin-1 rather than failing.
local function codepointAt(source: string, index: integer): integer, integer
    local first = byte(source, index)
    if first < 0x80 then
        return first, index + 1
    end

    local length: integer
    local value: integer
    if first >= 0xF0 then
        length, value = 4, first - 0xF0
    elseif first >= 0xE0 then
        length, value = 3, first - 0xE0
    elseif first >= 0xC0 then
        length, value = 2, first - 0xC0
    else
        return first, index + 1
    end

    if index + length - 1 > #source then
        return first, index + 1
    end
    for offset = 1, length - 1 do
        local continuation = byte(source, index + offset)
        if continuation < 0x80 or continuation > 0xBF then
            return first, index + 1
        end
        value = value * 64 + (continuation - 0x80)
    end
    return value, index + length
end

--- The laid-out glyphs, four numbers each: center x and y, then width and
--- height, all in world units relative to the text's transform. Reused, so a
--- layout allocates nothing.
local placements <const>: {number} = {}
--- Codepoint per placement, for addressing the atlas in the same order.
local codepoints <const>: {integer} = {}
--- First and last placement of each line, and the line's width.
local lineFirst <const>: {integer} = {}
local lineLast <const>: {integer} = {}
local lineWidth <const>: {number} = {}

--- How far a line moves within the block, as a fraction of the room left over.
local ALIGNMENTS <const>: {string: number} = {
    left = 0.0,
    center = 0.5,
    right = 1.0,
}

--- Lays `item` out into `placements`, answering the glyph count and extent.
---
--- Explicit newlines break lines and nothing else does: there is no wrapping
--- and no anchor, so the block's top-left corner is the entity's position.
local function layout(item: Text): integer, number, number
    local font = item.font
    local scale = item.size / font.size
    local glyphs = font.glyphs
    local kernings = font.kernings
    local step = font.lineHeight * scale * item.lineSpacing
    local tracking = item.tracking
    local body = item.text
    local length = #body

    local count = 0
    local lines = 1
    local blockWidth = 0.0
    local pen = 0.0
    local top = 0.0
    local previous = 0
    local index = 1
    lineFirst[1] = 1

    while index <= length do
        local codepoint: integer
        codepoint, index = codepointAt(body, index)

        if codepoint == 10 then
            lineLast[lines] = count
            lineWidth[lines] = pen
            if pen > blockWidth then
                blockWidth = pen
            end
            lines = lines + 1
            lineFirst[lines] = count + 1
            pen = 0.0
            top = top + step
            previous = 0
        elseif codepoint ~= 13 then
            local glyph = glyphs[codepoint]
            if glyph == nil then
                pen = pen + font._fallbackAdvance * scale + tracking
                previous = 0
            else
                if previous ~= 0 then
                    local trailing = kernings[previous]
                    if trailing ~= nil and trailing[codepoint] ~= nil then
                        pen = pen + trailing[codepoint] * scale
                    end
                end

                -- A space has an advance and no quad, so it moves the pen and
                -- costs no slot.
                if glyph.width > 0 and glyph.height > 0 then
                    local width = glyph.width * scale
                    local height = glyph.height * scale
                    local base = count * 4
                    count = count + 1
                    placements[base + 1] = pen + glyph.xOffset * scale + width * 0.5
                    placements[base + 2] = top + glyph.yOffset * scale + height * 0.5
                    placements[base + 3] = width
                    placements[base + 4] = height
                    codepoints[count] = codepoint
                end

                pen = pen + glyph.xAdvance * scale + tracking
                previous = codepoint
            end
        end
    end

    lineLast[lines] = count
    lineWidth[lines] = pen
    if pen > blockWidth then
        blockWidth = pen
    end

    -- Alignment moves whole lines within the block, which is why it waits
    -- until the widest one is known.
    local weight = ALIGNMENTS[item.align] or 0.0
    if weight ~= 0.0 then
        for line = 1, lines do
            local shift = (blockWidth - lineWidth[line]) * weight
            if shift ~= 0.0 then
                for placement = lineFirst[line], lineLast[line] do
                    local base = (placement - 1) * 4
                    placements[base + 1] = placements[base + 1] + shift
                end
            end
        end
    end

    return count, blockWidth, lines * step
end

-- This calls the same layout routine as the plugin, without producing
-- instances or touching an entity.
function text.measureText(item: Text): number, number
    if item == nil or item.font == nil or item.text == nil then
        return 0.0, 0.0
    end
    local _, width, height = layout(item)
    return width, height
end

-------------------------------------------------------------------------------
-- The glyph instances
-------------------------------------------------------------------------------

--- Layouts run, by world, for a test or a tool that wants to see the gate
--- working. Weak keys, so a discarded world is not held alive by its count.
local layoutCounts <const>: {World: integer} = setmetatable(
    {} as {World: integer}, {__mode = "k"} as metatable<{World: integer}>
)

--- What the plugin holds on one world, for the same reason and on the same
--- terms: a reload is asked for from outside any frame and has to reach the run
--- the glyphs live in, the atlases this world's renderer resolved for them, and
--- the gate the layout system reads.
local record Install
    glyphs: Glyphs
    --- Which texture-array layer each font's atlas landed on, which is this
    --- renderer's answer and not the font's.
    known: {Font: Atlas}
    --- Set when the next layout has to look at every archetype rather than only
    --- the dirty ones: an atlas that has just settled, or a font just re-read.
    --- A text whose font had not arrived was left unbuilt with its archetype
    --- clean, so nothing else says to look at it again.
    waiting: boolean
    --- Fonts re-read since the last layout, or nil when there are none. A
    --- re-read keeps the font's table, so nothing a text holds differs
    --- afterwards and nothing it is compared against does either; this is what
    --- the layout pass consults instead of inferring from identity.
    reloaded: {Font: boolean}
end

local installs <const>: {World: Install} = setmetatable(
    {} as {World: Install}, {__mode = "k"} as metatable<{World: Install}>
)

-------------------------------------------------------------------------------
-- Resolving an atlas
-------------------------------------------------------------------------------

--- Starts the decode of `font`'s atlas and answers the load that fills `atlas`.
---
--- The upload is the load's transform rather than something the layout pass
--- does when it next looks. Two things follow. An atlas reaches the shelf
--- packer from the loader's own drain, in the order the worker answered, and
--- one atlas is one link carrying one transform, so nothing reorders the
--- coordinates a `Sprite` ends up holding. And the layout pass has no reason to
--- pump the loader, because it no longer has a state machine of its own to
--- nudge: `Application` polls once a frame, ahead of the world's update, so an
--- atlas that arrives is registered before the pass that draws it runs.
---
--- The listener is the layout's wake, and one settlement is one call however
--- many texts name the font, so a page that will not decode is reported once
--- rather than every frame.
local function startAtlas(install: Install, atlas: Atlas, font: Font, renderer: Renderer): Future<components.Sprite>
    return assets.loadImage(font.atlas):map(
        function(image: assets.Image): components.Sprite
            local sprite <const>, region <const> = renderer:registerImage(image)
            atlas.image = sprite.image
            atlas.slot = sprite.slot
            atlas.u = region.u1
            atlas.v = region.v1
            -- The material scales the field by how many screen pixels its
            -- range covers, and it measures that in cell fractions, so the
            -- range has to arrive as one. An atlas smaller than a cell
            -- covers less of it, which is what the region reports.
            atlas.param = font.distanceRange * region.u1 / font.atlasWidth
            return sprite
        end
    ):onSettle(
        function(settled: Future<components.Sprite>)
            -- Reached for a raise inside the upload as well as for a page
            -- the worker could not read, because `map` turns one into the
            -- other rather than letting it escape into the frame.
            if settled.status == "failed" then
                logger:error("cannot load the font atlas '%s': %s", font.atlas, settled.error)
            end
            install.waiting = true
        end
    )
end

--- The font's atlas on this renderer, or nil while it decodes and after it fails.
local function residency(install: Install, font: Font, renderer: Renderer): Atlas
    local known <const> = install.known
    local atlas = known[font]
    if atlas == nil then
        -- Already on the renderer answers without the worker. Re-reading a
        -- font's metrics gives up this record and its derived fields, but the
        -- atlas itself is untouched and still holds its layer, so decoding the
        -- file again would end at `registerImage` handing back the region it
        -- already had and releasing the fresh pixels undrawn. The text would
        -- blank for the frames that took.
        local resident <const> = renderer:regionOf(font.atlas)
        if resident ~= nil then
            local sprite <const> = renderer:sprite(font.atlas)
            atlas = {
                image = sprite.image,
                slot = sprite.slot,
                u = resident.u1,
                v = resident.v1,
                param = font.distanceRange * resident.u1 / font.atlasWidth,
                pending = nil,
            }
            known[font] = atlas
            return atlas
        end

        -- The worker is what decodes the atlas, and a game that only ever
        -- draws text has no other reason to have started it.
        if not assets.installed() then
            assets.install()
        end
        -- Recorded before the load starts, and the load is what fills it. The
        -- record is what makes this lazy resolve happen once: every later text
        -- naming the font finds it here rather than starting a second decode.
        atlas = {image = 0, slot = 0, u = 1.0, v = 1.0, param = 0.0, pending = nil}
        known[font] = atlas
        atlas.pending = startAtlas(install, atlas, font, renderer)
    end

    local decoding <const> = atlas.pending
    if decoding == nil or decoding.status == "ready" then
        return atlas
    end
    return nil
end

-------------------------------------------------------------------------------
-- Re-reading a font
-------------------------------------------------------------------------------

--- Gives up what a renderer resolved for `font`, so the next layout resolves it
--- again.
---
--- Everything in an `Atlas` is an answer to the metrics. The field's range
--- arrives as a fraction of a cell, computed from `distanceRange` and the atlas
--- size, and the load that filled it remembers a page that would not decode. A
--- re-read is exactly the event that makes both of those questions worth asking
--- again, and the second is the more interesting one: a font regenerated over a
--- page that was missing has to be able to come back.
local function evict(install: Install, font: Font)
    local atlas = install.known[font]
    if atlas == nil then
        return
    end
    -- A load reached through this record and through nothing else, so this
    -- install's interest in it goes before the record does. One call covers both
    -- halves: before the decode lands this gives it up, and the last install to
    -- do so abandons it, while a load that already landed released its pixels
    -- into the upload and cancel on it does nothing.
    local decoding = atlas.pending
    if decoding ~= nil then
        decoding:cancel()
    end
    install.known[font] = nil
end

-- Reload in place so Text values retain their Font identity. The explicit
-- reloaded set tells the layout pass which unchanged table contents need
-- rebuilding. Atlas dimensions remain fixed because existing glyph UVs depend
-- on them.
function text.reloadFont(path: string): Future<Font>
    if path == nil or path == "" then
        error("tecs: a font re-read needs a metrics path", 2)
    end

    local font = fontAt(path)
    if font == nil then
        error(("tecs: no font is loaded from '%s', so there is nothing to " .. "re-read"):format(path), 0)
    end

    if not assets.installed() then
        assets.install()
    end

    return assets.loadBytes(resolve(font.name), "font"):map(function(document: string): Font
        -- Into a fresh table first. A malformed document raises part way
        -- through parsing, and the font every text is holding has to end up
        -- as the one it was or as the whole new one, never as half of each.
        local fresh = parseMetrics(document, font.name, font.atlas)
        if fresh.atlasWidth ~= font.atlasWidth or fresh.atlasHeight ~= font.atlasHeight then
            error(
                (
                    "tecs: '%s' was loaded against a %dx%d atlas and now names one "
                    .. "of %dx%d; a re-read keeps the size, because the glyphs already "
                    .. "drawn hold rects measured against the old one"
                ):format(font.name, font.atlasWidth, font.atlasHeight, fresh.atlasWidth, fresh.atlasHeight),
                0
            )
        end

        font.size = fresh.size
        font.lineHeight = fresh.lineHeight
        font.base = fresh.base
        font.distanceRange = fresh.distanceRange
        font.glyphs = fresh.glyphs
        font.kernings = fresh.kernings
        font._fallbackAdvance = fresh._fallbackAdvance

        for _, install in pairs(installs) do
            evict(install, font)
            local reloaded = install.reloaded
            if reloaded == nil then
                reloaded = {}
                install.reloaded = reloaded
            end
            reloaded[font] = true
            install.waiting = true
        end

        return font
    end)
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

--- The material id, resolved on first use: reading the material files needs
--- an asset root, and module load is too early to have one.
local materialId = -1

local function glyphMaterial(): integer
    if materialId < 0 then
        materialId = materials.id(MATERIAL)
    end
    return materialId
end

--- Rewrites one text's glyph instances, or empties them until its font arrives.
---
--- A text left empty here keeps a stale build record, so the next pass that
--- looks at it builds it again. What says to look is the atlas's own settlement,
--- and a text with no font at all is never looked at again until something
--- writes one.
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
    local atlas = font ~= nil and residency(install, font, renderer) or nil
    if atlas == nil then
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
    local originX <const> = transform.x
    local originY <const> = transform.y
    local z <const> = transform.z
    local layer <const> = transform.layer as integer
    local viewCulled <const> = layersModule.viewCulled(layer)
    -- Every glyph sits on the text's own layer, so the band is the block's and
    -- not the glyph's: resolved here and spent per glyph below.
    local bandBase <const>, bandSort <const> = layersModule.bandOf(layer)

    -- Material and parameter share one float: the integer part selects and the
    -- fraction carries the parameter, which is a ratio in 0..1.
    local param = atlas.param
    if param < 0.0 then
        param = 0.0
    elseif param > 0.999 then
        param = 0.999
    end
    local material <const> = glyphMaterial() + param
    -- The clip region rides above the texture-array layer in one float, packed
    -- the way the renderer packs an entity's. Region zero packs to the layer
    -- unchanged, so an unclipped text writes what it always wrote.
    local slot <const> = packSlot(clip, atlas.slot)

    -- Glyph rects are atlas pixels and the instance carries cell fractions,
    -- and an atlas smaller than its cell does not reach the cell's edge.
    local u <const> = atlas.u / font.atlasWidth
    local v <const> = atlas.v / font.atlasHeight
    local metrics <const> = font.glyphs

    for index = 1, count do
        local place = (index - 1) * 4
        local offsetX = placements[place + 1] * blockX
        local offsetY = placements[place + 2] * blockY
        local x = originX + offsetX * turnX - offsetY * turnY
        local y = originY + offsetX * turnY + offsetY * turnX
        local scaleX = placements[place + 3] * blockX
        local scaleY = placements[place + 4] * blockY

        -- The metrics are BMFont pixels measured from the atlas's top left,
        -- and the rect goes out in that order: a glyph is a sub-rect of an
        -- image like any other sprite.
        local glyph = metrics[codepoints[index]]
        local u0, u1 = glyph.x * u, (glyph.x + glyph.width) * u
        local v0, v1 = glyph.y * v, (glyph.y + glyph.height) * v

        local base = (span + index - 2) * INSTANCE_FLOATS
        instances[base] = rotation
        instances[base + 1] = scaleX
        instances[base + 2] = scaleY
        instances[base + 3] = layersModule.depthIn(bandBase, bandSort, z, x, y)

        instances[base + 4] = x
        instances[base + 5] = y
        instances[base + 6] = slot
        instances[base + 7] = material

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
        bounds[bound + 2] = ex
        bounds[bound + 3] = ey
    end

    if count > 0 then
        mark(glyphs, span, span + count - 1)
    end

    item._builtText = item.text
    item._builtFont = font
    item._builtSize = item.size
    item._builtAlign = item.align
    item._builtSpacing = item.lineSpacing
    item._builtTracking = item.tracking
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
        or item._builtSpacing ~= item.lineSpacing
        or item._builtTracking ~= item.tracking
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

-- Run after RelativeTransform because glyph instances use absolute positions;
-- running before parent composition would consume the previous frame's
-- transform.
function text.textPlugin(options: TextOptions): function(World)
    if options == nil or options.renderer == nil then
        error("tecs: the text plugin needs a `renderer`", 2)
    end
    local renderer <const> = options.renderer

    return function(world: World)
        local texts <const> = world:query(
            {
                name = "tecs.Text",
                include = {text.Text, Transform},
            }
        )
        local install <const>: Install = {
            glyphs = newGlyphs(),
            known = {},
            waiting = false,
            reloaded = nil,
        }
        local glyphs <const> = install.glyphs
        glyphs.destroy = function() for loadedFont in pairs(install.known) do evict(install, loadedFont) end end

        installs[world] = install
        renderer:addProducer(glyphs as Renderer.InstanceProducer)

        world:addSystem(
            {
                name = "tecs.TextLayout",
                phase = ecs.phases.PostUpdate,
                after = {"RelativeTransform"},
                run = function()
                    -- A font that has not arrived leaves its texts unbuilt and
                    -- their archetypes clean, so something other than a dirty
                    -- column has to say to look at them. The atlas's own
                    -- settlement is what says it, from the drain the application
                    -- already pumps; a font just re-read says it too, because its
                    -- atlas was given up and has to be resolved again.
                    local all = install.waiting
                    install.waiting = false
                    -- Read once and dropped, because clearing what it marks is the
                    -- text's own build record and that survives until a build
                    -- actually succeeds. An atlas that takes a few frames to come
                    -- back is retried on the record, not on this.
                    local reloaded <const> = install.reloaded
                    install.reloaded = nil

                    local built = 0
                    local live = 0
                    for archetype, length, entities in texts:iter() do
                        live = live + length
                        if
                            all
                            or archetype:isComponentDirty(text.Text)
                            or archetype:isComponentDirty(Tint)
                            or archetype:isComponentDirty(Clip)
                            or archetype:isComponentDirty(Transform)
                        then
                            local column = archetype:get(text.Text)
                            local transforms = archetype:get(Transform)
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
                                -- The font this text holds was read again under it,
                                -- so what its glyphs were built from is the table
                                -- it still names and comparing the two says
                                -- nothing. Forgetting the font is what makes the
                                -- comparison fail, and it goes on failing until a
                                -- build writes it back, which is what carries the
                                -- text across the frames its atlas is decoding in.
                                if reloaded ~= nil and reloaded[item.font] then
                                    item._builtFont = nil
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
            }
        )

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

text.Text = ecs.newComponent(
    {
        name = "Text",
        container = Text,
        -- A text is a position and a string. Requiring the position means one is
        -- never accidentally left off, which would make the text quietly not
        -- appear rather than fail.
        requires = {Transform},
        fields = {
            "text",
            "font",
            "size",
            "align",
            "lineSpacing",
            "tracking",
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
            if item.lineSpacing == nil then
                item.lineSpacing = 1.0
            end
            if item.tracking == nil then
                item.tracking = 0.0
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
                lineSpacing = item.lineSpacing,
                tracking = item.tracking,
            }
        end,
        deserialize = function(_world: World, stored: {string: any}): Text
            -- A font that was never loaded in this process leaves the text
            -- without one, which lays out nothing rather than failing a load.
            local name = stored.font as string
            local font = name ~= nil and fontsByName[name] or nil
            return text.Text(
                stored.text as string,
                font,
                stored.size as number,
                stored.align as string,
                stored.lineSpacing as number,
                stored.tracking as number
            )
        end,
    }
)

return text
