--[=[
A GPU buffer with staged, dirty-ranged writes.

The renderer is SSBO-driven, so this is the primary way data reaches the
GPU: instance data, draw arguments, and anything a compute pass produces.

SDL_GPU has no mappable device buffer. Data reaches one by being written
into a mapped transfer buffer and copied across in a copy pass, and the
transfer buffer must be unmapped before that copy is encoded. That staged
copy is unavoidable. What is avoidable is a second one: `map` hands out the
driver's own address, so a producer walking archetype columns copies
straight into it rather than filling a staging array that then has to be
copied again.

Writes are tracked as ranges rather than replacing the whole buffer,
because most frames change very little of what is resident. Only marked
ranges are copied.

One device buffer, several staging slots. Extraction writes into one slot
while a submitted upload is still reading another, so the CPU never
overwrites memory the GPU has not finished with and no copy passes between
them. The rotation answers GPU concurrency, which one thread does not
remove.
Slots are addressed by index and all of their bookkeeping is per slot:
mapped address, recorded ranges, dirty byte count. A caller that only
writes sees an address and a capacity; creating, mapping, unmapping,
flushing, cycling and destroying slots belongs to whoever owns the device.

The device buffer is shared, persistent, and never cycled.
]=]

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local dirtyranges <const> = require("tecs.gpu.dirtyranges")

local C <const> = sdl.C
local K <const> = sdl.K

--- Staging slots every buffer carries.
---
--- Two: one being written while the other is being flushed. Slot zero is what
--- a caller that never names a slot gets.
local SLOT_COUNT <const> = 2

--- One slot's staging allocation and the writes recorded against it.
---
--- Ranges are per slot rather than shared. Two slots being written and flushed
--- independently is the entire point, and a shared range list would make each
--- flush copy the other slot's bytes out of memory that never received them.
local record Slot
    --- The `SDL_GPUTransferBuffer`, created the first time the slot is mapped.
    transfer: loader.CPtr
    --- The driver's address while the slot is mapped, nil while it is not.
    --- Held rather than remapped, because remapping cycles and cycling would
    --- move the address out from under a writer still holding it.
    mapped: loader.CValue
    --- Recorded writes. Empty is a slot with nothing to flush, which is what
    --- `flushSlot` returns false on.
    ranges: dirtyranges
    --- The last typed view handed out over this slot, the declaration it was
    --- cast to, and the address it was cast from. A cast allocates a cdata
    --- object, and `mapSlotAs` is on the frame path, so the answer is kept and
    --- handed back whenever the driver maps the slot to the same address
    --- again, which is what mapping without cycling does.
    view: loader.CArray
    viewDeclaration: string
    viewOf: loader.CValue
end

local record BufferOptions
    --- Any of "index", "indirect", "storage", "computeRead", "computeWrite". A
    --- buffer written by compute and then drawn from needs both "indirect" and
    --- "computeWrite". Defaults to "storage".
    usage: {string}
    --- Size in bytes, fixed for the buffer's life. Growing means creating
    --- another buffer, and the old one stays live until every frame that could
    --- still reference it has retired.
    size: integer
    --- Bytes of staging to allocate per slot. Defaults to the full buffer
    --- size, which lets any range be written. A smaller value bounds the extra
    --- residency at the cost of capping how much may change in one frame.
    stagingSize: integer
    --- Label handed to SDL, which a graphics debugger shows against the
    --- resource. Optional; a buffer created without one is unnamed there.
    name: string
end

--- One device buffer and its staging slots, and the type `create` returns.
---
--- The device buffer is persistent and never cycled, so what it holds survives
--- every frame that does not overwrite it. Writes go into a slot's mapped
--- staging and reach the device only when that slot is flushed onto a command
--- buffer. Size is fixed for the buffer's life.
local record Buffer
    --- Staging slots every buffer carries, so a caller can loop by index.
    slotCount: integer
    --- The `SDL_GPUBuffer`, shared by every slot. Nil once `destroy` has run.
    handle: loader.CPtr
    --- Device buffer size in bytes, which is the largest offset plus size a
    --- write may name.
    size: integer
    --- The name SDL was given, or nil when none was asked for.
    name: string
    --- Bytes marked dirty on slot zero since its last flush. Slot-aware
    --- callers read `slotDirtyBytes` instead.
    dirtyBytes: integer
    --- The `SDL_GPUDevice` the buffer and its staging were created against, and
    --- the one `destroy` releases them from.
    _device: loader.CPtr
    --- The `SDL_GPU_BUFFERUSAGE_*` bits `create` resolved from the usage names.
    --- Recorded and read nowhere: the buffer is created once and never rebuilt.
    _usage: integer
    --- Staging bytes per slot, and the capacity `mapSlot` reports.
    _transferSize: integer
    --- Indexed one-based, while every method takes a slot zero-based: the
    --- outside numbering matches the frame index a caller alternates with.
    _slots: {Slot}
    --- Set by the first `destroy`, so a second one releases nothing again.
    _destroyed: boolean
