
















local loader = require("tecs2d.ffi.loader")
local Texture = require("tecs2d.gpu.Texture")
local Sampler = require("tecs2d.gpu.Sampler")
local RenderPass = require("tecs2d.gpu.RenderPass")
local Frame = require("tecs2d.gpu.Frame")




local DEFAULT_FORMAT = 4




































local PassGraph = {}


















local PassGraphMT = { __index = PassGraph }


function PassGraph.create(device, swapchainFormat)
   local self = setmetatable({}, PassGraphMT)
   self.device = device
   self.swapchainFormat = swapchainFormat
   self._targets = {}
   self._textures = {}
   self._order = {}
   self._passes = {}
   self._sampler = Sampler.create(device, { filter = "nearest", address = "clamp" })
   self._width = 0
   self._height = 0
   self._built = false
   self._destroyed = false
   return self
end


function PassGraph:target(spec)
   if self._targets[spec.name] ~= nil then
      error(("tecs2d: target '%s' is already declared"):format(spec.name), 2)
   end
   spec.format = spec.format or DEFAULT_FORMAT
   spec.scale = spec.scale or 1.0
   self._targets[spec.name] = spec
   self._order[#self._order + 1] = spec.name
   return self
end


function PassGraph:pass(spec)


   local produced = {}
   for _, earlier in ipairs(self._passes) do
      for _, output in ipairs(earlier.outputs or {}) do
         produced[output] = true
      end
   end

   for _, input in ipairs(spec.inputs or {}) do
      if self._targets[input] == nil then
         error(("tecs2d: pass '%s' reads undeclared target '%s'"):
         format(spec.name, input), 2)
      end
      if not produced[input] then
         error(("tecs2d: pass '%s' reads '%s' before any pass writes it"):
         format(spec.name, input), 2)
      end
   end

   for _, output in ipairs(spec.outputs or {}) do
      if self._targets[output] == nil then
         error(("tecs2d: pass '%s' writes undeclared target '%s'"):
         format(spec.name, output), 2)
      end
   end

   self._passes[#self._passes + 1] = spec
   return self
end


function PassGraph:texture(name)
   return self._textures[name]
end





function PassGraph:formatOf(name)
   local spec = self._targets[name]
   if spec == nil then
      error(("tecs2d: no target named '%s'"):format(tostring(name)), 2)
   end
   return spec.format
end


local function resize(self, width, height)
   if self._width == width and self._height == height then return end

   for _, name in ipairs(self._order) do
      local existing = self._textures[name]
      if existing ~= nil then existing:destroy() end

      local spec = self._targets[name]
      local scaledWidth = math.max(1, math.floor(width * spec.scale))
      local scaledHeight = math.max(1, math.floor(height * spec.scale))
      self._textures[name] = Texture.create(self.device, {
         width = scaledWidth,
         height = scaledHeight,
         format = spec.format,
         usage = { "colorTarget", "sampled" },
         name = name,
      })
   end

   self._width = width
   self._height = height
end


function PassGraph:execute(frame)
   local frameWidth = frame.width
   local frameHeight = frame.height
   resize(self, frameWidth, frameHeight)

   for _, spec in ipairs(self._passes) do
      local enabled = spec.enabled == nil or spec.enabled()
      if enabled then
         local outputs = spec.outputs or {}
         local attachments = {}
         local width, height = frameWidth, frameHeight

         if #outputs == 0 then
            attachments[1] = {
               texture = frame.swapchainTexture,
               clear = nil,
            }
         else
            for index, name in ipairs(outputs) do
               local texture = self._textures[name]
               attachments[index] = {
                  texture = texture.handle,
                  clear = self._targets[name].clear,
               }
               width, height = texture.width, texture.height
            end
         end

         local pass = RenderPass.begin(frame.commandBuffer, attachments)

         local inputs = spec.inputs or {}
         if #inputs > 0 then
            local textures = {}
            for index, name in ipairs(inputs) do
               textures[index] = self._textures[name].handle
            end
            pass:bindTextures(0, textures, self._sampler.handle)
         end

         spec.execute({
            pass = pass,
            frame = frame,
            commandBuffer = frame.commandBuffer,
            width = width,
            height = height,
         })

         pass:finish()
      end
   end
end


function PassGraph:destroy()
   if self._destroyed then return end
   self._destroyed = true
   for _, texture in pairs(self._textures) do
      texture:destroy()
   end
   self._textures = {}
   self._sampler:destroy()
end

return PassGraph
