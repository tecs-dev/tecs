local types = require("tecs.types")

local table_clear = require("table.clear")
local table_new = require("table.new")




local storage = {}















































local function initializeComponentFromArgs(component, ...)
   local nargs = select('#', ...)
   if nargs == 1 and type((...)) == "table" then

      local value = (...)
      for k, v in pairs(value) do
         (component)[k] = v
      end
   end
   return component
end



local function createTableComponentConstructor()
   return function(...)
      return initializeComponentFromArgs({}, ...)
   end
end


local TABLE_STORAGE = {
   storageType = "table",
   createColumn = function(_self, size)
      return table_new(size, 0)
   end,
   clear = function(_self, column)
      table_clear(column)
   end,
   ensureCapacity = function(_self, column, _needed)

      return column
   end,
   createComponent = createTableComponentConstructor,

}

function storage.newTableStorage()
   return TABLE_STORAGE
end

function storage.newScalarStorage(kind, defaultValue)
   if kind ~= "number" and kind ~= "boolean" and kind ~= "string" then
      error("newScalarStorage: kind must be one of 'number', 'boolean', or 'string'")
   end
   if type(defaultValue) ~= kind then
      error("newScalarStorage: defaultValue type must match kind '" .. kind .. "'")
   end
   return {
      storageType = "scalar",
      createColumn = function(_self, size)
         return table_new(size, 0)
      end,
      clear = function(_self, column)
         table_clear(column)
      end,
      ensureCapacity = function(_self, column, _needed)
         return column
      end,
      createComponent = function(_self, _container)
         return function(value)
            if value == nil then
               return defaultValue
            end
            if type(value) ~= kind then
               error("scalar component value type must match kind '" .. kind .. "'")
            end
            return value
         end
      end,
      _scalarKind = kind,
      _scalarDefault = defaultValue,
   }
end





local function tagIndex(t, _index)
   return (t).__container
end
local function tagNewIndex() end
local TAG_MT = {
   __index = tagIndex,
   __newindex = tagNewIndex,
}

function storage.newBitsetStorage(container)
   return {
      storageType = "tag",

      createColumn = function(_self, _size)
         local data = { __container = container }
         return setmetatable(data, TAG_MT)
      end,

      clear = function(_self, _column) end,

      ensureCapacity = function(_self, column, _needed)
         return column
      end,

      createComponent = function(_self, _container)
         return function()
            return container
         end
      end,
   }
end

function storage.newFFIStorage(def)
   local ffi = require("tecs.internal.ffi")
   return (ffi.newFFIStorage)(def)
end

function storage.syncMetadataToFFI(s, container)
   local storageAny = s
   if not storageAny.setMetadata then
      return
   end
   local setMetadata = storageAny.setMetadata
   setMetadata(s, "relationshipType", container)


   setMetadata(s, "wildcardContainer", container)


   if (container).isSparse then
      setMetadata(s, "isSparseInstance", true)
   end
   local containerAny = container
   if containerAny.exclusiveRelationship ~= nil then
      setMetadata(s, "exclusiveRelationship", containerAny.exclusiveRelationship)
   end


   setMetadata(s, "storage", s)
   setMetadata(s, "storageType", s.storageType)
   setMetadata(s, "transient", containerAny.transient == true)



   for _, key in ipairs({
         "frameworkBehavior", "frameworkBehaviorBits",
      }) do
      if containerAny[key] ~= nil then
         setMetadata(s, key, containerAny[key])
      end
   end
end

return storage