end

Buffer.slotCount = SLOT_COUNT

local BufferMT <const>: metatable<Buffer> = {__index = Buffer}

-- Reused across flushes; every buffer flushes a slot every frame and an array
-- allocated for each would be two cdata objects per flush on the frame path.
-- SDL copies out of these during `SDL_UploadToGPUBuffer`, so they only have to
-- hold still for that call, and only one flush may be walking them: the encode
-- below runs to completion on the thread that owns the device, which is the
-- same constraint `RenderPass` records its color targets under.
local transferSource <const> = loader.newArray("SDL_GPUTransferBufferLocation[1]")
local bufferDestination <const> = loader.newArray("SDL_GPUBufferRegion[1]")

-- No vertex usage: geometry comes from storage buffers indexed by vertex and
-- instance ID, so there is no vertex buffer to bind. An index buffer is the one
-- exception, because indices are what let a quad cost four vertex invocations
-- instead of six.
local USAGE_FLAGS <const>: {string: integer} = {
    index = K.SDL_GPU_BUFFERUSAGE_INDEX,
    indirect = K.SDL_GPU_BUFFERUSAGE_INDIRECT,
    storage = K.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
    computeRead = K.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ,
    computeWrite = K.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
}

local function createDeviceBuffer(device: loader.CPtr, usage: integer, size: integer): loader.CPtr
    local info = loader.newArray("SDL_GPUBufferCreateInfo[1]")
    local settings = info[0] as loader.CStruct
    settings.usage = usage
    settings.size = size
    settings.props = 0
    local handle = C.SDL_CreateGPUBuffer(device, info)
    if handle == nil then
        sdl.fail("SDL_CreateGPUBuffer")
    end
    return handle as loader.CPtr
end

local function createTransfer(device: loader.CPtr, size: integer): loader.CPtr
    local info = loader.newArray("SDL_GPUTransferBufferCreateInfo[1]")
    local settings = info[0] as loader.CStruct
    settings.usage = C.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD
    settings.size = size
    settings.props = 0
    local transfer = C.SDL_CreateGPUTransferBuffer(device, info)
    if transfer == nil then
        sdl.fail("SDL_CreateGPUTransferBuffer")
    end
    return transfer as loader.CPtr
end

--- Creates a buffer and the bookkeeping for its staging slots.
---
--- Staging itself is allocated on first use, so a buffer nobody writes to
--- costs one device allocation and nothing else.
--- @param device The `SDL_GPUDevice`, which is `Device.handle` and not the
---     wrapper around it.
--- @param options An unknown usage name raises. `size` is required and fixed;
---     growing means creating another buffer.
--- @return A buffer whose device memory is undefined until something writes
---     it, with no staging allocated and no slot mapped.
function Buffer.create(device: loader.CPtr, options: BufferOptions): Buffer
    local flags = 0
    for _, name in ipairs(options.usage or {"storage"}) do
        local flag = USAGE_FLAGS[name]
        if flag == nil then
            error(("tecs: unknown buffer usage '%s'"):format(tostring(name)), 2)
        end
        flags = flags + flag
    end

    local self = setmetatable({} as Buffer, BufferMT)
    self.handle = createDeviceBuffer(device, flags, options.size)
    -- A device created without debug mode keeps no names, so this is free in a
    -- release and the difference is only visible in a graphics debugger.
    if options.name ~= nil then
        C.SDL_SetGPUBufferName(device, self.handle, options.name)
    end
    self.name = options.name
    self.size = options.size
    self.dirtyBytes = 0
    self._device = device
    self._usage = flags
    self._transferSize = options.stagingSize or options.size
    self._destroyed = false
    self._slots = {}
    for index = 1, SLOT_COUNT do
        self._slots[index] = {ranges = dirtyranges.create()}
    end
    return self
