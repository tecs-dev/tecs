--- GlyphBlockAllocator: Stable GPU glyph slot allocation for text entities.
---
--- Each text entity gets a "glyph block" with a stable position in the GPU buffer.
--- When text changes, only that entity's block is updated - no need to rebuild all.
--- Blocks can grow in place if capacity allows, or reallocate to larger slots.

local ffi <const> = require("ffi")
local ChunkedArray <const> = require("tecs.internal.ffi.StableChunkedArray")
local free_range <const> = require("tecs2d.gfx.internal.text.free_range")

-- Define the block metadata struct
ffi.cdef[[
typedef struct {
    int32_t gpuStartIdx;   // Start index in GPU glyph buffer (stable)
    int32_t capacity;      // Reserved capacity (glyph count)
    int32_t count;         // Current glyph count
    int32_t refCount;      // Reference count (for potential sharing)
} GlyphBlockFFI;
]]

local record glyph_block
    --- A glyph block (stable GPU buffer slot range)
    record GlyphBlock
        gpuStartIdx: integer   -- Start index in GPU glyph buffer
        capacity: integer      -- Reserved capacity
        count: integer         -- Current glyph count
        refCount: integer      -- Reference count
    end

    --- The block allocator
    record GlyphBlockAllocator
        --- Block metadata storage (uses ChunkedArray for stable pointers)
        blocks: ChunkedArray.ChunkedArray

        --- GPU slot allocation tracking
        nextGpuSlot: integer        -- Next free GPU slot
        freeRanges: {{integer, integer}}  -- Free ranges: {start, capacity}

        --- Allocate a new block with given capacity
        alloc: function(self: GlyphBlockAllocator, glyphCount: integer): integer, GlyphBlock

        --- Get block by ID
        get: function(self: GlyphBlockAllocator, blockId: integer): GlyphBlock

        --- Resize a block (returns new block if reallocation needed)
        resize: function(self: GlyphBlockAllocator, blockId: integer, newCount: integer): boolean

        --- Free a block
        free: function(self: GlyphBlockAllocator, blockId: integer)

        --- Get total GPU slots allocated
        getTotalGpuSlots: function(self: GlyphBlockAllocator): integer

        --- Get debug statistics: allocatedBlocks, nextGpuSlot, freeRangesCount, totalFreeSlots
        getStats: function(self: GlyphBlockAllocator): integer, integer, integer, integer
    end

    --- Create a new block allocator
    new: function(): GlyphBlockAllocator
end

local GlyphBlockAllocator <const> = glyph_block.GlyphBlockAllocator
local ALLOC_MT <const>: metatable<GlyphBlockAllocator> = { __index = GlyphBlockAllocator }

-- Default block capacity multiplier (allocate extra space for growth)
local CAPACITY_MULTIPLIER <const> = 1.5
local MIN_BLOCK_CAPACITY <const> = 16

-- Add range to free list, merging with adjacent ranges
local function addFreeRange(self: glyph_block.GlyphBlockAllocator, start: integer, capacity: integer)
    free_range.insert(self.freeRanges, start, capacity)
end

function GlyphBlockAllocator:alloc(glyphCount: integer): integer, glyph_block.GlyphBlock
    -- Calculate capacity with growth room
    local capacity = math.max(
        MIN_BLOCK_CAPACITY,
        math.ceil(glyphCount * CAPACITY_MULTIPLIER)
    )

    -- Try to find existing free range
    local gpuStart, actualCapacity = free_range.find(self.freeRanges, capacity)

    if gpuStart < 0 then
        -- Allocate new GPU slots at end
        gpuStart = self.nextGpuSlot
        actualCapacity = capacity
        self.nextGpuSlot = self.nextGpuSlot + capacity
    end

    -- Allocate block ID using ChunkedArray
    local blockId = self.blocks:alloc()
    local block = self.blocks:get(blockId) as glyph_block.GlyphBlock

    -- Initialize block
    block.gpuStartIdx = gpuStart
    block.capacity = actualCapacity
    block.count = glyphCount
    block.refCount = 1

    return blockId, block
end

function GlyphBlockAllocator:get(blockId: integer): glyph_block.GlyphBlock
    if blockId < 1 then return nil end
    local block = self.blocks:get(blockId) as glyph_block.GlyphBlock
    if block and block.refCount > 0 then
        return block
    end
    return nil
end

function GlyphBlockAllocator:resize(blockId: integer, newCount: integer): boolean
    local block = self.blocks:get(blockId) as glyph_block.GlyphBlock
    if not block or block.refCount <= 0 then
        return false
    end

    if newCount <= block.capacity then
        -- Fits in current allocation
        block.count = newCount
        return true
    end

    -- Need to reallocate
    local oldStart = block.gpuStartIdx
    local oldCapacity = block.capacity

    -- Calculate new capacity
    local newCapacity = math.max(
        MIN_BLOCK_CAPACITY,
        math.ceil(newCount * CAPACITY_MULTIPLIER)
    )

    -- Try to find existing free range
    local gpuStart, actualCapacity = free_range.find(self.freeRanges, newCapacity)

    if gpuStart < 0 then
        -- Allocate at end
        gpuStart = self.nextGpuSlot
        actualCapacity = newCapacity
        self.nextGpuSlot = self.nextGpuSlot + newCapacity
    end

    -- Update block
    block.gpuStartIdx = gpuStart
    block.capacity = actualCapacity
    block.count = newCount

    -- Free old range
    addFreeRange(self, oldStart, oldCapacity)

    return true
end

function GlyphBlockAllocator:free(blockId: integer)
    local block = self.blocks:get(blockId) as glyph_block.GlyphBlock
    if not block or block.refCount <= 0 then
        return
    end

    block.refCount = block.refCount - 1
    if block.refCount <= 0 then
        -- Free GPU range
        addFreeRange(self, block.gpuStartIdx, block.capacity)
        -- Free block ID
        self.blocks:free(blockId)
    end
end

function GlyphBlockAllocator:getTotalGpuSlots(): integer
    return self.nextGpuSlot
end

--- Get debug statistics for memory monitoring.
--- Returns: allocated blocks, nextGpuSlot (high water mark), free ranges count, total free slots
function GlyphBlockAllocator:getStats(): integer, integer, integer, integer
    -- Calculate allocated count: nextId - 1 (total ever allocated) minus freed ones
    local blocks = self.blocks as ChunkedArray.ChunkedArray
    local allocatedCount = blocks.nextId - 1 - #blocks.freeIds
    local freeRangesCount = #self.freeRanges
    local totalFreeSlots = 0
    for _, range in ipairs(self.freeRanges) do
        totalFreeSlots = totalFreeSlots + range[2]
    end
    return allocatedCount, self.nextGpuSlot, freeRangesCount, totalFreeSlots
end

function glyph_block.new(): glyph_block.GlyphBlockAllocator
    local allocator: glyph_block.GlyphBlockAllocator = {
        blocks = ChunkedArray.new("GlyphBlockFFI", 256),
        nextGpuSlot = 0,
        freeRanges = {},
    }

    return setmetatable(allocator, ALLOC_MT)
end

return glyph_block
