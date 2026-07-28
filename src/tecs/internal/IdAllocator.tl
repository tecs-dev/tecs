--[[
Packed-id allocator

Terminology:
- Public "id": a packed numeric entity identity returned from world:spawn and passed to world:* methods.
  Two parts packed via plain arithmetic: a 22-bit `slot` (allocator index, up to 4M) and a 31-bit `generation`
  (for ABA staleness detection, up to 2^31 ≈ 2.1B). Total 53 bits, so every id is representable exactly by a double.
- Internal "slot": allocator index used by hot transaction paths. Public API entry points decode id -> slot once, then
  operate on slot metadata.

All pack/unpack operations are declared as `macroexp` fields on the module record, so every use site inlines the
arithmetic.

Recycling:
Slot recycling: a LIFO free stack lets despawn recycle slot indices (keeps memory bounded under long-run churn).
Most-recently-freed slot wins, which is cache-friendly and needs no head/tail arithmetic.

Capacity:
Slot table and free stack are sized to maxSlotCount upfront. No grow path.

Slot 0 is reserved as the "null entity" sentinel: never allocated, always dead. `nextFreshSlot` starts at 1.
]]

local C <const> = require("ffi")

C.cdef([[
typedef struct TecsEntitySlot {
    uint32_t generation;
    uint32_t archetypeId;
    uint32_t row;
} TecsEntitySlot;
]])

local SLOT_ARRAY_T <const> = C.typeof("TecsEntitySlot[?]")
local UINT32_ARRAY_T <const> = C.typeof("uint32_t[?]")

local floor <const> = math.floor

local SLOT_BITS <const> = 22
local GEN_BITS <const> = 31
local SLOT_COUNT <const>: integer = (2 ^ 22) as integer
local GEN_COUNT <const>: integer = (2 ^ 31) as integer

-- Per-world ceilings. Default sizes the allocator for ~1M entities;
-- callers may raise up to the usable format cap (2^22 - 1, ~4M).
-- Slot 0 is reserved, so a 22-bit slot field has 2^22 - 1 usable values.
local ABSOLUTE_MAX_SLOT_COUNT <const> = SLOT_COUNT - 1 -- 4194303 usable slots
local DEFAULT_MAX_SLOT_COUNT <const> = 1048576 -- ~1M (2^20)

local record IdAllocator

    -- Bit widths (information only; encoding uses arithmetic)
    SLOT_BITS: integer
    GEN_BITS: integer

    -- Counts (exposed for callers that need upper bounds)
    SLOT_COUNT: integer
    GEN_COUNT: integer

    ABSOLUTE_MAX_SLOT_COUNT: integer
    DEFAULT_MAX_SLOT_COUNT: integer

    --- Teal typing for the per-slot FFI struct.
    record EntitySlot
        generation: integer
        archetypeId: integer
        row: integer
    end

    slots: {integer: EntitySlot}
    maxSlotCount: integer
    nextFreshSlot: integer

    -- LIFO free stack
    freeStack: {integer: integer} -- C.CData: uint32_t[maxSlotCount]
    freeCount: integer -- number of slots currently on the stack

    new: function(maxSlotCount?: integer): IdAllocator
    allocSlot: function(allocator: IdAllocator): integer
    allocContiguousSlots: function(allocator: IdAllocator, count: integer): integer
    freeSlot: function(allocator: IdAllocator, slot: integer)
    unfree: function(allocator: IdAllocator, slot: integer)
    rebuildFreeStack: function(allocator: IdAllocator)

    -- ----- Pack/unpack macroexps -----
    -- Declared as `macroexp` so every callsite inlines the arithmetic
    -- with the stride baked in as a KNUM. No function dispatch.

    --- Pack (slot, generation) into a packed id.
    encodeId: function(slot: integer, generation: integer): integer
        = macroexp(slot: integer, generation: integer): integer
            return slot + generation * 2 ^ 22
        end

    --- Extract slot from an id (low 22 bits).
    slotOf: function(id: integer): integer = macroexp(id: integer): integer
        return id % 2 ^ 22
    end

    --- Extract generation from an id. Uses `floor(id / 2^22)` so the
    --- caller does not need slot in hand; if you already have slot,
    --- prefer `generationOfWithSlot` to avoid the floor call.
    generationPartOf: function(id: integer): integer = macroexp(id: integer): integer
        return math.floor(id / 2 ^ 22)
    end

    --- Extract generation from an id given the caller already computed
    --- slot. `(id - slot)` is an exact multiple of 2^22, so the
    --- division produces an integer directly, with no floor or modulo.
    generationOfWithSlot: function(id: integer, slot: integer): integer = macroexp(id: integer, slot: integer): integer
        return (id - slot) / 2 ^ 22
    end

    --- True when a packed id's generation does not match the slot's
    --- sidecar generation: the handle is stale (slot recycled) or dead
    --- (slot freed). Mutation-path guards inline this to one compare;
    --- the floor form keeps each macroexp argument single-use.
    isStale: function(slots: {integer: EntitySlot}, id: integer, slot: integer): boolean
        = macroexp(slots: {integer: EntitySlot}, id: integer, slot: integer): boolean
            return math.floor(id / 2 ^ 22) ~= slots[slot].generation
        end

    reset: function(allocator: IdAllocator)
end

IdAllocator.SLOT_BITS = SLOT_BITS
IdAllocator.GEN_BITS = GEN_BITS
IdAllocator.SLOT_COUNT = SLOT_COUNT
IdAllocator.GEN_COUNT = GEN_COUNT
IdAllocator.ABSOLUTE_MAX_SLOT_COUNT = ABSOLUTE_MAX_SLOT_COUNT
IdAllocator.DEFAULT_MAX_SLOT_COUNT = DEFAULT_MAX_SLOT_COUNT

