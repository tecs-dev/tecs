










local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")
local Shader = require("tecs2d.gpu.Shader")

local C = sdl.C




















local GraphicsPipeline = {}





local GraphicsPipelineMT = {
   __index = GraphicsPipeline,
}

local PRIMITIVES = {
   triangleList = 0,
   triangleStrip = 1,
   lineList = 2,
   lineStrip = 3,
   pointList = 4,
}

local CULL_MODES = {
   none = 0,
   front = 1,
   back = 2,
}


local BLEND_FACTOR_SRC_ALPHA = 5
local BLEND_FACTOR_ONE_MINUS_SRC_ALPHA = 6
local BLEND_FACTOR_ONE = 2
local BLEND_OP_ADD = 1


function GraphicsPipeline.create(device,
   options)
   local primitive = PRIMITIVES[options.primitive or "triangleList"]
   if primitive == nil then
      error(("tecs2d: unknown primitive type '%s'"):format(
      tostring(options.primitive)), 2)
   end
   local cull = CULL_MODES[options.cull or "none"]
   if cull == nil then
      error(("tecs2d: unknown cull mode '%s'"):format(tostring(options.cull)), 2)
   end

   local formats = options.colorFormats
   if formats == nil then
      if options.colorFormat == nil then
         error("tecs2d: a pipeline needs colorFormat or colorFormats", 2)
      end
      formats = { options.colorFormat }
   end

   local targets = loader.newArray("SDL_GPUColorTargetDescription[?]", #formats)
   for index, format in ipairs(formats) do
      local target = targets[index - 1]
      target.format = format

      local blend = target.blend_state
      if options.blend then
         blend.enable_blend = true
         blend.src_color_blendfactor = BLEND_FACTOR_SRC_ALPHA
         blend.dst_color_blendfactor = BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
         blend.color_blend_op = BLEND_OP_ADD
         blend.src_alpha_blendfactor = BLEND_FACTOR_ONE
         blend.dst_alpha_blendfactor = BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
         blend.alpha_blend_op = BLEND_OP_ADD
      else
         blend.enable_blend = false
      end
   end

   local info = loader.newArray("SDL_GPUGraphicsPipelineCreateInfo[1]")
   local settings = info[0]
   settings.vertex_shader = options.vertexShader.handle
   settings.fragment_shader = options.fragmentShader.handle
   settings.primitive_type = primitive

   local rasterizer = settings.rasterizer_state
   rasterizer.fill_mode = 0
   rasterizer.cull_mode = cull
   rasterizer.front_face = 0

   local targetInfo = settings.target_info
   targetInfo.color_target_descriptions = targets
   targetInfo.num_color_targets = #formats
   targetInfo.has_depth_stencil_target = false

   local handle = C.SDL_CreateGPUGraphicsPipeline(device, info)
   if handle == nil then sdl.fail("SDL_CreateGPUGraphicsPipeline") end

   local self = setmetatable({}, GraphicsPipelineMT)
   self.handle = handle
   self._device = device
   self._destroyed = false
   return self
end


function GraphicsPipeline:destroy()
   if self._destroyed then return end
   self._destroyed = true
   C.SDL_ReleaseGPUGraphicsPipeline(self._device, self.handle)
   self.handle = nil
end

return GraphicsPipeline
