--- A compute pass recorded into a frame's command buffer.
---
--- Read-write bindings are declared when the pass begins rather than bound
--- inside it. That is SDL_GPU's design, not an accident of this wrapper: the
--- declaration is what lets SDL insert the barriers between a compute pass
--- that writes a buffer and the render pass that reads it.

local sdl <const> = require("tecs2d.ffi.sdl3")
local loader <const> = require("tecs2d.ffi.loader")

local C <const> = sdl.C

local record ComputePass
    handle: loader.CPtr
    _finished: boolean
end

local ComputePassMT <const>: metatable<ComputePass> = { __index = ComputePass }

--- Wraps a begun compute pass handle.
function ComputePass.wrap(handle: loader.CPtr): ComputePass
    local self = setmetatable({} as ComputePass, ComputePassMT)
    self.handle = handle
    self._finished = false
    return self
end

--- Begins a compute pass on `commandBuffer`.
---
--- `readWriteBuffers` are the buffers this pass writes. They must be declared
--- here rather than bound inside the pass: SDL_GPU derives its barriers from
--- this list, so a buffer written by compute and then read by a draw is only
--- correctly ordered if it appears in it.
function ComputePass.begin(commandBuffer: loader.CValue,
                           readWriteBuffers: {loader.CValue}): ComputePass
    readWriteBuffers = readWriteBuffers or {}

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
    return ComputePass.wrap(handle)
end

--- Binds the pipeline whose shader this pass dispatches.
function ComputePass:bindPipeline(pipeline: loader.CValue)
    C.SDL_BindGPUComputePipeline(self.handle, pipeline)
end

--- Binds read-only storage buffers, starting at `firstSlot`.
---
--- Read-write buffers are not bound here; they were declared when the pass
--- began.
function ComputePass:bindStorageBuffers(firstSlot: integer,
                                        buffers: {loader.CValue})
    local handles = loader.newArray("SDL_GPUBuffer*[?]", #buffers)
    for index, buffer in ipairs(buffers) do
        handles[index - 1] = buffer
    end
    C.SDL_BindGPUComputeStorageBuffers(self.handle, firstSlot, handles, #buffers)
end

--- Dispatches `x` by `y` by `z` workgroups.
---
--- These are workgroup counts, not thread counts: the threads per group come
--- from the shader's declared local size.
function ComputePass:dispatch(x: integer, y?: integer, z?: integer)
    C.SDL_DispatchGPUCompute(self.handle, x, y or 1, z or 1)
end

--- Ends the pass. Safe to call more than once.
function ComputePass:finish()
    if self._finished then return end
    self._finished = true
    C.SDL_EndGPUComputePass(self.handle)
    self.handle = nil
end

return ComputePass
