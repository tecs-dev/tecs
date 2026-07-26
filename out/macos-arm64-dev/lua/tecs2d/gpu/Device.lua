





local ffi = require("ffi")
local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")
local Frame = require("tecs2d.gpu.Frame")
local Window = require("tecs2d.platform.Window")

local C = sdl.C
local K = sdl.K









local Device = {}













local DeviceMT = { __index = Device }












local function supportedShaderFormats()
   if ffi.os == "OSX" then
      return K.SDL_GPU_SHADERFORMAT_MSL
   end
   return K.SDL_GPU_SHADERFORMAT_SPIRV
end


function Device.create(window, options)
   options = options or {}

   local handle = C.SDL_CreateGPUDevice(supportedShaderFormats(),
   options.debug == true, options.driver)
   if handle == nil then sdl.fail("SDL_CreateGPUDevice") end

   sdl.check(C.SDL_ClaimWindowForGPUDevice(handle, window.handle),
   "SDL_ClaimWindowForGPUDevice")

   local self = setmetatable({}, DeviceMT)
   self.handle = handle
   self.window = window
   self.driver = loader.toString(C.SDL_GetGPUDeviceDriver(handle))
   self.framesInFlight = 2
   self._destroyed = false


   self._swapchainOut = loader.newArray("SDL_GPUTexture*[1]")
   self._widthOut = loader.newArray("Uint32[1]")
   self._heightOut = loader.newArray("Uint32[1]")
   return self
end






function Device:setPresentMode(mode)
   local modes = {
      vsync = C.SDL_GPU_PRESENTMODE_VSYNC,
      immediate = C.SDL_GPU_PRESENTMODE_IMMEDIATE,
      mailbox = C.SDL_GPU_PRESENTMODE_MAILBOX,
   }
   local selected = modes[mode]
   if selected == nil then
      error(("tecs2d: unknown present mode '%s'"):format(tostring(mode)), 2)
   end
   if not C.SDL_WindowSupportsGPUPresentMode(self.handle, self.window.handle,
      selected) then
      return false
   end
   sdl.check(C.SDL_SetGPUSwapchainParameters(self.handle, self.window.handle,
   C.SDL_GPU_SWAPCHAINCOMPOSITION_SDR, selected),
   "SDL_SetGPUSwapchainParameters")
   return true
end





function Device:setFramesInFlight(count)
   sdl.check(C.SDL_SetGPUAllowedFramesInFlight(self.handle, count),
   "SDL_SetGPUAllowedFramesInFlight")
   self.framesInFlight = count
end






function Device:beginFrame()
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

   return Frame.wrap(commandBuffer, texture,
   self._widthOut[0], self._heightOut[0])
end



function Device:getSwapchainFormat()
   return tonumber(
   C.SDL_GetGPUSwapchainTextureFormat(self.handle, self.window.handle))

end



function Device:waitForIdle()
   C.SDL_WaitForGPUIdle(self.handle)
end


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
