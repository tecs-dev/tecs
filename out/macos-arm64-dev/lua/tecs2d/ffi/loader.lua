






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










function loader.library(soname, formula, envVar)
   local cached = loaded[soname]
   if cached ~= nil then return cached, "(cached)" end

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
      error(("tecs2d: missing generated cdef for %s. Run `make cdef`."):format(name), 2)
   end
   ffi.cdef(source)
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
