






local ffi = require("ffi")
local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")

local C = sdl.C

local capabilities = {}

































local resolved = nil





local function jitEnabled()
   local ok, module = pcall(require, "jit")
   if not ok then return false end
   local status = (module).status
   if status == nil then return false end
   local running = (status)()
   return running == true
end




function capabilities.get()
   if resolved ~= nil then return resolved end

   local platform = loader.toString(C.SDL_GetPlatform())




   local hasCompiler = pcall(require, "tecs2d.ffi.shaderc") and
   pcall(require, "tecs2d.ffi.spvc")


   local formats = { "spirv" }
   if ffi.os == "OSX" or ffi.os == "iOS" then
      formats = { "msl", "metallib" }
   end

   resolved = {
      target = platform,
      architecture = ffi.arch,


      jit = jitEnabled(),
      ffi = true,


      dynamicLibraries = not loader.isStatic("sdl3"),
      runtimeShaders = hasCompiler,
      shaderFormats = formats,
      touch = tonumber(C.SDL_GetNumLogicalCPUCores()) ~= nil and
      (platform == "iOS" or platform == "Android"),
      controller = true,
      sensors = platform == "iOS" or platform == "Android",
      workers = pcall(require, "tecs2d.workers"),
      cores = tonumber(C.SDL_GetNumLogicalCPUCores()),
      writableStorage = true,
   }
   return resolved
end

return capabilities
