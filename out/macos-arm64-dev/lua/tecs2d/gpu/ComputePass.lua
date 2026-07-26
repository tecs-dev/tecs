






local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")

local C = sdl.C

local ComputePass = {}




local ComputePassMT = { __index = ComputePass }


function ComputePass.wrap(handle)
   local self = setmetatable({}, ComputePassMT)
   self.handle = handle
   self._finished = false
   return self
end







function ComputePass.begin(commandBuffer,
   readWriteBuffers)
   readWriteBuffers = readWriteBuffers or {}

   local bindings = loader.newArray("SDL_GPUStorageBufferReadWriteBinding[?]",
   math.max(#readWriteBuffers, 1))
   for index, buffer in ipairs(readWriteBuffers) do
      local binding = bindings[index - 1]
      binding.buffer = buffer


      binding.cycle = false
   end

   local handle = C.SDL_BeginGPUComputePass(commandBuffer,
   nil, 0, bindings, #readWriteBuffers)
   if handle == nil then sdl.fail("SDL_BeginGPUComputePass") end
   return ComputePass.wrap(handle)
end


function ComputePass:bindPipeline(pipeline)
   C.SDL_BindGPUComputePipeline(self.handle, pipeline)
end





function ComputePass:bindStorageBuffers(firstSlot,
   buffers)
   local handles = loader.newArray("SDL_GPUBuffer*[?]", #buffers)
   for index, buffer in ipairs(buffers) do
      handles[index - 1] = buffer
   end
   C.SDL_BindGPUComputeStorageBuffers(self.handle, firstSlot, handles, #buffers)
end





function ComputePass:dispatch(x, y, z)
   C.SDL_DispatchGPUCompute(self.handle, x, y or 1, z or 1)
end


function ComputePass:finish()
   if self._finished then return end
   self._finished = true
   C.SDL_EndGPUComputePass(self.handle)
   self.handle = nil
end

return ComputePass
