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
---
--- `begin` and `bindStorageBuffers` each fill a module-level array that SDL
--- copies out of during the call and never reads again, so one of each may be
--- in flight at a time. That is the same constraint SDL's own one-pass rule
--- already imposes, and it is what makes both allocation free.

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local passscope <const> = require("tecs.gpu.passscope")

local C <const> = sdl.C

--- Read-write and read-only storage buffers one call may carry, which is SDL's
--- per-stage ceiling. Over it is refused here rather than read past the end of
--- the arrays below.
local MAX_BUFFER_BINDINGS <const> = 8

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
    --- @param reuse A finished pass whose object is begun again, or nil for a
    ---     fresh one. This is for the frame path, which begins the same passes
    ---     every frame: a pass object per pass per frame is a table per pass
    ---     per frame, and reusing one costs nothing. What it costs the caller
    ---     is that the object describes one pass at a time, so a pass handed to
    ---     anything that might keep it must not be a reused one.
    --- @return The open pass, which the caller must `finish` before beginning
    ---     another or submitting the frame.
    begin: function(commandBuffer: loader.CValue, readWriteBuffers: {loader.CValue}, reuse?: ComputePass): ComputePass

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

-- Reused across passes, for the reason in the header.
local readWrite <const> = loader.newArray(
    "SDL_GPUStorageBufferReadWriteBinding[?]", MAX_BUFFER_BINDINGS)
local handles <const> = loader.newArray("SDL_GPUBuffer*[?]", MAX_BUFFER_BINDINGS)

--- Fills `pass` in and records it as open. Shared by `wrap` and `begin`.
local function open(pass: ComputePass, handle: loader.CPtr,
                    commandBuffer: loader.CValue): ComputePass
    pass.handle = handle
    pass.commandBuffer = commandBuffer
    pass._finished = false
    if commandBuffer ~= nil then
        passscope.opened(commandBuffer, pass as passscope.Pass)
    end
    return pass
end

function ComputePass.wrap(handle: loader.CPtr,
                          commandBuffer?: loader.CValue): ComputePass
    return open(setmetatable({} as ComputePass, ComputePassMT), handle,
        commandBuffer)
end

function ComputePass.begin(commandBuffer: loader.CValue, readWriteBuffers: {loader.CValue}, reuse?: ComputePass): ComputePass
    local count = 0
    if readWriteBuffers ~= nil then
        count = #readWriteBuffers
        if count > MAX_BUFFER_BINDINGS then
            error(("tecs: %d read-write buffers exceeds the limit of %d")
                :format(count, MAX_BUFFER_BINDINGS), 2)
        end
        for index = 1, count do
            local binding = readWrite[index - 1] as loader.CStruct
            binding.buffer = readWriteBuffers[index]
            -- Not cycling: the pass overwrites contents it is about to have
            -- read back, so there is no prior data worth preserving.
            binding.cycle = false
        end
    end

    local handle = C.SDL_BeginGPUComputePass(commandBuffer,
        nil, 0, readWrite, count)
    if handle == nil then sdl.fail("SDL_BeginGPUComputePass") end
    return open(reuse or setmetatable({} as ComputePass, ComputePassMT),
        handle, commandBuffer)
end

function ComputePass:bindPipeline(pipeline: loader.CValue)
    C.SDL_BindGPUComputePipeline(self.handle, pipeline)
end

function ComputePass:bindStorageBuffers(firstSlot: integer, buffers: {loader.CValue})
    local count <const> = #buffers
    if count > MAX_BUFFER_BINDINGS then
        error(("tecs: %d storage buffers exceeds the limit of %d")
            :format(count, MAX_BUFFER_BINDINGS), 2)
    end
    for index = 1, count do
        handles[index - 1] = buffers[index]
    end
    C.SDL_BindGPUComputeStorageBuffers(self.handle, firstSlot, handles, count)
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
