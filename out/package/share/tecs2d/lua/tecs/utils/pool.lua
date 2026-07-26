





























local table_clear = require("table.clear")
local table_new = require("table.new")

local DEFAULT_MAX_SIZE = 4096















local TablePool = {}













local pool = {}












local READONLY_MT = {
   __newindex = function(_t, _k, _v)
      error("Attempt to modify read-only EMPTY table")
   end,
   __metatable = "protected",
}

local GLOBAL_EMPTY = setmetatable({}, READONLY_MT)
pool.EMPTY = GLOBAL_EMPTY



function TablePool:acquire()
   local n = self._size
   if n > 0 then
      local t = self._stack[n]
      self._stack[n] = nil
      self._size = n - 1
      if self._clearOnAcquire then
         table_clear(t)
      end
      return t
   end
   return table_new(self._arrayHint, self._hashHint)
end

function TablePool:release(item)
   local n = self._size
   if n >= self._maxSize then
      return
   end
   if self._clearOnRelease then
      table_clear(item)
   end
   self._size = n + 1
   self._stack[n + 1] = item
end

function TablePool:clear()
   table_clear(self._stack)
   self._size = 0
end

local TABLE_POOL_MT = { __index = TablePool }

function pool.newTablePool(opts)
   local clearOn = opts and opts.clearOn or "acquire"
   local maxSize = opts and opts.maxSize or DEFAULT_MAX_SIZE
   local arrayHint = opts and opts.arrayHint or 0
   local hashHint = opts and opts.hashHint or 0
   local p = setmetatable({
      _stack = table_new(maxSize, 0),
      _size = 0,
      _maxSize = maxSize,
      _arrayHint = arrayHint,
      _hashHint = hashHint,
      _clearOnAcquire = clearOn == "acquire",
      _clearOnRelease = clearOn == "release",
   }, TABLE_POOL_MT)
   return p
end

return pool
