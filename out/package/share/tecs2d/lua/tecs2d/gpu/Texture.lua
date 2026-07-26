








local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")

local C = sdl.C
local K = sdl.K


















local Texture = {}










local TextureMT = { __index = Texture }

local USAGE_FLAGS = {
   sampled = K.SDL_GPU_TEXTUREUSAGE_SAMPLER,
   colorTarget = K.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET,
   depthTarget = K.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
   computeRead = K.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_READ,
   computeWrite = K.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_WRITE,
   graphicsRead = K.SDL_GPU_TEXTUREUSAGE_GRAPHICS_STORAGE_READ,
}

local DEFAULT_USAGE = { "colorTarget", "sampled" }


function Texture.create(device, options)
   local flags = 0
   for _, name in ipairs(options.usage or DEFAULT_USAGE) do
      local flag = USAGE_FLAGS[name]
      if flag == nil then
         error(("tecs2d: unknown texture usage '%s'"):format(tostring(name)), 2)
      end
      flags = flags + flag
   end

   local info = loader.newArray("SDL_GPUTextureCreateInfo[1]")
   local settings = info[0]
   settings.type = 0
   settings.format = options.format
   settings.usage = flags
   settings.width = options.width
   settings.height = options.height
   settings.layer_count_or_depth = 1
   settings.num_levels = 1
   settings.sample_count = 0
   settings.props = 0

   local handle = C.SDL_CreateGPUTexture(device, info)
   if handle == nil then sdl.fail("SDL_CreateGPUTexture") end

   local self = setmetatable({}, TextureMT)
   self.handle = handle
   self.width = options.width
   self.height = options.height
   self.format = options.format
   self._device = device
   self._transferSize = 0
   self._destroyed = false
   return self
end





function Texture:upload(pixels, byteCount)
   local info = loader.newArray("SDL_GPUTransferBufferCreateInfo[1]")
   local settings = info[0]
   settings.usage = C.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD
   settings.size = byteCount
   settings.props = 0

   local transfer = C.SDL_CreateGPUTransferBuffer(self._device, info)
   if transfer == nil then sdl.fail("SDL_CreateGPUTransferBuffer") end

   local mapped = C.SDL_MapGPUTransferBuffer(self._device, transfer, true)
   if mapped == nil then sdl.fail("SDL_MapGPUTransferBuffer") end
   loader.copyBytes(mapped, pixels, byteCount)
   C.SDL_UnmapGPUTransferBuffer(self._device, transfer)

   local commandBuffer = C.SDL_AcquireGPUCommandBuffer(self._device)
   if commandBuffer == nil then sdl.fail("SDL_AcquireGPUCommandBuffer") end
   local copyPass = C.SDL_BeginGPUCopyPass(commandBuffer)

   local source = loader.newArray("SDL_GPUTextureTransferInfo[1]")
   local from = source[0]
   from.transfer_buffer = transfer
   from.offset = 0
   from.pixels_per_row = self.width
   from.rows_per_layer = self.height

   local region = loader.newArray("SDL_GPUTextureRegion[1]")
   local to = region[0]
   to.texture = self.handle
   to.mip_level = 0
   to.layer = 0
   to.x, to.y, to.z = 0, 0, 0
   to.w, to.h, to.d = self.width, self.height, 1

   C.SDL_UploadToGPUTexture(copyPass, source, region, false)
   C.SDL_EndGPUCopyPass(copyPass)
   sdl.check(C.SDL_SubmitGPUCommandBuffer(commandBuffer),
   "SDL_SubmitGPUCommandBuffer")

   C.SDL_ReleaseGPUTransferBuffer(self._device, transfer)
end





function Texture:readback()
   local byteCount = self.width * self.height * 4

   if self._transfer == nil then
      local info = loader.newArray("SDL_GPUTransferBufferCreateInfo[1]")
      local settings = info[0]
      settings.usage = C.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD
      settings.size = byteCount
      settings.props = 0
      self._transfer = C.SDL_CreateGPUTransferBuffer(self._device, info)
      if self._transfer == nil then sdl.fail("SDL_CreateGPUTransferBuffer") end
      self._transferSize = byteCount
   end

   local commandBuffer = C.SDL_AcquireGPUCommandBuffer(self._device)
   if commandBuffer == nil then sdl.fail("SDL_AcquireGPUCommandBuffer") end
   local copyPass = C.SDL_BeginGPUCopyPass(commandBuffer)

   local region = loader.newArray("SDL_GPUTextureRegion[1]")
   local source = region[0]
   source.texture = self.handle
   source.mip_level = 0
   source.layer = 0
   source.x = 0
   source.y = 0
   source.z = 0
   source.w = self.width
   source.h = self.height
   source.d = 1

   local destination = loader.newArray("SDL_GPUTextureTransferInfo[1]")
   local sink = destination[0]
   sink.transfer_buffer = self._transfer
   sink.offset = 0
   sink.pixels_per_row = self.width
   sink.rows_per_layer = self.height

   C.SDL_DownloadFromGPUTexture(copyPass, region, destination)
   C.SDL_EndGPUCopyPass(copyPass)

   local fence = C.SDL_SubmitGPUCommandBufferAndAcquireFence(commandBuffer)
   if fence == nil then sdl.fail("SDL_SubmitGPUCommandBufferAndAcquireFence") end
   local fences = loader.newArray("SDL_GPUFence*[1]")
   fences[0] = fence
   C.SDL_WaitForGPUFences(self._device, true, fences, 1)
   C.SDL_ReleaseGPUFence(self._device, fence)

   local mapped = C.SDL_MapGPUTransferBuffer(self._device, self._transfer, false)
   if mapped == nil then sdl.fail("SDL_MapGPUTransferBuffer") end
   local pixels = loader.newArray("uint8_t[?]", byteCount)
   loader.copyBytes(pixels, mapped, byteCount)
   C.SDL_UnmapGPUTransferBuffer(self._device, self._transfer)

   return pixels
end


function Texture:getPixel(pixels, x, y)
   local offset = (y * self.width + x) * 4
   return {
      r = pixels[offset],
      g = pixels[offset + 1],
      b = pixels[offset + 2],
      a = pixels[offset + 3],
   }
end


function Texture:destroy()
   if self._destroyed then return end
   self._destroyed = true
   if self._transfer ~= nil then
      C.SDL_ReleaseGPUTransferBuffer(self._device, self._transfer)
      self._transfer = nil
   end
   C.SDL_ReleaseGPUTexture(self._device, self.handle)
   self.handle = nil
end

return Texture