end

local function slotAt(self: Buffer, index: integer): Slot
    local slot = self._slots[index + 1]
    if slot == nil then
        error(("tecs: buffer slot %s is outside 0..%d"):format(tostring(index), SLOT_COUNT - 1), 3)
    end
    return slot
end

local function ensureTransfer(self: Buffer, slot: Slot)
    if slot.transfer ~= nil then
        return
    end
    -- Every slot carries a full staging set, so the second one doubles
    -- worst-case transfer residency: at four million instances the two staging
    -- sets are roughly 640 MB, before the driver's own cycling doubles what it
    -- holds again. That is the price of letting a producer write while the
    -- device owner uploads, and it is paid deliberately.
    slot.transfer = createTransfer(self._device, self._transferSize)
end

local function mapSlotRecord(self: Buffer, slot: Slot, cycle?: boolean): loader.CValue
    ensureTransfer(self, slot)
    if slot.mapped ~= nil then
        return slot.mapped
    end
    local shouldCycle = cycle ~= false
    local mapped = C.SDL_MapGPUTransferBuffer(self._device, slot.transfer, shouldCycle)
    if mapped == nil then
        sdl.fail("SDL_MapGPUTransferBuffer")
    end
    slot.mapped = mapped as loader.CValue
    return slot.mapped
end

local function unmapSlotRecord(self: Buffer, slot: Slot)
    if slot.mapped == nil then
        return
    end
    C.SDL_UnmapGPUTransferBuffer(self._device, slot.transfer)
    slot.mapped = nil
end

--- Maps a slot's staging memory and returns its address and capacity.
---
--- Write directly into the address: it is the whole point of the type. The
--- capacity is how many bytes the slot holds, which is the buffer size unless
--- `stagingSize` bounded it.
---
--- Cycling is on by default, so a map never waits on a frame still reading the
--- previous contents; only ranges marked since the last flush are copied, so
--- nothing is lost by cycling. A slot already mapped hands back the same
--- address without remapping, because cycling would move it out from under a
--- writer that is still holding it.
---
--- The address is valid until the slot is flushed or cycled.
--- @param index Slot to map, zero-based, below `slotCount`.
--- @param cycle Pass false to keep the driver's existing allocation, which is
---     what a writer adding to what a previous frame left in the slot wants.
--- @return The address to write into.
--- @return The bytes the slot holds, which is `stagingSize` or the buffer's
---     size when none was given.
function Buffer:mapSlot(index: integer, cycle?: boolean): loader.BytePointer, integer
    local slot = slotAt(self, index)
    return loader.bytePointer(mapSlotRecord(self, slot, cycle)), self._transferSize
end

--- Maps a slot's staging memory as an array of `declaration`.
---
--- Lets a producer assign struct fields in place rather than assembling a
--- record elsewhere and copying it in.
---
--- The view is cached against the address it was cast from, so a slot mapped
--- again to the same allocation hands back the same object instead of
--- allocating another. A cycled slot, or one asked for under a different
--- declaration, is cast afresh.
--- @param index Slot to map, zero-based, below `slotCount`.
--- @param declaration A C array declaration such as "Instance*", cast from the
---     slot's base address. Element indices, not bytes; `markSlotDirty` still
---     takes bytes.
--- @param cycle Pass false to keep the driver's existing allocation.
--- @return An array over the slot's staging, valid until the slot is flushed
---     or cycled, and shared with anything else that asked for the same view.
function Buffer:mapSlotAs(index: integer, declaration: string, cycle?: boolean): loader.CArray
    local slot = slotAt(self, index)
    local mapped = mapSlotRecord(self, slot, cycle)
    if slot.view ~= nil and slot.viewDeclaration == declaration and slot.viewOf == mapped then
        return slot.view
    end
    local view = loader.castPointer(declaration, mapped)
    slot.view = view
    slot.viewDeclaration = declaration
    slot.viewOf = mapped
    return view
end

