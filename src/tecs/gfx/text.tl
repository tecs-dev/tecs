--- Text, laid out into entities and drawn from a signed distance field.
---
--- A `Text` names a font and a string; a system lays it out and keeps one
--- child entity per glyph, each carrying a Transform, a Sprite addressing the
--- glyph in the font atlas, and a Material selecting the distance-field
--- shader. Nothing about drawing text is special from there: extraction,
--- culling, the indirect draw, layers and depth all work on glyphs because
--- glyphs are ordinary renderables.
---
--- The cost is an entity per glyph. That is the right first version and the
--- wrong final one: a scene with a great deal of text pays an archetype row,
--- an instance and a cull bound for every character on screen. The
--- optimisation, if a measurement ever asks for it, is to batch a text's
--- glyphs into a buffer of their own and draw them together, which trades all
--- of the above for a second path through the renderer. Do not reach for it
--- before the measurement.
---
--- A glyph belongs to its text through `ChildOf`, which cascades on despawn,
--- so a text takes its glyphs with it. Position is a `RelativeTransform`, so a
--- text on a screen-space layer, or moved by a parent, works without any of
--- this knowing about either.
---
--- Layout runs every frame and almost no text changes, so it is gated twice:
--- an archetype whose `Text` and `Tint` columns are both clean is skipped
--- whole, and within a dirty archetype a row whose authored fields match what
--- its glyphs were built from is skipped too.
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
local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local assets <const> = require("tecs.assets")
local components <const> = require("tecs.components")
local materials <const> = require("tecs.gpu.materials")
local paths <const> = require("tecs.platform.paths")
local json <const> = require("tecs.utils.json")
local log <const> = require("tecs.log")

local type Renderer = require("tecs.Renderer")

local type Component = ecs.Component
local type World = ecs.World

local C <const> = sdl.C

local Transform <const> = ecs.builtins.Transform
local RelativeTransform <const> = ecs.builtins.RelativeTransform
local ChildOf <const> = ecs.builtins.ChildOf
local Sprite <const> = components.Sprite
local Tint <const> = components.Tint
local Material <const> = components.Material
local Renderable <const> = components.Renderable

local byte <const> = string.byte

--- Material the glyph quads select, resolved by name because the numbering
--- depends on which material files exist.
local MATERIAL <const> = "glyph"

--- The font the engine ships, relative to the asset root.
local DEFAULT_METRICS <const> = "fonts/jetbrainsmono-extrabold-msdf.json"

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

--- A string laid out into glyph entities.
---
--- The entity's Transform places the top-left corner of the text block, and
--- its Tint, if it has one, colours every glyph. Both are ordinary components
--- on an ordinary entity, so a text is moved, parented, tweened and layered
--- like anything else.
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

    --- What the glyphs were last built from. A row whose authored fields all
    --- match these is already laid out.
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
    --- The glyph entities, in layout order.
    _glyphs: {integer}
end

--- Marks an entity as one glyph of a text.
---
--- Derived state: the layout system owns these entities entirely, and a
--- snapshot omits them because loading a Text lays out its own again.
local record Glyph is Component end

local record FontOptions
    --- Path to the metrics JSON, resolved against the asset root when it is
    --- not absolute.
    metrics: string
    --- Path to the atlas image. Defaults to the page the metrics name,
    --- resolved beside them.
    atlas: string
end

local record TextOptions
    --- The renderer the font atlases upload into.
    renderer: Renderer
end

local record text
    type Font = Font
    type GlyphMetrics = GlyphMetrics
    type FontOptions = FontOptions
    type TextOptions = TextOptions

    Text: Text
    Glyph: Glyph

    loadFont: function(options: FontOptions): Font
    defaultFont: function(): Font
    fontByName: function(name: string): Font
    measure: function(item: Text): number, number
    plugin: function(options: TextOptions): function(World)
    layouts: function(world: World): integer
end

text.Glyph = ecs.newComponent({
    name = "Glyph",
    container = Glyph,
    transient = true,
})

-------------------------------------------------------------------------------
-- Fonts
-------------------------------------------------------------------------------

