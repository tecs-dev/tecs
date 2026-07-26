


local C = require("ffi")

local ROW_BITS = 12
local ROW_CAPACITY = 2 ^ ROW_BITS
local PAGE_CAPACITY = 2 ^ ROW_BITS
local DEFAULT_PAGE_SIZE = 4096




local EpochArena = {}








































local ARENA_MT = { __index = EpochArena }

function EpochArena.new(ffiType, initialPageSize)
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

function EpochArena:allocate()
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
