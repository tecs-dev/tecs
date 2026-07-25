--- Glyph Slab allocator for shared text layouts.
--- Multiple text entities with identical (text + font + scale) share the same layout data.
--- Reference-counted: layouts are freed when no entities use them.
--- Stores full GPU-ready glyph data (32 bytes per glyph) to eliminate UV lookup during sync.

local C <const> = require("ffi")
local bit <const> = require("bit")
local bmfont <const> = require("tecs2d.gfx.bmfont")
local freerange <const> = require("tecs2d.gfx.internal.text.freerange")

-- Layout dedup needs object identity, but that renderer detail should not be
-- part of the public BMFont contract.
local fontIdentities <const>: {bmfont.BMFont: integer} =
    setmetatable({}, {__mode = "k"} as metatable<{bmfont.BMFont: integer}>)
local nextFontIdentity = 1

local function fontIdentity(font: bmfont.BMFont): integer
    local identity = fontIdentities[font]
    if identity then return identity end
    identity = nextFontIdentity
    nextFontIdentity = identity + 1
    fontIdentities[font] = identity
    return identity
end

-- Define the slab entry struct (32 bytes per glyph, matches GPUGlyphData exactly)
C.cdef[[
    typedef struct {
        float localX, localY;    // Position relative to text entity origin
        float uvX, uvY;          // UV origin in atlas (normalized)
        float uvW, uvH;          // UV size in atlas (normalized)
        float glyphW, glyphH;    // Glyph pixel dimensions (scaled)
    } GlyphSlabEntry;
]]

local record glyph_slab
    --- A single entry in the glyph slab (32 bytes, matches GPUGlyphData)
    record GlyphSlabEntry
        localX: number         -- Position relative to entity origin
        localY: number
        uvX: number            -- UV origin (normalized 0-1)
        uvY: number
        uvW: number            -- UV size (normalized)
        uvH: number
        glyphW: number         -- Glyph pixel dimensions (scaled)
        glyphH: number
    end

    --- A registered slab entry (shared layout for multiple entities)
    record SlabEntry
        offset: integer        -- Start index in the slab buffer
        count: integer         -- Number of glyphs (actual used)
        capacity: integer      -- Allocated capacity (for free list)
        refCount: integer      -- Number of entities using this layout
        width: number          -- Cached text width (scaled)
        height: number         -- Cached text height (scaled)
        fontId: integer        -- Font ID for atlas layer lookup
        key: string            -- Registry key (font uid + text + scale)
    end

    --- The slab allocator
    record SlabAllocator
        --- The FFI slab buffer
        buffer: any  -- GlyphSlabEntry[?]

        --- Current capacity
        capacity: integer

        --- Next free slot
        nextSlot: integer

        --- Registry: composite key (font uid + text + scale) → SlabEntry.
        --- Plain string keys make dedup exact; there is no hashing to
        --- collide and no probing to corrupt on release.
        registry: {string: SlabEntry}

        --- Free ranges: {offset, count} pairs for reclaimed slots
        freeRanges: {{integer, integer}}

        --- Font registry: font atlas → fontId
        fontRegistry: {love.graphics.Image: integer}
        nextFontId: integer

        --- Acquire a slab entry for the given text/font/scale.
        --- Returns existing entry (increments refCount) or creates new one.
        acquire: function(
            self: SlabAllocator,
            font: bmfont.BMFont,
            text: string,
            sx: number,
            sy: number
        ): SlabEntry

        --- Release a slab entry (decrements refCount, frees if zero).
        release: function(self: SlabAllocator, entry: SlabEntry)

        --- Get the slab buffer data pointer
        getDataPtr: function(self: SlabAllocator): any

        --- Get or register a font ID
        getFontId: function(self: SlabAllocator, font: bmfont.BMFont): integer

        --- Get debug statistics: capacity, nextSlot, registryCount, memoryBytes
        getStats: function(self: SlabAllocator): integer, integer, integer, integer
    end

    --- Create a new slab allocator
    new: function(initialCapacity?: integer): SlabAllocator

    --- FFI type name
    SLAB_ENTRY_CTYPE: string
end

glyph_slab.SLAB_ENTRY_CTYPE = "GlyphSlabEntry"

local SlabAllocator <const> = glyph_slab.SlabAllocator
local SLAB_MT <const>: metatable<SlabAllocator> = { __index = SlabAllocator }