--- Every font loaded in this process, by the path its metrics came from. A
--- snapshot writes a name, so this is what one is resolved back through.
local fontsByName <const>: {string: Font} = {}

local function readFile(path: string): string
    local size = loader.newArray("size_t[1]")
    local data = C.SDL_LoadFile(path, size)
    if data == nil then return nil end
    local body = loader.toBytes(data, tonumber(size[0]) as integer)
    C.SDL_free(data)
    return body
end

--- Resolves a path against the asset root unless it already names one.
local function resolve(path: string): string
    if path:sub(1, 1) == "/" then return path end
    return paths.asset(path)
end

--- Everything up to and including the final separator, or the empty string.
local function directoryOf(path: string): string
    local cut = path:match("^.*()/")
    if cut == nil then return "" end
    return path:sub(1, cut as integer)
end

--- Reads a BMFont-style metrics document into a Font.
local function parseMetrics(document: string, name: string, atlas: string): Font
    local root = json.parse(document) as {string: any}
    if root == nil then
        error(("tecs: '%s' is not a font metrics document"):format(name), 0)
    end

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
    if existing ~= nil then return existing end

    local metricsPath = resolve(options.metrics)
    local document = readFile(metricsPath)
    if document == nil then
        error(("tecs: cannot read the font metrics '%s'"):format(metricsPath), 2)
    end

    local atlas = options.atlas
    if atlas == nil then
        local root = json.parse(document) as {string: any}
        local pages = root ~= nil and root.pages as {string} or nil
        if pages == nil or pages[1] == nil then
            error(("tecs: '%s' names no atlas page; pass `atlas`")
                :format(metricsPath), 2)
        end
        atlas = directoryOf(options.metrics) .. pages[1]
    end

    local self = parseMetrics(document, options.metrics, resolve(atlas))
    fontsByName[self.name] = self
    return self
end

--- The font the engine ships, loaded on first use.
function text.defaultFont(): Font
    return text.loadFont({ metrics = DEFAULT_METRICS })
end

--- A loaded font by the metrics path it was loaded from, or nil.
function text.fontByName(name: string): Font
    return fontsByName[name]
end

--- The font's atlas on this renderer, or nil while it is still decoding.
local function residency(known: {Font: Atlas}, font: Font,
                         renderer: Renderer): Atlas
    local atlas = known[font]
    if atlas == nil then
        -- The worker is what decodes the atlas, and a game that only ever
        -- draws text has no other reason to have started it.
        if not assets.installed() then assets.install() end
        atlas = { image = 0, slot = 0, u = 1.0, v = 1.0, param = 0.0,
            handle = assets.loadImage(font.atlas), failed = false }
        known[font] = atlas
    end

    if atlas.handle == nil then
        if atlas.failed then return nil end
        return atlas
    end
    if atlas.handle.status == "loading" then return nil end

    if atlas.handle.status ~= "ready" then
        logger:error("cannot load the font atlas '%s': %s",
            font.atlas, atlas.handle.error or atlas.handle.status)
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
-- Layout
-------------------------------------------------------------------------------

--- Decodes one UTF-8 codepoint, answering it and the index after it.
---
--- A malformed byte is answered as itself, so a string that is not UTF-8 lays
--- out as Latin-1 rather than failing.
local function codepointAt(source: string, index: integer): integer, integer
    local first = byte(source, index)
    if first < 0x80 then return first, index + 1 end

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

    if index + length - 1 > #source then return first, index + 1 end
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
            if pen > blockWidth then blockWidth = pen end
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
                -- costs no entity.
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
    if pen > blockWidth then blockWidth = pen end

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
-- The glyph entities
-------------------------------------------------------------------------------

--- Layouts run, by world, for a test or a tool that wants to see the gate
--- working. Weak keys, so a discarded world is not held alive by its count.
local layoutCounts <const>: {World: integer} = setmetatable(
    {} as {World: integer}, { __mode = "k" } as metatable<{World: integer}>)

--- How many texts have been laid out in `world` since it was created.
---
--- Laying out a string that did not change is the cost the dirty gates exist
--- to avoid, and this is how that is asserted rather than assumed.
function text.layouts(world: World): integer
    return layoutCounts[world] or 0
