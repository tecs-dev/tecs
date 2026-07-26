




























local ffi = require("ffi")
local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")
local shaders = require("tecs2d.gpu.shaders")
local shaderpack = require("tecs2d.gpu.shaderpack")

local K = sdl.K






local SC = nil
local SP = nil
local compilerMissing = nil

local function loadCompiler()
   if SC ~= nil then return true end
   if compilerMissing ~= nil then return false end
   local okShaderc, shadercModule = pcall(require, "tecs2d.ffi.shaderc")
   if not okShaderc then
      compilerMissing = tostring(shadercModule)
      return false
   end
   local okSpvc, spvcModule = pcall(require, "tecs2d.ffi.spvc")
   if not okSpvc then
      compilerMissing = tostring(spvcModule)
      return false
   end
   SC = (shadercModule).C
   SP = (spvcModule).C
   return true
end

local function requireCompiler(level)
   if loadCompiler() then return end
   error("tecs2d: this build links no shader compiler, so every shader must " ..
   "come from a pack: " .. compilerMissing, level + 1)
end


local DECORATION_BINDING = 33
local DECORATION_DESCRIPTOR_SET = 34












local SET_LAYOUTS = {
   vertex = { resources = 0, readWrite = -1, uniforms = 1 },
   fragment = { resources = 2, readWrite = -1, uniforms = 3 },
   compute = { resources = 0, readWrite = 1, uniforms = 2 },
}


local MSL_ENTRYPOINT = "main0"



















local shadercompiler = {}









local STAGE_KINDS = nil

local compilerHandle = nil

local function shadercCompiler()
   if compilerHandle == nil then
      requireCompiler(3)
      compilerHandle = SC.shaderc_compiler_initialize()
      if compilerHandle == nil then
         error("tecs2d: shaderc_compiler_initialize failed", 2)
      end
      STAGE_KINDS = {
         vertex = SC.shaderc_vertex_shader,
         fragment = SC.shaderc_fragment_shader,
         compute = SC.shaderc_compute_shader,
      }
   end
   return compilerHandle
end





