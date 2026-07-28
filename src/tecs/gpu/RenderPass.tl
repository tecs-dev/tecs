--- A render pass recorded into a command buffer.
---
--- Held as a value rather than reached through module state, so a pass can
--- never outlive the frame that opened it without that being visible at the
--- call site, and two passes recorded from different command buffers keep their
--- own handles.
---
--- One pass at a time, per command buffer and in practice per thread: SDL
--- forbids beginning any render, compute or copy pass on a command buffer
--- before the open render pass is finished, and `begin` fills a module-level
--- staging struct that a concurrent `begin` would overwrite. `finish` is what
--- releases both.
---
--- The same goes for every `bind`: each fills a module-level array that SDL
--- copies out of during the call and never reads again, so two threads binding
--- at once would overwrite each other's arguments. That is what buys a bind
--- that allocates nothing, on a path that runs several times a frame.
---
--- A begun pass is also recorded in `passscope` against its command buffer and
--- taken off there by `finish`. That is the one thing the call site cannot do
--- for itself: a body that throws skips the `finish` written after it, and the
--- command buffer is all a recovery path has to find the pass by.
---
--- Supports multiple colour attachments, which is what makes a deferred
--- G-buffer one pass rather than one pass per channel.

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local passscope <const> = require("tecs.gpu.passscope")

local C <const> = sdl.C

--- Colour attachments the staging array holds, and so the most `begin` accepts.
---
--- Not the device's ceiling, which is lower: SDL documents four colour textures
--- and one depth texture per pass. A pass begun with five to eight is rejected
--- by SDL rather than by the check here.
local MAX_COLOR_TARGETS <const> = 8

--- Sampled textures, and storage buffers, one `bind` call may carry.
---
--- SDL's own per-stage ceilings: sixteen sampled textures and eight storage
--- buffers. A call over the limit is refused here rather than by SDL, which
--- would otherwise read past the end of the staging array below.
local MAX_TEXTURE_BINDINGS <const> = 16
local MAX_BUFFER_BINDINGS <const> = 8

