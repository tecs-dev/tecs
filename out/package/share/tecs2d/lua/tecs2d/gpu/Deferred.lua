










local loader = require("tecs2d.ffi.loader")
local sdl = require("tecs2d.ffi.sdl3")
local PassGraph = require("tecs2d.gpu.PassGraph")
local Shader = require("tecs2d.gpu.Shader")
local Buffer = require("tecs2d.gpu.Buffer")
local GraphicsPipeline = require("tecs2d.gpu.GraphicsPipeline")
local Frame = require("tecs2d.gpu.Frame")

local C = sdl.C


local RGBA8 = 4


local MAX_LIGHTS = 256


local LIGHT_STRIDE = 32






















local Deferred = {}
















local DeferredMT = { __index = Deferred }

local function buildPipeline(device, fragmentName,
   format, name)
   local vertex = Shader.load(device, "deferred.fullscreen.vert", {})
   local fragment = Shader.load(device, fragmentName, {})
   local pipeline = GraphicsPipeline.create(device, {
      vertexShader = vertex,
      fragmentShader = fragment,
      colorFormat = format,
      name = name,
   })
   vertex:destroy()
   fragment:destroy()
   return pipeline
end


function Deferred.create(device, swapchainFormat,
   options)
   options = options or {}

   local self = setmetatable({}, DeferredMT)
   self._device = device
   self.lightCount = 0
   self.ambient = options.ambient or { 0.08, 0.08, 0.10 }
   self._destroyed = false

   self._lightBuffer = Buffer.create(device, {
      usage = { "storage" },
      size = MAX_LIGHTS * LIGHT_STRIDE,
   })
   self._sceneUniform = loader.newArray("float[8]")

   local graph = PassGraph.create(device, swapchainFormat)
   graph:target({
      name = "albedo",
      format = RGBA8,
      clear = { r = 0, g = 0, b = 0, a = 0 },
   })
   graph:target({
      name = "normal",
      format = RGBA8,


      clear = { r = 0.5, g = 0.5, b = 1.0, a = 0 },
   })
   graph:target({
      name = "lit",
      format = RGBA8,
      clear = { r = 0, g = 0, b = 0, a = 1 },
   })

   self._lightingPipeline = buildPipeline(device, "deferred.lighting.frag",
   RGBA8, "lighting")
   self._compositePipeline = buildPipeline(device, "deferred.composite.frag",
   swapchainFormat, "composite")

   graph:pass({
      name = "geometry",
      outputs = { "albedo", "normal" },
      execute = function(context)
         if options.geometry ~= nil then options.geometry(context) end
      end,
   })

   graph:pass({
      name = "lighting",
      inputs = { "albedo", "normal" },
      outputs = { "lit" },
      execute = function(context)
         local scene = self._sceneUniform
         scene[0] = self.ambient[1]
         scene[1] = self.ambient[2]
         scene[2] = self.ambient[3]
         scene[3] = 0.0
         scene[4] = context.width
         scene[5] = context.height
         scene[6] = self.lightCount
         scene[7] = 0.0

         context.pass:bindPipeline(self._lightingPipeline.handle)
         context.pass:bindFragmentStorageBuffers(0, { self._lightBuffer.handle })
         C.SDL_PushGPUFragmentUniformData(context.commandBuffer, 0, scene, 32)
         context.pass:draw(3)
      end,
   })

   graph:pass({
      name = "composite",
      inputs = { "lit" },
      outputs = {},
      execute = function(context)
         context.pass:bindPipeline(self._compositePipeline.handle)
         context.pass:draw(3)
      end,
   })

   self.graph = graph
   return self
end






function Deferred:setLights(lights)
   local count = math.min(#lights, MAX_LIGHTS)
   self.lightCount = count
   if count == 0 then return end

   local staging = self._lightBuffer:mapAs("float *")
   for index = 1, count do
      local light = lights[index]
      local base = (index - 1) * 8
      staging[base] = light.x or 0.0
      staging[base + 1] = light.y or 0.0
      staging[base + 2] = light.z or 32.0
      staging[base + 3] = light.radius or 128.0
      staging[base + 4] = light.r or 1.0
      staging[base + 5] = light.g or 1.0
      staging[base + 6] = light.b or 1.0
      staging[base + 7] = light.intensity or 1.0
   end
   self._lightBuffer:markDirty(0, count * LIGHT_STRIDE)
end






function Deferred:render(frame)
   self._lightBuffer:flush(frame.commandBuffer)
   self.graph:execute(frame)
end


function Deferred:geometryFormats()
   return self.graph:formatOf("albedo"), self.graph:formatOf("normal")
end


function Deferred:destroy()
   if self._destroyed then return end
   self._destroyed = true
   self.graph:destroy()
   self._lightingPipeline:destroy()
   self._compositePipeline:destroy()
   self._lightBuffer:destroy()
end

return Deferred
