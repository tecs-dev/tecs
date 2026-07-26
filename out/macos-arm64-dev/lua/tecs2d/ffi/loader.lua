













local ffi = require("ffi")

local loader = { CValue = {}, BytePointer = {}, CNamespace = {} }






































loader.searchPaths = {



   (os.getenv("TECS2D_LIB") or "") .. "/",
   "/opt/homebrew/lib/",
   "/opt/homebrew/opt/%s/lib/",
   "/usr/local/lib/",
   "/usr/local/opt/%s/lib/",
   "/usr/lib/",
}

local suffix = ffi.os == "Windows" and ".dll" or
ffi.os == "OSX" and ".dylib" or
".so"

local loaded = {}




local STRUCTS = {
   sdl3 = "Tecs2dSdl3Api",
   sdl3image = "Tecs2dSdl3ImageApi",
   box2d = "Tecs2dBox2dApi",
   shaderc = "Tecs2dShadercApi",
   spvc = "Tecs2dSpvcApi",
   worker = "Tecs2dWorkerApi",
}


local function registryTable(name)
   local registry = (_G)["__tecs2dRegistry"]
   if registry == nil then return nil end
   return (registry)[name]
end











local function registryNamespace(functions)
   local proxy = {}
   return setmetatable(proxy, {
      __index = function(_self, name)



         local ok, found = pcall(function()
            return (functions)[name]
         end)
         if not ok or found == nil then
            found = (ffi.C)[name]
         end
         rawset(proxy, name, found)
         return found
      end,
   })
end


function loader.isStatic(name)
   return registryTable(name) ~= nil
end











function loader.library(soname, formula, envVar,
   registryName)
   local cached = loaded[soname]
   if cached ~= nil then return cached, "(cached)" end



   local key = registryName or soname
   local table_ = registryTable(key)
   if table_ ~= nil then
      local struct = STRUCTS[key]
      if struct == nil then
         error(("tecs2d: %s is in the registry with no declared table"):format(key), 2)
      end
      local namespace = registryNamespace(
      ffi.cast(struct .. " *", table_))
      loaded[soname] = namespace
      return namespace, "(registry)"
   end

   local attempts = {}

   local override = os.getenv(envVar)
   if override ~= nil and override ~= "" then
      attempts[#attempts + 1] = override
   end
   attempts[#attempts + 1] = soname

   for _, prefix in ipairs(loader.searchPaths) do
      local dir = prefix:find("%%s") and prefix:format(formula) or prefix
      attempts[#attempts + 1] = dir .. "lib" .. soname .. suffix
   end

   local failures = {}
   for _, path in ipairs(attempts) do
      local ok, result = pcall(ffi.load, path)
      if ok then
         local namespace = result
         loaded[soname] = namespace
         return namespace, path
      end
      failures[#failures + 1] = path
   end

   error(("tecs2d: cannot load %s. Tried:\n  %s\nSet %s to an absolute path."):
   format(soname, table.concat(failures, "\n  "), envVar), 2)
end

local declared = {}



local function requireGenerated(name)
   return pcall(require, "tecs2d.ffi." .. name)
end






function loader.declare(name)
   if declared[name] then return end
   local ok, source = requireGenerated(name .. "cdef")
   if not ok then
      error(("tecs2d: missing generated cdef for %s. Run the build."):format(name), 2)
   end
   ffi.cdef(source)

   if registryTable(name) ~= nil then
      local hasApi, api = requireGenerated(name .. "apicdef")
      if not hasApi then
         error(("tecs2d: %s is registered but its table declaration is missing"):
         format(name), 2)
      end
      ffi.cdef(api)
   end

   declared[name] = true
end






function loader.toString(value)
   if value == nil then return "" end
   return ffi.string(value)
end








function loader.newStruct(declaration)
   return ffi.new(declaration)
end


function loader.newArray(declaration, count)
   if count ~= nil then
      return ffi.new(declaration, count)
   end
   return ffi.new(declaration)
end


function loader.bytePointer(base)
   return ffi.cast("uint8_t *", base)
end



function loader.castPointer(declaration, base)
   return ffi.cast(declaration, base)
end


function loader.copyBytes(destination, source,
   size)
   ffi.copy(destination, source, size)
end



function loader.copyTo(destination, source,
   size)
   ffi.copy(destination, source, size)
end


function loader.copyString(destination, source)
   ffi.copy(destination, source)
end





function loader.constants(name)
   local ok, table_ = requireGenerated(name .. "const")
   if not ok then
      error(("tecs2d: missing generated constants for %s. Run `make cdef`."):format(name), 2)
   end
   return table_
end

return loader