end

--- The material id, resolved on first use: reading the material files needs
--- an asset root, and module load is too early to have one.
local materialId = -1

local function glyphMaterial(): integer
    if materialId < 0 then materialId = materials.id(MATERIAL) end
    return materialId
end

--- Despawns the glyphs from `first` onwards.
local function trimGlyphs(world: World, owned: {integer}, first: integer)
    for index = #owned, first, -1 do
        world:despawn(owned[index])
        owned[index] = nil
    end
end

--- Rebuilds one text's glyphs. False when its font has not arrived.
local function build(world: World, renderer: Renderer, known: {Font: Atlas},
                     entity: integer): boolean
    local item = world:get(entity, Text)
    if item == nil then return true end

    local owned = item._glyphs
    if owned == nil then
        owned = {}
        item._glyphs = owned
    end

    local font = item.font
    local atlas = font ~= nil and residency(known, font, renderer) or nil
    if atlas == nil then
        trimGlyphs(world, owned, 1)
        item.width = 0.0
        item.height = 0.0
        -- A font that is absent or broken is settled; one still decoding is
        -- not, and has to be looked at again.
        return font == nil or known[font].failed
    end

    local tint = world:get(entity, Tint)
    local r, g, b, a = 1.0, 1.0, 1.0, 1.0
    if tint ~= nil then r, g, b, a = tint.r, tint.g, tint.b, tint.a end

    local count, width, height = layout(item)
    item.width = width
    item.height = height

    local material <const> = glyphMaterial()
    local param <const> = atlas.param
    local image <const> = atlas.image
    local slot <const> = atlas.slot
    -- Glyph rects are atlas pixels and a Sprite carries cell fractions, and an
    -- atlas smaller than its cell does not reach the cell's edge.
    local u <const> = atlas.u / font.atlasWidth
    local v <const> = atlas.v / font.atlasHeight
    local glyphs <const> = font.glyphs

    for index = 1, count do
        local base = (index - 1) * 4
        local x, y = placements[base + 1], placements[base + 2]
        local sx, sy = placements[base + 3], placements[base + 4]

        -- V runs from the glyph's lower edge to its upper one, because a
        -- quad's local Y and the screen's disagree in sign: the rows arrive
        -- in the order the glyph is drawn in rather than the order the atlas
        -- stores them.
        local glyph = glyphs[codepoints[index]]
        local u0, u1 = glyph.x * u, (glyph.x + glyph.width) * u
        local v0, v1 = (glyph.y + glyph.height) * v, glyph.y * v

        local entry = owned[index]
        local relative = entry ~= nil
            and world:getMut(entry, RelativeTransform) or nil
        if relative == nil then
            -- A row with no live entity behind it is either new or one whose
            -- entity something else despawned; either way it is spawned now.
            owned[index] = world:spawn(
                Transform(),
                RelativeTransform(x, y, 0, 0, sx, sy),
                ChildOf(entity) as Component,
                Sprite(image, u0, v0, u1, v1, slot),
                Tint(r, g, b, a),
                Material(material, param),
                Renderable(),
                text.Glyph()
            )
        else
            relative.x = x
            relative.y = y
            relative.scaleX = sx
            relative.scaleY = sy

            local sprite = world:getMut(entry, Sprite)
            sprite.image = image
            sprite.slot = slot
            sprite.u0, sprite.v0 = u0, v0
            sprite.u1, sprite.v1 = u1, v1

            local colour = world:getMut(entry, Tint)
            colour.r, colour.g, colour.b, colour.a = r, g, b, a
        end
    end

    trimGlyphs(world, owned, count + 1)

    -- Written straight onto the instance rather than through getMut: these
    -- fields are this system's own bookkeeping, nothing dirty-gated reads
    -- them, and marking the column would reopen the gate that let this row
    -- through in the first place.
    item._builtText = item.text
    item._builtFont = font
    item._builtSize = item.size
    item._builtAlign = item.align
    item._builtSpacing = item.lineSpacing
    item._builtTracking = item.tracking
    item._builtR, item._builtG = r, g
    item._builtB, item._builtA = b, a
    return true
