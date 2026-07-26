--- One frame's command buffer and swapchain target.
---
--- The command buffer is a field on this value, never module state. SDL_GPU
--- allows acquiring a command buffer per thread, and a global would make
--- threaded recording impossible to retrofit once render code is written
--- against it. Everything that records passes the frame explicitly.

local sdl <const> = require("tecs2d.ffi.sdl3")
local loader <const> = require("tecs2d.ffi.loader")
local RenderPass <const> = require("tecs2d.gpu.RenderPass")
local ComputePass <const> = require("tecs2d.gpu.ComputePass")

local C <const> = sdl.C

local record RenderPassOptions
    --- Clears the target to this colour. Omit to load and preserve existing
    --- contents.
    clear: RenderPass.ClearColor
end

local record Frame
    --- This frame's command buffer. Passed to anything that records work.
    commandBuffer: loader.CPtr
    --- The acquired swapchain texture.
    swapchainTexture: loader.CPtr
    --- Swapchain dimensions in pixels, which may differ from the window size.
    width: integer
    height: integer
    _done: boolean
end

local FrameMT <const>: metatable<Frame> = { __index = Frame }

--- Wraps an acquired command buffer and swapchain texture.
function Frame.wrap(commandBuffer: loader.CPtr, swapchainTexture: loader.CPtr,
                    width: integer, height: integer): Frame
    local self = setmetatable({} as Frame, FrameMT)
    self.commandBuffer = commandBuffer
    self.swapchainTexture = swapchainTexture
    self.width = width
    self.height = height
    self._done = false
    return self
end

--- Begins a render pass targeting the swapchain.
function Frame:beginRenderPass(options: RenderPassOptions): RenderPass
    return RenderPass.begin(self.commandBuffer, {
        { texture = self.swapchainTexture, clear = options and options.clear },
    })
end

--- Begins a compute pass on this frame's command buffer.
---
--- `readWriteBuffers` are the buffers the pass writes; see `ComputePass.begin`
--- for why they are declared here rather than bound inside the pass.
function Frame:beginComputePass(readWriteBuffers: {loader.CValue}): ComputePass
    return ComputePass.begin(self.commandBuffer, readWriteBuffers)
end

--- Submits the frame's recorded work for execution and presentation.
function Frame:submit()
    if self._done then return end
    self._done = true
    sdl.check(C.SDL_SubmitGPUCommandBuffer(self.commandBuffer) as boolean,
        "SDL_SubmitGPUCommandBuffer")
    self.commandBuffer = nil
end

--- Discards the frame without presenting, releasing the command buffer.
function Frame:cancel()
    if self._done then return end
    self._done = true
    C.SDL_CancelGPUCommandBuffer(self.commandBuffer)
    self.commandBuffer = nil
end

return Frame
