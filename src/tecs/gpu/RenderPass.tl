--- A render pass recorded into a command buffer.
---
--- Held as a value rather than reached through module state, so passes on
--- different threads cannot collide and a pass can never outlive the frame
--- that opened it without that being visible at the call site.
---
--- Supports multiple colour attachments, which is what makes a deferred
--- G-buffer one pass rather than one pass per channel.

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")

local C <const> = sdl.C

--- Largest number of simultaneous colour attachments a pass may bind.
local MAX_COLOR_TARGETS <const> = 8

local record RenderPass
    record ClearColor
        r: number
        g: number
        b: number
        a: number
    end

    record Attachment
        --- Texture handle to render into.
        texture: loader.CValue
        --- Clears to this colour. Omit to load and preserve existing contents.
        clear: RenderPass.ClearColor
    end

    handle: loader.CPtr
    --- The command buffer this pass records into. Uniform pushes target the
    --- command buffer rather than the pass, so it is kept here to save every
    --- caller from threading it alongside.
    commandBuffer: loader.CValue
    --- Number of colour attachments this pass was begun with.
    targetCount: integer
    _finished: boolean
end

local RenderPassMT <const>: metatable<RenderPass> = { __index = RenderPass }

-- Reused across passes; a pass is begun far too often to allocate for it.
local targets <const> = loader.newArray("SDL_GPUColorTargetInfo[?]", MAX_COLOR_TARGETS)

--- Wraps an already-begun pass handle.
function RenderPass.wrap(handle: loader.CPtr, commandBuffer: loader.CValue,
                        targetCount?: integer): RenderPass
    local self = setmetatable({} as RenderPass, RenderPassMT)
    self.handle = handle
    self.commandBuffer = commandBuffer
    self.targetCount = targetCount or 1
    self._finished = false
    return self
end

--- Begins a render pass over one or more colour attachments.
function RenderPass.begin(commandBuffer: loader.CValue,
                          attachments: {RenderPass.Attachment}): RenderPass
    local count = #attachments
    if count == 0 then
        error("tecs2d: a render pass needs at least one colour attachment", 2)
    end
    if count > MAX_COLOR_TARGETS then
        error(("tecs2d: %d colour attachments exceeds the limit of %d")
            :format(count, MAX_COLOR_TARGETS), 2)
    end

    for index, attachment in ipairs(attachments) do
        local target = targets[index - 1] as loader.CStruct
        target.texture = attachment.texture
        target.mip_level = 0
        target.layer_or_depth_plane = 0
        target.resolve_texture = nil
        target.cycle = false
        target.cycle_resolve_texture = false
        target.store_op = C.SDL_GPU_STOREOP_STORE

        local clear = attachment.clear
        if clear ~= nil then
            target.load_op = C.SDL_GPU_LOADOP_CLEAR
            local color = target.clear_color as loader.CStruct
            color.r = clear.r or 0.0
            color.g = clear.g or 0.0
            color.b = clear.b or 0.0
            color.a = clear.a or 1.0
        else
            target.load_op = C.SDL_GPU_LOADOP_LOAD
        end
    end

    local handle = C.SDL_BeginGPURenderPass(commandBuffer, targets, count, nil)
    if handle == nil then sdl.fail("SDL_BeginGPURenderPass") end
    return RenderPass.wrap(handle, commandBuffer, count)
end

--- Binds a pipeline. All subsequent draws in this pass use its baked state.
function RenderPass:bindPipeline(pipeline: loader.CValue)
    C.SDL_BindGPUGraphicsPipeline(self.handle, pipeline)
end

--- Binds textures with their samplers to the fragment stage.
---
--- This is how a deferred pass reads the previous pass's output.
function RenderPass:bindTextures(firstSlot: integer,
                                 textures: {loader.CValue},
                                 sampler: loader.CValue)
    local bindings = loader.newArray("SDL_GPUTextureSamplerBinding[?]", #textures)
    for index, texture in ipairs(textures) do
        local binding = bindings[index - 1] as loader.CStruct
        binding.texture = texture
        binding.sampler = sampler
    end
    C.SDL_BindGPUFragmentSamplers(self.handle, firstSlot, bindings, #textures)
end

--- Binds read-only storage buffers to the vertex stage.
function RenderPass:bindVertexStorageBuffers(firstSlot: integer,
                                             buffers: {loader.CValue})
    local handles = loader.newArray("SDL_GPUBuffer*[?]", #buffers)
    for index, buffer in ipairs(buffers) do
        handles[index - 1] = buffer
    end
    C.SDL_BindGPUVertexStorageBuffers(self.handle, firstSlot, handles, #buffers)
end

--- Binds read-only storage buffers to the fragment stage.
function RenderPass:bindFragmentStorageBuffers(firstSlot: integer,
                                               buffers: {loader.CValue})
    local handles = loader.newArray("SDL_GPUBuffer*[?]", #buffers)
    for index, buffer in ipairs(buffers) do
        handles[index - 1] = buffer
    end
    C.SDL_BindGPUFragmentStorageBuffers(self.handle, firstSlot, handles, #buffers)
end

--- Pushes uniform data to the vertex stage.
function RenderPass:pushVertexUniform(slot: integer, data: loader.CArray,
                                      byteCount: integer)
    C.SDL_PushGPUVertexUniformData(self.commandBuffer, slot, data, byteCount)
end

--- Pushes uniform data to the fragment stage.
function RenderPass:pushFragmentUniform(slot: integer, data: loader.CArray,
                                        byteCount: integer)
    C.SDL_PushGPUFragmentUniformData(self.commandBuffer, slot, data, byteCount)
end

--- Issues a draw.
---
--- There are no vertex buffers: the vertex shader reads whatever it needs
--- from storage buffers, indexed by vertex and instance ID.
function RenderPass:draw(vertexCount: integer, instanceCount?: integer,
                         firstVertex?: integer, firstInstance?: integer)
    C.SDL_DrawGPUPrimitives(self.handle, vertexCount, instanceCount or 1,
        firstVertex or 0, firstInstance or 0)
end

--- Issues a draw whose parameters the GPU wrote into `buffer`.
---
--- This is the shape the renderer is built around: a compute pass culls and
--- writes the draw arguments, and the CPU never learns the count.
function RenderPass:drawIndirect(buffer: loader.CValue, offset: integer,
                                 drawCount: integer)
    C.SDL_DrawGPUPrimitivesIndirect(self.handle, buffer, offset or 0, drawCount or 1)
end

--- Ends the pass. Every begun pass must be finished before its frame submits.
--- Safe to call more than once.
--- Binds the index buffer subsequent indexed draws read.
---
--- 16-bit indices: a quad needs four distinct corners, so the values never
--- approach the limit and the buffer stays half the size of a 32-bit one.
function RenderPass:bindIndexBuffer(buffer: loader.CValue, offset?: integer)
    local binding = loader.newArray("SDL_GPUBufferBinding[1]")
    local slot = binding[0] as loader.CStruct
    slot.buffer = buffer
    slot.offset = offset or 0
    C.SDL_BindGPUIndexBuffer(self.handle, binding,
        C.SDL_GPU_INDEXELEMENTSIZE_16BIT)
end

--- Issues an indexed draw whose parameters the GPU wrote.
function RenderPass:drawIndexedIndirect(buffer: loader.CValue, offset: integer,
                                        drawCount: integer)
    C.SDL_DrawGPUIndexedPrimitivesIndirect(self.handle, buffer, offset,
        drawCount)
end

function RenderPass:finish()
    if self._finished then return end
    self._finished = true
    C.SDL_EndGPURenderPass(self.handle)
    self.handle = nil
end

return RenderPass