local record RenderPass
    record ClearColor
        --- In 0..1 per channel. A field left out is zero, except `a`, which is
        --- one, so a colour given as rgb alone clears opaque.
        r: number
        g: number
        b: number
        a: number
    end

    record Attachment
        --- Texture handle to render into, created with the colour-target usage
        --- bit. Its format has to be the one the bound pipeline baked for this
        --- attachment's position in the list.
        texture: loader.CValue
        --- Clears to this colour. Omit to load and preserve existing contents,
        --- which is only defined once something has written the texture: a load
        --- from a texture nothing has drawn to yet reads undefined memory
        --- rather than black.
        clear: RenderPass.ClearColor
    end

    record DepthAttachment
        --- Depth texture handle the pass tests and writes against. Only a
        --- pipeline that baked a matching depth format can be bound while this
        --- is attached, and only one that baked none can be bound while it is
        --- not.
        texture: loader.CValue
        --- Clears to this value. Omit to load and preserve existing contents.
        --- One is the far plane, so that is what a pass drawing a fresh frame
        --- clears to.
        clear: number
    end

    --- The `SDL_GPURenderPass`. Nil once `finish` has run, and valid only
    --- between the begin and the end.
    handle: loader.CPtr
    --- The command buffer this pass records into. Uniform pushes target the
    --- command buffer rather than the pass, so it is kept here to save every
    --- caller from threading it alongside. It is also what the pass takes
    --- itself off the open list by, which is what lets a recovery path end a
    --- pass whose body threw.
    commandBuffer: loader.CValue
    --- Number of colour attachments this pass was begun with.
    targetCount: integer
    _finished: boolean

    --- Wraps an already-begun pass handle.
    ---
    --- For a caller that began the pass itself. `begin` is the usual way in,
    --- and calls this.
    --- @param handle An `SDL_GPURenderPass` that has been begun and not ended.
    --- @param commandBuffer The command buffer it was begun on, which uniform
    ---     pushes need and the handle does not carry.
    --- @param targetCount Colour attachments it was begun with. Defaults to
    ---     one; it is recorded, not enforced, so a wrong value misreports
    ---     rather than misbinds.
    --- @return A pass that owns the handle and will end it on `finish`.
    wrap: function(handle: loader.CPtr, commandBuffer: loader.CValue, targetCount?: integer): RenderPass

    --- Begins a render pass over one or more colour attachments.
    ---
    --- The depth attachment is optional and its absence is meaningful: a pass
    --- begun without one cannot test or write depth, and a pipeline bound in it
    --- must declare no depth-stencil target either.
    ---
    --- Beginning resets viewport and scissor to cover the attachments, so a
    --- pass starts drawing to the whole target whatever the previous one did.
    --- @param commandBuffer The command buffer to record into, with no other
    ---     pass open on it.
    --- @param attachments At least one, and no more than SDL's four. Order is
    ---     the fragment shader's output location order and the order the bound
    ---     pipeline's `colorFormats` were given in.
    --- @param depth Omit for a pass with no depth attachment.
    --- @param reuse A finished pass whose object is begun again, or nil for a
    ---     fresh one. This is for the frame path, which begins the same passes
    ---     every frame: a pass object per pass per frame is a table per pass
    ---     per frame, and reusing one costs nothing. What it costs the caller
    ---     is that the object describes one pass at a time, so a pass handed to
    ---     anything that might keep it must not be a reused one.
    --- @return The open pass, which the caller must `finish` before beginning
    ---     another or submitting the frame.
    begin: function(
        commandBuffer: loader.CValue, attachments: {RenderPass.Attachment},
        depth?: RenderPass.DepthAttachment, reuse?: RenderPass
    ): RenderPass

    --- Binds a pipeline. All subsequent draws in this pass use its baked state.
    --- @param pipeline An `SDL_GPUGraphicsPipeline` whose colour formats and
    ---     depth-stencil target match what this pass was begun with. A pipeline
    ---     must be bound before the pass's first draw.
    bindPipeline: function(self, pipeline: loader.CValue)

    --- Binds textures with their samplers to the fragment stage.
    ---
    --- This is how a deferred pass reads the previous pass's output. One
    --- sampler covers every texture in the call, so textures wanting different
    --- filtering are separate calls at separate slots.
    --- @param firstSlot Zero-based index into the fragment stage's sampled
    ---     texture range, which the list continues from in order.
    --- @param textures Texture handles, each created with the sampler usage
    ---     bit. A texture this pass is also rendering into cannot be read here.
    --- @param sampler One `SDL_GPUSampler`, paired with every texture in the
    ---     list.
    bindTextures: function(self, firstSlot: integer, textures: {loader.CValue}, sampler: loader.CValue)

    --- Binds read-only storage buffers to the vertex stage.
    --- @param firstSlot Zero-based index into the vertex stage's storage buffer
    ---     range, which sits after its sampled and storage textures in set 0.
    --- @param buffers Device buffer handles, not `Buffer` objects. The count
    ---     has to be what the vertex shader declared.
    bindVertexStorageBuffers: function(self, firstSlot: integer, buffers: {loader.CValue})

    --- Binds read-only storage buffers to the fragment stage.
    --- @param firstSlot Zero-based index into the fragment stage's storage
    ---     buffer range, which sits after its sampled and storage textures in
    ---     set 2.
    --- @param buffers Device buffer handles, not `Buffer` objects. The count
    ---     has to be what the fragment shader declared.
    bindFragmentStorageBuffers: function(self, firstSlot: integer, buffers: {loader.CValue})

    --- Pushes uniform data to the vertex stage.
    ---
    --- Uniforms belong to the command buffer, not the pass, so a push applies
    --- to every draw recorded after it until the next push to that slot.
    --- @param slot Zero-based uniform buffer index in the vertex stage's set 1.
    --- @param data The bytes to copy, read immediately: the array may be reused
    ---     as soon as this returns.
    --- @param byteCount Bytes to copy out of `data`. Anything short of the
    ---     shader's declared block leaves the remainder of that block holding
    ---     no defined value.
    pushVertexUniform: function(self, slot: integer, data: loader.CArray, byteCount: integer)

    --- Pushes uniform data to the fragment stage.
    ---
    --- Uniforms belong to the command buffer, not the pass, so a push applies
    --- to every draw recorded after it until the next push to that slot.
    --- @param slot Zero-based uniform buffer index in the fragment stage's
    ---     set 3.
    --- @param data The bytes to copy, read immediately: the array may be reused
    ---     as soon as this returns.
    --- @param byteCount Bytes to copy out of `data`. Anything short of the
    ---     shader's declared block leaves the remainder of that block holding
    ---     no defined value.
    pushFragmentUniform: function(self, slot: integer, data: loader.CArray, byteCount: integer)

    --- Issues a draw.
    ---
    --- There are no vertex buffers: the vertex shader reads whatever it needs
    --- from storage buffers, indexed by vertex and instance ID.
    --- @param vertexCount Vertices per instance, which the bound pipeline's
    ---     primitive type groups.
    --- @param instanceCount Defaults to one.
    --- @param firstVertex Value `gl_VertexIndex` starts at. Defaults to zero.
    --- @param firstInstance Value `gl_InstanceIndex` starts at. Defaults to
    ---     zero.
    draw: function(self, vertexCount: integer, instanceCount?: integer, firstVertex?: integer, firstInstance?: integer)

    --- Issues a draw whose parameters the GPU wrote into `buffer`.
    ---
    --- This is the shape the renderer is built around: a compute pass culls and
    --- writes the draw arguments, and the CPU never learns the count.
    --- @param buffer A device buffer created with the indirect usage bit,
    ---     holding `SDL_GPUIndirectDrawCommand` records. The compute pass that
    ---     wrote it has to have declared it read-write and been finished, or
    ---     the draw reads whatever was there before.
    --- @param offset Bytes from the start of the buffer to the first command.
    --- @param drawCount Commands to read, laid out back to back from `offset`.
    drawIndirect: function(self, buffer: loader.CValue, offset: integer, drawCount: integer)

    --- Binds the index buffer subsequent indexed draws read.
    ---
    --- 16-bit indices: a quad needs four distinct corners, so the values never
    --- approach the limit and the buffer stays half the size of a 32-bit one.
    --- An index buffer holding 32-bit values read through this is silently
    --- misinterpreted rather than rejected.
    --- @param buffer A device buffer created with the index usage bit.
    --- @param offset Bytes from the start of the buffer to index zero.
    ---     Defaults to zero.
    bindIndexBuffer: function(self, buffer: loader.CValue, offset?: integer)

    --- Issues an indexed draw whose parameters the GPU wrote.
    --- @param buffer A device buffer created with the indirect usage bit,
    ---     holding `SDL_GPUIndexedIndirectDrawCommand` records, whose indices
    ---     address the buffer last given to `bindIndexBuffer`.
    --- @param offset Bytes from the start of the buffer to the first command.
    --- @param drawCount Commands to read, laid out back to back from `offset`.
    drawIndexedIndirect: function(self, buffer: loader.CValue, offset: integer, drawCount: integer)

    --- Ends the pass.
    ---
    --- Every begun pass must be finished before another pass begins on its
    --- command buffer and before the frame submits. Safe to call more than
    --- once. Ending discards every binding, so a pass reopened over the same
    --- attachments rebinds its pipeline and its buffers from scratch.
    finish: function(self)
