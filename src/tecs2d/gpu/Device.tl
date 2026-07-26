--- The GPU device.
---
--- Owns the swapchain and hands out per-frame command buffers. There is no
--- immediate mode and no global render state: SDL_GPU bakes blend, depth, and
--- cull into immutable pipeline objects, so every draw goes through a render
--- pass on an explicit frame.
local ffi <const> = require("ffi")
local sdl <const> = require("tecs2d.ffi.sdl3")
local loader <const> = require("tecs2d.ffi.loader")
local Frame <const> = require("tecs2d.gpu.Frame")
local Window <const> = require("tecs2d.platform.Window")

local C <const> = sdl.C
local K <const> = sdl.K

--- Largest number of simultaneous colour attachments a pass may bind.
local MAX_COLOR_TARGETS <const> = 8

local record DeviceOptions
    --- Enables the backend's validation layers.
    debug: boolean
    --- Forces a named backend ("metal", "vulkan", "direct3d12"). Omit to let
    --- SDL choose.
    driver: string
end

local record Device
    handle: loader.CPtr
    --- Backend SDL selected, e.g. "metal".
    driver: string
    window: Window
    --- Frames the CPU may run ahead of the GPU. Resource retirement depth
    --- must match this or the GPU reads freed memory.
    framesInFlight: integer
    _swapchainOut: loader.CArray
    _widthOut: loader.CArray
    _heightOut: loader.CArray
    _colorTargets: loader.CArray
    _destroyed: boolean
end

local DeviceMT <const>: metatable<Device> = { __index = Device }

--- Shader formats this build can actually supply.
---
--- SDL abstracts the whole API across Metal, Vulkan, and D3D12, but it does
--- not abstract shaders: `SDL_CreateGPUShader` takes precompiled bytecode in a
--- backend-specific format and never compiles or translates. This set is what
--- SDL uses to choose a backend, so declaring a format the shader pipeline
--- cannot emit selects a backend that then fails at shader creation.
---
--- Only MSL and SPIR-V are claimed, because those are what `shadercompiler`
--- produces. DXIL needs DXC, which is not wired up, so Windows currently
--- resolves to the Vulkan backend rather than D3D12.
local function supportedShaderFormats(): integer
    if ffi.os == "OSX" then
        return K.SDL_GPU_SHADERFORMAT_MSL
    end
    return K.SDL_GPU_SHADERFORMAT_SPIRV
end

--- Creates a GPU device and claims `window` for presentation.
function Device.create(window: Window, options: DeviceOptions): Device
    options = options or {}

    local handle = C.SDL_CreateGPUDevice(supportedShaderFormats(),
        options.debug == true, options.driver)
    if handle == nil then sdl.fail("SDL_CreateGPUDevice") end

    sdl.check(C.SDL_ClaimWindowForGPUDevice(handle, window.handle) as boolean,
        "SDL_ClaimWindowForGPUDevice")

    local self = setmetatable({} as Device, DeviceMT)
    self.handle = handle
    self.window = window
    self.driver = loader.toString(C.SDL_GetGPUDeviceDriver(handle))
    self.framesInFlight = 2
    self._destroyed = false

    -- Reused across frames: acquiring a frame must not allocate.
    self._swapchainOut = loader.newArray("SDL_GPUTexture*[1]")
    self._widthOut = loader.newArray("Uint32[1]")
    self._heightOut = loader.newArray("Uint32[1]")
    self._colorTargets =
        loader.newArray("SDL_GPUColorTargetInfo[?]", MAX_COLOR_TARGETS)

    return self
end

--- Sets how many frames the CPU may run ahead of the GPU.
---
--- Resource retirement must match this depth: a buffer replaced this frame
--- stays live until every frame still referencing it has retired.
function Device:setFramesInFlight(count: integer)
    sdl.check(C.SDL_SetGPUAllowedFramesInFlight(self.handle, count) as boolean,
        "SDL_SetGPUAllowedFramesInFlight")
    self.framesInFlight = count
end

--- Acquires a command buffer and the swapchain texture for this frame.
---
--- Returns nil when the window cannot be presented to, which happens while it
--- is minimised or occluded. Callers skip rendering that frame; the command
--- buffer is cancelled rather than leaked.
function Device:beginFrame(): Frame
    local commandBuffer = C.SDL_AcquireGPUCommandBuffer(self.handle)
    if commandBuffer == nil then sdl.fail("SDL_AcquireGPUCommandBuffer") end

    local ok = C.SDL_WaitAndAcquireGPUSwapchainTexture(commandBuffer,
        self.window.handle, self._swapchainOut, self._widthOut, self._heightOut)
    if not ok then
        C.SDL_CancelGPUCommandBuffer(commandBuffer)
        sdl.fail("SDL_WaitAndAcquireGPUSwapchainTexture")
    end

    local texture = self._swapchainOut[0]
    if texture == nil then
        C.SDL_CancelGPUCommandBuffer(commandBuffer)
        return nil
    end

    return Frame.wrap(commandBuffer, texture as loader.CPtr,
        self._widthOut[0] as integer, self._heightOut[0] as integer,
        self._colorTargets)
end

--- Returns the swapchain's texture format, which pipelines writing to it must
--- be created against.
function Device:getSwapchainFormat(): integer
    return tonumber(
        C.SDL_GetGPUSwapchainTextureFormat(self.handle, self.window.handle)
    ) as integer
end

--- Blocks until the GPU has finished all submitted work. Required before
--- releasing resources the GPU may still be reading.
function Device:waitForIdle()
    C.SDL_WaitForGPUIdle(self.handle)
end

--- Releases the device. Safe to call more than once.
function Device:destroy()
    if self._destroyed then return end
    self._destroyed = true
    C.SDL_WaitForGPUIdle(self.handle)
    if self.window ~= nil and self.window.handle ~= nil then
        C.SDL_ReleaseWindowFromGPUDevice(self.handle, self.window.handle)
    end
    C.SDL_DestroyGPUDevice(self.handle)
    self.handle = nil
end

return Device
