--[[
pool - Table pooling abstraction for Tecs

Per-subsystem table pools. Each subsystem owns its own pool instance so
hot paths can choose their own sizing and clear policy.

This module currently exposes one pool flavor:

  newTablePool(opts) - LIFO stack of reusable tables. Usable for both
                       arrays and maps. Callers explicitly acquire and
                       release. acquire() returns `any`; callers cast to
                       their concrete shape.

Clear policies (newTablePool only):

  "acquire" (default) - Clear just before returning from acquire.
  "release"           - Clear on release. Right when the pooled table
                        holds GC roots the caller wants dropped promptly.
  "never"             - Caller manages content.

Other opts:

  maxSize   - Drop (don't pool) releases that exceed this stack depth.
              Default 4096.
  arrayHint - table_new(arrayHint, hashHint) preallocation for fresh tables.
  hashHint  - See above.

EMPTY is a module-level immutable empty table for use as a placeholder.
]]

local table_clear <const> = require("table.clear")
local table_new <const> = require("table.new")

local DEFAULT_MAX_SIZE <const> = 4096

local enum ClearPolicy
    "acquire"
    "release"
    "never"
end

local record TablePoolOpts
    clearOn: ClearPolicy
    maxSize: integer
    arrayHint: integer
    hashHint: integer
end

--- LIFO pool of reusable tables. acquire() returns `any`; callers cast it.
local record TablePool
    _stack: {any}
    _size: integer
    _maxSize: integer
    _arrayHint: integer
    _hashHint: integer
    _clearOnAcquire: boolean
    _clearOnRelease: boolean

    acquire: function(self): any
    release: function(self, item: any)
    clear: function(self)
end

local record pool
    --- Immutable empty table placeholder.
    EMPTY: {any}

    type ClearPolicy = ClearPolicy
    type TablePoolOpts = TablePoolOpts
    type TablePool = TablePool

    newTablePool: function(opts?: TablePoolOpts): TablePool
end

-- EMPTY implementation

local READONLY_MT <const>: {string: any} = {
    __newindex = function(_t: any, _k: any, _v: any) error("Attempt to modify read-only EMPTY table") end,
    __metatable = "protected",
}

local GLOBAL_EMPTY <const> = setmetatable({}, READONLY_MT as metatable<{any: any}>)
pool.EMPTY = GLOBAL_EMPTY

-- TablePool

function TablePool:acquire(): any
    local n = self._size
    if n > 0 then
        local t = self._stack[n]
        self._stack[n] = nil
        self._size = n - 1
        if self._clearOnAcquire then
            table_clear(t as table)
        end
        return t
    end
    return table_new(self._arrayHint, self._hashHint)
end

function TablePool:release(item: any)
    local n = self._size
    if n >= self._maxSize then
        return
    end
    if self._clearOnRelease then
        table_clear(item as table)
    end
    self._size = n + 1
    self._stack[n + 1] = item
end

function TablePool:clear()
    table_clear(self._stack)
    self._size = 0
end

local TABLE_POOL_MT <const> = {__index = TablePool}

function pool.newTablePool(opts?: TablePoolOpts): TablePool
    local clearOn: ClearPolicy = opts and opts.clearOn or "acquire"
    local maxSize = opts and opts.maxSize or DEFAULT_MAX_SIZE
    local arrayHint = opts and opts.arrayHint or 0
    local hashHint = opts and opts.hashHint or 0
    local p: TablePool = setmetatable(
        {
            _stack = table_new(maxSize, 0),
            _size = 0,
            _maxSize = maxSize,
            _arrayHint = arrayHint,
            _hashHint = hashHint,
            _clearOnAcquire = clearOn == "acquire",
            _clearOnRelease = clearOn == "release",
        },
        TABLE_POOL_MT
    )
    return p
end

return pool
