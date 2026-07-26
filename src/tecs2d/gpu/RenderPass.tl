--- A render pass recorded into a frame's command buffer.
---
--- Held as a value rather than reached through module state, so passes on
--- different threads cannot collide and a pass can never outlive the frame
--- that opened it without that being visible at the call site.

local sdl <const> = require("tecs2d.ffi.sdl3")
local loader <const> = require("tecs2d.ffi.loader")

local C <const> = sdl.C

local record RenderPass
    handle: loader.CPtr
    _finished: boolean
end

local RenderPassMT <const>: metatable<RenderPass> = { __index = RenderPass }

--- Wraps a begun pass handle.
function RenderPass.wrap(handle: loader.CPtr): RenderPass
    local self = setmetatable({} as RenderPass, RenderPassMT)
    self.handle = handle
    self._finished = false
    return self
end

--- Binds a pipeline. All subsequent draws in this pass use its baked state.
function RenderPass:bindPipeline(pipeline: loader.CValue)
    C.SDL_BindGPUGraphicsPipeline(self.handle, pipeline)
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
function RenderPass:finish()
    if self._finished then return end
    self._finished = true
    C.SDL_EndGPURenderPass(self.handle)
    self.handle = nil
end

return RenderPass
