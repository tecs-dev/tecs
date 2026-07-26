






local ffi = require("ffi")
local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")
local shadercompiler = require("tecs2d.gpu.shadercompiler")
local shaderpack = require("tecs2d.gpu.shaderpack")

local C = sdl.C

local capabilities = {}





































local resolved = nil





local function hasTouch()
   local count = loader.newArray("int[1]")
   local devices = C.SDL_GetTouchDevices(count)
   if devices == nil then return false end
   C.SDL_free(devices)
   return tonumber(count[0]) > 0
end





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




   local pack = shadercompiler.pack()
   local formats = { shaderpack.formatName(shadercompiler.format()) }

   resolved = {
      target = platform,
      architecture = ffi.arch,


      jit = jitEnabled(),
      ffi = true,


      dynamicLibraries = not loader.isStatic("sdl3"),
      runtimeShaders = shadercompiler.available(),
      packagedShaders = pack ~= nil,
      shaderFormats = formats,
      touch = hasTouch(),
      controller = true,
      sensors = platform == "iOS" or platform == "Android",
      workers = pcall(require, "tecs2d.workers"),
      cores = tonumber(C.SDL_GetNumLogicalCPUCores()),
      writableStorage = true,
   }
   return resolved
end

return capabilities
