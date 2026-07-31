--[=[
Owned, reusable binary memory and retained zero-copy views.

`Buffer:view` retains a range without copying it. A later buffer write detaches
the buffer only when a view still shares its allocation, so a view is an
immutable snapshot and normal producer-to-consumer paths remain zero-copy.
]=]

local ffi <const> = require("ffi")
local loader <const> = require("tecs.ffi.loader")
local type types = require("tecs.io.types")
local type IOBuffer = types.Buffer
local type ByteView = types.ByteView
local type WriteRange = types.WriteRange

local floor <const> = math.floor
local max <const> = math.max
local MIN_CAPACITY <const> = 64
local MAX_INTEGER <const> = 9007199254740991

local record Allocation
    bytes: loader.CArray
    capacity: integer
    references: integer
end
local record OwnedBuffer is IOBuffer
    _allocation: Allocation
    _length: integer
    _released: boolean
end
local record OwnedView is ByteView
    _allocation: Allocation
    _offset: integer
    _length: integer
    _released: boolean
end
local record OwnedWriteRange is WriteRange
    _buffer: OwnedBuffer
    _pointer: loader.BytePointer
    _offset: integer
    _capacity: integer
    _released: boolean
end
local OwnedBufferMT <const>: metatable<OwnedBuffer> = {__index = OwnedBuffer}
local OwnedViewMT <const>: metatable<OwnedView> = {__index = OwnedView}
local OwnedWriteRangeMT <const>: metatable<OwnedWriteRange> = {__index = OwnedWriteRange}
local rawSetMetatable <const> = setmetatable as function(any, any): any

local function integer(value: integer, what: string, level: integer): integer
    if type(value) ~= "number" or value ~= floor(value) or value < 0 or value > MAX_INTEGER then
        error(("tecs: %s must be a non-negative integer"):format(what), level)
    end
    return value
end
local function allocation(capacity: integer): Allocation
    return {bytes = loader.newArray("uint8_t[?]", max(1, capacity)), capacity = capacity, references = 1}
end
local function open(self: OwnedBuffer, level: integer)
    if self._released then
        error("tecs: io.Buffer is released", level)
    end
end
local function range(length: integer, offset: integer, count: integer, what: string, level: integer): integer, integer
    offset = integer(offset or 0, what .. " offset", level)
    if offset > length then
        error("tecs: " .. what .. " offset is past its length", level)
    end
    count = count == nil and length - offset or integer(count, what .. " count", level)
    if count > length - offset then
        error("tecs: " .. what .. " range is past its length", level)
    end
    return offset, count
end
local function detach(self: OwnedBuffer, minimum: integer)
    local old <const> = self._allocation
    if old.references == 1 and minimum <= old.capacity then
        return
    end
    local capacity = max(MIN_CAPACITY, old.capacity)
    while capacity < minimum do
        capacity = capacity * 2
    end
    local fresh <const> = allocation(capacity)
    if self._length > 0 then
        ffi.copy(fresh.bytes as ffi.CData, old.bytes as ffi.CData, self._length)
    end
    old.references = old.references - 1
    self._allocation = fresh
end
local function prepareWrite(self: OwnedBuffer, offset: integer, count: integer): loader.BytePointer
    open(self, 3)
    offset = integer(offset, "io.Buffer write offset", 3)
    count = integer(count, "io.Buffer write count", 3)
    local finish <const> = offset + count
    if finish > MAX_INTEGER then
        error("tecs: io.Buffer write range is too large", 3)
    end
    detach(self, finish)
    return loader.bytePointer(self._allocation.bytes as loader.CValue) + offset
end
local function commitWrite(self: OwnedBuffer, offset: integer, count: integer)
    local finish <const> = offset + count
    if offset > self._length then
        ffi.fill(
            (loader.bytePointer(self._allocation.bytes as loader.CValue) + self._length) as ffi.CData,
            offset - self._length,
            0
        )
    end
    self._length = max(self._length, finish)
end
function OwnedBuffer:length(): integer
    open(self, 2)
    return self._length
end
function OwnedBuffer:capacity(): integer
    open(self, 2)
    return self._allocation.capacity
end
function OwnedBuffer:clear()
    open(self, 2)
    if self._length > 0 then
        detach(self, self._length)
        self._length = 0
    end
end
function OwnedBuffer:ensureCapacity(minimum: integer)
    open(self, 2)
    detach(self, integer(minimum, "io.Buffer:ensureCapacity minimum", 2))
end
function OwnedBuffer:resize(length: integer)
    open(self, 2)
    length = integer(length, "io.Buffer:resize length", 2)
    if length ~= self._length then
        detach(self, length)
        if length > self._length then
            ffi.fill(
                (loader.bytePointer(self._allocation.bytes as loader.CValue) + self._length) as ffi.CData,
                length - self._length,
                0
            )
        end
        self._length = length
    end
end
function OwnedBuffer:getString(offset?: integer, count?: integer): string
    open(self, 2)
    offset, count = range(self._length, offset, count, "io.Buffer", 2)
    return count == 0 and ""
        or ffi.string(
            (loader.bytePointer(self._allocation.bytes as loader.CValue) + offset) as ffi.CData, count
        ) as string