local function toSpirv(source, stage, name,
   defines)
   local compiler = shadercCompiler()
   local kind = STAGE_KINDS[stage]
   if kind == nil then
      error(("tecs2d: unknown shader stage '%s'"):format(tostring(stage)), 3)
   end

   local options = SC.shaderc_compile_options_initialize()


   SC.shaderc_compile_options_set_target_env(options,
   SC.shaderc_target_env_vulkan, SC.shaderc_env_version_vulkan_1_0)
   SC.shaderc_compile_options_set_optimization_level(options,
   SC.shaderc_optimization_level_performance)
   if defines ~= nil then
      for key, value in pairs(defines) do
         SC.shaderc_compile_options_add_macro_definition(options,
         key, #key, value, #value)
      end
   end

   local result = SC.shaderc_compile_into_spv(compiler, source, #source,
   kind, name or "shader.glsl", "main", options)
   SC.shaderc_compile_options_release(options)

   local status = SC.shaderc_result_get_compilation_status(result)
   if tonumber(status) ~= 0 then
      local message = loader.toString(SC.shaderc_result_get_error_message(result))
      SC.shaderc_result_release(result)
      error(("tecs2d: %s failed to compile:\n%s"):format(name or "shader", message), 3)
   end

   local length = tonumber(SC.shaderc_result_get_length(result))
   local bytes = SC.shaderc_result_get_bytes(result)


   local words = loader.newArray("uint32_t[?]", math.floor(length / 4))
   loader.copyBytes(words, bytes, length)
   SC.shaderc_result_release(result)

   return words, math.floor(length / 4)
end











local function spvcCheck(context, result, what)
   if tonumber(result) ~= 0 then
      local message = loader.toString(SP.spvc_context_get_last_error_string(context))
      error(("tecs2d: %s failed: %s"):format(what, message), 3)
   end
end



local function collect(compiler, resources,
   resourceType)
   local listOut = loader.newArray("const spvc_reflected_resource*[1]")
   local countOut = loader.newArray("size_t[1]")
   SP.spvc_resources_get_resource_list_for_type(resources, resourceType,
   listOut, countOut)

   local list = listOut[0]
   local count = tonumber(countOut[0])
   local found = {}
   for i = 0, count - 1 do
      local entry = (list)[i]
      local id = entry.id
      found[#found + 1] = {
         set = tonumber(SP.spvc_compiler_get_decoration(compiler, id,
         DECORATION_DESCRIPTOR_SET)),
         binding = tonumber(SP.spvc_compiler_get_decoration(compiler, id,
         DECORATION_BINDING)),
         id = id,
      }
   end
   table.sort(found, function(a, b)
      return a.binding < b.binding
   end)
   return found
end

local function inSet(bindings, set)
   local out = {}
   for _, entry in ipairs(bindings) do
      if entry.set == set then out[#out + 1] = entry end
   end
   return out
end


local EXECUTION_MODE_LOCAL_SIZE = 17





local function localSize(compiler)
   local size = {}
   for axis = 0, 2 do
      size[axis + 1] = tonumber(
      SP.spvc_compiler_get_execution_mode_argument_by_index(
      compiler, EXECUTION_MODE_LOCAL_SIZE, axis))
   end
   return size
end









local function reflect(words, wordCount,
   stage, translate)
   local contextOut = loader.newArray("spvc_context[1]")
   if tonumber(SP.spvc_context_create(contextOut)) ~= 0 then
      error("tecs2d: spvc_context_create failed", 3)
   end
   local context = contextOut[0]

   local work = function()
      local irOut = loader.newArray("spvc_parsed_ir[1]")
      spvcCheck(context,
      SP.spvc_context_parse_spirv(context, words, wordCount, irOut),
      "spvc_context_parse_spirv")

      local compilerOut = loader.newArray("spvc_compiler[1]")
      local backend = translate and SP.SPVC_BACKEND_MSL or SP.SPVC_BACKEND_NONE
      spvcCheck(context, SP.spvc_context_create_compiler(context,
      backend, irOut[0],
      SP.SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, compilerOut),
      "spvc_context_create_compiler")
      local compiler = compilerOut[0]

      local resourcesOut = loader.newArray("spvc_resources[1]")
      spvcCheck(context,
      SP.spvc_compiler_create_shader_resources(compiler, resourcesOut),
      "spvc_compiler_create_shader_resources")
      local resources = resourcesOut[0]

      local layout = SET_LAYOUTS[stage]
      if layout == nil then
         error(("tecs2d: no descriptor layout for stage '%s'"):format(
         tostring(stage)), 2)
      end

      local sampled = inSet(
      collect(compiler, resources, SP.SPVC_RESOURCE_TYPE_SAMPLED_IMAGE),
      layout.resources)
      local images = collect(compiler, resources, SP.SPVC_RESOURCE_TYPE_STORAGE_IMAGE)
      local buffers = collect(compiler, resources, SP.SPVC_RESOURCE_TYPE_STORAGE_BUFFER)
      local uniforms = collect(compiler, resources, SP.SPVC_RESOURCE_TYPE_UNIFORM_BUFFER)

      local roTextures = inSet(images, layout.resources)
      local roBuffers = inSet(buffers, layout.resources)
      local rwTextures = inSet(images, layout.readWrite)
      local rwBuffers = inSet(buffers, layout.readWrite)
      local uniformBuffers = inSet(uniforms, layout.uniforms)

      local counts = {
         samplers = #sampled,
         readOnlyStorageTextures = #roTextures,
         readOnlyStorageBuffers = #roBuffers,
         readWriteStorageTextures = #rwTextures,
         readWriteStorageBuffers = #rwBuffers,
         uniformBuffers = #uniformBuffers,
      }

      local executionModel = stage == "vertex" and 0 or
      stage == "fragment" and 4 or
      5


      local binding = loader.newArray("spvc_msl_resource_binding[1]")
      local function remap(entry, bufferIndex,
         textureIndex, samplerIndex)
         SP.spvc_msl_resource_binding_init(binding)
         local slot = binding[0]
         slot.stage = executionModel
         slot.desc_set = entry.set
         slot.binding = entry.binding
         slot.msl_buffer = bufferIndex
         slot.msl_texture = textureIndex
         slot.msl_sampler = samplerIndex
         spvcCheck(context,
         SP.spvc_compiler_msl_add_resource_binding(compiler, binding),
         "spvc_compiler_msl_add_resource_binding")
      end

      if not translate then
         local threadsOnly = stage == "compute" and localSize(compiler) or nil
         return nil, counts, threadsOnly
      end

      local bufferSlot = 0
      for _, entry in ipairs(uniformBuffers) do
         remap(entry, bufferSlot, 0, 0); bufferSlot = bufferSlot + 1
      end
      for _, entry in ipairs(roBuffers) do
         remap(entry, bufferSlot, 0, 0); bufferSlot = bufferSlot + 1
      end
      for _, entry in ipairs(rwBuffers) do
         remap(entry, bufferSlot, 0, 0); bufferSlot = bufferSlot + 1
      end

      local textureSlot = 0
      for _, entry in ipairs(sampled) do
         remap(entry, 0, textureSlot, textureSlot); textureSlot = textureSlot + 1
      end
      for _, entry in ipairs(roTextures) do
         remap(entry, 0, textureSlot, 0); textureSlot = textureSlot + 1
      end
      for _, entry in ipairs(rwTextures) do
         remap(entry, 0, textureSlot, 0); textureSlot = textureSlot + 1
      end

      local optionsOut = loader.newArray("spvc_compiler_options[1]")
      spvcCheck(context,
      SP.spvc_compiler_create_compiler_options(compiler, optionsOut),
      "spvc_compiler_create_compiler_options")
      spvcCheck(context, SP.spvc_compiler_install_compiler_options(
      compiler, optionsOut[0]), "spvc_compiler_install_compiler_options")

      local sourceOut = loader.newArray("const char*[1]")
      spvcCheck(context, SP.spvc_compiler_compile(compiler, sourceOut),
      "spvc_compiler_compile")

      local threads = stage == "compute" and localSize(compiler) or nil



      return loader.toString(sourceOut[0]), counts, threads
   end

   local ok, source, counts, threads = pcall(work)
   SP.spvc_context_destroy(context)
   if not ok then error(source, 3) end
   return source, counts, threads
end

















function shadercompiler.compile(source, stage,
   options)
   options = options or {}
   local name = options.name or ("<%s shader>"):format(stage)

   local words, wordCount = toSpirv(source, stage, name, options.defines)

   if ffi.os ~= "OSX" then


      local _, counts, threads = reflect(words, wordCount, stage, false)
      return {
         code = words,
         codeSize = wordCount * 4,
         _codeOwner = words,
         format = K.SDL_GPU_SHADERFORMAT_SPIRV,
         entrypoint = "main",
         counts = counts,
         threadCount = threads,
      }
   end

   local msl, counts, threads = reflect(words, wordCount, stage, true)


   local bytes = loader.newArray("uint8_t[?]", #msl + 1)
   loader.copyString(bytes, msl)
   return {
      code = bytes,
      codeSize = #msl + 1,
      _codeOwner = bytes,
      format = K.SDL_GPU_SHADERFORMAT_MSL,
      entrypoint = MSL_ENTRYPOINT,
      counts = counts,
      threadCount = threads,
   }
end



function shadercompiler.translate(source, stage,
   options)
   options = options or {}
   local words, wordCount = toSpirv(source, stage,
   options.name or "<shader>", options.defines)
   return reflect(words, wordCount, stage, true)
end







function shadercompiler.available()
   return loadCompiler()
end





local loadedPack = nil


function shadercompiler.usePack(pack)
   loadedPack = pack
end


function shadercompiler.pack()
   return loadedPack
end







function shadercompiler.format()
   if loadedPack ~= nil then return loadedPack.format end
   if ffi.os == "OSX" or ffi.os == "iOS" then
      return K.SDL_GPU_SHADERFORMAT_MSL
   end
   return K.SDL_GPU_SHADERFORMAT_SPIRV
end


local function fromPack(entry)
   local bytes, size = loader.fromString(entry.code)
   return {
      code = bytes,
      codeSize = size,
      _codeOwner = bytes,
      format = entry.format,
      entrypoint = entry.entrypoint,
      counts = entry.counts,
      threadCount = entry.threadCount,
   }
end











function shadercompiler.plan(name, defines,
   hasCompiler)
   local entry = shaders.get(name)
   local key = shaders.key(name, defines)
   local packed = loadedPack ~= nil and loadedPack.shaders[key] or nil

   if packed ~= nil then
      local hash = shaders.hash(entry.source)
      if packed.sourceHash == hash then return "pack" end
      if not hasCompiler then
         error(("tecs2d: packed shader '%s' was built from different source " ..
         "(%s, now %s) and this build cannot recompile"):
         format(key, packed.sourceHash, hash), 2)
      end
      return "compile"
   end

   if hasCompiler then return "compile" end
   if loadedPack == nil then
      error(("tecs2d: no shader pack is loaded and this build cannot compile " ..
      "'%s'"):format(key), 2)
   end
   error(("tecs2d: shader '%s' is not in the pack and this build cannot " ..
   "compile it"):format(key), 2)
end






function shadercompiler.load(name, defines)
   local entry = shaders.get(name)
   if shadercompiler.plan(name, defines, shadercompiler.available()) == "pack" then
      return fromPack(loadedPack.shaders[shaders.key(name, defines)])
   end
   return shadercompiler.compile(entry.source, entry.stage, {
      name = name,
      defines = defines,
   })
end

return shadercompiler
