--[[
    WeakArray.tl - Array-like container with weak references and automatic size tracking

    This module provides a drop-in replacement for regular Lua arrays that:
    - Maintains weak references to stored values (allowing GC when no longer referenced)
    - Automatically tracks array size for efficient # operator via Teal macros
    - Provides lazy compaction to remove dead references during growth
    - Uses familiar array syntax: arr[1] = value, for i = 1, #arr do...

    Use this when you need array-like behavior with automatic garbage collection
    of unreferenced values, such as for observer/listener collections.

    WARNING: This is an internal module and should not be required directly.
]]

local record WeakArray<T>
    --- Creates a new WeakArray instance.
    new: function(): WeakArray<T>

    --- Manually compacts the array to remove nil gaps from GC'd values.
    compact: function(self): integer

    _size: integer

    metamethod __len: function(self): integer = macroexp(self: WeakArray<T>): integer
        return self._size
    end

    --- You can index into the WeakArray just like a normal array.
    -- Using: `is {T}` doesn't work here since Teal gets confused and doesn't keep the __len macro.
    metamethod __index: function(self, index: integer): T
end

local WEAK_ARRAY_MT <const>: metatable<WeakArray> = {
    __mode = "v",
    __index = WeakArray,
    __newindex = function<T>(self: WeakArray<T>, k: integer, v: any)
        -- Update size if we're extending the array
        if k > self._size then
            self._size = k
        end

        -- Lazy compaction: check every 25 adds starting at size 25
        if self._size >= 25 and self._size % 25 == 0 then
            local alive = 0
            for i = 1, self._size do
                if rawget(self, i) then
                    alive = alive + 1
                end
            end
            -- Compact if less than 30% of entries are alive (70% dead)
            if alive < self._size * 0.3 then
                local arr = self as WeakArray<any>
                arr:compact()
            end
        end

        rawset(self, k, v)
    end
}

function WeakArray.new<T>(): WeakArray<T>
    local arr: WeakArray<T> = {_size = 0}
    return setmetatable(arr, WEAK_ARRAY_MT)
end

function WeakArray:compact(): integer
    local size = self._size as integer
    if size == 0 then
        return 0
    end

    local write = 0
    for read = 1, size do
        local value = rawget(self as {any: any}, read)
        if value ~= nil then
            write = write + 1
            if write ~= read then
                rawset(self as {any: any}, write, value)
                rawset(self as {any: any}, read, nil)
            end
        end
    end

    self._size = write
    return write
end

return WeakArray