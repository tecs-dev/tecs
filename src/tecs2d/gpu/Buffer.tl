--- A GPU buffer with staged, dirty-ranged writes.
---
--- The renderer is SSBO-driven, so this is the primary way data reaches the
--- GPU: instance data, draw arguments, and anything a compute pass produces.
---
--- SDL_GPU has no mappable device buffer. Data reaches one by being written
--- into a mapped transfer buffer and copied across in a copy pass, and the
--- transfer buffer must be unmapped before that copy is encoded. That staged
--- copy is unavoidable. What is avoidable is a second one: `map` hands out the
--- driver's own address, so a producer walking archetype columns copies
--- straight into it rather than filling a staging array that then has to be
--- copied again.
---
--- Writes are tracked as ranges rather than replacing the whole buffer,
--- because most frames change very little of what is resident. Only marked
--- ranges are copied.

local sdl <const> = require("tecs2d.ffi.sdl3")
local loader <const> = require("tecs2d.ffi.loader")

local C <const> = sdl.C
local K <const> = sdl.K

--- Distinct dirty ranges tracked before they are collapsed into one span.
--- Collapsing costs bandwidth; tracking costs nothing until it is exceeded.
local MAX_RANGES <const> = 64

local record BufferOptions
    --- Any of "storage", "indirect", "vertex", "index", "computeRead",
    --- "computeWrite". A buffer written by compute and then drawn from needs
    --- both "indirect" and "computeWrite".
    usage: {string}
    --- Size in bytes.
    size: integer
    --- Bytes of staging to allocate. Defaults to the full buffer size, which
    --- lets any range be written. A smaller value bounds the extra residency
    --- at the cost of capping how much may change in one frame.
    stagingSize: integer
    name: string
end

local record Buffer
    handle: loader.CPtr
    size: integer
    --- Bytes marked dirty since the last flush.
    dirtyBytes: integer
    _device: loader.CPtr
    _transfer: loader.CPtr
    _transferSize: integer
    _mapped: loader.CValue
    _ranges: loader.CArray
    _rangeCount: integer
    _collapsed: boolean
    _destroyed: boolean
end

local BufferMT <const>: metatable<Buffer> = { __index = Buffer }

local USAGE_FLAGS <const>: {string: integer} = {
    vertex = K.SDL_GPU_BUFFERUSAGE_VERTEX,
    index = K.SDL_GPU_BUFFERUSAGE_INDEX,
    indirect = K.SDL_GPU_BUFFERUSAGE_INDIRECT,
    storage = K.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
    computeRead = K.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ,
    computeWrite = K.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
}

--- Creates a buffer and its staging allocation.
function Buffer.create(device: loader.CPtr, options: BufferOptions): Buffer
    local flags = 0
    for _, name in ipairs(options.usage or { "storage" }) do
        local flag = USAGE_FLAGS[name]
        if flag == nil then
            error(("tecs2d: unknown buffer usage '%s'"):format(tostring(name)), 2)
        end
        flags = flags + flag
    end

    local info = loader.newArray("SDL_GPUBufferCreateInfo[1]")
    local settings = info[0] as loader.CStruct
    settings.usage = flags
    settings.size = options.size
    settings.props = 0

    local handle = C.SDL_CreateGPUBuffer(device, info)
    if handle == nil then sdl.fail("SDL_CreateGPUBuffer") end

    local self = setmetatable({} as Buffer, BufferMT)
    self.handle = handle
    self.size = options.size
    self.dirtyBytes = 0
    self._device = device
    self._transferSize = options.stagingSize or options.size
    self._rangeCount = 0
    self._collapsed = false
    self._destroyed = false
    self._ranges = loader.newArray("uint32_t[?]", MAX_RANGES * 2)
    return self
end

local function ensureTransfer(self: Buffer)
    if self._transfer ~= nil then return end
    local info = loader.newArray("SDL_GPUTransferBufferCreateInfo[1]")
    local settings = info[0] as loader.CStruct
    settings.usage = C.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD
    settings.size = self._transferSize
    settings.props = 0
    self._transfer = C.SDL_CreateGPUTransferBuffer(self._device, info)
    if self._transfer == nil then sdl.fail("SDL_CreateGPUTransferBuffer") end
end

--- Maps the staging memory and returns the driver's address.
---
--- Write directly into this: it is the whole point of the type. Cycling is on
--- by default, so a map never waits on a frame still reading the previous
--- contents; only ranges marked since the last flush are copied, so nothing
--- is lost by cycling.
---
--- The pointer is valid until `flush`, which must unmap before it can encode
--- the copy.
function Buffer:map(cycle?: boolean): loader.BytePointer
    ensureTransfer(self)
    if self._mapped ~= nil then
        return loader.bytePointer(self._mapped)
    end
    local shouldCycle = cycle ~= false
    local mapped = C.SDL_MapGPUTransferBuffer(self._device, self._transfer,
        shouldCycle)
    if mapped == nil then sdl.fail("SDL_MapGPUTransferBuffer") end
    self._mapped = mapped as loader.CValue
    return loader.bytePointer(self._mapped)
end

