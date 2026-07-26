








local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")
local shadercompiler = require("tecs2d.gpu.shadercompiler")

local C = sdl.C






local ComputePipeline = {}









local ComputePipelineMT = {
   __index = ComputePipeline,
}


function ComputePipeline.fromGLSL(device, source,
   options)
   options = options or {}
   local compiled = shadercompiler.compile(source, "compute", {
      name = options.name,
      defines = options.defines,
   })

   local info = loader.newArray("SDL_GPUComputePipelineCreateInfo[1]")
   local settings = info[0]
   settings.code = compiled.code
   settings.code_size = compiled.codeSize
   settings.entrypoint = compiled.entrypoint
   settings.format = compiled.format
   settings.num_samplers = compiled.counts.samplers
   settings.num_readonly_storage_textures = compiled.counts.readOnlyStorageTextures
   settings.num_readonly_storage_buffers = compiled.counts.readOnlyStorageBuffers
   settings.num_readwrite_storage_textures = compiled.counts.readWriteStorageTextures
   settings.num_readwrite_storage_buffers = compiled.counts.readWriteStorageBuffers
   settings.num_uniform_buffers = compiled.counts.uniformBuffers
   settings.threadcount_x = compiled.threadCount[1]
   settings.threadcount_y = compiled.threadCount[2]
   settings.threadcount_z = compiled.threadCount[3]
   settings.props = 0

   local handle = C.SDL_CreateGPUComputePipeline(device, info)
   if handle == nil then sdl.fail("SDL_CreateGPUComputePipeline") end

   local self = setmetatable({}, ComputePipelineMT)
   self.handle = handle
   self.counts = compiled.counts
   self.threadCount = compiled.threadCount
   self._device = device
   self._code = compiled.code
   self._destroyed = false
   return self
end


function ComputePipeline:destroy()
   if self._destroyed then return end
   self._destroyed = true
   C.SDL_ReleaseGPUComputePipeline(self._device, self.handle)
   self.handle = nil
   self._code = nil
end

return ComputePipeline
