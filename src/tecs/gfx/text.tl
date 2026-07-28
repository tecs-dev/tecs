--- Text, laid out into instances and drawn from a signed distance field.
---
--- A `Text` names a font and a string. It is one entity, and its glyphs are
--- not entities at all: the plugin registers an instance producer with the
--- renderer and every text owns a span of that producer's run. A glyph is
--- still a textured quad with a UV rect addressing the font atlas and a
--- material selecting the distance-field shader, so culling, depth, layers and
--- the indirect draw all apply to it exactly as they apply to an entity.
---
--- What a span buys is what dirty tracking cannot give an entity here. Dirty
--- is per archetype per component, so glyph entities would share one archetype
--- and editing one string would rewrite every glyph in the world; and spawning
--- or despawning a glyph moves an archetype's length, which relays the whole
--- scene out. A producer reports the sub-ranges it changed, so editing one
--- string rewrites that string.
---
--- Spans come from a size-bucketed free list. Allocating takes an exact-size
--- span off the free list when one is there and extends the high-water mark
--- otherwise, so short strings appearing and disappearing reuse each other's
--- spans exactly and the producer's length stops moving after warmup. The
--- tradeoff is fragmentation: a text that grows past its span leaves a hole
--- that only a text of that exact length reclaims. Compaction is the answer if
--- a measurement ever shows it mattering, and there is none here until one
--- does.
---
--- The producer keeps its own copy of the glyph instances, so writing a text
--- is a write into ordinary memory and the renderer's sync is a bulk copy of
--- the ranges that moved. That decouples when layout happens from when the
--- GPU buffer is filled, and the copy is contiguous.
---
--- Glyph positions are absolute, so a text composes its own transform: its
--- position, rotation and scale are applied to the glyph offsets here. The
--- text entity is ordinary, so a parent has already composed its `Transform`
--- into world space by the time this reads it.
---
--- Layout runs every frame and almost no text changes, so it is gated twice:
--- an archetype whose `Text`, `Tint` and `Transform` columns are all clean is
--- skipped whole, and within a dirty archetype a row whose authored fields and
--- transform match what its glyphs were built from is skipped too.
---
--- A `Font` is metrics and an atlas path, and nothing about a device. Which
--- texture-array layer the atlas occupies is a renderer's answer, so the
--- plugin holds that and a font can be shared by two of them.
---
--- Layout is advances, kerning where the metrics carry it, explicit newlines
--- and an alignment within the block. What it does not do: wrapping to a
--- width, anchoring anywhere but the block's top-left corner, per-glyph
--- styling, right-to-left or complex shaping, and any effect around the
--- outline. Each of those is a decision rather than an omission of effort,
--- and none is needed by anything drawing text today.

local ecs <const> = require("tecs.ecs")
local filesystem <const> = require("tecs.platform.filesystem")
local loader <const> = require("tecs.ffi.loader")
local assets <const> = require("tecs.assets")
local components <const> = require("tecs.components")
local materials <const> = require("tecs.gpu.materials")
local instancelayout <const> = require("tecs.gpu.instancelayout")
local layersModule <const> = require("tecs.gfx.layers")
local paths <const> = require("tecs.platform.paths")
local json <const> = require("tecs.json")
local log <const> = require("tecs.log")

local type Renderer = require("tecs.Renderer")

local type Component = ecs.Component
local type World = ecs.World

local Transform <const> = ecs.builtins.Transform
local Tint <const> = components.Tint
local Clip <const> = components.Clip

local type TransformInstance = ecs.builtins.Transform
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

local logger <const> = log.get("tecs.text")

--- One glyph's metrics, in the units the atlas was generated at.
local record GlyphMetrics
    --- Rect within the atlas, in atlas pixels.
    x: number
    y: number
    width: number
    height: number
    --- Offset from the pen to the glyph's top-left corner.
    xOffset: number
    yOffset: number
    --- How far the pen moves after this glyph.
    xAdvance: number
end

--- A distance-field font: an atlas image and the metrics describing it.
---
--- Data only. The metrics are read when the font is loaded, which is a few
--- kilobytes of JSON; the atlas is named rather than held, and a renderer
--- decodes and uploads it the first frame a text needs it.
local record Font
    --- Path the metrics were read from, which is the font's identity and what
    --- a snapshot writes.
    name: string
    --- Path the atlas image is read from, which is also the name it is
    --- registered under.
    atlas: string
    --- Em size the metrics were generated at. Everything else here is in the
    --- same units and scales by `Text.size / size`.
    size: number
    --- Distance from one baseline to the next.
    lineHeight: number
    --- Baseline offset from the top of a line box.
    base: number
    --- Atlas dimensions, in pixels.
    atlasWidth: number
    atlasHeight: number
    --- Width of the distance field, in atlas pixels.
    distanceRange: number
    --- Metrics by codepoint.
    glyphs: {integer: GlyphMetrics}
    --- Kerning by leading then trailing codepoint, in font units. Empty when
    --- the metrics carry none.
    kernings: {integer: {integer: number}}

    --- Advance for a codepoint the font has no metrics for.
    _fallbackAdvance: number