--- Maps the staging memory as an array of `declaration`.
---
--- Lets a producer assign struct fields in place rather than assembling a
--- record elsewhere and copying it in.
function Buffer:mapAs(declaration: string, cycle?: boolean): loader.CArray
    self:map(cycle)
    return loader.castPointer(declaration, self._mapped)
end

--- Records that `size` bytes at `offset` were written.
---
--- Adjacent and overlapping writes merge, which is the common case when a
--- producer walks rows in order. Beyond `MAX_RANGES` distinct spans the whole
--- dirty region collapses to one, trading bandwidth for bounded bookkeeping.
function Buffer:markDirty(offset: integer, size: integer)
    if size <= 0 then return end
    self.dirtyBytes = self.dirtyBytes + size

    if self._collapsed then
        local ranges = self._ranges
        local start = math.min(ranges[0] as integer, offset)
        local finish = math.max((ranges[0] as integer) + (ranges[1] as integer),
            offset + size)
        ranges[0] = start
        ranges[1] = finish - start
        return
    end

    local ranges = self._ranges
    local count = self._rangeCount

    if count > 0 then
        local lastOffset = ranges[(count - 1) * 2] as integer
        local lastSize = ranges[(count - 1) * 2 + 1] as integer
        if offset <= lastOffset + lastSize and offset + size >= lastOffset then
            local start = math.min(lastOffset, offset)
            local finish = math.max(lastOffset + lastSize, offset + size)
            ranges[(count - 1) * 2] = start
            ranges[(count - 1) * 2 + 1] = finish - start
            return
        end
    end

    if count >= MAX_RANGES then
        local start = ranges[0] as integer
        local finish = start
        for index = 0, count - 1 do
            local rangeEnd = (ranges[index * 2] as integer)
                + (ranges[index * 2 + 1] as integer)
            start = math.min(start, ranges[index * 2] as integer)
            finish = math.max(finish, rangeEnd)
        end
        start = math.min(start, offset)
        finish = math.max(finish, offset + size)
        ranges[0] = start
        ranges[1] = finish - start
        self._rangeCount = 1
        self._collapsed = true
        return
    end

    ranges[count * 2] = offset
    ranges[count * 2 + 1] = size
    self._rangeCount = count + 1
end

--- Copies `size` bytes from `source` into staging at `offset` and marks it.
---
--- A convenience for producers that already hold a contiguous block. A
--- producer that can write in place should use `map` and skip this copy.
function Buffer:write(offset: integer, source: loader.CValue, size: integer)
    local base = self:map()
    loader.copyTo(base + offset, source, size)
    self:markDirty(offset, size)
end

--- Unmaps staging and encodes the marked ranges onto `commandBuffer`.
---
--- Returns whether anything was copied. Uses the caller's command buffer
--- rather than submitting its own, so the upload is ordered against the frame
--- that consumes it instead of racing a separate submission.
---
--- The destination is never cycled: cycling discards a buffer's contents, so
--- it would erase every range this frame did not rewrite.
function Buffer:flush(commandBuffer: loader.CValue): boolean
    if self._mapped ~= nil then
        C.SDL_UnmapGPUTransferBuffer(self._device, self._transfer)
        self._mapped = nil
    end

    local count = self._rangeCount
    if count == 0 then return false end

    local from = loader.newArray("SDL_GPUTransferBufferLocation[1]")
    local to = loader.newArray("SDL_GPUBufferRegion[1]")
    local source = from[0] as loader.CStruct
    local destination = to[0] as loader.CStruct
    source.transfer_buffer = self._transfer
    destination.buffer = self.handle

    local copyPass = C.SDL_BeginGPUCopyPass(commandBuffer)
    for index = 0, count - 1 do
        local offset = self._ranges[index * 2] as integer
        local size = self._ranges[index * 2 + 1] as integer
        source.offset = offset
        destination.offset = offset
        destination.size = size
        C.SDL_UploadToGPUBuffer(copyPass, from, to, false)
    end
    C.SDL_EndGPUCopyPass(copyPass)

    self._rangeCount = 0
    self._collapsed = false
    self.dirtyBytes = 0
    return true
end

--- Uploads a contiguous block on its own command buffer.
---
--- For setup and tests. Per-frame writes belong on the frame's command buffer
--- through `map` and `flush`.
function Buffer:upload(source: loader.CArray, byteCount: integer, offset?: integer)
    self:write(offset or 0, source as loader.CValue, byteCount)
    local commandBuffer = C.SDL_AcquireGPUCommandBuffer(self._device)
    if commandBuffer == nil then sdl.fail("SDL_AcquireGPUCommandBuffer") end
    self:flush(commandBuffer as loader.CValue)
    sdl.check(C.SDL_SubmitGPUCommandBuffer(commandBuffer) as boolean,
        "SDL_SubmitGPUCommandBuffer")
end

--- Releases the buffer and its staging. Safe to call more than once.
function Buffer:destroy()
    if self._destroyed then return end
    self._destroyed = true
    if self._mapped ~= nil then
        C.SDL_UnmapGPUTransferBuffer(self._device, self._transfer)
        self._mapped = nil
    end
    if self._transfer ~= nil then
        C.SDL_ReleaseGPUTransferBuffer(self._device, self._transfer)
        self._transfer = nil
    end
    C.SDL_ReleaseGPUBuffer(self._device, self.handle)
    self.handle = nil
end

return Buffer
