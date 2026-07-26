






local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")
local RenderPass = require("tecs2d.gpu.RenderPass")
local ComputePass = require("tecs2d.gpu.ComputePass")

local C = sdl.C







local Frame = {}










local FrameMT = { __index = Frame }


function Frame.wrap(commandBuffer, swapchainTexture,
   width, height)
   local self = setmetatable({}, FrameMT)
   self.commandBuffer = commandBuffer
   self.swapchainTexture = swapchainTexture
   self.width = width
   self.height = height
   self._done = false
   return self
end


function Frame:beginRenderPass(options)
   return RenderPass.begin(self.commandBuffer, {
      { texture = self.swapchainTexture, clear = options and options.clear },
   })
end





function Frame:beginComputePass(readWriteBuffers)
   return ComputePass.begin(self.commandBuffer, readWriteBuffers)
end


function Frame:submit()
   if self._done then return end
   self._done = true
   sdl.check(C.SDL_SubmitGPUCommandBuffer(self.commandBuffer),
   "SDL_SubmitGPUCommandBuffer")
   self.commandBuffer = nil
end


function Frame:cancel()
   if self._done then return end
   self._done = true
   C.SDL_CancelGPUCommandBuffer(self.commandBuffer)
   self.commandBuffer = nil
end

return Frame
