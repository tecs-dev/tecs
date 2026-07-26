


local types = require("tecs.types")
local storage = require("tecs.internal.storage")
local componentids = require("tecs.internal.componentids")
local C = require("ffi")
local schema = require("tecs.internal.ffi.schema")
local StringBuffer = require("string.buffer")



local BUF_PROBE = StringBuffer.new()
local BUF_PUTCDATA = (BUF_PROBE).putcdata
local BUF_REF = (BUF_PROBE).ref
local BUF_SKIP = (BUF_PROBE).skip

local max = math.max
local min = math.min
local select = select





local byteDataByColumn = setmetatable({}, { __mode = "k" })

local FFIStorage = { StructDefinition = {} }




































local INITIAL_CAPACITY = 64

























local CAny = C
local RUNTIME_REGISTRY_KEY = "__tecsFFIStorageRegistry"
local runtimeRegistry = CAny[RUNTIME_REGISTRY_KEY]
if not runtimeRegistry then
   runtimeRegistry = {
      structCounter = 0,
      structRegistry = {},
      arrayTypeCache = {},
   }
   CAny[RUNTIME_REGISTRY_KEY] = runtimeRegistry
end
local structRegistry = runtimeRegistry.structRegistry
local arrayTypeCache = runtimeRegistry.arrayTypeCache










local storageMetadata = setmetatable({}, { __mode = "k" })


