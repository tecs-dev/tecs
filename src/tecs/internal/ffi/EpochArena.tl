--[=[
Epoch-local FFI arena for managing memory with LuaJIT FFI.
Uses page-based allocation and rewind-on-clear semantics.
]=]

local C <const> = require("ffi")

local ROW_BITS <const> = 12
local ROW_CAPACITY <const> = 2 ^ ROW_BITS
local PAGE_CAPACITY <const> = 2 ^ ROW_BITS
local DEFAULT_PAGE_SIZE <const> = 4096

--- Arena used to manage FFI memory for elements of type `T`.
--- Pages never move within the arena; `clear()` rewinds allocation state
--- so the same backing pages can be reused for the next epoch.
local record EpochArena<T>
    --- All pages owned by this arena.
    pages: {Page<T>}

    --- Current page index used for appends (1-based, or 0 when empty).
    currentPage: integer

    --- High-water mark of pages used since last clear (1-based).
    usedPages: integer

    --- Base FFI type name used to create per-page arrays.
    ffiType: string

    --- Number of elements allocated per page.
    pageAllocSize: integer

    record Page<U>
        --- FFI cdata array for this page. One extra slot supports 1-based row indexes.
        data: any
        --- Capacity in elements.
        capacity: integer
        --- Used element count in this page for the current epoch.
        count: integer
    end

    --- Create a new epoch arena.
    ---
    --- @param ffiType The FFI type string.
    --- @param initialPageSize Initial page size (defaults to 4096)
    --- @return the created arena.
    new: function<U>(ffiType: string, initialPageSize?: integer): EpochArena<U>

    --- Rewind usage so allocations can start again from page 1.
    clear: function(self)

    --- Allocate a slot and immediately return the backing array and 1-based index.
    ---
    --- @return FFI array cdata, 1-based index.
    allocate: function(self): any, integer
end

local ARENA_MT <const> = {__index = EpochArena}

function EpochArena.new<T>(ffiType: string, initialPageSize?: integer): EpochArena<T>
    local pageAllocSize = initialPageSize or DEFAULT_PAGE_SIZE
    if pageAllocSize < 1 or pageAllocSize > ROW_CAPACITY then
        error("EpochArena.new: initialPageSize must be between 1 and " .. ROW_CAPACITY)
    end
    return setmetatable({
        pages = {},
        currentPage = 0,
        usedPages = 0,
        ffiType = ffiType .. "[?]",
        pageAllocSize = pageAllocSize,
    }, ARENA_MT)
end

function EpochArena:clear()
    local pages, used = self.pages, self.usedPages
    for i = 1, used do
        pages[i].count = 0
    end
    self.currentPage = used > 0 and 1 or 0
    self.usedPages = 0
end

function EpochArena:allocate(): any, integer
    local pages, currentPage = self.pages, self.currentPage

    if currentPage == 0 or pages[currentPage].count >= pages[currentPage].capacity then
        local nextPage = currentPage + 1
        if nextPage > PAGE_CAPACITY then
            error("EpochArena: page count exceeds maximum arena page capacity: " .. PAGE_CAPACITY)
        end
        if nextPage > #pages then
            local cap = self.pageAllocSize
            pages[nextPage] = {
                data = C.new(self.ffiType, cap + 1),
                capacity = cap,
                count = 0,
            }
        end
        currentPage = nextPage
        self.currentPage = currentPage
    end

    if currentPage > self.usedPages then
        self.usedPages = currentPage
    end

    local page = pages[currentPage]
    local row = page.count
    page.count = row + 1

    return page.data, row + 1
end

return EpochArena
