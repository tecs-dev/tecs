--- One frame's command buffer and swapchain target.
---
--- The command buffer is a field on this value, never module state. SDL_GPU
--- allows acquiring a command buffer per thread, and a global would make
--- threaded recording impossible to retrofit once render code is written
--- against it. Everything that records passes the frame explicitly.
---
--- A command buffer is a resource, not a value: it holds a slot in the driver's
--- pool and, once a swapchain texture has been acquired on it, the texture the
--- presenter is waiting for. It leaves that state exactly once, through
--- `submit` or `cancel`, and which of the two is legal is not a preference.
--- SDL documents cancelling after a swapchain texture has been acquired as an
--- error, so an acquired frame can only be submitted. `state` and `acquired`
--- are here so that a recovery path with nothing but the frame can work out
--- which it is looking at.

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local RenderPass <const> = require("tecs.gpu.RenderPass")
local ComputePass <const> = require("tecs.gpu.ComputePass")
local passscope <const> = require("tecs.gpu.passscope")

local C <const> = sdl.C

local record RenderPassOptions
    --- Clears the target to this colour. Omit to load and preserve existing
    --- contents.
    clear: RenderPass.ClearColor
end

--- Where a frame's command buffer has got to.
---
--- "recording" is the only state that owns anything. The other two are
--- terminal, and the difference between them is only whether the work reached
--- the GPU.
local enum FrameState
    "recording"
    "submitted"
    "cancelled"
end

local record Frame
    type State = FrameState

    --- This frame's command buffer. Passed to anything that records work. Nil
    --- once the frame has been submitted or cancelled.
    commandBuffer: loader.CPtr
    --- The acquired swapchain texture.
    swapchainTexture: loader.CPtr
    --- Swapchain dimensions in pixels, which may differ from the window size.
    width: integer
    height: integer
    --- Whether a swapchain texture was acquired on this command buffer.
    ---
    --- Stated rather than inferred, because it is what decides how a frame that
    --- cannot finish is resolved and the rule it encodes is SDL's: cancelling
    --- after an acquisition is an error, and the texture is only handed back by
    --- a submission.
    acquired: boolean
    state: FrameState
end

local FrameMT <const>: metatable<Frame> = {__index = Frame}

--- Wraps an acquired command buffer and swapchain texture.
---
--- A nil `swapchainTexture` is a command buffer that acquired nothing, which is
--- the only kind that may still be cancelled.
--- @param reuse A resolved frame whose object is filled in again, or nil for a
---     fresh one. One frame is acquired per iteration and the device holds the
---     object between them, so reusing it is what keeps acquisition from
---     costing a table. What it costs: the object describes the frame being
---     recorded now, so nothing may keep one and expect it to still describe
---     the frame it was handed.
function Frame.wrap(
    commandBuffer: loader.CPtr, swapchainTexture: loader.CPtr, width: integer, height: integer, reuse?: Frame
): Frame
    local self = reuse or setmetatable({} as Frame, FrameMT)
    self.commandBuffer = commandBuffer
    self.swapchainTexture = swapchainTexture
    self.width = width
    self.height = height
    self.acquired = swapchainTexture ~= nil
    self.state = "recording"
    return self
end

--- Begins a render pass targeting the swapchain.
function Frame:beginRenderPass(options: RenderPassOptions): RenderPass
    return RenderPass.begin(
        self.commandBuffer,
        {
            {texture = self.swapchainTexture, clear = options and options.clear},
        }
    )
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
    if self.state ~= "recording" then
        return
    end
    self.state = "submitted"
    local commandBuffer <const> = self.commandBuffer
    self.commandBuffer = nil
    sdl.check(C.SDL_SubmitGPUCommandBuffer(commandBuffer) as boolean, "SDL_SubmitGPUCommandBuffer")
end

--- Discards the frame without presenting, releasing the command buffer.
---
--- Only legal before a swapchain texture has been acquired. SDL documents
--- cancelling after one has been as an error, and this refuses rather than
--- makes the call: the frame is still recoverable at that point, and
--- `abandon` is what recovers it.
function Frame:cancel()
    if self.state ~= "recording" then
        return
    end
    if self.acquired then
        error(
            "tecs: a frame that acquired a swapchain texture cannot be "
                .. "cancelled; submit it, or use abandon to resolve it either way",
            2
        )
    end
    self.state = "cancelled"
    local commandBuffer <const> = self.commandBuffer
    self.commandBuffer = nil
    C.SDL_CancelGPUCommandBuffer(commandBuffer)
end

--- Resolves a frame whose recording did not finish.
---
--- The recovery path, and the only caller that should exist: a frame that
--- recorded to the end submits and says so. What is put back is the pass left
--- open by a body that threw, and then the command buffer itself, submitted or
--- cancelled by whether a swapchain texture was acquired on it. Doing nothing
--- is not an option, because the pool the buffer came from is finite and the
--- presenter is waiting on the texture.
---
--- What reaches the screen is what the frame drew before it threw, which for a
--- throw ahead of the composite is whatever the swapchain texture last held.
--- Clearing it would be a decision about what the game looks like, and this is
--- not the place that makes those.
---
--- Safe on a frame that already resolved, which is what makes it safe to call
--- from a recovery path that cannot know how far the frame got.
--- @return Why resolving failed, or nil when it did not. A failure here is
---     reported beside whatever went wrong first and never in place of it.
function Frame:abandon(): string
    if self.state ~= "recording" then
        return nil
    end

    -- Cast because neither call declares a return `pcall` could carry the
    -- failure in, and the failure is the whole point of protecting them.
    local ended, endFailure = pcall(passscope.endOpen, self.commandBuffer) as (boolean, any)

    local resolved, resolveFailure: boolean, any
    if self.acquired then
        resolved, resolveFailure = pcall(self.submit, self) as (boolean, any)
    else
        resolved, resolveFailure = pcall(self.cancel, self) as (boolean, any)
    end

    if not ended then
        return tostring(endFailure)
    end
    if not resolved then
        return tostring(resolveFailure)
    end
    return nil
end

return Frame