end

--- Whether `item` differs from what its glyphs were built from.
local function stale(world: World, entity: integer, item: Text): boolean
    if item._builtText ~= item.text
        or item._builtFont ~= item.font
        or item._builtSize ~= item.size
        or item._builtAlign ~= item.align
        or item._builtSpacing ~= item.lineSpacing
        or item._builtTracking ~= item.tracking then
        return true
    end

    local tint = world:get(entity, Tint)
    if tint == nil then
        return item._builtR ~= 1.0 or item._builtG ~= 1.0
            or item._builtB ~= 1.0 or item._builtA ~= 1.0
    end
    return item._builtR ~= tint.r or item._builtG ~= tint.g
        or item._builtB ~= tint.b or item._builtA ~= tint.a
end

--- Registers the layout system and the snapshot exclusion on a world.
---
--- The system runs ahead of `RelativeTransform`, which composes the glyph
--- offsets into world transforms in the same phase: a glyph spawned after it
--- would sit at the world origin for a frame.
function text.plugin(options: TextOptions): function(World)
    if options == nil or options.renderer == nil then
        error("tecs: the text plugin needs a `renderer`", 2)
    end
    local renderer <const> = options.renderer

    return function(world: World)
        local texts <const> = world:query({
            name = "tecs.Text",
            include = { text.Text, Transform },
        })
        --- Which texture-array layer each font's atlas landed on, which is
        --- this renderer's answer and not the font's.
        local known <const>: {Font: Atlas} = {}
        local pending <const>: {integer} = {}
        local waiting = false

        world:addSystem({
            name = "tecs.TextLayout",
            phase = ecs.phases.PostUpdate,
            before = { "RelativeTransform" },
            run = function()
                -- A font that has not arrived leaves its texts unbuilt and
                -- their archetypes clean, so the gate is held open until it
                -- does, and the decode is pumped meanwhile.
                local all = waiting
                if all then assets.update() end
                waiting = false

                local count = 0
                for archetype, length, entities in texts:iter() do
                    if all or archetype:isComponentDirty(text.Text)
                        or archetype:isComponentDirty(Tint) then
                        local column = archetype:get(text.Text)
                        for row = 1, length do
                            local entity = entities[row]
                            if stale(world, entity, column[row]) then
                                count = count + 1
                                pending[count] = entity
                            end
                        end
                    end
                end

                if count == 0 then return end
                layoutCounts[world] = (layoutCounts[world] or 0) + count
                -- Spawning happens here rather than inside the walk above,
                -- because a spawn made while a query is iterating is deferred
                -- and the composition that follows this system would not see
                -- it until the next frame.
                for index = 1, count do
                    if not build(world, renderer, known, pending[index]) then
                        waiting = true
                    end
                    pending[index] = nil
                end
            end,
        })

        -- Glyphs are derived, so a snapshot leaves them out and loading a
        -- Text lays them out again. Saving them would double every string.
        world:observe(0, ecs.builtins.OnSnapshotSave,
            function(event: ecs.builtins.OnSnapshotSave)
                event:exclude(text.Glyph)
            end)
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
    requires = { Transform },
    fields = {
        "text", "font", "size", "align", "lineSpacing", "tracking",
    },
    init = function(item: Text)
        if item.text == nil then item.text = "" end
        if item.size == nil then item.size = 16 end
        if item.align == nil then item.align = "left" end
        if item.lineSpacing == nil then item.lineSpacing = 1.0 end
        if item.tracking == nil then item.tracking = 0.0 end
        if ALIGNMENTS[item.align] == nil then
            error(("tecs: '%s' is not an alignment; use left, centre or right")
                :format(tostring(item.align)), 3)
        end
        item.width = 0.0
        item.height = 0.0
    end,
    serialize = function(item: Text): {string: any}
        -- The font by name and the authored fields only. The glyph entities
        -- are derived and the font is a shared table; neither belongs in a
        -- save.
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
        return text.Text(data.text as string, font, data.size as number,
            data.align as string, data.lineSpacing as number,
            data.tracking as number)
    end,
})

return text