function IdAllocator.new(maxSlotCount?: integer): IdAllocator
    local n = maxSlotCount or DEFAULT_MAX_SLOT_COUNT
    if n < 1 or n ~= floor(n) then
        error("IdAllocator.new: maxSlotCount must be a positive integer, got " .. tostring(n))
    end
    if n > ABSOLUTE_MAX_SLOT_COUNT then
        error(
            "IdAllocator.new: maxSlotCount "
                .. n
                .. " exceeds format limit "
                .. ABSOLUTE_MAX_SLOT_COUNT
                .. " (packed id has "
                .. SLOT_BITS
                .. " bits for slot)"
        )
    end
    return {
        -- Index 0 is the null sentinel; configured slots are 1..n.
        slots = C.new(SLOT_ARRAY_T, n + 1) as C.CData,
        maxSlotCount = n,
        nextFreshSlot = 1, -- slot 0 reserved as null
        freeStack = C.new(UINT32_ARRAY_T, n),
        freeCount = 0,
    } as IdAllocator
end

function IdAllocator.allocSlot(allocator: IdAllocator): integer
    local freeCount = allocator.freeCount
    if freeCount > 0 then
        freeCount = freeCount - 1
        allocator.freeCount = freeCount
        -- Gen was bumped by freeSlot; archetypeId is already 0.
        return allocator.freeStack[freeCount]
    end

    local slot = allocator.nextFreshSlot
    if slot > allocator.maxSlotCount then
        error("entity ID exhaustion: maxSlotCount (" .. allocator.maxSlotCount .. ") reached")
    end

    allocator.nextFreshSlot = slot + 1
    -- Fresh slot: already zero from ffi.new.
    return slot
end

function IdAllocator.allocContiguousSlots(allocator: IdAllocator, count: integer): integer
    if count < 1 or count ~= floor(count) then
        error("IdAllocator.allocContiguousSlots: count must be a positive integer, got " .. tostring(count))
    end
    -- Contiguous allocation only uses the fresh region. Freed slots in
    -- freeStack are intentionally bypassed here.
    local firstSlot = allocator.nextFreshSlot
    local newNext = firstSlot + count
    if newNext > allocator.maxSlotCount + 1 then
        error("entity slot exhaustion: maxSlotCount (" .. allocator.maxSlotCount .. ") reached")
    end
    allocator.nextFreshSlot = newNext
    return firstSlot
end

function IdAllocator.freeSlot(allocator: IdAllocator, slot: integer)
    -- Hot per-entity despawn: mark dead, bump generation, push slot.
    --
    -- `row` is intentionally not zeroed: no reader should use row when
    -- archetypeId == 0, and placement writes row before reuse.
    --
    -- Generation wraps at 2^31 so packed ids stay below 2^53.
    -- Branch wrap is cheaper than `% GEN_COUNT`.
    --
    -- No free-stack overflow check: capacity equals maxSlotCount and
    -- slot 0 is reserved, so every allocatable slot can be stacked.
    local s = allocator.slots[slot]
    s.archetypeId = 0
    local g = s.generation + 1
    if g == GEN_COUNT then
        g = 0
    end
    s.generation = g
    local freeCount = allocator.freeCount
    allocator.freeStack[freeCount] = slot
    allocator.freeCount = freeCount + 1
end

--- Rebuild the free stack from slot liveness. Snapshot loads restore
--- entities at their saved slots; every dead slot below the watermark
--- must return to the stack or its id range is stranded.
function IdAllocator.rebuildFreeStack(allocator: IdAllocator)
    local slots = allocator.slots
    local stack = allocator.freeStack
    local n = 0
    for slot = 1, allocator.nextFreshSlot - 1 do
        if slots[slot].archetypeId == 0 then
            stack[n] = slot
            n = n + 1
        end
    end
    allocator.freeCount = n
end

--- Remove `slot` from the free stack if present. spawnAt-style staking
--- revives specific slots; leaving one on the stack lets a later
--- allocSlot hand it out again and alias two live entities. O(freeCount)
--- scan; callers skip it for fresh-range slots, which are never stacked.
function IdAllocator.unfree(allocator: IdAllocator, slot: integer)
    local stack = allocator.freeStack
    local n = allocator.freeCount
    for i = 0, n - 1 do
        if stack[i] == slot then
            stack[i] = stack[n - 1]
            allocator.freeCount = n - 1
            return
        end
    end
end

function IdAllocator.reset(allocator: IdAllocator)
    -- Full wipe for clearEntities. Invalidate every touched slot by
    -- raising every generation past the prefix maximum, then clear
    -- placement metadata. The uniform value keeps the recycled prefix
    -- single-generation, so contiguous batch handles only need to check
    -- the range ends against each other.
    local usedLimit = allocator.nextFreshSlot - 1
    if usedLimit > 0 then
        local slots = allocator.slots
        local maxGen = 0
        for slot = 1, usedLimit do
            local g = slots[slot].generation
            if g > maxGen then
                maxGen = g
            end
        end
        local newGen = maxGen + 1
        if newGen >= GEN_COUNT then
            newGen = 0
        end
        for slot = 1, usedLimit do
            local s = slots[slot]
            s.archetypeId = 0
            s.row = 0
            s.generation = newGen
        end
    end
    allocator.nextFreshSlot = 1
    allocator.freeCount = 0
end

return IdAllocator
