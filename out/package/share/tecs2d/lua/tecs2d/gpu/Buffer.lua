
















local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")

local C = sdl.C
local K = sdl.K



local MAX_RANGES = 64















local Buffer = {}














local BufferMT = { __index = Buffer }



local USAGE_FLAGS = {
   indirect = K.SDL_GPU_BUFFERUSAGE_INDIRECT,
   storage = K.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
   computeRead = K.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ,
   computeWrite = K.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
}


function Buffer.create(device, options)
   local flags = 0
   for _, name in ipairs(options.usage or { "storage" }) do
      local flag = USAGE_FLAGS[name]
      if flag == nil then
         error(("tecs2d: unknown buffer usage '%s'"):format(tostring(name)), 2)
      end
      flags = flags + flag
   end

   local info = loader.newArray("SDL_GPUBufferCreateInfo[1]")
   local settings = info[0]
   settings.usage = flags
   settings.size = options.size
   settings.props = 0

   local handle = C.SDL_CreateGPUBuffer(device, info)
   if handle == nil then sdl.fail("SDL_CreateGPUBuffer") end

   local self = setmetatable({}, BufferMT)
   self.handle = handle
   self.size = options.size
   self.dirtyBytes = 0
   self._device = device
   self._transferSize = options.stagingSize or options.size
   self._rangeCount = 0
   self._collapsed = false
   self._destroyed = false
   self._ranges = loader.newArray("uint32_t[?]", MAX_RANGES * 2)
   return self
end

local function ensureTransfer(self)
   if self._transfer ~= nil then return end
   local info = loader.newArray("SDL_GPUTransferBufferCreateInfo[1]")
   local settings = info[0]
   settings.usage = C.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD
   settings.size = self._transferSize
   settings.props = 0
   self._transfer = C.SDL_CreateGPUTransferBuffer(self._device, info)
   if self._transfer == nil then sdl.fail("SDL_CreateGPUTransferBuffer") end
end










function Buffer:map(cycle)
   ensureTransfer(self)
   if self._mapped ~= nil then
      return loader.bytePointer(self._mapped)
   end
   local shouldCycle = cycle ~= false
   local mapped = C.SDL_MapGPUTransferBuffer(self._device, self._transfer,
   shouldCycle)
   if mapped == nil then sdl.fail("SDL_MapGPUTransferBuffer") end
   self._mapped = mapped
   return loader.bytePointer(self._mapped)
end





function Buffer:mapAs(declaration, cycle)
   self:map(cycle)
   return loader.castPointer(declaration, self._mapped)
end






function Buffer:markDirty(offset, size)
   if size <= 0 then return end
   self.dirtyBytes = self.dirtyBytes + size

   if self._collapsed then
      local ranges = self._ranges
      local start = math.min(ranges[0], offset)
      local finish = math.max((ranges[0]) + (ranges[1]),
      offset + size)
      ranges[0] = start
      ranges[1] = finish - start
      return
   end

   local ranges = self._ranges
   local count = self._rangeCount

   if count > 0 then
      local lastOffset = ranges[(count - 1) * 2]
      local lastSize = ranges[(count - 1) * 2 + 1]
      if offset <= lastOffset + lastSize and offset + size >= lastOffset then
         local start = math.min(lastOffset, offset)
         local finish = math.max(lastOffset + lastSize, offset + size)
         ranges[(count - 1) * 2] = start
         ranges[(count - 1) * 2 + 1] = finish - start
         return
      end
   end

   if count >= MAX_RANGES then
      local start = ranges[0]
      local finish = start
      for index = 0, count - 1 do
         local rangeEnd = (ranges[index * 2]) +
         (ranges[index * 2 + 1])
         start = math.min(start, ranges[index * 2])
         finish = math.max(finish, rangeEnd)
      end
      start = math.min(start, offset)
      finish = math.max(finish, offset + size)
      ranges[0] = start
      ranges[1] = finish - start
      self._rangeCount = 1
      self._collapsed = true
      return
   end

   ranges[count * 2] = offset
   ranges[count * 2 + 1] = size
   self._rangeCount = count + 1
end





function Buffer:write(offset, source, size)
   local base = self:map()
   loader.copyTo(base + offset, source, size)
   self:markDirty(offset, size)
end









function Buffer:flush(commandBuffer)
   if self._mapped ~= nil then
      C.SDL_UnmapGPUTransferBuffer(self._device, self._transfer)
      self._mapped = nil
   end

   local count = self._rangeCount
   if count == 0 then return false end

   local from = loader.newArray("SDL_GPUTransferBufferLocation[1]")
   local to = loader.newArray("SDL_GPUBufferRegion[1]")
   local source = from[0]
   local destination = to[0]
   source.transfer_buffer = self._transfer
   destination.buffer = self.handle

   local copyPass = C.SDL_BeginGPUCopyPass(commandBuffer)
   for index = 0, count - 1 do
      local offset = self._ranges[index * 2]
      local size = self._ranges[index * 2 + 1]
      source.offset = offset
      destination.offset = offset
      destination.size = size
      C.SDL_UploadToGPUBuffer(copyPass, from, to, false)
   end
   C.SDL_EndGPUCopyPass(copyPass)

   self._rangeCount = 0
   self._collapsed = false
   self.dirtyBytes = 0
   return true
end





function Buffer:upload(source, byteCount, offset)
   self:write(offset or 0, source, byteCount)
   local commandBuffer = C.SDL_AcquireGPUCommandBuffer(self._device)
   if commandBuffer == nil then sdl.fail("SDL_AcquireGPUCommandBuffer") end
   self:flush(commandBuffer)
   sdl.check(C.SDL_SubmitGPUCommandBuffer(commandBuffer),
   "SDL_SubmitGPUCommandBuffer")
end


function Buffer:destroy()
   if self._destroyed then return end
   self._destroyed = true
   if self._mapped ~= nil then
      C.SDL_UnmapGPUTransferBuffer(self._device, self._transfer)
      self._mapped = nil
   end
   if self._transfer ~= nil then
      C.SDL_ReleaseGPUTransferBuffer(self._device, self._transfer)
      self._transfer = nil
   end
   C.SDL_ReleaseGPUBuffer(self._device, self.handle)
   self.handle = nil
end

return Buffer
