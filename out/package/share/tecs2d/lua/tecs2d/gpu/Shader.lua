









local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")
local shadercompiler = require("tecs2d.gpu.shadercompiler")
local shaders = require("tecs2d.gpu.shaders")

local C = sdl.C








local Shader = {}









local ShaderMT = { __index = Shader }

local STAGES = {
   vertex = 0,
   fragment = 1,
}


local function create(device, stage,
   compiled)
   local stageEnum = STAGES[stage]
   if stageEnum == nil then
      error(("tecs2d: '%s' is not a graphics shader stage"):format(tostring(stage)), 3)
   end

   local info = loader.newArray("SDL_GPUShaderCreateInfo[1]")
   local settings = info[0]
   settings.code = compiled.code
   settings.code_size = compiled.codeSize
   settings.entrypoint = compiled.entrypoint
   settings.format = compiled.format
   settings.stage = stageEnum
   settings.num_samplers = compiled.counts.samplers
   settings.num_storage_textures = compiled.counts.readOnlyStorageTextures
   settings.num_storage_buffers = compiled.counts.readOnlyStorageBuffers
   settings.num_uniform_buffers = compiled.counts.uniformBuffers
   settings.props = 0

   local handle = C.SDL_CreateGPUShader(device, info)
   if handle == nil then sdl.fail("SDL_CreateGPUShader") end

   local self = setmetatable({}, ShaderMT)
   self.handle = handle
   self.stage = stage
   self.counts = compiled.counts
   self._device = device
   self._code = compiled.code
   self._destroyed = false
   return self
end







function Shader.load(device, name,
   options)
   options = options or {}
   local entry = shaders.get(name)
   return create(device, entry.stage,
   shadercompiler.load(name, options.defines))
end







function Shader.fromGLSL(device, source, stage,
   options)
   options = options or {}
   return create(device, stage, shadercompiler.compile(source, stage, {
      name = options.name,
      defines = options.defines,
   }))
end





function Shader:destroy()
   if self._destroyed then return end
   self._destroyed = true
   C.SDL_ReleaseGPUShader(self._device, self.handle)
   self.handle = nil
   self._code = nil
end

return Shader
