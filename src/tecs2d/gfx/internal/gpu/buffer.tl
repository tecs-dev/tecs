--- GPU Buffer management for instanced rendering.
--- Provides slot allocation, dirty tracking, and zero-copy FFI uploads.

local C <const> = require("ffi")

local lg <const> = love.graphics

local record buffer
    --- A managed GPU buffer with slot allocation and dirty tracking.
    record GPUBuffer
        --- The Love2D graphics buffer (SSBO)
        handle: love.graphics.Buffer

        --- ByteData backing store for zero-copy uploads
        byteData: love.data.ByteData

        --- FFI pointer into the ByteData (use with C.cast)
        dataPtr: C.CData

        --- Size of each element in bytes
        elementSize: integer

        --- Maximum number of elements
        capacity: integer

        --- High-water mark: next fresh slot index to hand out before the
        --- freelist is consulted. NOT decremented on free(). Represents the
        --- max extent of slots ever occupied contiguously from index 0.
        count: integer

        --- Free list for slot reuse (stack of free indices)
        freeList: {integer}

        --- Set of currently-freed indices (for double-free detection).
        freedSet: {integer: boolean}

        --- Optional debug label used in error messages.
        debugName: string

        --- Dirty range tracking (min/max modified indices)
        dirtyMin: integer
        dirtyMax: integer

        --- Allocate a new slot, returns the index (0-based for FFI)
        allocate: function(GPUBuffer): integer

        --- Free a slot for reuse
        free: function(GPUBuffer, index: integer)

        --- Mark a slot as dirty (needs upload)
        markDirty: function(GPUBuffer, index: integer)

        --- Mark a range as dirty
        markDirtyRange: function(GPUBuffer, minIndex: integer, maxIndex: integer)

        --- Upload dirty data to GPU, returns true if anything was uploaded
        upload: function(GPUBuffer): boolean

        --- Reset dirty tracking (called after upload)
        clearDirty: function(GPUBuffer)

        --- Check if buffer has any dirty data
        isDirty: function(GPUBuffer): boolean

        --- Grow the buffer to accommodate more elements (doubles capacity)
        grow: function(GPUBuffer)

        --- The FFI ctype name for elements (needed for resize)
        ctypeName: string

        --- The buffer format (needed for resize)
        format: BufferFormat

        --- Optional callback when buffer grows (receives old and new capacity)
        onGrow: function(oldCapacity: integer, newCapacity: integer)

        --- When true, buffer will error instead of growing (prevents GPU memory crashes)
        growthDisabled: boolean

        --- Counter that increments each time the buffer grows (for cache invalidation)
        growCount: integer
    end

    --- Buffer format specification for Love2D (alias to love.graphics.BufferFormat)
    type BufferFormat = love.graphics.BufferFormat

    --- Create a new GPU buffer.
    --- @param format Buffer format specification matching the struct layout
    --- @param capacity Maximum number of elements
    --- @param ctypeName FFI ctype name for the element struct
    --- @param debugName Optional label for error messages
    --- @return A new GPUBuffer instance
    new: function(format: BufferFormat, capacity: integer, ctypeName: string, debugName?: string): GPUBuffer
end

function buffer.new(format: buffer.BufferFormat, capacity: integer, ctypeName: string, debugName?: string): buffer.GPUBuffer
    if capacity < 1 then capacity = 1 end
    local elementSize = C.sizeof(ctypeName)

    -- Create ByteData backing store
    local byteData = love.data.newByteData(capacity * elementSize)

    -- FFI pointer into the ByteData (zero-copy access)
    local dataPtr = C.cast(ctypeName .. "*", byteData:getFFIPointer()) as C.CData

    -- Create GPU buffer with shaderstorage for SSBO use
    local handle = lg.newBuffer(format, capacity, {
        usage = "dynamic",
        shaderstorage = true
    })

    local buf: buffer.GPUBuffer = {
        handle = handle,
        byteData = byteData,
        dataPtr = dataPtr,
        elementSize = elementSize,
        capacity = capacity,
        count = 0,
        freeList = {},
        freedSet = {},
        dirtyMin = capacity + 1,  -- Invalid (nothing dirty)
        dirtyMax = -1,
        ctypeName = ctypeName,
        format = format,
        growCount = 0,
        debugName = debugName or ctypeName,
    }

    setmetatable(buf, {__index = buffer.GPUBuffer})
    return buf
end

local GPUBuffer <const> = buffer.GPUBuffer

