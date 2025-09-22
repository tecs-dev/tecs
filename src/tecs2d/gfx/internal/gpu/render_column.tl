--- Per-archetype renderer-internal column. Canonical layout is std430 from
--- day one (the renderer chooses it), so canonical and shadow are the same
--- bytes and there is no translation step. This is the right primitive for
--- per-archetype data the renderer produces itself (e.g., circle material
--- params, packed shape derived state) without involving the ECS component
--- system.
---
--- Lifecycle is driven by the renderer (typically via archetype-create /
--- destroy hooks). Unlike `component_shadow`, this module is NOT a
--- ColumnShadow — it is owned by per-shape plugin code, not by tecs core.

local C <const> = require("ffi")
local Bitset <const> = require("tecs.utils.Bitset")

local lg <const> = love.graphics

local DEFAULT_PAGE_SIZE <const> = 256

local record render_column
    record RenderColumn
        byteData: love.data.ByteData
        --- Typed FFI pointer into `byteData`. Renderer writes through this
        --- pointer; same bytes go to the GPU. 1-based: row 1 is at index 0
        --- of the cdata array (offset by the ByteData padding row).
        storagePtr: C.CData
        gpuBuffer: love.graphics.Buffer
        capacity: integer
        elementSize: integer
        format: love.graphics.BufferFormat
        shadowCtype: string
        pageBits: Bitset
        pageSize: integer
        pageCount: integer

        --- Renderer writes go through this pointer. After writing, call
        --- `markPagesDirty(rowStart, rowEnd)` to schedule those rows for
        --- upload at the next flush.
        getPtr: function(self): C.CData
        markPagesDirty: function(self, firstRow: integer, lastRow: integer)
        markAllDirty: function(self)
        clearDirty: function(self)
        anyDirty: function(self): boolean
        flush: function(self)
        grow: function(self, newCapacity: integer)
        getCapacity: function(self): integer
        --- Total bytes including the padding row at index 0. For tests.
        getByteSize: function(self): integer
    end

    new: function(
        capacity: integer,
        elementSize: integer,
        shadowCtype: string,
        format: love.graphics.BufferFormat,
        pageSize?: integer
    ): RenderColumn
end

local RenderColumn <const> = render_column.RenderColumn
local RENDER_COLUMN_MT <const>: metatable<RenderColumn> = {__index = RenderColumn}

local function computePageCount(capacity: integer, pageSize: integer): integer
    if capacity <= 0 then return 0 end
    return math.floor((capacity - 1) / pageSize) + 1
end

local function allocateStorage(
    capacity: integer,
    elementSize: integer,
    shadowCtype: string
): love.data.ByteData, C.CData
    local byteSize = (capacity + 1) * elementSize
    local byteData = love.data.newByteData(byteSize)
    local rawPtr = byteData:getFFIPointer()
    local typedPtr = C.cast(shadowCtype .. "*", rawPtr) as C.CData
    return byteData, typedPtr
end

function render_column.new(
    capacity: integer,
    elementSize: integer,
    shadowCtype: string,
    format: love.graphics.BufferFormat,
    pageSize?: integer
): render_column.RenderColumn
    if capacity < 1 then capacity = 1 end
    pageSize = pageSize or DEFAULT_PAGE_SIZE

    local byteData, storagePtr = allocateStorage(capacity, elementSize, shadowCtype)
    local gpuBuffer = lg.newBuffer(format, capacity, {
        usage = "dynamic",
        shaderstorage = true,
    })

    local self: render_column.RenderColumn = {
        byteData = byteData,
        storagePtr = storagePtr,
        gpuBuffer = gpuBuffer,
        capacity = capacity,
        elementSize = elementSize,
        format = format,
        shadowCtype = shadowCtype,
        pageBits = Bitset.new(64),
        pageSize = pageSize,
        pageCount = computePageCount(capacity, pageSize),
    }
    return setmetatable(self, RENDER_COLUMN_MT)
end

function RenderColumn:getPtr(): C.CData
    return self.storagePtr
end

function RenderColumn:markPagesDirty(firstRow: integer, lastRow: integer)
    if lastRow < firstRow then return end
    local pageSize = self.pageSize
    local firstPage = math.floor((firstRow - 1) / pageSize)
    local lastPage = math.floor((lastRow - 1) / pageSize)
    self.pageBits:setRange(firstPage, lastPage)
end

function RenderColumn:markAllDirty()
    if self.pageCount > 0 then
        self.pageBits:setRange(0, self.pageCount - 1)
    end
end

function RenderColumn:clearDirty()
    self.pageBits:clearAll()
end

function RenderColumn:anyDirty(): boolean
    return not self.pageBits:isEmpty()
end

function RenderColumn:flush()
    if self.pageBits:isEmpty() then return end

    local pageSize = self.pageSize
    local capacity = self.capacity
    local gpuBuffer = self.gpuBuffer
    local byteData = self.byteData

    local page = self.pageBits:beginScan(0)
    while page do
        local firstRow = page * pageSize + 1
        local lastRow = firstRow + pageSize - 1
        if lastRow > capacity then lastRow = capacity end
        if firstRow <= capacity then
            local count = lastRow - firstRow + 1
            gpuBuffer:setArrayData(byteData, firstRow, firstRow, count)
        end
        page = self.pageBits:nextScan()
    end

    self.pageBits:clearAll()
end

function RenderColumn:grow(newCapacity: integer)
    if newCapacity <= self.capacity then return end

    local oldCapacity = self.capacity
    local elementSize = self.elementSize
    local shadowCtype = self.shadowCtype

    local newByteSize = (newCapacity + 1) * elementSize
    local newByteData = love.data.newByteData(newByteSize)
    local newRawPtr = newByteData:getFFIPointer()
    local newStoragePtr = C.cast(shadowCtype .. "*", newRawPtr) as C.CData

    -- Preserve existing canonical contents.
    C.copy(newStoragePtr as C.CData, self.storagePtr as C.CData,
           (oldCapacity + 1) * elementSize)

    local newGpuBuffer = lg.newBuffer(self.format, newCapacity, {
        usage = "dynamic",
        shaderstorage = true,
    })

    -- New GPU buffer is uninitialized; mark every existing row dirty so
    -- the next flush re-uploads.
    self.pageBits:clearAll()
    if oldCapacity > 0 then
        local lastOldPage = math.floor((oldCapacity - 1) / self.pageSize)
        self.pageBits:setRange(0, lastOldPage)
    end

    self.byteData = newByteData
    self.storagePtr = newStoragePtr
    self.gpuBuffer = newGpuBuffer
    self.capacity = newCapacity
    self.pageCount = computePageCount(newCapacity, self.pageSize)
end

function RenderColumn:getCapacity(): integer
    return self.capacity
end

function RenderColumn:getByteSize(): integer
    return (self.capacity + 1) * self.elementSize
end

return render_column
