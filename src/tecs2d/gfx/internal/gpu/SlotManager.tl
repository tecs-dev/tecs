--- GPU Slot Manager - manages stable GPU buffer slots via free-list allocation.
--- Each drawable component type gets its own SlotManager for compact buffer usage.

local record SlotManager
    --- Free list of available slots (LIFO for cache friendliness)
    freeList: {integer}

    --- Next slot to allocate when free list is empty
    nextSlot: integer

    --- Allocate a slot (reuses freed slots or allocates new)
    allocate: function(SlotManager): integer

    --- Free a slot (returns it to the free list for reuse)
    free: function(SlotManager, slot: integer)

    --- Get the current high-water mark (max slot ever allocated)
    getHighWaterMark: function(SlotManager): integer

    --- Create a new SlotManager
    new: function(): SlotManager
end

local SLOT_MANAGER_MT <const>: metatable<SlotManager> = {
    __index = SlotManager
}

function SlotManager:allocate(): integer
    local freeList = self.freeList
    local freeCount = #freeList

    if freeCount > 0 then
        -- Reuse from free list (pop from end for O(1))
        local slot = freeList[freeCount]
        freeList[freeCount] = nil
        return slot
    end

    -- Allocate new slot
    local slot = self.nextSlot
    self.nextSlot = slot + 1
    return slot
end

function SlotManager:free(slot: integer)
    -- Add to free list for reuse
    self.freeList[#self.freeList + 1] = slot
end

function SlotManager:getHighWaterMark(): integer
    return self.nextSlot
end

function SlotManager.new(): SlotManager
    local self: SlotManager = {
        freeList = {},
        nextSlot = 0,  -- Slots are 0-indexed for GPU buffer compatibility
    }
    return setmetatable(self, SLOT_MANAGER_MT)
end

return SlotManager