function GPUBuffer:allocate(): integer
    local freeList <const> = self.freeList
    local freeCount <const> = #freeList

    if freeCount > 0 then
        -- Reuse a freed slot
        local index = freeList[freeCount]
        freeList[freeCount] = nil
        self.freedSet[index] = nil
        return index
    end

    -- Allocate new slot at end
    if self.count >= self.capacity then
        -- Grow buffer instead of erroring
        self:grow()
    end

    local index = self.count
    self.count = self.count + 1
    return index
end

function GPUBuffer:grow()
    if self.growthDisabled then
        error(string.format(
            "Buffer '%s' growth disabled: capacity %d exceeded. " ..
            "Increase initial capacity or reduce entity count to prevent GPU memory crashes.",
            self.debugName, self.capacity
        ))
    end

    local oldCapacity = self.capacity
    -- Guard against zero/tiny capacities so *4 can actually grow the buffer.
    if oldCapacity < 1 then oldCapacity = 1 end
    local newCapacity = oldCapacity * 4

    -- Create new larger ByteData
    local newByteData = love.data.newByteData(newCapacity * self.elementSize)
    local newDataPtr = C.cast(self.ctypeName .. "*", newByteData:getFFIPointer()) as C.CData

    -- Copy existing data from old ByteData to new
    C.copy(newDataPtr, self.dataPtr, oldCapacity * self.elementSize)

    -- Create new larger GPU buffer
    local newHandle = lg.newBuffer(self.format, newCapacity, {
        usage = "dynamic",
        shaderstorage = true
    })

    -- Old GPU buffer will be garbage collected

    -- Update buffer fields
    self.byteData = newByteData
    self.dataPtr = newDataPtr
    self.handle = newHandle
    self.capacity = newCapacity

    -- Mark all existing data as dirty so it gets uploaded to new GPU buffer
    if self.count > 0 then
        self.dirtyMin = 0
        self.dirtyMax = self.count - 1
    end

    -- Increment grow count for cache invalidation in sync modules
    self.growCount = self.growCount + 1

    -- Notify callback if set (so renderer can resize output buffers)
    if self.onGrow then
        self.onGrow(oldCapacity, newCapacity)
    end
end

-- Helper for FFI pointer arithmetic. LuaJIT supports `cdata + integer`
-- natively on pointer cdata, but Teal's type checker doesn't allow it.
-- Compiled via `load()` once at module scope to bypass the check.
local ffi_offset_ptr: function(ptr: C.CData, offset: integer): C.CData
do
    local loadfn = rawget(_G as table, "load") or rawget(_G as table, "loadstring")
    local code = "local ffi = require('ffi'); return function(ptr, offset) return ffi.cast('char*', ptr) + offset end"
    local fn = (loadfn as function(string): function(): any)(code)()
    ffi_offset_ptr = fn as function(C.CData, integer): C.CData
end

function GPUBuffer:free(index: integer)
    -- Double-free guard: if the slot is already on the free list, drop it.
    -- Without this, allocate() would hand out the same slot twice, corrupting
    -- entity <-> slot mappings.
    if self.freedSet[index] then
        return
    end
    self.freedSet[index] = true

    -- Zero out the slot data so it doesn't render
    local offset = index * self.elementSize
    local offsetPtr = ffi_offset_ptr(self.dataPtr, offset)
    C.fill(offsetPtr, self.elementSize, 0)

    -- Mark slot as dirty so the zeroed data gets uploaded
    self:markDirty(index)

    -- Add to free list for reuse
    local freeList <const> = self.freeList
    freeList[#freeList + 1] = index
end

function GPUBuffer:markDirty(index: integer)
    if index < self.dirtyMin then
        self.dirtyMin = index
    end
    if index > self.dirtyMax then
        self.dirtyMax = index
    end
end

function GPUBuffer:markDirtyRange(minIndex: integer, maxIndex: integer)
    if minIndex < self.dirtyMin then
        self.dirtyMin = minIndex
    end
    if maxIndex > self.dirtyMax then
        self.dirtyMax = maxIndex
    end
end

function GPUBuffer:isDirty(): boolean
    return self.dirtyMax >= self.dirtyMin
end

function GPUBuffer:clearDirty()
    self.dirtyMin = self.capacity + 1
    self.dirtyMax = -1
end

function GPUBuffer:upload(): boolean
    if not self:isDirty() then
        return false
    end

    -- Upload only the dirty range
    -- setArrayData(data, srcIndex, destIndex, count) - indices are 1-based
    local startIndex = self.dirtyMin
    local endIndex = self.dirtyMax
    local count = endIndex - startIndex + 1

    self.handle:setArrayData(self.byteData, startIndex + 1, startIndex + 1, count)
    self:clearDirty()
    return true
end

return buffer