-- Decode the UTF-8 codepoint starting at byte i.
-- Returns the codepoint and the index of the next character. Malformed
-- bytes decode as U+FFFD-style fallback (the byte value) and advance by
-- one so bad input degrades to mojibake instead of skewing the layout.
local band <const> = bit.band
local bor <const> = bit.bor
local lshift <const> = bit.lshift
local function decodeUtf8(text: string, i: integer): integer, integer
    local b1 = text:byte(i)
    if b1 < 0x80 then
        return b1, i + 1
    elseif b1 >= 0xC0 and b1 < 0xE0 then
        local b2 = text:byte(i + 1)
        if not b2 then return b1, i + 1 end
        return bor(lshift(band(b1, 0x1F), 6), band(b2, 0x3F)), i + 2
    elseif b1 < 0xF0 then
        local b2, b3 = text:byte(i + 1), text:byte(i + 2)
        if not b3 then return b1, i + 1 end
        return bor(lshift(band(b1, 0x0F), 12), lshift(band(b2, 0x3F), 6), band(b3, 0x3F)), i + 3
    elseif b1 < 0xF8 then
        local b2, b3, b4 = text:byte(i + 1), text:byte(i + 2), text:byte(i + 3)
        if not b4 then return b1, i + 1 end
        return bor(lshift(band(b1, 0x07), 18), lshift(band(b2, 0x3F), 12),
            lshift(band(b3, 0x3F), 6), band(b4, 0x3F)), i + 4
    end
    return b1, i + 1
end

-- Compute glyph layout and write full GPU-ready data to slab buffer
local function computeLayout(
    allocator: glyph_slab.SlabAllocator,
    font: bmfont.BMFont,
    text: string,
    sx: number,
    sy: number,
    startOffset: integer
): integer, number, number
    local buffer = allocator.buffer as {integer: glyph_slab.GlyphSlabEntry}
    local cursorX = 0.0
    local cursorY = 0.0
    local maxWidth = 0.0
    local lineCount = 1
    local prevCodepoint: integer = nil
    local glyphCount = 0

    -- Atlas dimensions for UV normalization
    local atlasW = font.scaleW
    local atlasH = font.scaleH

    local i = 1
    local textLen = #text
    while i <= textLen do
        local codepoint: integer
        codepoint, i = decodeUtf8(text, i)

        -- Skip control characters (except newline and tab)
        if codepoint < 32 and codepoint ~= 9 and codepoint ~= 10 then
            goto continue
        end

        -- Handle newlines
        if codepoint == 10 then  -- '\n'
            if cursorX > maxWidth then
                maxWidth = cursorX
            end
            cursorX = 0
            cursorY = cursorY + font.lineHeight * sy
            lineCount = lineCount + 1
            prevCodepoint = nil
            goto continue
        end

        -- Handle tabs (4 spaces worth of advance)
        if codepoint == 9 then  -- '\t'
            local spaceChar = font:getChar(32)  -- space
            if spaceChar then
                local space = spaceChar as bmfont.BMFontChar
                cursorX = cursorX + space.xadvance * sx * 4
            end
            prevCodepoint = nil
            goto continue
        end

        local char = font:getChar(codepoint)
        if not char then
            goto continue
        end
        local glyph = char as bmfont.BMFontChar

        -- Apply kerning if available
        if prevCodepoint then
            cursorX = cursorX + font:getKerning(prevCodepoint, codepoint) * sx
        end

        -- Store renderable glyphs (skip spaces)
        if codepoint ~= 32 and glyph.width > 0 and glyph.height > 0 then
            local entry = buffer[startOffset + glyphCount]
            -- Store full GPU-ready data (no lookup needed during sync)
            entry.localX = cursorX + glyph.xoffset * sx
            entry.localY = cursorY + glyph.yoffset * sy
            entry.uvX = glyph.x / atlasW
            entry.uvY = glyph.y / atlasH
            entry.uvW = glyph.width / atlasW
            entry.uvH = glyph.height / atlasH
            entry.glyphW = glyph.width * sx
            entry.glyphH = glyph.height * sy
            glyphCount = glyphCount + 1
        end

        -- Advance cursor
        cursorX = cursorX + glyph.xadvance * sx
        prevCodepoint = codepoint

        ::continue::
    end

    if cursorX > maxWidth then
        maxWidth = cursorX
    end

    -- Height: lineHeight between lines, font.size for last line
    local height = ((lineCount - 1) * font.lineHeight + font.size) * sy

    -- Bake pivot offset (0.5, 0.5) into glyph positions
    -- This eliminates pivot math from the CPU hot path
    local pivotOffsetX = 0.5 * maxWidth
    local pivotOffsetY = 0.5 * height
    for g = 0, glyphCount - 1 do
        local entry = buffer[startOffset + g]
        entry.localX = entry.localX - pivotOffsetX
        entry.localY = entry.localY - pivotOffsetY
    end

    return glyphCount, maxWidth, height
