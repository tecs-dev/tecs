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

--- When a pooled table is emptied.
---
--- `"acquire"` clears just before `acquire` hands the table back, so a released table keeps
--- whatever it held until it is next taken out. `"release"` clears on the way in instead,
--- which is what a pool holding GC roots wants: the references are dropped at the moment the
--- caller is done rather than at the moment somebody asks. `"never"` leaves the contents
--- alone and the caller owns emptying it.
local enum ClearPolicy
    "acquire"
    "release"
    "never"
end

--- Options for `pool.newTablePool`. Every field is optional.
local record TablePoolOpts
    --- Defaults to `"acquire"`.
    clearOn: ClearPolicy

    --- Deepest the free stack grows. A release past it drops the table for the collector
    --- rather than pooling it, so a pool cannot pin an unbounded number of tables when
    --- releases outrun acquires. Defaults to 4096, and the stack is preallocated to this
    --- many slots, so a large value costs that memory up front.
    maxSize: integer

    --- Array part preallocated on a table the pool creates fresh, in elements. Recycled
    --- tables keep whatever capacity they already grew to, so this only shapes the first
    --- use of each. Defaults to 0.
    arrayHint: integer

    --- Hash part preallocated on a table the pool creates fresh, in entries. Defaults to 0.
    hashHint: integer
end

--- LIFO pool of reusable tables. acquire() returns `any`; callers cast it.
---
--- Acquire and release are entirely by hand: nothing tracks which tables are out, so
--- releasing one twice pools the same table twice and two later acquires hand the same table
--- to two callers. A table that is never released is not leaked, it is simply collected.
local record TablePool
    --- Private. The free stack, holding `_size` tables from index 1 upwards.
    _stack: {any}

    --- Private. How many tables are on the free stack, which is not `#_stack`, because
    --- popping stores nil above the new top rather than shrinking anything.
    _size: integer

    --- Private. `TablePoolOpts.maxSize`, resolved.
    _maxSize: integer

    --- Private. `TablePoolOpts.arrayHint`, resolved.
    _arrayHint: integer

    --- Private. `TablePoolOpts.hashHint`, resolved.
    _hashHint: integer

    --- Private. `ClearPolicy` decided once, so neither hot path compares strings.
    _clearOnAcquire: boolean

    --- Private. See `_clearOnAcquire`.
    _clearOnRelease: boolean

    --- Takes a table off the pool, or makes one when the pool is empty.
    ---
    --- Never nil: an empty pool is not an error, it allocates. So a pool sized under its
    --- real peak still works and only stops saving allocations, which is why nothing here
    --- reports depth.
    ---
    --- @return The caller's until it is released, and empty only under `"acquire"` or
    ---     `"release"` clearing. A fresh table is always empty whatever the policy.
    acquire: function(self): any

    --- Hands a table back.
    ---
    --- The caller must hold no further reference: a later `acquire` returns this same table
    --- and two owners then write over each other. A release that would take the free stack
    --- past `maxSize` drops the table instead, and skips clearing it, since nothing can
    --- reach it afterwards.
    release: function(self, item: any)

    --- Drops every pooled table, leaving the pool empty.
    ---
    --- Tables currently out are unaffected and may still be released.
    clear: function(self)
end

--- Per-subsystem table pools.
---
--- Each subsystem owns its own pool, so a hot path picks the sizing and the clear policy
--- that suit it instead of contending for one shared free list.
local record pool
    --- Immutable empty table placeholder.
    ---
    --- One table for the whole process, so returning it costs nothing and every caller
    --- returning "no elements" compares equal. Writing to it raises rather than corrupting
    --- every other holder, and `getmetatable` answers the string `"protected"`, so the
    --- metatable cannot be replaced to get around that.
    EMPTY: {any}

    --- When a pooled table is emptied.
    type ClearPolicy = ClearPolicy

    --- Options for `newTablePool`.
    type TablePoolOpts = TablePoolOpts

    --- A LIFO pool of reusable tables.
    type TablePool = TablePool

    --- Creates an empty pool. Nothing is allocated for the tables themselves up front; the
    --- first `maxSize` acquires all allocate.
    ---
    --- @param opts Omitted takes every default: `"acquire"` clearing, 4096 deep, no
    ---     preallocation on a fresh table.
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
