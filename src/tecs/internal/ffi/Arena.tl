--- General-purpose FFI Arena for managing POD type memory with LuaJIT FFI.
--- Uses page-based allocation with handle packing for efficient memory management.

local libffi = require("tecs.internal.ffi.libffi")
local floor <const> = math.floor

-- Check FFI availability first - Arena is only usable with FFI
local ffiAvailable <const> = libffi.isFFIAvailable()
local ffi_native = ffiAvailable and libffi.getFFI() or nil

local EPOCH_BITS <const> = 21
local PAGE_BITS <const> = 12
local ROW_BITS <const> = 12
local EPOCH_MULTIPLIER <const> = (2 ^ (PAGE_BITS + ROW_BITS)) as integer
local PAGE_MULTIPLIER <const> = (2 ^ ROW_BITS) as integer
local EPOCH_MASK <const> = 2 ^ EPOCH_BITS - 1
local DEFAULT_PAGE_SIZE <const> = 4096

--- Arena used to manage FFI memory for a type `T`.
--- Pages never move during a frame; clear() invalidates all prior handles.
local record Arena<T>
    --- Current epoch (bumped on clear); embedded into handles to invalidate old ones.
    epoch: integer

    --- All pages owned by this arena.
    pages: {Page<T>}

    --- Current page index used for appends (1-based).
    currentPage: integer

    --- FFI type string for creating arrays (e.g., "float[?]", "struct MyStruct[?]")
    ffiType: string

    --- Element size in bytes
    elemSize: integer

    --- Page allocation size (can be smaller than PAGE_SIZE for memory efficiency)
    pageAllocSize: integer

    record Page<U>
        --- FFI cdata array for this page
        data: any  -- Actually a cdata array

        --- Capacity (number of elements) in this page
        capacity: integer

        --- Used element count in this page for the current frame
        count: integer
    end

    --- Create a new FFI arena.
    ---
    --- @param ffiType The FFI type string (e.g., "float", "int32_t", "struct MyStruct")
    --- @param elemSize Size of each element in bytes
    --- @param initialPageSize Initial page size (defaults to 4096)
    --- @return the created arena.
    new: function<U>(ffiType: string, elemSize: integer, initialPageSize?: integer): Arena<U>

    --- Ensures that the arena has at least size capacity.
    ---
    --- @param size The desired element capacity size.
    ensureCapacity: function(self, size: integer)

    --- Clears usage for the next frame, and invalidates all prior handles via a generation bump.
    --- @return nil
    clear: function(self)

    --- Vends (reserves) one slot from the arena for this frame.
    --- No per-entity malloc is performed; slots come from preallocated pages.
    ---
    --- @param id Entity id or caller-supplied correlation token (not used by the arena itself).
    --- @return A handle ID pointing to the reserved slot (valid until clear()).
    vend: function(self, _: integer): integer

    --- Borrows a raw pointer to the element for immediate, short-lived use.
    --- For FFI POD backends this returns the array and index.
    --- The returned pointer becomes invalid after `clear()` (or if the handle's generation mismatches).
    ---
    --- @param handle Handle obtained from `vend`.
    --- @return FFI array cdata and 1-based index, or nil if stale/invalid.
    borrow: function(self, handle: integer): any, integer

    --- Stores a value into the slot identified by `handle`.
    --- Overwrites are allowed; returns `true` on success and `false` if the handle is stale/invalid.
    ---
    --- @param handle Handle obtained from `vend`.
    --- @param value Value to store (must be compatible with the arena's POD type).
    --- @return boolean `true` if written; `false` if handle/gen invalid.
    write: function(self, handle: integer, value: T): boolean

    --- Get all pages with data for bulk copying.
    --- @return Array of pages with non-zero count.
    getPages: function(self): {Page<T>}
end

local ARENA_MT <const> = { __index = Arena }

local ffi = ffiAvailable and ffi_native or nil
local ffi_new = ffiAvailable and ffi.new or nil

local function packHandle(epoch: integer, page: integer, row: integer): integer
    -- Use multiplication to pack values (safe in Lua's 53-bit integer range)
    return epoch * EPOCH_MULTIPLIER + page * PAGE_MULTIPLIER + row
end

local function unpackHandle(handle: integer): integer, integer, integer
    -- Use division and modulo to unpack (avoiding bit operations)
    local row = floor(handle % PAGE_MULTIPLIER)
    local remaining = floor(handle / PAGE_MULTIPLIER)
    local page = floor(remaining % (2^PAGE_BITS))
    local epoch = floor(remaining / (2^PAGE_BITS))
    return epoch, page, row
end

function Arena.new<T>(ffiType: string, elemSize: integer, initialPageSize?: integer): Arena<T>
    if not ffiAvailable then
        error("Arena requires FFI support - cannot create Arena when FFI is not available")
    end

    local self: Arena<T> = {
        epoch = 0,
        pages = {},
        currentPage = 0,
        ffiType = ffiType .. "[?]",  -- Convert to array type
        elemSize = elemSize,
        pageAllocSize = initialPageSize or DEFAULT_PAGE_SIZE,
    }
    return setmetatable(self, ARENA_MT)
end

function Arena:ensureCapacity(size: integer)
    -- Calculate how many pages we need
    local pagesNeeded = math.ceil(size / self.pageAllocSize as number)

    -- Allocate pages if needed
    while #self.pages < pagesNeeded do
        local pageCapacity = self.pageAllocSize

        -- Allocate with one extra element for 1-based indexing
        local data = ffi_new(self.ffiType, pageCapacity + 1)

        local newPage: Arena.Page<T> = {
            data = data,
            capacity = pageCapacity,
            count = 0,
        }

        self.pages[#self.pages + 1] = newPage
    end

    -- Set current page if not set
    if self.currentPage == 0 and #self.pages > 0 then
        self.currentPage = 1
    end
end

function Arena:clear()
    -- Bump epoch to invalidate all handles
    self.epoch = (self.epoch + 1) % (EPOCH_MASK + 1) as integer

    -- Reset all page counts but keep the memory allocated
    for i = 1, #self.pages do
        local page = self.pages[i]
        page.count = 0
    end

    -- Reset to first page if we have any
    self.currentPage = #self.pages > 0 and 1 or 0
end

function Arena:vend(_: integer): integer
    -- Ensure we have a current page
    if self.currentPage == 0 or
       (self.pages[self.currentPage].count >= self.pages[self.currentPage].capacity) then
        -- Need to move to next page or allocate
        local nextPage = self.currentPage + 1

        if nextPage > #self.pages then
            -- Allocate new page
            local pageCapacity = self.pageAllocSize
            local data = ffi_new(self.ffiType, pageCapacity + 1)

            local newPage: Arena.Page<T> = {
                data = data,
                capacity = pageCapacity,
                count = 0,
            }
            self.pages[nextPage] = newPage
        end

        self.currentPage = nextPage
    end

    local page = self.pages[self.currentPage]
    local row = page.count
    page.count = page.count + 1

    -- Pack handle with current epoch, page index (0-based), and row
    return packHandle(self.epoch, self.currentPage - 1, row)
end

function Arena:borrow(handle: integer): any, integer
    local epoch, pageIdx, row = unpackHandle(handle)

    -- Check epoch validity
    if epoch ~= self.epoch then
        return nil, 0
    end

    -- Convert to 1-based page index
    pageIdx = pageIdx + 1

    -- Check page bounds
    if pageIdx < 1 or pageIdx > #self.pages then
        return nil, 0
    end

    local page = self.pages[pageIdx]

    -- Check row bounds
    if row >= page.count then
        return nil, 0
    end

    -- Return the FFI array and let caller index with row + 1
    -- This avoids pointer arithmetic issues in Teal
    -- Caller will need to use: array[row + 1] where row comes from unpacking the handle
    return page.data, row + 1
end

function Arena:write(handle: integer, value: T): boolean
    local epoch, pageIdx, row = unpackHandle(handle)

    -- Check epoch validity
    if epoch ~= self.epoch then
        return false
    end

    -- Convert to 1-based page index
    pageIdx = pageIdx + 1

    -- Check page bounds
    if pageIdx < 1 or pageIdx > #self.pages then
        return false
    end

    local page = self.pages[pageIdx]

    -- Check row bounds
    if row >= page.count then
        return false
    end

    -- Store value (row + 1 for 1-based FFI array indexing)
    local array = page.data as {T}
    array[row + 1] = value
    return true
end

function Arena:getPages(): {Arena.Page<T>}
    local activePages: {Arena.Page<T>} = {}
    for i = 1, self.currentPage do
        local page = self.pages[i]
        if page and page.count > 0 then
            activePages[#activePages + 1] = page
        end
    end
    return activePages
end

return Arena