local function generateStructDef(name, fieldTuples)
   local parts = { "typedef struct { " }
   local fieldNames = {}
   local nFields = #fieldTuples

   for i = 1, nFields do
      local tuple = fieldTuples[i]
      local fieldName = tuple[1]
      local fieldType = tuple[2]

      local baseType, arraySize = fieldType:match("^([^%[]+)%[(%d+)%]$")

      if baseType and arraySize then
         parts[#parts + 1] = baseType .. " " .. fieldName .. "[" .. arraySize .. "]; "
      else
         parts[#parts + 1] = fieldType .. " " .. fieldName .. "; "
      end

      fieldNames[i] = fieldName
   end

   parts[#parts + 1] = "} " .. name .. ";"
   return table.concat(parts), fieldNames
end

local function buildFieldInfo(fieldTuples)
   local infos = {}
   for i = 1, #fieldTuples do
      local tuple = fieldTuples[i]
      local baseType, arraySize = tuple[2]:match("^([^%[]+)%[(%d+)%]$")
      infos[i] = {
         name = tuple[1],
         isArray = baseType ~= nil,
         arraySize = arraySize and (tonumber(arraySize)) or 0,
      }
   end
   return infos
end

local function copyArrayField(dst, fieldInfo, value)
   local field = (dst)[fieldInfo.name]
   local src = value



   local base = src[0] == nil and 1 or 0
   for i = 0, fieldInfo.arraySize - 1 do
      local item = src[i + base]
      if item == nil then
         break
      end
      field[i] = item
   end
end

local function serializeArrayField(src, fieldInfo)
   local out = {}
   local field = (src)[fieldInfo.name]
   for i = 0, fieldInfo.arraySize - 1 do
      out[i + 1] = field[i]
   end
   return out
end

function FFIStorage.defineStruct(name, fields)
   local cdef = generateStructDef(name, fields)
   local entry = structRegistry[name]
   if entry then
      if entry.cdef ~= cdef then
         error("FFI struct name collision: '" .. name .. "' already defined with a different layout")
      end
   else
      C.cdef(cdef)
      entry = {
         cdef = cdef,
         metadataFields = {},
         instanceIds = nil,
         metatypeInstalled = false,
      }
      structRegistry[name] = entry
   end
   local structType = C.typeof(name)
   local size = C.sizeof(structType)
   return structType, size
end

function FFIStorage.new(def)

   assert(def.fields, "FFI storage requires 'fields' array")
   assert(#def.fields > 0, "FFI storage requires at least one field")
   assert(type(def.fields[1]) == "table", "FFI storage fields must be in tuple format: {{name, type}, ...}")

   schema.validateFields(def.fields)





   local columnAllocator = nil

   local structName = def.name
   if not structName then
      runtimeRegistry.structCounter = runtimeRegistry.structCounter + 1
      structName = "FFIComponent" .. runtimeRegistry.structCounter
   end

   local cdef, fieldNames = generateStructDef(structName, def.fields)
   local nFields = #fieldNames
   local fieldInfo = buildFieldInfo(def.fields)



   local schemaParts = {}
   for i = 1, #def.fields do
      local f = def.fields[i]
      schemaParts[i] = f[1] .. ":" .. f[2]
   end

   local registryEntry = structRegistry[structName]
   if registryEntry then
      if registryEntry.cdef ~= cdef then
         error("FFI struct name collision: '" .. structName .. "' already defined with a different layout")
      end
   else
      C.cdef(cdef)
      registryEntry = {
         cdef = cdef,
         metadataFields = {},
         instanceIds = nil,
         metatypeInstalled = false,
      }
      structRegistry[structName] = registryEntry
   end

   local metadataFields = registryEntry.metadataFields



   if def.perEntityComponent and not registryEntry.instanceIds then
      registryEntry.instanceIds = setmetatable({}, { __mode = "k" })
   end
   local instanceIds = registryEntry.instanceIds

   if not registryEntry.metatypeInstalled then
      local indexFn
      local tostringFn
      if def.perEntityComponent then


         local targetField = fieldNames[1]
         indexFn = function(self, key)
            if key == "componentType" then
               return self
            elseif key == "componentId" then
               return instanceIds[self]
            end
            return (metadataFields)[key]
         end

         tostringFn = function(self)
            local target = (self)[targetField]
            return structName .. "(" .. target .. ")"
         end
      else
         indexFn = function(_self, key)
            return (metadataFields)[key]
         end

         tostringFn = function(_self)
            return structName
         end
      end

      local mt = {
         __tostring = tostringFn,
         __index = indexFn,
      }


      if def.metatable then
         for k, v in pairs(def.metatable) do
            if k == "__index" then

               if type(v) == "table" then
                  for method, impl in pairs(v) do
                     (metadataFields)[method] = impl
                  end
               end
            else

               mt[k] = v
            end
         end
      end

      C.metatype(structName, mt)
      registryEntry.metatypeInstalled = true
   end

   local structSize = C.sizeof(structName)
   local fingerprint = table.concat(schemaParts, ",") .. "|" .. structSize

   local arrayTypeName = structName .. "[?]"
   local arrayType = arrayTypeCache[arrayTypeName]
   if not arrayType then
      arrayType = C.typeof(arrayTypeName)
      arrayTypeCache[arrayTypeName] = arrayType
   end

   local structType = C.typeof(structName)

   local function createInstance(...)
      local instance = C.new(structType)

      local nargs = select('#', ...)

      if nargs == 0 then

      elseif nargs == 1 and type(select(1, ...)) == "table" then

         local value = select(1, ...)
         for i = 1, nFields do
            local info = fieldInfo[i]
            local k = info.name
            local v = value[k]
            if v ~= nil then
               if info.isArray then
                  copyArrayField(instance, info, v)
               else
                  (instance)[k] = v
               end
            end
         end
      else




         local inst = instance
         if nFields == 1 then
            local a = ...
            if nargs >= 1 and a ~= nil then
               local info = fieldInfo[1]
               if info.isArray then copyArrayField(inst, info, a) else inst[info.name] = a end
            end
         elseif nFields == 2 then
            local a, b = ...
            if nargs >= 1 and a ~= nil then
               local info = fieldInfo[1]
               if info.isArray then copyArrayField(inst, info, a) else inst[info.name] = a end
            end
            if nargs >= 2 and b ~= nil then
               local info = fieldInfo[2]
               if info.isArray then copyArrayField(inst, info, b) else inst[info.name] = b end
            end
         elseif nFields == 3 then
            local a, b, c = ...
            if nargs >= 1 and a ~= nil then
               local info = fieldInfo[1]
               if info.isArray then copyArrayField(inst, info, a) else inst[info.name] = a end
            end
            if nargs >= 2 and b ~= nil then
               local info = fieldInfo[2]
               if info.isArray then copyArrayField(inst, info, b) else inst[info.name] = b end
            end
            if nargs >= 3 and c ~= nil then
               local info = fieldInfo[3]
               if info.isArray then copyArrayField(inst, info, c) else inst[info.name] = c end
            end
         elseif nFields == 4 then
            local a, b, c, d = ...
            if nargs >= 1 and a ~= nil then
               local info = fieldInfo[1]
               if info.isArray then copyArrayField(inst, info, a) else inst[info.name] = a end
            end
            if nargs >= 2 and b ~= nil then
               local info = fieldInfo[2]
               if info.isArray then copyArrayField(inst, info, b) else inst[info.name] = b end
            end
            if nargs >= 3 and c ~= nil then
               local info = fieldInfo[3]
               if info.isArray then copyArrayField(inst, info, c) else inst[info.name] = c end
            end
            if nargs >= 4 and d ~= nil then
               local info = fieldInfo[4]
               if info.isArray then copyArrayField(inst, info, d) else inst[info.name] = d end
            end
         else


            local args = { ... }
            local count = min(nargs, nFields)
            for i = 1, count do
               local value = args[i]
               if value ~= nil then
                  local info = fieldInfo[i]
                  if info.isArray then
                     copyArrayField(inst, info, value)
                  else
                     inst[info.name] = value
                  end
               end
            end
         end
      end

      if instanceIds then
         local componentId = componentids.allocate()
         instanceIds[instance] = componentId
      end

      return instance
   end


   local function growArray(oldArray, usedCount, neededCapacity)
      local newCapacity = neededCapacity
      local newArray
      if columnAllocator then
         local ptr, holder = columnAllocator((newCapacity + 1) * structSize, structName)
         byteDataByColumn[ptr] = holder
         newArray = ptr
      else
         newArray = C.new(arrayType, newCapacity + 1)
      end

      if oldArray and usedCount > 0 then
         local copyCount = min(usedCount, newCapacity)
         C.copy(newArray, oldArray, (copyCount + 1) * structSize)
      end

      storageMetadata[newArray] = {
         capacity = newCapacity,
         structSize = structSize,
         arrayType = arrayType,
         structType = structType,
      }

      if oldArray then
         storageMetadata[oldArray] = nil
      end

      return newArray
   end

   return {
      storageType = "ffi",

      createColumn = function(_self, size)
         local capacity = max(INITIAL_CAPACITY, size * 2)
         local data
         if columnAllocator then
            local ptr, holder = columnAllocator((capacity + 1) * structSize, structName)
            byteDataByColumn[ptr] = holder
            data = ptr
         else
            data = C.new(arrayType, capacity + 1)
         end

         storageMetadata[data] = {
            capacity = capacity,
            structSize = structSize,
            arrayType = arrayType,
            structType = structType,
         }

         return data
      end,

      clear = function(_self, column)

         local meta = storageMetadata[column]
         if meta then
            C.fill(column, (meta.capacity + 1) * meta.structSize, 0)
         end
      end,






      ensureCapacity = function(
         _self,
         column,
         needed)

         local meta = storageMetadata[column]
         if meta and needed > meta.capacity then
            local usedCount = min(needed - 1, meta.capacity)
            return growArray(column, usedCount, needed)
         end
         return column
      end,





      adjustCapacity = function(
         _self,
         column,
         usedCount)

         local meta = storageMetadata[column]
         if meta and meta.capacity >= 2048 and usedCount <= meta.capacity / 8 then
            local newCapacity = max(512, usedCount * 2)
            return growArray(column, usedCount, newCapacity)
         end
         return column
      end,






      setColumnAllocator = function(_self, fn)
         columnAllocator = fn
      end,

      createComponent = function(
         _self,
         container)


         if container then



            local bound = metadataFields.componentType
            if bound ~= nil and bound ~= container then





               local nextName = def.bindingName or container.componentName
               if bound.componentName ~= nextName then
                  error("FFI struct '" .. structName .. "' is already bound to component '" ..
                  tostring(bound.componentName) .. "'; use a distinct struct name", 0)
               end
            end
            metadataFields.componentType = container
            metadataFields.componentName = structName
            metadataFields.componentId = (container).componentId
            metadataFields.storage = (container).storage
            metadataFields.storageType = (container).storageType




            metadataFields.structSize = structSize
            metadataFields.fingerprint = fingerprint
         end


         return createInstance
      end,

      _sizeof = structSize,

      fieldNames = fieldNames,

      _ffiConstructor = true,


      _fingerprint = fingerprint,
      _structSize = structSize,


      setMetadata = function(_self, key, value)
         metadataFields[key] = value
      end,


      serialize = function(_self, instance)
         local data = {}
         for i = 1, nFields do
            local info = fieldInfo[i]
            if info.isArray then
               data[info.name] = serializeArrayField(instance, info)
            else
               data[info.name] = (instance)[info.name]
            end
         end
         return data
      end,


      deserialize = function(_self, data)
         return createInstance(data)
      end,





      serializeRaw = function(_self, instance, buf)
         BUF_PUTCDATA(buf, instance, structSize)
      end,





      deserializeRaw = function(_self, buf)
         local instance = C.new(structType)
         local ptr = BUF_REF(buf)
         C.copy(instance, ptr, structSize)
         BUF_SKIP(buf, structSize)
         if instanceIds then
            local componentId = componentids.allocate()
            instanceIds[instance] = componentId
         end
         return instance
      end,
   }
end

function FFIStorage.getColumnByteData(column)
   return byteDataByColumn[column]
end

return FFIStorage
