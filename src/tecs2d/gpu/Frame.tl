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

local record ClearColor
    r: number
    g: number
    b: number
    a: number
end

local record RenderPassOptions
    --- Clears the target to this colour. Omit to load and preserve existing
    --- contents.
    clear: ClearColor
end

local record Frame
    --- This frame's command buffer. Passed to anything that records work.
    commandBuffer: loader.CPtr
    --- The acquired swapchain texture.
    swapchainTexture: loader.CPtr
    --- Swapchain dimensions in pixels, which may differ from the window size.
    width: integer
    height: integer
    _colorTargets: loader.CArray
    _done: boolean
end

local FrameMT <const>: metatable<Frame> = { __index = Frame }

--- Wraps an acquired command buffer and swapchain texture.
---
--- `colorTargets` is owned by the device and reused every frame, so acquiring
--- a frame performs no allocation.
function Frame.wrap(commandBuffer: loader.CPtr, swapchainTexture: loader.CPtr,
                    width: integer, height: integer,
                    colorTargets: loader.CArray): Frame
    local self = setmetatable({} as Frame, FrameMT)
    self.commandBuffer = commandBuffer
    self.swapchainTexture = swapchainTexture
    self.width = width
    self.height = height
    self._colorTargets = colorTargets
    self._done = false
    return self
end

--- Begins a render pass targeting the swapchain.
function Frame:beginRenderPass(options: RenderPassOptions): RenderPass
    local target = self._colorTargets[0] as loader.CStruct
    target.texture = self.swapchainTexture
    target.mip_level = 0
    target.layer_or_depth_plane = 0
    target.resolve_texture = nil
    target.cycle = false
    target.cycle_resolve_texture = false
    target.store_op = C.SDL_GPU_STOREOP_STORE

    local clear = options and options.clear
    if clear ~= nil then
        target.load_op = C.SDL_GPU_LOADOP_CLEAR
        local clearColor = target.clear_color as loader.CStruct
        clearColor.r = clear.r or 0.0
        clearColor.g = clear.g or 0.0
        clearColor.b = clear.b or 0.0
        clearColor.a = clear.a or 1.0
    else
        target.load_op = C.SDL_GPU_LOADOP_LOAD
    end

    local handle = C.SDL_BeginGPURenderPass(self.commandBuffer,
        self._colorTargets, 1, nil)
    if handle == nil then sdl.fail("SDL_BeginGPURenderPass") end
    return RenderPass.wrap(handle)
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
