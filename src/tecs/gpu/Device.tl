--- The GPU device.
---
--- Owns the swapchain and hands out per-frame command buffers. There is no
--- immediate mode and no global render state: SDL_GPU bakes blend, depth, and
--- cull into immutable pipeline objects, so every draw goes through a render
--- pass on an explicit frame.
local sdl <const> = require("tecs.ffi.sdl3")
local shadercompiler <const> = require("tecs.gpu.shadercompiler")
local loader <const> = require("tecs.ffi.loader")
local Buffer <const> = require("tecs.gpu.Buffer")
local Frame <const> = require("tecs.gpu.Frame")
local Window <const> = require("tecs.platform.Window")

local C <const> = sdl.C

local record DeviceOptions
    --- Enables the backend's validation layers.
    debug: boolean
    --- Forces a named backend ("metal", "vulkan", "direct3d12"). Omit to let
    --- SDL choose.
    driver: string
end

--- The GPU device and its swapchain, and the type `create` returns.
---
--- One device presents to one window. Every other wrapper in this directory is
--- created against `handle` and must be released before `destroy` runs, since
--- the device outlives nothing it made.
local record Device
    --- The `SDL_GPUDevice`, and what every other wrapper here is created
    --- against. Nil once `destroy` has run.
    handle: loader.CPtr
    --- Backend SDL selected, e.g. "metal".
    driver: string
    --- The window claimed for presentation. One device presents to one window
    --- here, and the device releases its claim before destroying itself.
    window: Window
    --- Frames the CPU may run ahead of the GPU. Resource retirement depth
    --- must match this or the GPU reads freed memory.
    framesInFlight: integer
    --- Out-parameters `beginFrame` fills, held rather than allocated so
    --- acquiring a frame costs nothing.
    _swapchainOut: loader.CArray
    --- Swapchain width in pixels, as `SDL_WaitAndAcquireGPUSwapchainTexture`
    --- writes it.
    _widthOut: loader.CArray
    --- Swapchain height in pixels, from the same call. Not the window's size on
    --- a high-density display.
    _heightOut: loader.CArray
    --- The frame object `beginFrame` fills in, for the same reason. One frame
    --- is recorded at a time on this device, so the one object serves all of
    --- them; see `Frame.wrap` for what that asks of a caller.
    _frame: Frame
    --- Set by the first `destroy`, so a second one releases nothing again.
    _destroyed: boolean
end

local DeviceMT <const>: metatable<Device> = {__index = Device}

--- Shader formats this build can actually supply.
---
--- SDL abstracts the whole API across Metal, Vulkan, and D3D12, but it does
--- not abstract shaders: `SDL_CreateGPUShader` takes precompiled bytecode in a
--- backend-specific format and never compiles or translates. This set is what
--- SDL uses to choose a backend, so declaring a format the shader pipeline
--- cannot supply selects a backend that then fails at shader creation.
---
--- The shader pipeline is asked rather than the platform, because a build that
--- ships a pack supplies exactly the pack's format and nothing else. Only MSL
--- and SPIR-V are ever claimed: DXIL needs DXC, which is not wired up, so
--- Windows resolves to the Vulkan backend rather than D3D12.
local function supportedShaderFormats(): integer
    return shadercompiler.format()
end

--- Creates a GPU device and claims `window` for presentation.
---
--- The claim is what makes a swapchain exist for that window, and `destroy`
--- releases it before destroying the device, so the two can be torn down in
--- either order from the caller's point of view.
--- @param window Must already have a handle; the claim is what gives it a
---     swapchain, and there is no way to move the claim to another window.
--- @param options Nil takes SDL's own backend choice with validation off.
--- @return A device with `framesInFlight` at SDL's default of two, which
---     `setFramesInFlight` may lower and cannot raise past `Buffer.slotCount`.
function Device.create(window: Window, options: DeviceOptions): Device
    options = options or {}

    local handle = C.SDL_CreateGPUDevice(supportedShaderFormats(), options.debug == true, options.driver)
    if handle == nil then
        sdl.fail("SDL_CreateGPUDevice")
    end

    sdl.check(C.SDL_ClaimWindowForGPUDevice(handle, window.handle) as boolean, "SDL_ClaimWindowForGPUDevice")

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
    return self
end

