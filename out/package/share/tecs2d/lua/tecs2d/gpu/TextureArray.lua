













local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")

local C = sdl.C
local K = sdl.K


local TYPE_2D_ARRAY = 1


local RGBA8 = 4











local TextureArray = { Region = {} }






















local TextureArrayMT = { __index = TextureArray }


function TextureArray.create(device,
   options)
   local info = loader.newArray("SDL_GPUTextureCreateInfo[1]")
   local settings = info[0]
   settings.type = TYPE_2D_ARRAY
   settings.format = RGBA8
   settings.usage = K.SDL_GPU_TEXTUREUSAGE_SAMPLER
   settings.width = options.width
   settings.height = options.height
   settings.layer_count_or_depth = options.layers
   settings.num_levels = 1
   settings.sample_count = 0
   settings.props = 0

   local handle = C.SDL_CreateGPUTexture(device, info)
   if handle == nil then sdl.fail("SDL_CreateGPUTexture") end

   local self = setmetatable({}, TextureArrayMT)
   self.handle = handle
   self.width = options.width
   self.height = options.height
   self.layers = options.layers
   self.used = 0
   self._device = device
   self._transferSize = 0
   self._destroyed = false
   return self
end

local function ensureTransfer(self, byteCount)
   if self._transfer ~= nil and self._transferSize >= byteCount then return end
   if self._transfer ~= nil then
      C.SDL_ReleaseGPUTransferBuffer(self._device, self._transfer)
   end
   local info = loader.newArray("SDL_GPUTransferBufferCreateInfo[1]")
   local settings = info[0]
   settings.usage = C.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD
   settings.size = byteCount
   settings.props = 0
   self._transfer = C.SDL_CreateGPUTransferBuffer(self._device, info)
   if self._transfer == nil then sdl.fail("SDL_CreateGPUTransferBuffer") end
   self._transferSize = byteCount
end






function TextureArray:add(pixels, width,
   height, pitch)
   if self.used >= self.layers then
      error(("tecs2d: texture array is full at %d layers"):format(self.layers), 2)
   end
   if width > self.width or height > self.height then
      error(("tecs2d: image %dx%d exceeds the %dx%d cell"):
      format(width, height, self.width, self.height), 2)
   end

   local rowBytes = width * 4
   local byteCount = rowBytes * height
   ensureTransfer(self, byteCount)

   local mapped = C.SDL_MapGPUTransferBuffer(self._device, self._transfer, true)
   if mapped == nil then sdl.fail("SDL_MapGPUTransferBuffer") end



   local source = loader.bytePointer(pixels)
   local destination = loader.bytePointer(mapped)
   for row = 0, height - 1 do
      loader.copyTo(destination + row * rowBytes,
      (source + row * pitch), rowBytes)
   end
   C.SDL_UnmapGPUTransferBuffer(self._device, self._transfer)

   local layer = self.used
   self.used = layer + 1

   local commandBuffer = C.SDL_AcquireGPUCommandBuffer(self._device)
   if commandBuffer == nil then sdl.fail("SDL_AcquireGPUCommandBuffer") end
   local copyPass = C.SDL_BeginGPUCopyPass(commandBuffer)

   local from = loader.newArray("SDL_GPUTextureTransferInfo[1]")
   local sourceInfo = from[0]
   sourceInfo.transfer_buffer = self._transfer
   sourceInfo.offset = 0
   sourceInfo.pixels_per_row = width
   sourceInfo.rows_per_layer = height

   local to = loader.newArray("SDL_GPUTextureRegion[1]")
   local region = to[0]
   region.texture = self.handle
   region.mip_level = 0
   region.layer = layer
   region.x, region.y, region.z = 0, 0, 0
   region.w, region.h, region.d = width, height, 1

   C.SDL_UploadToGPUTexture(copyPass, from, to, false)
   C.SDL_EndGPUCopyPass(copyPass)
   sdl.check(C.SDL_SubmitGPUCommandBuffer(commandBuffer),
   "SDL_SubmitGPUCommandBuffer")

   return {
      layer = layer,
      u1 = width / self.width,
      v1 = height / self.height,
      width = width,
      height = height,
   }
end


function TextureArray:destroy()
   if self._destroyed then return end
   self._destroyed = true
   if self._transfer ~= nil then
      C.SDL_ReleaseGPUTransferBuffer(self._device, self._transfer)
      self._transfer = nil
   end
   C.SDL_ReleaseGPUTexture(self._device, self.handle)
   self.handle = nil
end

return TextureArray