end
function OwnedBuffer:setString(bytes: string, offset?: integer)
    open(self, 2)
    if type(bytes) ~= "string" then
        error("tecs: io.Buffer:setString needs a byte string", 2)
    end
    offset = integer(offset or 0, "io.Buffer:setString offset", 2)
    local pointer <const> = prepareWrite(self, offset, #bytes)
    if #bytes > 0 then
        ffi.copy(pointer as ffi.CData, bytes, #bytes)
    end
    commitWrite(self, offset, #bytes)
end
function OwnedBuffer:view(offset?: integer, count?: integer): ByteView
    open(self, 2)
    offset, count = range(self._length, offset, count, "io.Buffer", 2)
    local held <const> = self._allocation
    held.references = held.references + 1
    return rawSetMetatable(
        {_allocation = held, _offset = offset, _length = count, _released = false} as OwnedView, OwnedViewMT
    ) as ByteView
end
function OwnedBuffer:reserveRange(offset: integer, minimum: integer): WriteRange
    local pointer <const> = prepareWrite(self, offset, minimum)
    return rawSetMetatable(
        {
            _buffer = self, _pointer = pointer, _offset = offset, _capacity = minimum, _released = false
        } as OwnedWriteRange,
        OwnedWriteRangeMT
    ) as WriteRange
end
function OwnedBuffer:getFFIPointer(): loader.BytePointer
    open(self, 2)
    detach(self, self._length)
    return loader.bytePointer(self._allocation.bytes as loader.CValue)
end
function OwnedBuffer:isReleased(): boolean
    return self._released
end
function OwnedBuffer:close()
    if not self._released then
        self._released = true
        self._allocation.references = self._allocation.references - 1
        self._allocation = nil
        self._length = 0
    end
end
function OwnedView:length(): integer
    if self._released then
        error("tecs: io.ByteView is released", 2)
    end
    return self._length
end
function OwnedView:getString(): string
    if self._released then
        error("tecs: io.ByteView is released", 2)
    end
    return self._length == 0 and ""
        or ffi.string(
            (loader.bytePointer(self._allocation.bytes as loader.CValue) + self._offset) as ffi.CData, self._length
        ) as string
end
function OwnedView:getFFIPointer(): loader.BytePointer
    if self._released then
        error("tecs: io.ByteView is released", 2)
    end
    return loader.bytePointer(self._allocation.bytes as loader.CValue) + self._offset
end
function OwnedView:view(offset?: integer, count?: integer): ByteView
    if self._released then
        error("tecs: io.ByteView is released", 2)
    end
    offset, count = range(self._length, offset, count, "io.ByteView", 2)
    self._allocation.references = self._allocation.references + 1
    return rawSetMetatable(
        {
            _allocation = self._allocation, _offset = self._offset + offset, _length = count, _released = false
        } as OwnedView,
        OwnedViewMT
    ) as ByteView
end
function OwnedView:isReleased(): boolean
    return self._released
end
function OwnedView:close()
    if not self._released then
        self._released = true
        self._allocation.references = self._allocation.references - 1
        self._allocation = nil
    end
end
function OwnedWriteRange:getFFIPointer(): loader.BytePointer
    if self._released then
        error("tecs: io.WriteRange is released", 2)
    end
    return self._pointer
end
function OwnedWriteRange:capacity(): integer
    if self._released then
        error("tecs: io.WriteRange is released", 2)
    end
    return self._capacity
end
function OwnedWriteRange:commit(used: integer)
    if self._released then
        error("tecs: io.WriteRange is released", 2)
    end
    used = integer(used, "io.WriteRange commit", 2)
    if used > self._capacity then
        error("tecs: io.WriteRange commit is past its capacity", 2)
    end
    commitWrite(self._buffer, self._offset, used)
    self:close()
end
function OwnedWriteRange:close()
    self._released = true
    self._pointer = nil
end
local record buffer
    new: function(initial?: integer | string): IOBuffer
    prepareWrite: function(destination: IOBuffer, offset: integer, count: integer): loader.BytePointer, integer
    commitWrite: function(destination: IOBuffer, offset: integer, count: integer, previousLength: integer)
end
function buffer.new(initial?: integer | string): IOBuffer
    local length = type(initial) == "string" and #(initial as string)
        or (initial ~= nil and integer(initial as integer, "io.newBuffer initial length", 2) or 0)
    local self <const> = setmetatable(
        {_allocation = allocation(length), _length = length, _released = false} as OwnedBuffer, OwnedBufferMT
    )
    if type(initial) == "string" and length > 0 then
        ffi.copy(self._allocation.bytes as ffi.CData, initial as string, length)
    end
    return self
end
function buffer.prepareWrite(destination: IOBuffer, offset: integer, count: integer): loader.BytePointer, integer
    local previous <const> = destination:length()
    if (getmetatable(destination as any) as any) == (OwnedBufferMT as any) then
        return prepareWrite(destination as OwnedBuffer, offset, count), previous
    end
    destination:resize(max(previous, offset + count))
    return destination:getFFIPointer() + offset, previous
end
function buffer.commitWrite(destination: IOBuffer, offset: integer, count: integer, previous: integer)
    if (getmetatable(destination as any) as any) == (OwnedBufferMT as any) then
        if count == 0 then
            (destination as OwnedBuffer)._length = previous
        else
            commitWrite(destination as OwnedBuffer, offset, count)
        end
        return
    end
    destination:resize(count == 0 and previous or max(previous, offset + count))
end
return buffer
