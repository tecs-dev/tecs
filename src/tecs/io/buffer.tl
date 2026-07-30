--[=[
Owned, reusable binary memory.

A `Buffer` keeps bytes in FFI memory so an SDL reader can fill it and an SDL
writer can drain it without constructing an intermediate Lua string. Its
logical length is separate from its capacity. `clear` keeps the allocation,
and `reserve` grows geometrically so a loop can reuse one buffer.

Offsets are zero-based. A pointer returned by `getFFIPointer` is borrowed from
the buffer. It remains valid only until a later operation grows the capacity
or `release` gives the allocation up.
]=]

local ffi <const> = require("ffi")
local loader <const> = require("tecs.ffi.loader")
local type types = require("tecs.io.types")
local type IOBuffer = types.Buffer

local MIN_CAPACITY <const> = 64
local MAX_INTEGER <const> = 9007199254740991

local record OwnedBuffer is IOBuffer
    _bytes: loader.CArray
    _length: integer
    _capacity: integer
    _released: boolean
end

local OwnedBufferMT <const>: metatable<OwnedBuffer> = {__index = OwnedBuffer}

local function integer(value: integer, what: string, level: integer): integer
    if type(value) ~= "number" or value ~= math.floor(value) or value < 0 or value > MAX_INTEGER then
        error(("tecs: %s must be a non-negative integer"):format(what), level)
    end
    return value
end

local function open(self: OwnedBuffer, level: integer)
    if self._released then
        error("tecs: io.Buffer is released", level)
    end
end

local function allocate(capacity: integer): loader.CArray
    -- LuaJIT permits a zero-length VLA, but retaining one real byte gives an
    -- empty live buffer a stable, non-null address for native zero-byte calls.
    return loader.newArray("uint8_t[?]", math.max(1, capacity))
end

function OwnedBuffer:length(): integer
    open(self, 2)
    return self._length
end

function OwnedBuffer:capacity(): integer
    open(self, 2)
    return self._capacity
end

function OwnedBuffer:clear()
    open(self, 2)
    self._length = 0
end

function OwnedBuffer:reserve(minimum: integer)
    open(self, 2)
    minimum = integer(minimum, "io.Buffer:reserve minimum", 2)
    if minimum <= self._capacity then
        return
    end

    local capacity = math.max(MIN_CAPACITY, self._capacity)
    while capacity < minimum do
        local doubled <const> = capacity * 2
        if doubled <= capacity or doubled > MAX_INTEGER then
            capacity = minimum
            break
        end
        capacity = doubled
    end

    local grown <const> = allocate(capacity)
    if self._length > 0 then
        ffi.copy(grown as ffi.CData, self._bytes as ffi.CData, self._length)
    end
    self._bytes = grown
    self._capacity = capacity
end

function OwnedBuffer:resize(length: integer)
    open(self, 2)
    length = integer(length, "io.Buffer:resize length", 2)
    local oldLength <const> = self._length
    if length > oldLength then
        self:reserve(length)
        ffi.fill((loader.bytePointer(self._bytes as loader.CValue) + oldLength) as ffi.CData, length - oldLength, 0)
    end
    self._length = length
end

-- Internal direct-write protocol. The caller reserves a range, writes through
-- the returned pointer, then commits only the bytes the source produced.
-- Keeping this off the record leaves the public Buffer surface unchanged.
local function prepareWrite(self: OwnedBuffer, offset: integer, count: integer): loader.BytePointer
    open(self, 3)
    offset = integer(offset, "io.Buffer write offset", 3)
    count = integer(count, "io.Buffer write count", 3)
    local finish <const> = offset + count
    if finish > MAX_INTEGER then
        error("tecs: io.Buffer write range is too large", 3)
    end
    self:reserve(finish)
    return loader.bytePointer(self._bytes as loader.CValue) + offset
end