--- Records that `size` bytes at `offset` were written into a slot.
---
--- Adjacent and overlapping writes merge; see `dirtyranges` for the ceiling
--- and what happens past it.
--- @param offset Bytes from the start of the buffer, matching the address
---     `mapSlot` returned. A size of zero or less records nothing.
function Buffer:markSlotDirty(index: integer, offset: integer, size: integer)
    if size <= 0 then
        return
    end
    local slot = slotAt(self, index)
    slot.ranges:mark(offset, size)
    if index == 0 then
        self.dirtyBytes = slot.ranges.bytes
    end
end

--- Records every range in `ranges` against a slot.
---
--- What a frame packet's ranges arrive through: the half that wrote the bytes
--- recorded them without a buffer to record them on, and this is where they
--- meet the device buffer they describe.
--- @param ranges Read and not kept, so the caller may clear it as soon as this
---     returns. Offsets are bytes into the device buffer, as `markSlotDirty`
---     takes them.
function Buffer:markSlotRanges(index: integer, ranges: dirtyranges)
    for entry = 0, ranges.count - 1 do
        local offset, size = ranges:at(entry)
        self:markSlotDirty(index, offset, size)
    end
end

--- Copies `size` bytes from `source` into a slot at `offset` and marks it.
---
--- A convenience for producers that already hold a contiguous block. A
--- producer that can write in place should map the slot and skip this copy.
--- @param offset Bytes from the start of the buffer, not an element index.
--- @param source Read during this call only; the caller's memory is free
---     immediately afterwards.
--- @param size Bytes to copy. Maps the slot as a side effect, so the address
---     any earlier `mapSlot` handed out is still the right one.
function Buffer:writeSlot(index: integer, offset: integer, source: loader.CValue, size: integer)
    local base = self:mapSlot(index)
    loader.copyTo(base + offset, source, size)
    self:markSlotDirty(index, offset, size)
end

--- Bytes marked dirty on a slot since its last flush.
---
--- Summed as marked rather than deduplicated, so this answers how much a
--- producer wrote and not how much the flush copies. Zero means the flush
--- would encode nothing, which is the useful test.
function Buffer:slotDirtyBytes(index: integer): integer
    return slotAt(self, index).ranges.bytes
end

--- Unmaps a slot without flushing it.
---
--- The recorded ranges survive, so a later flush still copies them.
function Buffer:unmapSlot(index: integer)
    unmapSlotRecord(self, slotAt(self, index))
end

--- Unmaps a slot and encodes its marked ranges onto `commandBuffer`.
---
--- Returns whether anything was copied. Uses the caller's command buffer
--- rather than submitting its own, so the upload is ordered against the frame
--- that consumes it instead of racing a separate submission. SDL executes
--- command buffers in submission order, so a slot flushed after another cannot
--- overtake it: a later delta never runs before the packet it builds on.
---
--- The destination is never cycled: cycling discards a buffer's contents, so
--- it would erase every range this flush did not rewrite. That is what makes
--- one persistent device buffer behind several slots correct, and it is why
--- ranges are tracked at all.
---
--- The slot is left unmapped and its ranges cleared, so flushing twice copies
--- nothing the second time.
--- @return Whether any range was encoded. False on a slot nothing marked,
---     which is how a caller skips the pass that would have consumed it.
function Buffer:flushSlot(index: integer, commandBuffer: loader.CValue): boolean
    local slot = slotAt(self, index)
    unmapSlotRecord(self, slot)

    local ranges = slot.ranges
    local count = ranges.count
    if count == 0 then
        return false
    end

    local source = transferSource[0] as loader.CStruct
    local destination = bufferDestination[0] as loader.CStruct
    source.transfer_buffer = slot.transfer
    destination.buffer = self.handle

    local copyPass = C.SDL_BeginGPUCopyPass(commandBuffer)
    for entry = 0, count - 1 do
        local offset, size = ranges:at(entry)
        source.offset = offset
        destination.offset = offset
        destination.size = size
        C.SDL_UploadToGPUBuffer(copyPass, transferSource, bufferDestination, false)
    end
    C.SDL_EndGPUCopyPass(copyPass)

    ranges:clear()
    if index == 0 then
        self.dirtyBytes = 0
    end
    return true
end

