--- Glyph Slab allocator for shared text layouts.
--- Multiple text entities with identical (text + font + scale) share the same layout data.
--- Reference-counted: layouts are freed when no entities use them.
--- Stores full GPU-ready glyph data (32 bytes per glyph) to eliminate UV lookup during sync.

local C <const> = require("ffi")
local bit <const> = require("bit")
local bmfont <const> = require("tecs2d.gfx.bmfont")

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
        hash: integer          -- Hash key for registry removal on release
        -- Collision detection fields (verify hash match)
        text: string           -- Original text for collision check
        fontKey: string        -- Font identifier for collision check
        sx: number             -- Scale X for collision check
        sy: number             -- Scale Y for collision check
    end

    --- The slab allocator
    record SlabAllocator
        --- The FFI slab buffer
        buffer: any  -- GlyphSlabEntry[?]

        --- Current capacity
        capacity: integer

        --- Next free slot
        nextSlot: integer

        --- Registry: hash → SlabEntry
        registry: {integer: SlabEntry}

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

-- Hash function for (fontPath + text + scale)
local function computeHash(fontPath: string, text: string, sx: number, sy: number): integer
    -- FNV-1a hash
    local hash = 2166136261
    local str = fontPath .. "\0" .. text .. "\0" .. tostring(sx) .. "\0" .. tostring(sy)
    for i = 1, #str do
        hash = bit.bxor(hash, str:byte(i))
        hash = hash * 16777619
        hash = bit.band(hash, 0xFFFFFFFF)  -- Keep 32-bit
    end
    return hash
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

    for i = 1, #text do
        local codepoint = text:byte(i)

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
                cursorX = cursorX + spaceChar.xadvance * sx * 4
            end
            prevCodepoint = nil
            goto continue
        end

        local char = font:getChar(codepoint)
        if not char then
            goto continue
        end

        -- Apply kerning if available
        if prevCodepoint then
            cursorX = cursorX + font:getKerning(prevCodepoint, codepoint) * sx
        end

        -- Store renderable glyphs (skip spaces)
        if codepoint ~= 32 and char.width > 0 and char.height > 0 then
            local entry = buffer[startOffset + glyphCount]
            -- Store full GPU-ready data (no lookup needed during sync)
            entry.localX = cursorX + char.xoffset * sx
            entry.localY = cursorY + char.yoffset * sy
            entry.uvX = char.x / atlasW
            entry.uvY = char.y / atlasH
            entry.uvW = char.width / atlasW
            entry.uvH = char.height / atlasH
            entry.glyphW = char.width * sx
            entry.glyphH = char.height * sy
            glyphCount = glyphCount + 1
        end

        -- Advance cursor
        cursorX = cursorX + char.xadvance * sx
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
    for i = 0, glyphCount - 1 do
        local entry = buffer[startOffset + i]
        entry.localX = entry.localX - pivotOffsetX
        entry.localY = entry.localY - pivotOffsetY
    end

    return glyphCount, maxWidth, height
end

-- Find a free range that fits the requested glyph count
-- Returns offset and capacity, or -1, 0 if none found
local function findFreeRange(allocator: glyph_slab.SlabAllocator, needed: integer): integer, integer
    local freeRanges = allocator.freeRanges
    -- Search from end (most recently freed, likely still in cache)
    for i = #freeRanges, 1, -1 do
        local range = freeRanges[i]
        if range[2] >= needed then
            local offset = range[1]
            local capacity = range[2]
            -- Remove from free list
            freeRanges[i] = freeRanges[#freeRanges]
            freeRanges[#freeRanges] = nil
            return offset, capacity
        end
    end
    return -1, 0
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
    local fontKey = font.face .. (font.page or "")
    local hash = computeHash(fontKey, text, sx, sy)

    -- Check if already exists (with collision detection)
    local existing = self.registry[hash]
    if existing then
        -- Verify it's actually the same text/font/scale (hash collision check)
        if existing.text == text and existing.fontKey == fontKey
           and existing.sx == sx and existing.sy == sy then
            existing.refCount = existing.refCount + 1
            return existing
        end
        -- Hash collision: fall through to create new entry with different hash
        -- Use linear probing to find an unused hash slot
        local probeHash = hash
        while self.registry[probeHash] do
            probeHash = probeHash + 1
        end
        hash = probeHash
    end

    -- Estimate max glyphs needed (worst case: all printable)
    local maxGlyphs = #text

    -- Try to find a free range first
    local startOffset, allocatedCapacity = findFreeRange(self, maxGlyphs)

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

    -- Create entry with collision detection fields
    local entry: glyph_slab.SlabEntry = {
        offset = startOffset,
        count = glyphCount,
        capacity = allocatedCapacity,
        refCount = 1,
        width = width,
        height = height,
        fontId = fontId,
        hash = hash,
        text = text,
        fontKey = fontKey,
        sx = sx,
        sy = sy,
    }

    self.registry[hash] = entry

    return entry
end

function SlabAllocator:release(entry: glyph_slab.SlabEntry)
    entry.refCount = entry.refCount - 1
    if entry.refCount <= 0 then
        -- Remove from registry so the hash can be reused
        self.registry[entry.hash] = nil

        -- Add to free list with coalescing
        if entry.capacity > 0 then
            local newOffset = entry.offset
            local newCapacity = entry.capacity
            local freeRanges = self.freeRanges

            -- Try to coalesce with existing ranges
            local i = 1
            while i <= #freeRanges do
                local range = freeRanges[i]
                local rangeEnd = range[1] + range[2]
                local newEnd = newOffset + newCapacity

                if rangeEnd == newOffset then
                    -- Range is immediately before us: merge
                    newOffset = range[1]
                    newCapacity = newCapacity + range[2]
                    -- Remove merged range
                    freeRanges[i] = freeRanges[#freeRanges]
                    freeRanges[#freeRanges] = nil
                    -- Don't increment i, check same slot again
                elseif newEnd == range[1] then
                    -- Range is immediately after us: merge
                    newCapacity = newCapacity + range[2]
                    -- Remove merged range
                    freeRanges[i] = freeRanges[#freeRanges]
                    freeRanges[#freeRanges] = nil
                    -- Don't increment i, check same slot again
                else
                    i = i + 1
                end
            end

            -- Add the (possibly coalesced) range
            freeRanges[#freeRanges + 1] = {newOffset, newCapacity}
        end
    end
end

function SlabAllocator:getDataPtr(): any
    return self.buffer
end

function SlabAllocator:getFontId(font: bmfont.BMFont): integer
    local existing = self.fontRegistry[font.atlas]
    if existing then
        return existing
    end

    local fontId = self.nextFontId
    self.fontRegistry[font.atlas] = fontId
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