end

--- Where a font's atlas sits on one renderer.
local record Atlas
    --- Interned index of the atlas image's name.
    image: number
    --- Texture-array layer the atlas occupies.
    slot: number
    --- Fraction of a cell the atlas covers, which glyph UVs are scaled by.
    u: number
    v: number
    --- The field's range as a fraction of a cell, which is what the material
    --- reads from its parameter.
    param: number
    --- The decode in flight, nil once it has been uploaded.
    handle: assets.Handle
    --- Set once the atlas has failed, so a broken path is reported once
    --- rather than every frame.
    failed: boolean
end

--- A string laid out into glyph instances.
---
--- The entity's Transform places the top-left corner of the text block and
--- orients and scales the whole block, and its Tint, if it has one, colours
--- every glyph. Both are ordinary components on an ordinary entity, so a text
--- is moved, parented, tweened and layered like anything else, and a `Clip`
--- keeps its glyphs inside a rectangle exactly as it would any other quad.
---
--- Write through `world:getMut(entity, Text)`. A write through `world:get`
--- leaves the column clean and the glyphs stale.
local record Text is Component
    --- The string laid out. A newline starts a line; nothing else breaks one.
    text: string
    --- The font the glyphs come from. Without one the text draws nothing.
    font: Font
    --- Em size in world units.
    size: number
    --- "left", "centre" or "right", within the widest line of the block.
    align: string
    --- Multiplies the font's line height.
    lineSpacing: number
    --- Extra advance between glyphs, in world units.
    tracking: number

    --- Extent of the last layout, in world units. Written by the layout
    --- system; assigning it does nothing.
    width: number
    height: number

    --- First slot of the producer span this text owns, one-based, and how many
    --- slots it holds. Zero when it holds none.
    _span: integer
    _spanCount: integer

    --- What the glyphs were last built from. A row whose authored fields and
    --- transform all match these is already laid out.
    _builtText: string
    _builtFont: Font
    _builtSize: number
    _builtAlign: string
    _builtSpacing: number
    _builtTracking: number
    _builtR: number
    _builtG: number
    _builtB: number
    _builtA: number
    _builtX: number
    _builtY: number
    _builtZ: number
    _builtLayer: integer
    _builtRotation: number
    _builtScaleX: number
    _builtScaleY: number
    _builtClip: integer
end

local record FontOptions
    --- Path to the metrics JSON, resolved against the asset root when it is
    --- not absolute.
    metrics: string
    --- Path to the atlas image. Defaults to the page the metrics name,
    --- resolved beside them.
    atlas: string
end

local record TextOptions
    --- The renderer the font atlases upload into and the glyph instances are
    --- produced for.
    renderer: Renderer
end

local record text
    type Font = Font
    type GlyphMetrics = GlyphMetrics
    type FontOptions = FontOptions
    type TextOptions = TextOptions

    Text: Text

    loadFont: function(options: FontOptions): Font
    defaultFont: function(): Font
    fontByName: function(name: string): Font
    reloadFont: function(path: string): Font
    measure: function(item: Text): number, number
    plugin: function(options: TextOptions): function(World)
    layouts: function(world: World): integer
    glyphAt: function(world: World, entity: integer, index: integer): number, number, number, number
end

-------------------------------------------------------------------------------
-- Fonts
-------------------------------------------------------------------------------

--- Every font loaded in this process, by the path its metrics came from. A
--- snapshot writes a name, so this is what one is resolved back through.
local fontsByName <const>: {string: Font} = {}

--- Resolves a path against the asset root unless it already names one.
local function resolve(path: string): string
    if path:sub(1, 1) == "/" then
        return path
    end
    return paths.asset(path)
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
    local ok, root = pcall(json.decode, document)
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