end

local RenderPassMT <const>: metatable<RenderPass> = { __index = RenderPass }

-- Reused across passes; a pass is begun and bound far too often to allocate
-- for either. SDL copies out of these during the call it is given them in, so
-- they only have to hold still for its duration, and only one call may be in
-- flight over each of them. `bindings` and `handles` are separate because
-- their element types are, and `handles` serves both storage-buffer stages:
-- the two are bound in separate calls and neither reads the array afterwards.
local targets <const> = loader.newArray("SDL_GPUColorTargetInfo[?]", MAX_COLOR_TARGETS)
local depthTarget <const> = loader.newArray("SDL_GPUDepthStencilTargetInfo[1]")
local bindings <const> = loader.newArray("SDL_GPUTextureSamplerBinding[?]",
    MAX_TEXTURE_BINDINGS)
local handles <const> = loader.newArray("SDL_GPUBuffer*[?]", MAX_BUFFER_BINDINGS)
local indexBinding <const> = loader.newArray("SDL_GPUBufferBinding[1]")

--- Fills `pass` in and records it as open. Shared by `wrap` and `begin`.
local function open(pass: RenderPass, handle: loader.CPtr,
                    commandBuffer: loader.CValue, targetCount: integer): RenderPass
    pass.handle = handle
    pass.commandBuffer = commandBuffer
    pass.targetCount = targetCount
    pass._finished = false
    passscope.opened(commandBuffer, pass as passscope.Pass)
    return pass
end

function RenderPass.wrap(handle: loader.CPtr, commandBuffer: loader.CValue, targetCount?: integer): RenderPass
    return open(setmetatable({} as RenderPass, RenderPassMT), handle,
        commandBuffer, targetCount or 1)
end