local function commitWrite(self: OwnedBuffer, offset: integer, count: integer)
    open(self, 3)
    offset = integer(offset, "io.Buffer write offset", 3)
    count = integer(count, "io.Buffer write count", 3)
    local finish <const> = offset + count
    if finish > self._capacity then
        error("tecs: io.Buffer committed bytes were not reserved", 3)
    end
    if offset > self._length then
        ffi.fill(
            (loader.bytePointer(self._bytes as loader.CValue) + self._length) as ffi.CData, offset - self._length, 0
        )
    end
    self._length = math.max(self._length, finish)
end

local function range(self: OwnedBuffer, offset: integer, count: integer, level: integer): integer, integer
    offset = integer(offset or 0, "io.Buffer offset", level)
    if offset > self._length then
        error("tecs: io.Buffer offset is past its length", level)
    end
    if count == nil then
        count = self._length - offset
    else
        count = integer(count, "io.Buffer count", level)
    end
    if count > self._length - offset then
        error("tecs: io.Buffer range is past its length", level)
    end
    return offset, count
end

function OwnedBuffer:getString(offset?: integer, count?: integer): string
    open(self, 2)
    offset, count = range(self, offset, count, 2)
    if count == 0 then
        return ""
    end
    return ffi.string((loader.bytePointer(self._bytes as loader.CValue) + offset) as ffi.CData, count) as string
end

function OwnedBuffer:setString(bytes: string, offset?: integer)
    open(self, 2)
    if type(bytes) ~= "string" then
        error("tecs: io.Buffer:setString needs a byte string", 2)
    end
    offset = integer(offset or 0, "io.Buffer:setString offset", 2)
    local destination <const> = prepareWrite(self, offset, #bytes)
    if #bytes > 0 then
        ffi.copy(destination as ffi.CData, bytes, #bytes)
    end
    commitWrite(self, offset, #bytes)
end

function OwnedBuffer:getFFIPointer(): loader.BytePointer
    open(self, 2)
    return loader.bytePointer(self._bytes as loader.CValue)
end

function OwnedBuffer:isReleased(): boolean
    return self._released
end

function OwnedBuffer:release()
    if self._released then
        return
    end
    self._released = true
    self._bytes = nil
    self._length = 0
    self._capacity = 0
end

local record buffer
    new: function(initial?: integer | string): IOBuffer
    prepareWrite: function(destination: IOBuffer, offset: integer, count: integer): loader.BytePointer, integer
    commitWrite: function(destination: IOBuffer, offset: integer, count: integer, previousLength: integer)
end

function buffer.new(initial?: integer | string): IOBuffer
    local length = 0
    local text: string = nil
    if type(initial) == "string" then
        text = initial as string
        length = #text
    elseif initial ~= nil then
        length = integer(initial as integer, "io.newBuffer initial length", 2)
    end

    local self <const> = setmetatable(
        {
            _bytes = allocate(length),
            _length = length,
            _capacity = length,
            _released = false,
        } as OwnedBuffer,
        OwnedBufferMT
    )
    if text ~= nil and length > 0 then
        ffi.copy(self._bytes as ffi.CData, text, length)
    end
    return self
end

function buffer.prepareWrite(destination: IOBuffer, offset: integer, count: integer): loader.BytePointer, integer
    offset = integer(offset, "io.Buffer write offset", 3)
    count = integer(count, "io.Buffer write count", 3)
    local finish <const> = offset + count
    if finish > MAX_INTEGER then
        error("tecs: io.Buffer write range is too large", 3)
    end
    local previousLength <const> = destination:length()
    if (getmetatable(destination as any) as any) == (OwnedBufferMT as any) then
        return prepareWrite(destination as OwnedBuffer, offset, count), previousLength
    end
    destination:resize(math.max(previousLength, finish))
    return destination:getFFIPointer() + offset, previousLength
end

function buffer.commitWrite(destination: IOBuffer, offset: integer, count: integer, previousLength: integer)
    if (getmetatable(destination as any) as any) == (OwnedBufferMT as any) then
        local owned <const> = destination as OwnedBuffer
        if count == 0 then
            owned._length = previousLength
        else
            commitWrite(owned, offset, count)
        end
        return
    end
    destination:resize(math.max(previousLength, offset + count))
end

return buffer
