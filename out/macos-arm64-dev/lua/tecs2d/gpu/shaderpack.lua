










local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")

local C = sdl.C
local K = sdl.K
local buffer = require("string.buffer")




local MAGIC = "TECS2DSP"

local shaderpack = { ResourceCounts = {}, Shader = {}, Pack = {} }
















































shaderpack.VERSION = 1

local FORMAT_NAMES = {
   "private", "spirv", "dxbc", "dxil", "msl", "metallib",
}


function shaderpack.formatName(format)
   local names = {}
   names[K.SDL_GPU_SHADERFORMAT_PRIVATE] = "private"
   names[K.SDL_GPU_SHADERFORMAT_SPIRV] = "spirv"
   names[K.SDL_GPU_SHADERFORMAT_DXBC] = "dxbc"
   names[K.SDL_GPU_SHADERFORMAT_DXIL] = "dxil"
   names[K.SDL_GPU_SHADERFORMAT_MSL] = "msl"
   names[K.SDL_GPU_SHADERFORMAT_METALLIB] = "metallib"
   return names[format] or ("0x%x"):format(format)
end


function shaderpack.formatValue(name)
   for _, candidate in ipairs(FORMAT_NAMES) do
      if candidate == name then
         return K[("SDL_GPU_SHADERFORMAT_%s"):format(candidate:upper())]
      end
   end
   error(("tecs2d: '%s' is not a shader format"):format(tostring(name)), 2)
end


function shaderpack.encode(pack)
   return MAGIC .. string.char(shaderpack.VERSION) ..
   buffer.encode(pack)
end



function shaderpack.decode(bytes, origin)
   origin = origin or "<memory>"
   if #bytes < #MAGIC + 1 or bytes:sub(1, #MAGIC) ~= MAGIC then
      error(("tecs2d: %s is not a shader pack"):format(origin), 2)
   end
   local version = bytes:byte(#MAGIC + 1)
   if version ~= shaderpack.VERSION then
      error(("tecs2d: %s is a version %d shader pack, this build reads %d"):
      format(origin, version, shaderpack.VERSION), 2)
   end
   local ok, decoded = pcall(function()
      return buffer.decode(bytes:sub(#MAGIC + 2))
   end)
   if not ok then
      error(("tecs2d: %s is a corrupt shader pack: %s"):
      format(origin, tostring(decoded)), 2)
   end
   return decoded
end





function shaderpack.write(path, pack)
   local file, reason = io.open(path, "wb")
   if file == nil then
      error(("tecs2d: cannot write %s: %s"):format(path, tostring(reason)), 2)
   end
   file:write(shaderpack.encode(pack))
   file:close()
end





function shaderpack.read(path)
   local size = loader.newArray("size_t[1]")
   local data = C.SDL_LoadFile(path, size)
   if data == nil then return nil end
   local bytes = loader.toBytes(data, tonumber(size[0]))
   C.SDL_free(data)
   return shaderpack.decode(bytes, path)
end

return shaderpack