function RenderPass.begin(
    commandBuffer: loader.CValue, attachments: {RenderPass.Attachment},
    depth?: RenderPass.DepthAttachment, reuse?: RenderPass
): RenderPass
    local count = #attachments
    if count == 0 then
        error("tecs: a render pass needs at least one colour attachment", 2)
    end
    if count > MAX_COLOR_TARGETS then
        error(("tecs: %d colour attachments exceeds the limit of %d")
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

    local depthInfo: loader.CArray = nil
    if depth ~= nil then
        depthInfo = depthTarget
        local target = depthTarget[0] as loader.CStruct
        target.texture = depth.texture
        target.mip_level = 0
        target.layer = 0
        target.cycle = false
        target.store_op = C.SDL_GPU_STOREOP_STORE
        -- No stencil is ever attached, so these describe nothing. They are
        -- written anyway because the struct is reused across passes and a value
        -- left over from a previous one is worse than a meaningless one.
        target.stencil_load_op = C.SDL_GPU_LOADOP_DONT_CARE
        target.stencil_store_op = C.SDL_GPU_STOREOP_DONT_CARE
        target.clear_stencil = 0

        if depth.clear ~= nil then
            target.load_op = C.SDL_GPU_LOADOP_CLEAR
            target.clear_depth = depth.clear
        else
            target.load_op = C.SDL_GPU_LOADOP_LOAD
            target.clear_depth = 0.0
        end
    end

    local handle = C.SDL_BeginGPURenderPass(commandBuffer, targets, count,
        depthInfo)
    if handle == nil then sdl.fail("SDL_BeginGPURenderPass") end
    return open(reuse or setmetatable({} as RenderPass, RenderPassMT), handle,
        commandBuffer, count)
end

function RenderPass:bindPipeline(pipeline: loader.CValue)
    C.SDL_BindGPUGraphicsPipeline(self.handle, pipeline)
end

--- Fills the shared handle array, and answers how many it holds.
local function stageBuffers(buffers: {loader.CValue}): integer
    local count <const> = #buffers
    if count > MAX_BUFFER_BINDINGS then
        error(("tecs: %d storage buffers exceeds the limit of %d")
            :format(count, MAX_BUFFER_BINDINGS), 3)
    end
    for index = 1, count do
        handles[index - 1] = buffers[index]
    end
    return count
end

function RenderPass:bindTextures(firstSlot: integer, textures: {loader.CValue}, sampler: loader.CValue)
    local count <const> = #textures
    if count > MAX_TEXTURE_BINDINGS then
        error(("tecs: %d sampled textures exceeds the limit of %d")
            :format(count, MAX_TEXTURE_BINDINGS), 2)
    end
    for index = 1, count do
        local binding = bindings[index - 1] as loader.CStruct
        binding.texture = textures[index]
        binding.sampler = sampler
    end
    C.SDL_BindGPUFragmentSamplers(self.handle, firstSlot, bindings, count)
end

function RenderPass:bindVertexStorageBuffers(firstSlot: integer, buffers: {loader.CValue})
    local count <const> = stageBuffers(buffers)
    C.SDL_BindGPUVertexStorageBuffers(self.handle, firstSlot, handles, count)
end

function RenderPass:bindFragmentStorageBuffers(firstSlot: integer, buffers: {loader.CValue})
    local count <const> = stageBuffers(buffers)
    C.SDL_BindGPUFragmentStorageBuffers(self.handle, firstSlot, handles, count)
end

function RenderPass:pushVertexUniform(slot: integer, data: loader.CArray, byteCount: integer)
    C.SDL_PushGPUVertexUniformData(self.commandBuffer, slot, data, byteCount)
end

function RenderPass:pushFragmentUniform(slot: integer, data: loader.CArray, byteCount: integer)
    C.SDL_PushGPUFragmentUniformData(self.commandBuffer, slot, data, byteCount)
end

function RenderPass:draw(vertexCount: integer, instanceCount?: integer, firstVertex?: integer, firstInstance?: integer)
    C.SDL_DrawGPUPrimitives(self.handle, vertexCount, instanceCount or 1,
        firstVertex or 0, firstInstance or 0)
end

function RenderPass:drawIndirect(buffer: loader.CValue, offset: integer, drawCount: integer)
    C.SDL_DrawGPUPrimitivesIndirect(self.handle, buffer, offset or 0, drawCount or 1)
end

function RenderPass:bindIndexBuffer(buffer: loader.CValue, offset?: integer)
    local slot = indexBinding[0] as loader.CStruct
    slot.buffer = buffer
    slot.offset = offset or 0
    C.SDL_BindGPUIndexBuffer(self.handle, indexBinding,
        C.SDL_GPU_INDEXELEMENTSIZE_16BIT)
end

function RenderPass:drawIndexedIndirect(buffer: loader.CValue, offset: integer, drawCount: integer)
    C.SDL_DrawGPUIndexedPrimitivesIndirect(self.handle, buffer, offset,
        drawCount)
end

function RenderPass:finish()
    if self._finished then return end
    self._finished = true
    passscope.closed(self.commandBuffer)
    C.SDL_EndGPURenderPass(self.handle)
    self.handle = nil
end

return RenderPass
