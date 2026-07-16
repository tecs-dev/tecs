--- FFI Text component for GPU text rendering using BMFont atlases.
--- Uses slab-based glyph storage for shared layouts across entities.
--- Identical (text + font + scale) combinations share the same glyph data.

local tecs <const> = require("tecs")
local bmfont <const> = require("tecs2d.gfx.bmfont")
local types <const> = require("tecs2d.gfx.types")
local glyphslab <const> = require("tecs2d.gfx.internal.text.glyphslab")
local glyphblock <const> = require("tecs2d.gfx.internal.text.glyphblock")

local record text
    --- FFI Text component (40 bytes)
    record Text is tecs.Component, types.Rect
        --- Slab offset (start index in glyph slab buffer)
        slabOffset: integer
        --- Number of glyphs in the slab
        charCount: integer
        --- Font ID (index into font atlas array)
        fontId: integer
        --- Unique text ID (for setText/setScale context lookup)
        textId: integer
        --- Glyph block ID (for stable GPU buffer allocation)
        glyphBlockId: integer
        --- GPU glyph buffer start index resolved from `glyphBlockId`.
        --- Renderer-internal; written by sync, read by the cull shader.
        gpuStartIdx: integer
        --- Font atlas layer index resolved from `fontId`. Bit 31 is
        --- the SDF flag (set when the font's atlas is signed-distance);
        --- bits 0-30 are the array layer index.
        --- Renderer-internal; written by sync, read by the cull shader.
        fontLayer: integer
        --- Precomputed pivot offset X (ox + pivotX * width)
        pivotOffsetX: number
        --- Precomputed pivot offset Y (oy + pivotY * height)
        pivotOffsetY: number
        --- Cached text width (unscaled by transform)
        width: number
        --- Cached text height (unscaled by transform)
        height: number

        metamethod __call: function(
            self,
            fontPath: string,
            text: string,
            sx?: number,
            sy?: number
        ): Text

        --- Update the text string.
        --- This updates the slab reference (may share with other entities).
        setText: function(self: Text, newText: string)

        --- Get the current text string.
        getText: function(self: Text): string

        --- Update scale.
        --- This updates the slab reference (may share with other entities).
        setScale: function(self: Text, sx: number, sy?: number)
    end

    --- Resource key for the slab allocator
    SLAB_ALLOCATOR: tecs.Key<glyphslab.SlabAllocator>

    --- Resource key for the glyph block allocator (stable GPU slots)
    BLOCK_ALLOCATOR: tecs.Key<glyphblock.GlyphBlockAllocator>

    --- Resource key for Text metadata (non-FFI data like font reference)
    TEXT_META: tecs.Key<TextMetaRegistry>

    --- Registry for Text metadata (stores font/text/scale per entity)
    record TextMetaRegistry
        --- Font reference per entity
        fonts: {integer: bmfont.BMFont}
        --- Font path per entity (retained so `serialize` can round-trip)
        fontPaths: {integer: string}
        --- Text string per entity
        texts: {integer: string}
        --- Scale X per entity
        scaleX: {integer: number}
        --- Scale Y per entity
        scaleY: {integer: number}
        --- Origin offset X per entity
        originX: {integer: number}
        --- Origin offset Y per entity
        originY: {integer: number}
        --- Slab entry per entity (for reference counting)
        slabEntries: {integer: glyphslab.SlabEntry}
        --- Glyph block ID per entity (for stable GPU slots)
        glyphBlockIds: {integer: integer}
    end

    plugin: function(world: tecs.World)
end

text.SLAB_ALLOCATOR = tecs.newKey("tecs2d.gfx.text.slabAllocator")
text.BLOCK_ALLOCATOR = tecs.newKey("tecs2d.gfx.text.blockAllocator")
text.TEXT_META = tecs.newKey("tecs2d.gfx.text.meta")

local Text <const> = text.Text

-- Pending spawn data (textId -> spawn info)
-- Used to track font/text/scale during spawn before entity ID is known
local record PendingSpawn
    font: bmfont.BMFont
    fontPath: string
    textStr: string
    sx: number
    sy: number
    entry: glyphslab.SlabEntry
end
local pendingSpawns: {integer: PendingSpawn} = {}

-- Global slab reference (set by plugin)
local globalSlab: glyphslab.SlabAllocator = nil

-- Auto-incrementing text ID and context lookup
local NEXT_TEXT_ID: integer = 1
local type TextContext = {tecs.World, integer}
local textIdToContext: {integer: TextContext} = {}

--- Shared tail of setText/setScale: swap the slab entry for the new
--- (text, scale) combination, resize the glyph block, refresh the FFI
--- fields and pivot, and mark the component dirty for GPU sync.
--- The caller updates the changed meta field(s) before calling.
local function reacquireSlabEntry(
    self: text.Text,
    world: tecs.World,
    entityId: integer,
    textStr: string,
    sx: number,
    sy: number
)
    local meta = world.resources[text.TEXT_META]
    local slab = world.resources[text.SLAB_ALLOCATOR]
    local blockAlloc = world.resources[text.BLOCK_ALLOCATOR]

    -- Release old slab entry
    local oldEntry = meta.slabEntries[entityId]
    if oldEntry then
        slab:release(oldEntry)
    end

    -- Acquire new slab entry
    local font = meta.fonts[entityId]
    local entry = slab:acquire(font, textStr, sx, sy)
    meta.slabEntries[entityId] = entry

    -- Resize glyph block if needed
    local blockId = meta.glyphBlockIds[entityId]
    if blockId and blockId > 0 then
        blockAlloc:resize(blockId, entry.count)
    end

    -- Update FFI component
    self.slabOffset = entry.offset
    self.charCount = entry.count
    self.width = entry.width
    self.height = entry.height

    -- Recompute pivot offset
    local ox = meta.originX[entityId] or 0
    local oy = meta.originY[entityId] or 0
    self.pivotOffsetX = ox + 0.5 * entry.width
    self.pivotOffsetY = oy + 0.5 * entry.height

    -- Mark entity dirty so GPU sync picks up the change
    world:markComponentDirty(entityId, Text as tecs.Component)
end

-- Methods table for FFI metatable (defined after activeWorld/activeEntityId)
local methods = {
    getRect = function(self: text.Text): number, number, number, number
        return -self.pivotOffsetX, -self.pivotOffsetY, self.width, self.height
    end,

    setText = function(self: text.Text, newText: string)
        local ctx = textIdToContext[self.textId]
        if not ctx then
            error("Text:setText called on component not attached to an entity")
        end

        local world = ctx[1]
        local entityId = ctx[2]
        local meta = world.resources[text.TEXT_META]
        if meta.texts[entityId] == newText then return end

        meta.texts[entityId] = newText
        reacquireSlabEntry(self, world, entityId, newText,
            meta.scaleX[entityId], meta.scaleY[entityId])
    end,

    getText = function(self: text.Text): string
        local ctx = textIdToContext[self.textId]
        if not ctx then
            return ""
        end
        local world = ctx[1]
        local entityId = ctx[2]
        local meta = world.resources[text.TEXT_META]
        return meta.texts[entityId] or ""
    end,

    setScale = function(self: text.Text, sx: number, sy?: number)
        local ctx = textIdToContext[self.textId]
        if not ctx then
            error("Text:setScale called on component not attached to an entity")
        end

        local world = ctx[1]
        local entityId = ctx[2]
        local newSy = sy or sx
        local meta = world.resources[text.TEXT_META]
        if meta.scaleX[entityId] == sx and meta.scaleY[entityId] == newSy then return end

        meta.scaleX[entityId] = sx
        meta.scaleY[entityId] = newSy
        reacquireSlabEntry(self, world, entityId, meta.texts[entityId], sx, newSy)
    end,
}
local TEXT_MT <const> = { __index = methods }

-- Create the FFI component. Public construction is semantic
-- `(fontPath, text, sx?, sy?)`, so custom `__call` delegates straight
-- to `Text.init` instead of using positional FFI field mapping.
tecs.newFFIComponent({
    name = "Text",
    container = Text,
    fields = {
        {"slabOffset", "uint32_t"},
        {"charCount", "uint16_t"},
        {"fontId", "uint16_t"},
        {"textId", "uint32_t"},
        {"glyphBlockId", "uint32_t"},
        {"gpuStartIdx", "uint32_t"},
        {"fontLayer", "uint32_t"},
        {"pivotOffsetX", "float"},
        {"pivotOffsetY", "float"},
        {"width", "float"},
        {"height", "float"},
    },
    metatable = TEXT_MT as {any:any},
    __call = function(
        instance: text.Text,
        fontPath: string,
        textStr: string,
        sx?: number,
        sy?: number
    )
        Text.init(instance, fontPath, textStr, sx, sy)
    end,
    init = function(
        instance: text.Text,
        fontPath: string,
        textStr: string,
        sx?: number,
        sy?: number
    )
        -- Load font synchronously
        local font = bmfont.load(fontPath)
        local sxVal = sx or 1
        local syVal = sy or sxVal

        -- Acquire slab entry (plugin must be initialized first)
        if not globalSlab then
            error("text.plugin() must be called before creating Text components")
        end

        local entry = globalSlab:acquire(font, textStr, sxVal, syVal)
        local slabOffset = entry.offset
        local charCount = entry.count
        local fontId = entry.fontId
        local width = entry.width
        local height = entry.height

        -- Assign unique text ID
        local textId = NEXT_TEXT_ID
        NEXT_TEXT_ID = NEXT_TEXT_ID + 1

        -- glyphBlockId is lifecycle-managed (assigned on add). gpuStartIdx
        -- and fontLayer are written by the sync system once the glyph
        -- block is allocated and the font atlas layer is resolved; zero
        -- is a safe pre-sync placeholder.
        instance.slabOffset = slabOffset
        instance.charCount = charCount
        instance.fontId = fontId
        instance.textId = textId
        instance.glyphBlockId = 0
        instance.gpuStartIdx = 0
        instance.fontLayer = 0
        instance.pivotOffsetX = 0.5 * width
        instance.pivotOffsetY = 0.5 * height
        instance.width = width
        instance.height = height

        -- Store pending spawn data keyed by textId for the Text lifecycle query to pick up
        pendingSpawns[textId] = {
            font = font,
            fontPath = fontPath,
            textStr = textStr,
            sx = sxVal,
            sy = syVal,
            entry = entry,
        }
    end,

    -- Per-entity Text lifecycle (metadata setup on add, slab/block
    -- release on remove) is handled by query observers registered in
    -- `text.plugin` -- see `text.TextLifecycle` below.

    -- Serialization captures the three user-provided inputs (font path,
    -- string, scale). Deserialization reruns the normal construction
    -- path so a restored Text gets fresh textId / glyphBlockId / slab
    -- state.
    serialize = function(inst: text.Text): {string: any}
        local ctx = textIdToContext[inst.textId]
        if not ctx then return nil end
        local world = ctx[1]
        local entityId = ctx[2]
        local meta = world.resources[text.TEXT_META]
        return {
            font = meta.fontPaths[entityId],
            text = meta.texts[entityId],
            sx = meta.scaleX[entityId],
            sy = meta.scaleY[entityId],
        }
    end,

    deserialize = function(_world: tecs.World, data: {string: any}): text.Text
        return text.Text(
            data.font as string,
            data.text as string,
            data.sx as number,
            data.sy as number
        )
    end,
})

function text.plugin(world: tecs.World)
    -- Initialize slab allocator resource
    local slab = glyphslab.new()
    world.resources[text.SLAB_ALLOCATOR] = slab
    globalSlab = slab  -- Make available to initializer

    -- Initialize block allocator resource (for stable GPU slots)
    world.resources[text.BLOCK_ALLOCATOR] = glyphblock.new()

    -- Initialize metadata registry resource
    local meta: text.TextMetaRegistry = {
        fonts = {},
        fontPaths = {},
        texts = {},
        scaleX = {},
        scaleY = {},
        originX = {},
        originY = {},
        slabEntries = {},
        glyphBlockIds = {},
    }
    world.resources[text.TEXT_META] = meta

    local blockAlloc = world.resources[text.BLOCK_ALLOCATOR]

    -- Per-entity Text lifecycle: on add, pull pending spawn data into
    -- the meta registry and allocate a glyph block; on remove, release
    -- both. Single-component include ⇒ the observer matches
    -- transitions in/out of any arch containing Text, firing exactly
    -- once per entity per lifecycle event.
    world:query({
        name = "text.TextLifecycle",
        include = {text.Text},
        onEntitiesAdded = function(archetype: tecs.Archetype, firstRow: integer, lastRow: integer, _count: integer)
            local texts = archetype:getMut(text.Text) as {text.Text}
            local entities = archetype.entities
            for row = firstRow, lastRow do
                local self = texts[row]
                if not self then goto continue end
                local entityId = entities[row]
                local pending = assert(pendingSpawns[self.textId], "Missing pending spawn data for Text")
                pendingSpawns[self.textId] = nil

                textIdToContext[self.textId] = {world, entityId}

                local blockId, _ = blockAlloc:alloc(pending.entry.count)
                self.glyphBlockId = blockId

                meta.fonts[entityId] = pending.font
                meta.fontPaths[entityId] = pending.fontPath
                meta.texts[entityId] = pending.textStr
                meta.scaleX[entityId] = pending.sx
                meta.scaleY[entityId] = pending.sy
                meta.originX[entityId] = 0
                meta.originY[entityId] = 0
                meta.slabEntries[entityId] = pending.entry
                meta.glyphBlockIds[entityId] = blockId
                ::continue::
            end
        end,
        onEntitiesRemoved = function(archetype: tecs.Archetype, firstRow: integer, lastRow: integer, _count: integer)
            local texts = archetype:get(text.Text) as {text.Text}
            local entities = archetype.entities
            for row = firstRow, lastRow do
                local self = texts[row]
                if not self then goto continue end
                local entityId = entities[row]
                textIdToContext[self.textId] = nil

                local entry = meta.slabEntries[entityId]
                if entry then
                    slab:release(entry)
                end

                local bid = meta.glyphBlockIds[entityId]
                if bid and bid > 0 then
                    blockAlloc:free(bid)
                end

                meta.fonts[entityId] = nil
                meta.fontPaths[entityId] = nil
                meta.texts[entityId] = nil
                meta.scaleX[entityId] = nil
                meta.scaleY[entityId] = nil
                meta.originX[entityId] = nil
                meta.originY[entityId] = nil
                meta.slabEntries[entityId] = nil
                meta.glyphBlockIds[entityId] = nil
                ::continue::
            end
        end,
    })
end

return text
