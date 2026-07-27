--- A compute pass recorded into a frame's command buffer.
---
--- Read-write bindings are declared when the pass begins rather than bound
--- inside it. That is SDL_GPU's design, not an accident of this wrapper: the
--- declaration is what lets SDL insert the barriers between a compute pass
--- that writes a buffer and the render pass that reads it.
---
--- Nothing is synchronised within a pass. Two dispatches in one pass race
--- against each other over anything they both touch, so a dispatch that reads
--- what an earlier one wrote belongs in a second pass: finish this one and
--- begin another. That is also the only sequencing available, since no other
--- pass of any kind may begin on the command buffer until this one finishes.

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local passscope <const> = require("tecs.gpu.passscope")

local C <const> = sdl.C

local record ComputePass
    --- The `SDL_GPUComputePass`. Nil once `finish` has run, and valid only
    --- between the begin and the end: a pass does not outlive its command
    --- buffer's recording.
    handle: loader.CPtr
    --- The command buffer this pass was begun on, or nil for a pass wrapped
    --- without one. Kept so the pass can take itself off the open list, which
    --- is what lets a recovery path end a pass whose body threw. Nothing else
    --- reads it: a compute uniform is pushed onto the buffer the caller
    --- already holds.
    commandBuffer: loader.CValue
    _finished: boolean

    --- Wraps a begun compute pass handle.
    ---
    --- For a caller that began the pass itself. `begin` is the usual way in,
    --- and calls this.
    --- @param handle An `SDL_GPUComputePass` that has been begun and not ended.
    --- @param commandBuffer The command buffer it was begun on. Omitting it
    ---     leaves the pass untracked, so a body that throws inside it leaves it
    ---     open and only the caller can end it.
    --- @return A pass that owns the handle and will end it on `finish`.
    wrap: function(handle: loader.CPtr, commandBuffer?: loader.CValue): ComputePass

    --- Begins a compute pass on `commandBuffer`.
    ---
    --- `readWriteBuffers` are the buffers this pass writes. They must be
    --- declared here rather than bound inside the pass: SDL_GPU derives its
    --- barriers from this list, so a buffer written by compute and then read by
    --- a draw is only correctly ordered if it appears in it.
    ---
    --- Order is the binding order the shader's read-write set expects. Under
    --- SPIR-V that set is 1, read-write storage textures first and read-write
    --- storage buffers after them, so with no textures declared the list starts
    --- at binding zero and runs consecutively.
    --- @param commandBuffer The command buffer to record into, with no other
    ---     pass open on it.
    --- @param readWriteBuffers Device buffer handles, not `Buffer` objects,
    ---     each created with the compute-storage-write usage bit. An empty list
    ---     or nil is a pass that only reads.
    --- @return The open pass, which the caller must `finish` before beginning
    ---     another or submitting the frame.
    begin: function(commandBuffer: loader.CValue, readWriteBuffers: {loader.CValue}): ComputePass

    --- Binds the pipeline whose shader this pass dispatches.
    --- @param pipeline An `SDL_GPUComputePipeline` whose reflected read-write
    ---     storage count is what the pass was begun with. A pipeline must be
    ---     bound before the pass's first dispatch.
    bindPipeline: function(self, pipeline: loader.CValue)

    --- Binds read-only storage buffers, starting at `firstSlot`.
    ---
    --- Read-write buffers are not bound here; they were declared when the pass
    --- began.
    --- @param firstSlot Zero-based binding in the shader's read-only set, which
    ---     the list continues from in order. Under SPIR-V that is set 0, after
    ---     any sampled and read-only storage textures the shader declares.
    --- @param buffers Device buffer handles, not `Buffer` objects. Binding one
    ---     the pass also declared read-write races the dispatch that writes it,
    ---     since nothing inside a pass is synchronised.
    bindStorageBuffers: function(self, firstSlot: integer, buffers: {loader.CValue})

    --- Dispatches `x` by `y` by `z` workgroups.
    ---
    --- These are workgroup counts, not thread counts: the threads per group
    --- come from the shader's declared local size, which
    --- `ComputePipeline.threadCount` reports. Covering n items means
    --- dispatching n divided by that, rounded up, and the shader dropping the
    --- invocations past the end.
    --- @param x Workgroups along the first axis.
    --- @param y Defaults to one, as does `z`, which is what a linear dispatch
    ---     over a buffer wants.
    --- @param z Defaults to one.
    dispatch: function(self, x: integer, y?: integer, z?: integer)

    --- Ends the pass.
    ---
    --- Every begun pass must be finished before another pass begins on its
    --- command buffer and before the frame submits. Safe to call more than
    --- once. Finishing is also the ordering point: what this pass wrote is only
    --- visible to a later pass because this one ended.
    finish: function(self)
end

local ComputePassMT <const>: metatable<ComputePass> = { __index = ComputePass }

function ComputePass.wrap(handle: loader.CPtr,
                          commandBuffer?: loader.CValue): ComputePass
    local self = setmetatable({} as ComputePass, ComputePassMT)
    self.handle = handle
    self.commandBuffer = commandBuffer
    self._finished = false
    if commandBuffer ~= nil then
        passscope.opened(commandBuffer, self as passscope.Pass)
    end
    return self
end

function ComputePass.begin(commandBuffer: loader.CValue, readWriteBuffers: {loader.CValue}): ComputePass
    readWriteBuffers = readWriteBuffers or {}

    -- At least one element, because a zero-length VLA is not a thing to
    -- allocate. SDL is told the real count and never reads the slot.
    local bindings = loader.newArray("SDL_GPUStorageBufferReadWriteBinding[?]",
        math.max(#readWriteBuffers, 1))
    for index, buffer in ipairs(readWriteBuffers) do
        local binding = bindings[index - 1] as loader.CStruct
        binding.buffer = buffer
        -- Not cycling: the pass overwrites contents it is about to have read
        -- back, so there is no prior data worth preserving.
        binding.cycle = false
    end

    local handle = C.SDL_BeginGPUComputePass(commandBuffer,
        nil, 0, bindings, #readWriteBuffers)
    if handle == nil then sdl.fail("SDL_BeginGPUComputePass") end
    return ComputePass.wrap(handle, commandBuffer)
end

function ComputePass:bindPipeline(pipeline: loader.CValue)
    C.SDL_BindGPUComputePipeline(self.handle, pipeline)
end

function ComputePass:bindStorageBuffers(firstSlot: integer, buffers: {loader.CValue})
    local handles = loader.newArray("SDL_GPUBuffer*[?]", #buffers)
    for index, buffer in ipairs(buffers) do
        handles[index - 1] = buffer
    end
    C.SDL_BindGPUComputeStorageBuffers(self.handle, firstSlot, handles, #buffers)
end

function ComputePass:dispatch(x: integer, y?: integer, z?: integer)
    C.SDL_DispatchGPUCompute(self.handle, x, y or 1, z or 1)
end

function ComputePass:finish()
    if self._finished then return end
    self._finished = true
    if self.commandBuffer ~= nil then passscope.closed(self.commandBuffer) end
    C.SDL_EndGPUComputePass(self.handle)
    self.handle = nil
end

return ComputePass
