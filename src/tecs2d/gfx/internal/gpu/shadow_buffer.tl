--- A `ByteData`-backed std430 shadow paired with a `love.graphics.Buffer`.
--- Component-agnostic: the canonical column pointer is supplied externally
--- on every flush, and a per-component translation function turns canonical
--- FFI rows into std430 shadow rows.
---
--- Dirty tracking lives on the archetype (per-component bitset, see
--- `Archetype:isComponentDirty`), not in the buffer. Callers gate their
--- `flushRange` invocations on that signal; this module only knows about
--- bytes and how to grow a Buffer.

local C <const> = require("ffi")
local retire <const> = require("tecs2d.gfx.internal.gpu.retire")

local lg <const> = love.graphics

--- Translation function signature. Copies a row range `[firstRow, lastRow]`
--- (both 1-indexed, inclusive) from the canonical FFI column at
--- `canonicalPtr` to the std430 shadow at `shadowPtr`. Implementations
--- typically do field-by-field copies with explicit padding writes.
local type TranslateFn = function(
    canonicalPtr: C.CData,
    shadowPtr: C.CData,
    firstRow: integer,
    lastRow: integer
)

local record shadow_buffer
    record ShadowBuffer
        --- `love.data.ByteData` holding the std430 shadow.
        byteData: love.data.ByteData
        --- Typed FFI pointer into `byteData`, starting at row 1 (1-based;
        --- index 0 is unused for symmetry with FFI column padding).
        shadowPtr: C.CData
        --- The std430-shaped `love.graphics.Buffer`.
        gpuBuffer: love.graphics.Buffer
        --- Row capacity (also tracks `gpuBuffer` and `byteData` size).
        capacity: integer
        --- Bytes per std430 row.
        elementSize: integer
        --- Buffer format used to (re)create `gpuBuffer` on grow.
        format: love.graphics.BufferFormat
        --- Translator from canonical FFI rows to std430 rows.
        translate: TranslateFn

        --- Translate + upload a contiguous live row range in one shot.
        --- The component-dirty signal lives on the archetype; callers
        --- gate their flushRange invocations there.
        flushRange: function(self, canonicalPtr: C.CData, rowCount: integer)
        grow: function(self, newCapacity: integer)
        --- Total rows the shadow can address. Useful for tests and asserts.
        getCapacity: function(self): integer
    end

    new: function(
        capacity: integer,
        elementSize: integer,
        shadowCtype: string,
        format: love.graphics.BufferFormat,
        translate: TranslateFn
    ): ShadowBuffer
end

local ShadowBuffer <const> = shadow_buffer.ShadowBuffer
local SHADOW_BUFFER_MT <const>: metatable<ShadowBuffer> = {__index = ShadowBuffer}

local function allocateShadow(
    capacity: integer,
    elementSize: integer,
    shadowCtype: string
): love.data.ByteData, C.CData
    -- Match the FFI storage convention: index 0 is reserved padding so
    -- 1-based row writes align with archetype `luaRow` indexing without
    -- a -1 in every translate call.
    local byteSize = (capacity + 1) * elementSize
    local byteData = love.data.newByteData(byteSize)
    local rawPtr = byteData:getFFIPointer()
    local typedPtr = C.cast(shadowCtype .. "*", rawPtr) as C.CData
    return byteData, typedPtr
end

function shadow_buffer.new(
    capacity: integer,
    elementSize: integer,
    shadowCtype: string,
    format: love.graphics.BufferFormat,
    translate: TranslateFn
): shadow_buffer.ShadowBuffer
    if capacity < 1 then capacity = 1 end

    local byteData, shadowPtr = allocateShadow(capacity, elementSize, shadowCtype)
    local gpuBuffer = lg.newBuffer(format, capacity, {
        usage = "dynamic",
        shaderstorage = true,
    })

    local self: shadow_buffer.ShadowBuffer = {
        byteData = byteData,
        shadowPtr = shadowPtr,
        gpuBuffer = gpuBuffer,
        capacity = capacity,
        elementSize = elementSize,
        format = format,
        translate = translate,
    }
    return setmetatable(self, SHADOW_BUFFER_MT)
end

function ShadowBuffer:flushRange(canonicalPtr: C.CData, rowCount: integer)
    if rowCount <= 0 then return end
    if rowCount > self.capacity then rowCount = self.capacity end
    -- Translate writes into shadow rows 1..rowCount (matches canonical
    -- FFI column convention where index 0 is reserved padding).
    self.translate(canonicalPtr, self.shadowPtr, 1, rowCount)
    -- setArrayData uses 1-based source/dest element offsets. We want
    -- the upload to skip the padding row at byteData element 1 and
    -- start the GPU buffer at element 1 (GLSL index 0), so the cull
    -- shader can read `transforms[row]` with row=0..rowCount-1 directly.
    self.gpuBuffer:setArrayData(self.byteData, 2, 1, rowCount)
end

function ShadowBuffer:grow(newCapacity: integer)
    if newCapacity <= self.capacity then return end

    local oldCapacity = self.capacity
    local elementSize = self.elementSize

    -- Recover the element ctype from the existing pointer's type.
    local shadowCtype = C.typeof(self.shadowPtr)
    local newByteSize = (newCapacity + 1) * elementSize
    local newByteData = love.data.newByteData(newByteSize)
    local newRawPtr = newByteData:getFFIPointer()
    local newShadowPtr = C.cast(shadowCtype, newRawPtr) as C.CData

    -- Preserve existing shadow contents at the same row indices. The +1
    -- row covers the index-0 padding row.
    C.copy(newShadowPtr as C.CData, self.shadowPtr as C.CData,
           (oldCapacity + 1) * elementSize)

    local newGpuBuffer = lg.newBuffer(self.format, newCapacity, {
        usage = "dynamic",
        shaderstorage = true,
    })

    -- In-flight GPU work may still read the old buffer; defer release.
    retire.push(self.gpuBuffer)

    self.byteData = newByteData
    self.shadowPtr = newShadowPtr
    self.gpuBuffer = newGpuBuffer
    self.capacity = newCapacity
end

function ShadowBuffer:getCapacity(): integer
    return self.capacity
end

return shadow_buffer
