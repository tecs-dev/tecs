








local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")

local C = sdl.C


local MAX_COLOR_TARGETS = 8

local RenderPass = { ClearColor = {}, Attachment = {} }
























local RenderPassMT = { __index = RenderPass }


local targets = loader.newArray("SDL_GPUColorTargetInfo[?]", MAX_COLOR_TARGETS)


function RenderPass.wrap(handle, commandBuffer,
   targetCount)
   local self = setmetatable({}, RenderPassMT)
   self.handle = handle
   self.commandBuffer = commandBuffer
   self.targetCount = targetCount or 1
   self._finished = false
   return self
end


function RenderPass.begin(commandBuffer,
   attachments)
   local count = #attachments
   if count == 0 then
      error("tecs2d: a render pass needs at least one colour attachment", 2)
   end
   if count > MAX_COLOR_TARGETS then
      error(("tecs2d: %d colour attachments exceeds the limit of %d"):
      format(count, MAX_COLOR_TARGETS), 2)
   end

   for index, attachment in ipairs(attachments) do
      local target = targets[index - 1]
      target.texture = attachment.texture
      target.mip_level = 0
      target.layer_or_depth_plane = 0
      target.resolve_texture = nil
      target.cycle = false
      target.cycle_resolve_texture = false
      target.store_op = C.SDL_GPU_STOREOP_STORE

      local clear = attachment.clear
      if clear ~= nil then
         target.load_op = C.SDL_GPU_LOADOP_CLEAR
         local color = target.clear_color
         color.r = clear.r or 0.0
         color.g = clear.g or 0.0
         color.b = clear.b or 0.0
         color.a = clear.a or 1.0
      else
         target.load_op = C.SDL_GPU_LOADOP_LOAD
      end
   end

   local handle = C.SDL_BeginGPURenderPass(commandBuffer, targets, count, nil)
   if handle == nil then sdl.fail("SDL_BeginGPURenderPass") end
   return RenderPass.wrap(handle, commandBuffer, count)
end


function RenderPass:bindPipeline(pipeline)
   C.SDL_BindGPUGraphicsPipeline(self.handle, pipeline)
end




function RenderPass:bindTextures(firstSlot,
   textures,
   sampler)
   local bindings = loader.newArray("SDL_GPUTextureSamplerBinding[?]", #textures)
   for index, texture in ipairs(textures) do
      local binding = bindings[index - 1]
      binding.texture = texture
      binding.sampler = sampler
   end
   C.SDL_BindGPUFragmentSamplers(self.handle, firstSlot, bindings, #textures)
end


function RenderPass:bindVertexStorageBuffers(firstSlot,
   buffers)
   local handles = loader.newArray("SDL_GPUBuffer*[?]", #buffers)
   for index, buffer in ipairs(buffers) do
      handles[index - 1] = buffer
   end
   C.SDL_BindGPUVertexStorageBuffers(self.handle, firstSlot, handles, #buffers)
end


function RenderPass:bindFragmentStorageBuffers(firstSlot,
   buffers)
   local handles = loader.newArray("SDL_GPUBuffer*[?]", #buffers)
   for index, buffer in ipairs(buffers) do
      handles[index - 1] = buffer
   end
   C.SDL_BindGPUFragmentStorageBuffers(self.handle, firstSlot, handles, #buffers)
end


function RenderPass:pushVertexUniform(slot, data,
   byteCount)
   C.SDL_PushGPUVertexUniformData(self.commandBuffer, slot, data, byteCount)
end


function RenderPass:pushFragmentUniform(slot, data,
   byteCount)
   C.SDL_PushGPUFragmentUniformData(self.commandBuffer, slot, data, byteCount)
end





function RenderPass:draw(vertexCount, instanceCount,
   firstVertex, firstInstance)
   C.SDL_DrawGPUPrimitives(self.handle, vertexCount, instanceCount or 1,
   firstVertex or 0, firstInstance or 0)
end





function RenderPass:drawIndirect(buffer, offset,
   drawCount)
   C.SDL_DrawGPUPrimitivesIndirect(self.handle, buffer, offset or 0, drawCount or 1)
end



function RenderPass:finish()
   if self._finished then return end
   self._finished = true
   C.SDL_EndGPURenderPass(self.handle)
   self.handle = nil
end

return RenderPass