--- Remaps a flushed slot with cycling and hands back a fresh address.
---
--- Call this once the flush that consumed the slot has been submitted, before
--- Call this once the flush that consumed the slot has been submitted, before
--- the slot goes back to whoever writes it. Cycling is what makes the handback
--- free: the driver gives the writer a different allocation rather than
--- stalling until the copy pass has finished reading the old one.
---
--- Only the slot that was just flushed is ever cycled. Cycling moves the
--- address, and the other slot's writer is holding its own.
--- @return A fresh address to write into, which is not the one the previous
---     map handed out, so nothing may keep the old one.
--- @return The bytes the slot holds, which cycling does not change.
function Buffer:cycleSlot(index: integer): loader.BytePointer, integer
    local slot = slotAt(self, index)
    unmapSlotRecord(self, slot)
    return loader.bytePointer(mapSlotRecord(self, slot, true)), self._transferSize
end

-- The methods below name no slot and mean slot zero, and they delegate rather
-- than duplicate. Delegating is the choice because it leaves exactly one
-- implementation of range coalescing and one of the copy encoding: a second
-- copy of either is free to drift, and what drift produces is a partial
-- upload, which reads as a producer bug in whatever consumes the buffer three
-- subsystems later. Slot zero is the right default because a caller that does
-- not name a slot writes and flushes within one frame, which is what a single
-- slot means.

--- Maps slot zero's staging memory and returns the driver's address.
---
--- Drops the capacity `mapSlot` also returns, which a caller that already
--- knows the buffer's size does not need. Ask `mapSlot` for both.
function Buffer:map(cycle?: boolean): loader.BytePointer
    local pointer = self:mapSlot(0, cycle)
    return pointer
end

--- Maps slot zero's staging memory as an array of `declaration`.
function Buffer:mapAs(declaration: string, cycle?: boolean): loader.CArray
    return self:mapSlotAs(0, declaration, cycle)
end

--- Records that `size` bytes at `offset` were written into slot zero.
function Buffer:markDirty(offset: integer, size: integer)
    self:markSlotDirty(0, offset, size)
end

--- Copies `size` bytes from `source` into slot zero at `offset`.
function Buffer:write(offset: integer, source: loader.CValue, size: integer)
    self:writeSlot(0, offset, source, size)
end

--- Unmaps slot zero and encodes its marked ranges onto `commandBuffer`.
function Buffer:flush(commandBuffer: loader.CValue): boolean
    return self:flushSlot(0, commandBuffer)
end

--- Uploads a contiguous block on its own command buffer.
---
--- For setup and tests. Per-frame writes belong on the frame's command buffer
--- through a mapped slot and `flushSlot`.
---
--- Submitted and not waited on, so the copy is ordered only against work
--- submitted after it. That is enough for content uploaded before the first
--- frame and is not enough for anything a frame already in flight reads.
--- @param source Read during this call only.
--- @param byteCount Bytes to copy, which must fit inside slot zero's staging.
--- @param offset Bytes from the start of the device buffer. Defaults to zero.
function Buffer:upload(source: loader.CArray, byteCount: integer, offset?: integer)
    self:write(offset or 0, source as loader.CValue, byteCount)
    local commandBuffer = C.SDL_AcquireGPUCommandBuffer(self._device)
    if commandBuffer == nil then
        sdl.fail("SDL_AcquireGPUCommandBuffer")
    end
    self:flush(commandBuffer as loader.CValue)
    sdl.check(C.SDL_SubmitGPUCommandBuffer(commandBuffer) as boolean, "SDL_SubmitGPUCommandBuffer")
end

--- Releases the buffer and every slot's staging. Safe to call more than once.
function Buffer:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    for index = 1, SLOT_COUNT do
        local slot = self._slots[index]
        if slot.mapped ~= nil then
            C.SDL_UnmapGPUTransferBuffer(self._device, slot.transfer)
            slot.mapped = nil
        end
        if slot.transfer ~= nil then
            C.SDL_ReleaseGPUTransferBuffer(self._device, slot.transfer)
            slot.transfer = nil
        end
        -- The staging it points into is gone, so the cached view is a pointer
        -- to released memory and must not be handed to anyone again.
        slot.view = nil
        slot.viewDeclaration = nil
        slot.viewOf = nil
    end
    C.SDL_ReleaseGPUBuffer(self._device, self.handle)
    self.handle = nil
end

return Buffer
