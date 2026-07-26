











local shaders = require("tecs2d.gpu.shaders")
local shaderpack = require("tecs2d.gpu.shaderpack")
local shadercompiler = require("tecs2d.gpu.shadercompiler")
local loader = require("tecs2d.ffi.loader")
local sdl = require("tecs2d.ffi.sdl3")

local C = sdl.C

local shaderbuild = {}







function shaderbuild.build()
   if not shadercompiler.available() then
      error("tecs2d: building a shader pack needs a shader compiler", 2)
   end

   local pack = {
      version = shaderpack.VERSION,
      target = loader.toString(C.SDL_GetPlatform()),
      format = shadercompiler.format(),
      shaders = {},
   }

   for _, variant in ipairs(shaders.buildList()) do
      local compiled = shadercompiler.compile(variant.source, variant.stage, {
         name = variant.key,
         defines = variant.defines,
      })
      if compiled.format ~= pack.format then
         error(("tecs2d: '%s' compiled to %s but the pack is %s"):format(
         variant.key, shaderpack.formatName(compiled.format),
         shaderpack.formatName(pack.format)), 2)
      end
      pack.shaders[variant.key] = {
         key = variant.key,
         name = variant.name,
         stage = variant.stage,
         format = compiled.format,
         entrypoint = compiled.entrypoint,
         sourceHash = shaders.hash(variant.source),
         counts = compiled.counts,
         threadCount = compiled.threadCount,


         code = loader.toBytes(compiled.code, compiled.codeSize),
      }
   end

   return pack
end


function shaderbuild.manifest(pack)
   local keys = {}
   for key in pairs(pack.shaders) do keys[#keys + 1] = key end
   table.sort(keys)

   local lines = {}
   lines[#lines + 1] = ("tecs2d shader pack version %d"):format(pack.version)
   lines[#lines + 1] = ("target %s, format %s, %d shaders"):format(
   pack.target, shaderpack.formatName(pack.format), #keys)
   lines[#lines + 1] = ""
   lines[#lines + 1] = "key                          stage     bytes  entry  " ..
   "source    resources"
   lines[#lines + 1] = ("-"):rep(96)

   for _, key in ipairs(keys) do
      local entry = pack.shaders[key]
      local counts = entry.counts
      local resources = ("sam %d, ro %d/%d, rw %d/%d, uni %d"):format(
      counts.samplers,
      counts.readOnlyStorageTextures, counts.readOnlyStorageBuffers,
      counts.readWriteStorageTextures, counts.readWriteStorageBuffers,
      counts.uniformBuffers)
      local threads = ""
      if entry.stage == "compute" then
         threads = (" threads %dx%dx%d"):format(
         entry.threadCount[1], entry.threadCount[2], entry.threadCount[3])
      end
      lines[#lines + 1] = ("%-28s %-9s %6d  %-6s %-9s %s%s"):format(
      key, entry.stage, #entry.code, entry.entrypoint, entry.sourceHash,
      resources, threads)
   end

   lines[#lines + 1] = ""
   return table.concat(lines, "\n")
end


function shaderbuild.writeTo(path)
   local pack = shaderbuild.build()
   shaderpack.write(path, pack)

   local manifest, reason = io.open(path .. ".txt", "w")
   if manifest == nil then
      error(("tecs2d: cannot write %s.txt: %s"):format(path, tostring(reason)), 2)
   end
   manifest:write(shaderbuild.manifest(pack))
   manifest:close()

   return pack
end

return shaderbuild