--- Selects how presentation is paced.
---
--- "vsync" blocks the swapchain acquire on the display, which is what paces
--- the loop in normal use. "immediate" and "mailbox" do not, so a benchmark
--- can observe what a frame actually costs instead of what the display allows.
---
--- Only "vsync" is available everywhere; the other two are the backend's to
--- offer. An unknown name raises, since that is a typo rather than a
--- capability.
--- @param mode "vsync", "immediate" or "mailbox". Anything else raises.
--- @return Whether the mode was applied. False leaves the previous pacing in
---     place, which a benchmark should notice rather than assume away.
function Device:setPresentMode(mode: string): boolean
    local modes: {string: any} = {
        vsync = C.SDL_GPU_PRESENTMODE_VSYNC,
        immediate = C.SDL_GPU_PRESENTMODE_IMMEDIATE,
        mailbox = C.SDL_GPU_PRESENTMODE_MAILBOX,
    }
    local selected = modes[mode]
    if selected == nil then
        error(("tecs: unknown present mode '%s'"):format(tostring(mode)), 2)
    end
    if not C.SDL_WindowSupportsGPUPresentMode(self.handle, self.window.handle, selected) then
        return false
    end
    sdl.check(
        C.SDL_SetGPUSwapchainParameters(
            self.handle, self.window.handle, C.SDL_GPU_SWAPCHAINCOMPOSITION_SDR, selected
        ) as boolean,
        "SDL_SetGPUSwapchainParameters"
    )
    return true
end

--- Sets how many frames the CPU may run ahead of the GPU.
---
--- Resource retirement must match this depth: a buffer replaced this frame
--- stays live until every frame still referencing it has retired.
---
--- Staging rotation has to reach at least as far. A buffer rotates through
--- `Buffer.slotCount` staging slots and maps them without cycling, which is
--- only safe while the slot being written is not one the GPU is still copying
--- out of. Allowing more frames in flight than there are slots makes that
--- false, and the result is a write landing under a copy in progress: geometry
--- that is wrong only under load, which is why this refuses rather than
--- clamping.
--- @param count At least one and no more than `Buffer.slotCount`. Anything
---     above that raises rather than being clamped.
function Device:setFramesInFlight(count: integer)
    if count > Buffer.slotCount then
        error(
            ("tecs: %d frames in flight needs at least that many staging " .. "slots, and a buffer has %d"):format(
                count, Buffer.slotCount
            ),
            2
        )
    end
    sdl.check(C.SDL_SetGPUAllowedFramesInFlight(self.handle, count) as boolean, "SDL_SetGPUAllowedFramesInFlight")
    self.framesInFlight = count
end

--- Acquires a command buffer and the swapchain texture for this frame.
---
--- Returns nil when the window cannot be presented to, which happens while it
--- is minimised or occluded. Callers skip rendering that frame; the command
--- buffer is cancelled rather than leaked.
---
--- Waits for a frame to be available first, so this is where the loop is paced
--- under vsync and where a CPU running ahead of `framesInFlight` is held back.
--- The frame's size is the swapchain's, which is not the window's on a
--- high-density display and is what a pass should size targets to.
---
--- Both failures below cancel, and both are before an acquisition: a call that
--- returned false acquired nothing, and one that filled the handle with NULL
--- did not either, which SDL says is not an error and happens while the window
--- is minimised. Cancelling is only legal there. Once a texture has come back,
--- the command buffer's only way out is a submission, which is why the frame
--- this returns carries that fact rather than leaving it to be worked out.
--- @return A frame to record into, or nil to skip this one. The device's own
---     object, filled in again per frame, so nothing may keep it past the
---     frame it was handed for.
function Device:beginFrame(): Frame
    local commandBuffer = C.SDL_AcquireGPUCommandBuffer(self.handle)
    if commandBuffer == nil then
        sdl.fail("SDL_AcquireGPUCommandBuffer")
    end

    local ok = C.SDL_WaitAndAcquireGPUSwapchainTexture(
        commandBuffer, self.window.handle, self._swapchainOut, self._widthOut, self._heightOut
    )
    if not ok then
        C.SDL_CancelGPUCommandBuffer(commandBuffer)
        sdl.fail("SDL_WaitAndAcquireGPUSwapchainTexture")
    end

    local texture = self._swapchainOut[0]
    if texture == nil then
        C.SDL_CancelGPUCommandBuffer(commandBuffer)
        return nil
    end

    self._frame = Frame.wrap(
        commandBuffer, texture as loader.CPtr, self._widthOut[0] as integer, self._heightOut[0] as integer, self._frame
    )
    return self._frame
end

--- Returns the swapchain's texture format, which pipelines writing to it must
--- be created against.
---
--- The backend's choice, not a fixed value: asking is the only way to build a
--- pipeline that matches on every machine.
function Device:getSwapchainFormat(): integer
    return tonumber(C.SDL_GetGPUSwapchainTextureFormat(self.handle, self.window.handle)) as integer
end

--- Blocks until the GPU has finished all submitted work. Required before
--- releasing resources the GPU may still be reading.
function Device:waitForIdle()
    C.SDL_WaitForGPUIdle(self.handle)
end

--- Releases the device. Safe to call more than once.
function Device:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    C.SDL_WaitForGPUIdle(self.handle)
    if self.window ~= nil and self.window.handle ~= nil then
        C.SDL_ReleaseWindowFromGPUDevice(self.handle, self.window.handle)
    end
    C.SDL_DestroyGPUDevice(self.handle)
    self.handle = nil
end

return Device