--- Loads a font's metrics and names its atlas.
---
--- Answers with the font already loaded under the same metrics path rather
--- than reading it twice, so a path means one font for the life of the
--- process however many times it is asked for.
function text.loadFont(options: FontOptions): Font
    if options == nil or options.metrics == nil then
        error("tecs: a font needs a `metrics` path", 2)
    end

    local existing = fontsByName[options.metrics]
    if existing ~= nil then
        return existing
    end

    local metricsPath = resolve(options.metrics)
    -- Named as a font, because the bytes are a document like any other and the
    -- only thing that knows they are a font's metrics is the call that asked
    -- for them. A watcher routes a change by that name.
    local document = filesystem.read(metricsPath, "font")
    if document == nil then
        error(("tecs: cannot read the font metrics '%s'"):format(metricsPath), 2)
    end

    local atlas = options.atlas
    if atlas == nil then
        local root = decodeMetrics(document, metricsPath)
        local pages = root.pages as {string}
        if pages == nil or pages[1] == nil then
            error(("tecs: '%s' names no atlas page; pass `atlas`"):format(metricsPath), 2)
        end
        atlas = directoryOf(options.metrics) .. pages[1]
    end

    local self = parseMetrics(document, options.metrics, resolve(atlas))
    fontsByName[self.name] = self
    return self
end

--- The font the engine ships, loaded on first use.
function text.defaultFont(): Font
    return text.loadFont({metrics = DEFAULT_METRICS})
end

--- A loaded font by the metrics path it was loaded from, or nil.
function text.fontByName(name: string): Font
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

--- The font's atlas on this renderer, or nil while it is still decoding.
local function residency(known: {Font: Atlas}, font: Font, renderer: Renderer): Atlas
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
                handle = nil,
                failed = false,
            }
            known[font] = atlas
            return atlas
        end

        -- The worker is what decodes the atlas, and a game that only ever
        -- draws text has no other reason to have started it.
        if not assets.installed() then
            assets.install()
        end
        atlas = {
            image = 0, slot = 0, u = 1.0, v = 1.0, param = 0.0, handle = assets.loadImage(font.atlas), failed = false
        }
        known[font] = atlas
    end

    if atlas.handle == nil then
        if atlas.failed then
            return nil
        end
        return atlas
    end
    if atlas.handle.status == "loading" then
        return nil
    end

    if atlas.handle.status ~= "ready" then
        logger:error("cannot load the font atlas '%s': %s", font.atlas, atlas.handle.error or atlas.handle.status)
        atlas.handle = nil
        atlas.failed = true
        return nil
    end

    local sprite, region = renderer:registerImage(atlas.handle)
    atlas.handle = nil
    atlas.image = sprite.image
    atlas.slot = sprite.slot
    atlas.u = region.u1
    atlas.v = region.v1
    -- The material scales the field by how many screen pixels its range
    -- covers, and it measures that in cell fractions, so the range has to
    -- arrive as one. An atlas smaller than a cell covers less of it, which is
    -- what the region reports.
    atlas.param = font.distanceRange * region.u1 / font.atlasWidth
    return atlas
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

--- The laid-out glyphs, four numbers each: centre x and y, then width and
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
    centre = 0.5,
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

--- Extent of `item` in world units, without touching any entity.
---
--- The same layout the system runs, so a caller sizing a panel around a
--- string gets the number the glyphs will occupy.
function text.measure(item: Text): number, number
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
    --- the dirty ones: a font that has not arrived yet, or one just re-read.
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
-- Re-reading a font
-------------------------------------------------------------------------------

--- Gives up what a renderer resolved for `font`, so the next layout resolves it
--- again.
---
--- Everything in an `Atlas` is an answer to the metrics. The field's range
--- arrives as a fraction of a cell, computed from `distanceRange` and the atlas
--- size, and a page that would not decode is remembered so a broken path is
--- reported once rather than every frame. A re-read is exactly the event that
--- makes both of those questions worth asking again, and the second is the more
--- interesting one: a font regenerated over a page that was missing has to be
--- able to come back.
local function evict(install: Install, font: Font)
    local atlas = install.known[font]
    if atlas == nil then
        return
    end
    -- A decode still in flight is reachable through this record and through
    -- nothing else, so what the worker answers with has to be given back before
    -- the record goes.
    if atlas.handle ~= nil then
        atlas.handle:release()
    end
    install.known[font] = nil
end