end

-- Grow the slab buffer
local function growBuffer(allocator: glyph_slab.SlabAllocator, needed: integer)
    local newCapacity = allocator.capacity
    while newCapacity < needed do
        newCapacity = newCapacity * 2
    end

    local newBuffer = C.new("GlyphSlabEntry[?]", newCapacity)

    -- Copy old data
    if allocator.buffer and allocator.nextSlot > 0 then
        C.copy(newBuffer, allocator.buffer as C.CData, allocator.nextSlot * C.sizeof("GlyphSlabEntry"))
    end

    allocator.buffer = newBuffer
    allocator.capacity = newCapacity
end

function SlabAllocator:acquire(
    font: bmfont.BMFont,
    text: string,
    sx: number,
    sy: number
): glyph_slab.SlabEntry
    -- Font object identity (not face/page names, which collide across files) plus
    -- text and scale form an exact dedup key.
    local key = tostring(fontIdentity(font)) .. "\0" .. text .. "\0" ..
        tostring(sx) .. "\0" .. tostring(sy)

    local existing = self.registry[key]
    if existing then
        existing.refCount = existing.refCount + 1
        return existing
    end

    -- Estimate max glyphs needed (worst case: all printable; byte count
    -- is an upper bound on decoded codepoints)
    local maxGlyphs = #text

    -- Try to find a free range first
    local startOffset, allocatedCapacity = freerange.find(self.freeRanges, maxGlyphs)

    if startOffset < 0 then
        -- No suitable free range, allocate from end
        local neededCapacity = self.nextSlot + maxGlyphs
        if neededCapacity > self.capacity then
            growBuffer(self, neededCapacity)
        end
        startOffset = self.nextSlot
        allocatedCapacity = maxGlyphs
        -- Update high-water mark
        self.nextSlot = self.nextSlot + maxGlyphs
    end

    -- Compute layout and write to buffer
    local glyphCount, width, height = computeLayout(self, font, text, sx, sy, startOffset)

    -- Range splitting: if we allocated more than needed, put remainder back
    local usedCapacity = glyphCount
    if allocatedCapacity > usedCapacity + 4 then  -- Only split if remainder is worthwhile (>4 slots)
        local remainderOffset = startOffset + usedCapacity
        local remainderCapacity = allocatedCapacity - usedCapacity
        self.freeRanges[#self.freeRanges + 1] = {remainderOffset, remainderCapacity}
        allocatedCapacity = usedCapacity
    end

    -- Get or register font ID
    local fontId = self:getFontId(font)

    local entry: glyph_slab.SlabEntry = {
        offset = startOffset,
        count = glyphCount,
        capacity = allocatedCapacity,
        refCount = 1,
        width = width,
        height = height,
        fontId = fontId,
        key = key,
    }

    self.registry[key] = entry

    return entry
end

function SlabAllocator:release(entry: glyph_slab.SlabEntry)
    entry.refCount = entry.refCount - 1
    if entry.refCount <= 0 then
        self.registry[entry.key] = nil
        freerange.insert(self.freeRanges, entry.offset, entry.capacity)
    end
end

function SlabAllocator:getDataPtr(): any
    return self.buffer
end

function SlabAllocator:getFontId(font: bmfont.BMFont): integer
    local atlas = assert(font.atlas, "BMFont atlas must be attached before layout")
    local existing = self.fontRegistry[atlas]
    if existing then
        return existing
    end

    local fontId = self.nextFontId
    self.fontRegistry[atlas] = fontId
    self.nextFontId = fontId + 1
    return fontId
end

--- Get debug statistics for memory monitoring.
--- Returns: capacity, nextSlot (high water mark), registry entry count, free slots count
function SlabAllocator:getStats(): integer, integer, integer, integer
    local registryCount = 0
    for _ in pairs(self.registry) do
        registryCount = registryCount + 1
    end
    local freeSlots = 0
    for _, range in ipairs(self.freeRanges) do
        freeSlots = freeSlots + range[2]
    end
    return self.capacity, self.nextSlot, registryCount, freeSlots
end

function glyph_slab.new(initialCapacity?: integer): glyph_slab.SlabAllocator
    -- Default: 64K glyphs = 2MB (32 bytes each)
    local capacity = initialCapacity or 65536

    local allocator: glyph_slab.SlabAllocator = {
        buffer = C.new("GlyphSlabEntry[?]", capacity),
        capacity = capacity,
        nextSlot = 0,
        registry = {},
        freeRanges = {},
        fontRegistry = {},
        nextFontId = 0,
    }

    return setmetatable(allocator, SLAB_MT)
end

return glyph_slab
