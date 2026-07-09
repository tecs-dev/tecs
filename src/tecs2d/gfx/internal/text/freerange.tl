--- Shared free-range bookkeeping for the glyph slab and glyph block
--- allocators. A free range is a {start, capacity} pair.
local record free_range
    --- Find and claim a free range with at least `needed` capacity.
    --- Searches from the end (most recently freed, likely still in cache)
    --- and swap-removes the claimed range from the list.
    --- Returns the range's start and capacity, or -1, 0 when none fits.
    find: function(freeRanges: {{integer, integer}}, needed: integer): integer, integer

    --- Insert a range into the free list, merging with any adjacent
    --- ranges so fragmentation doesn't grow unbounded.
    insert: function(freeRanges: {{integer, integer}}, start: integer, capacity: integer)
end

function free_range.find(freeRanges: {{integer, integer}}, needed: integer): integer, integer
    for i = #freeRanges, 1, -1 do
        local range = freeRanges[i]
        if range[2] >= needed then
            local start = range[1]
            local capacity = range[2]
            -- Swap-remove from the free list
            freeRanges[i] = freeRanges[#freeRanges]
            freeRanges[#freeRanges] = nil
            return start, capacity
        end
    end
    return -1, 0
end

function free_range.insert(freeRanges: {{integer, integer}}, start: integer, capacity: integer)
    if capacity <= 0 then return end

    -- Merge with adjacent ranges. Each merge swap-removes the absorbed
    -- range and rechecks the same slot, so chains of neighbors collapse
    -- into one range.
    local i = 1
    while i <= #freeRanges do
        local range = freeRanges[i]
        local rangeEnd = range[1] + range[2]
        local newEnd = start + capacity

        if rangeEnd == start then
            -- Range is immediately before us: merge
            start = range[1]
            capacity = capacity + range[2]
            freeRanges[i] = freeRanges[#freeRanges]
            freeRanges[#freeRanges] = nil
        elseif newEnd == range[1] then
            -- Range is immediately after us: merge
            capacity = capacity + range[2]
            freeRanges[i] = freeRanges[#freeRanges]
            freeRanges[#freeRanges] = nil
        else
            i = i + 1
        end
    end

    freeRanges[#freeRanges + 1] = {start, capacity}
end

return free_range