--- Re-reads a font's metrics over the font already loaded from them.
---
--- Identity is the point, as it is for an image. A `Text` names its font by
--- holding the table, so the metrics are read back into that table rather than
--- into a new one and every text goes on pointing at the font it was given. A
--- replacement would strand each of them on the font that was.
---
--- Which is also why nothing can infer from identity that anything happened. A
--- text is laid out again when what its glyphs were built from differs from what
--- it holds now, and after a read in place none of it differs, so the texts
--- naming this font are told rather than left to notice. Exactly those: a text
--- naming another font is not laid out again, whatever archetype it shares.
---
--- Metrics naming an atlas of another size are refused, on the terms
--- `reloadImage` refuses an image whose size moved. Every glyph already drawn
--- carries UV extents measured against the size the atlas had, and a page of
--- another size makes each of them address something else. The atlas keeps the
--- name it was loaded under either way, since that name may have been given
--- rather than read and a re-read of the metrics is not a change of which image
--- the glyphs come from.
--- @param path The metrics path the font was loaded under, or the file it was
---     read from.
--- @return The font, which is the table it always was.
function text.reloadFont(path: string): Font
    if path == nil or path == "" then
        error("tecs: a font re-read needs a metrics path", 2)
    end

    local font = fontAt(path)
    if font == nil then
        error(("tecs: no font is loaded from '%s', so there is nothing to " .. "re-read"):format(path), 0)
    end

    local document = filesystem.read(resolve(font.name), "font")
    if document == nil then
        error(("tecs: cannot read the font metrics '%s'"):format(path), 0)
    end

    -- Into a fresh table first. A malformed document raises part way through
    -- parsing, and the font every text is holding has to end up as the one it
    -- was or as the whole new one, never as half of each.
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
end

--- How many texts have been laid out in `world` since it was created.
---
--- Laying out a string that did not change is the cost the dirty gates exist
--- to avoid, and this is how that is asserted rather than assumed.
function text.layouts(world: World): integer
    return layoutCounts[world] or 0
end

--- Where the `index`th glyph of `entity` landed, as world x, y, width and
--- height.
---
--- Read back out of the instance the producer wrote, so this is where the
--- glyph is drawn rather than where a layout intended it. Nothing when the
--- text has no such glyph.
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
    return instances[base + 4] as number, instances[base + 5] as number, instances[base + 1] as number, instances[base + 2] as number
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

--- Rewrites one text's glyph instances. False when its font has not arrived.
local function build(
    renderer: Renderer,
    known: {Font: Atlas},
    glyphs: Glyphs,
    item: Text,
    transform: TransformInstance,
    tint: TintInstance,
    clip: integer
): boolean
    local font = item.font
    local atlas = font ~= nil and residency(known, font, renderer) or nil
    if atlas == nil then
        reserve(glyphs, item, 0)
        item.width = 0.0
        item.height = 0.0
        -- A font that is absent or broken is settled; one still decoding is
        -- not, and has to be looked at again.
        return font == nil or known[font].failed
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
        instances[base + 3] = layersModule.depthOf(layer, z, x, y)

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
    return true
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

--- Registers the layout system and the producer on a world.
---
--- The system runs after `RelativeTransform`, which composes a parented text's
--- own world transform in the same phase. Glyph positions are absolute, so a
--- text laid out before that composition would use the transform the previous
--- frame left and never notice the write that changed it.
function text.plugin(options: TextOptions): function(World)
    if options == nil or options.renderer == nil then
        error("tecs: the text plugin needs a `renderer`", 2)
    end
    local renderer <const> = options.renderer

    return function(world: World)
        local texts <const> = world:query({
            name = "tecs.Text",
            include = {text.Text, Transform},
        })
        local install <const>: Install = {
            glyphs = newGlyphs(),
            known = {},
            waiting = false,
            reloaded = nil,
        }
        local known <const> = install.known
        local glyphs <const> = install.glyphs

        installs[world] = install
        renderer:addProducer(glyphs as Renderer.InstanceProducer)

        world:addSystem({
            name = "tecs.TextLayout",
            phase = ecs.phases.PostUpdate,
            after = {"RelativeTransform"},
            run = function()
                -- A font that has not arrived leaves its texts unbuilt and
                -- their archetypes clean, so the gate is held open until it
                -- does, and the decode is pumped meanwhile. A font just re-read
                -- holds it open for the same reason: its atlas was given up and
                -- has to be resolved again.
                local all = install.waiting
                if all then
                    assets.update()
                end
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
                                if not build(renderer, known, glyphs, item, transform, tint, clip) then
                                    install.waiting = true
                                end
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
            ecs.builtins.OnDespawn,
            function(event: ecs.builtins.OnDespawn)
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
        world:observe(
            0, ecs.builtins.FinishSnapshotLoad, function(_event: ecs.builtins.FinishSnapshotLoad) reset(glyphs) end
        )
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
                error(("tecs: '%s' is not an alignment; use left, centre or right"):format(tostring(item.align)), 3)
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
        deserialize = function(_world: World, data: {string: any}): Text
            -- A font that was never loaded in this process leaves the text
            -- without one, which lays out nothing rather than failing a load.
            local name = data.font as string
            local font = name ~= nil and fontsByName[name] or nil
            return text.Text(
                data.text as string,
                font,
                data.size as number,
                data.align as string,
                data.lineSpacing as number,
                data.tracking as number
            )
        end,
    }
)

return text
