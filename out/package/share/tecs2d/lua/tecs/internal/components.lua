local types = require("tecs.types")
local internal = require("tecs.internal.types")
local storage = require("tecs.internal.storage")
local componentcodegen = require("tecs.internal.componentcodegen")
local componentids = require("tecs.internal.componentids")
local behavior = require("tecs.internal.behavior")
local bit = require("bit")

local assert, table_concat = assert, table.concat
local rshift = bit.rshift















local components = {}





















components.registeredComponents = {}
components.componentsById = setmetatable({}, {
   __newindex = function()
      error("componentsById is read-only")
   end,
})





function components.registerComponent(container)
   assert(container.componentName, "Missing component name when registering component")
   assert(container.componentType, "Missing component type when registering component")

   if components.registeredComponents[container.componentName] then
      error("Component " .. container.componentName .. " already registered")
   end




   if not rawget(container, "componentId") then
      container.componentId = componentids.allocate()
   end

   local componentI = container
   local signatureIndex = container.componentId - 1
   componentI.signatureIndex = signatureIndex
   componentI.signatureWordIndex = rshift(signatureIndex, 5)

   components.registeredComponents[container.componentName] = container
   rawset(components.componentsById, container.componentId, container)
   return container
end










local INTERNAL_STORAGE_TOKEN = {}
local NOOP_INIT = function(_instance) end




local INSTANCE_METADATA_KEYS = {
   storage = true,
   storageType = true,
   relationshipType = true,
   exclusiveRelationship = true,
   wildcardContainer = true,
   isContainer = true,
   isSparseInstance = true,
   transient = true,
}

local function applyPositionalDefaults(instance, fields, defaults)
   if not defaults then
      return
   end
   for i = 1, #fields do
      local value = defaults[i]
      if value ~= nil then
         instance[fields[i]] = value
      end
   end
end

function components.newComponent(options)
   local opts = assert(options, "Missing component options")
   local name = assert(opts.name, "Missing component name")
   local container = assert(opts.container, "Missing component container")
   local optsAny = opts
   local userStorage = optsAny.storage
   if userStorage ~= nil and optsAny.__internalStorageToken ~= INTERNAL_STORAGE_TOKEN then
      error("Component " .. name .. ": `storage` is not a user option. " ..
      "Use one of newComponent / newTagComponent / newFFIComponent " ..
      "/ newScalarComponent (or the relationship variants) to pick " ..
      "a component layout.")
   end
   local componentStorage = userStorage or
   storage.newTableStorage()

   if opts.defaults and not opts.fields then
      error("Component " .. name .. ": `defaults` requires `fields`")
   end
   if opts.transient and opts.serialize then
      error("Component " .. name .. ": `transient` cannot be combined with `serialize`")
   end





   if opts.init and not opts.fields and not opts.new then
      error("Component " .. name .. ": `init` requires either `fields` (auto-codegens `.new`) or an explicit `new`")
   end

   local storageConstructor = componentStorage:createComponent(container)

   if components.registeredComponents[name] then
      error("Component " .. name .. " already registered")
   end

   local containerI = container
   container.componentType = container
   container.componentName = name
   container.componentId = componentids.allocate()
   container.init = opts.init or NOOP_INIT
   containerI.requires = opts.requires
   containerI._hasRequires = opts.requires ~= nil and #opts.requires > 0
   containerI.transient = opts.transient == true




   containerI.storage = componentStorage
   containerI.storageType = componentStorage.storageType

   local anyStorage = componentStorage


   if opts.transient then
      container.serialize = nil
   elseif opts.serialize then
      container.serialize = opts.serialize
   elseif componentStorage.storageType == "scalar" then





      container.serialize = function(instance)
         if type(instance) == "table" and (instance).componentType == container then
            return { value = (instance).value }
         end
         return { value = instance }
      end
   elseif anyStorage.serialize then
      container.serialize = function(instance)
         return (anyStorage.serialize)(componentStorage, instance)
      end
   else

      container.serialize = function(instance)
         local data = {}
         for k, v in pairs(instance) do
            if type(k) == "string" and not k:match("^component") and k ~= "storage" then
               local vtype = type(v)
               if vtype == "number" or vtype == "string" or vtype == "boolean" or vtype == "table" then
                  data[k] = v
               end
            end
         end
         return data
      end
   end

   if opts.deserialize then
      container.deserialize = opts.deserialize
   elseif componentStorage.storageType == "scalar" then


      container.deserialize = function(_world, data)
         local v
         if data ~= nil then v = data.value end
         return (container)(v)
      end
   elseif anyStorage.deserialize then
      container.deserialize = function(_world, data)
         return (anyStorage.deserialize)(componentStorage, data)
      end
   end



   local tostringFn = function(_self) return name end



   local callFn
   local storageType = componentStorage.storageType or "table"
   local tableInstanceMt = nil
   local customCall = optsAny["__call"]
   if storageType == "tag" then

      callFn = function(_c) return container end
   elseif storageType == "scalar" then








      local scalarDefault = (anyStorage._scalarDefault)
      local kind = (anyStorage._scalarKind)
      if kind == "string" then
         local cache = setmetatable({}, { __mode = "v" })
         callFn = function(_c, value)
            if value == nil then value = scalarDefault end
            local hit = cache[value]
            if hit then return hit end
            local w = { componentType = container, value = value }
            cache[value] = w
            return w
         end
      else
         callFn = function(_c, value)
            if value == nil then value = scalarDefault end
            return { componentType = container, value = value }
         end
      end
   elseif storageType == "ffi" then

      local ffiFields = {}
      local rawFfiFields = opts.fields
      if rawFfiFields then
         for i = 1, #rawFfiFields do
            ffiFields[i] = rawFfiFields[i][1]
         end
      end
      local ffiDefaults = optsAny.defaults
      local ffiAllocator = storageConstructor
      if customCall then
         callFn = function(_c, ...)
            local instance = ffiAllocator()
            applyPositionalDefaults(instance, ffiFields, ffiDefaults)
            customCall(instance, ...)
            return instance
         end
      else
         local ffiAlloc = componentcodegen.createCallFn({
            backend = "allocatorCall",
            fields = ffiFields,
            defaults = ffiDefaults,
            leadingArgCount = 0,
            includeSelfParam = true,
            allocator = ffiAllocator,
            instanceMt = nil,
         })
         if opts.init then
            local userInit = opts.init
            callFn = function(_c, ...)
               local instance = ffiAlloc(container, ...)
               userInit(instance, ...)
               return instance
            end
         else
            callFn = ffiAlloc
         end
      end
   else



      tableInstanceMt = { __index = container, __tostring = tostringFn }


      if customCall then
         local tableFields = opts.fields
         local tableDefaults = opts.defaults
         callFn = function(_c, ...)
            local instance = setmetatable({}, tableInstanceMt)
            applyPositionalDefaults(instance, tableFields, tableDefaults)
            customCall(instance, ...)
            return instance
         end
      else
         local baseCall
         if opts.fields then
            local tableFields = opts.fields
            local generated = componentcodegen.createCallFn({
               backend = "tableLiteral",
               fields = tableFields,
               defaults = opts.defaults,
               leadingArgCount = 0,
               includeSelfParam = true,
               instanceMt = tableInstanceMt,
               allocator = nil,
            })
            baseCall = generated
         else
            baseCall = function(_c, ...)
               return setmetatable(storageConstructor(...), tableInstanceMt)
            end
         end

         local userInit = opts.init
         if opts.init then
            callFn = function(_c, ...)
               local instance = baseCall(container, ...)
               userInit(instance, ...)
               return instance
            end
         else
            callFn = baseCall
         end
      end
   end

   setmetatable(container, { __tostring = tostringFn, __call = callFn })




   if opts.new then
      local userNew = opts.new
      if tableInstanceMt then
         container.new = function(data)
            return setmetatable(userNew(data), tableInstanceMt)
         end
      else
         container.new = userNew
      end
   elseif opts.fields then
      container.new = componentcodegen.createNewFn(container, opts.fields)
   elseif storageType == "scalar" then


      container.new = function(data)
         local v
         if data ~= nil then v = data.value end
         return (container)(v)
      end
   else
      container.new = function(data)
         return (container)(data)
      end
   end




   if not opts.deserialize and not anyStorage.deserialize then
      container.deserialize = function(_world, data)
         return container.new(data)
      end
   end

   return components.registerComponent(container)
end





local DEFAULT_RELATIONSHIP_CTOR = function(_id, _)
   return {}
end

function components.newRelationship(config)
   local cfg = assert(config, "Missing relationship config")
   local name = assert(cfg.name, "Missing relationship name")
   local isExclusive = cfg.exclusive or false
   local isSparse = cfg.sparse or false
   local hasReverseIndex = cfg.reverseIndex or false
   local isCascadeDelete = cfg.cascadeDelete or false

   if isCascadeDelete and not hasReverseIndex then
      error("cascadeDelete requires reverseIndex = true (needs inverse index to find children)")
   elseif isCascadeDelete and not isExclusive then
      error("cascadeDelete requires exclusive = true")
   elseif not cfg.container and cfg.init then
      error("Cannot provide init for relationship without a container")
   end

   if cfg.defaults and not cfg.fields then
      error("Relationship " .. name .. ": `defaults` requires `fields`")
   end
   if cfg.transient and cfg.serialize then
      error("Relationship " .. name .. ": `transient` cannot be combined with `serialize`")
   end



   local cfgAny = cfg
   if cfgAny.storage ~= nil and cfgAny.__internalStorageToken ~= INTERNAL_STORAGE_TOKEN then
      error("Relationship " .. name .. ": `storage` is not a user option. " ..
      "Use newRelationship / newFFIRelationship " ..
      "to pick a relationship layout.")
   end



   if cfg.init and not cfg.fields and not cfg.new then
      error("Relationship " .. name .. ": `init` requires either `fields` (auto-codegens `.new`) or an explicit `new`")
   end





   if not cfg.container and not cfg.fields and cfgAny.new == nil and cfgAny.storage == nil then
      return components.newFFIRelationship({
         name = name,
         container = {},
         fields = {},
         exclusive = cfg.exclusive,
         sparse = cfg.sparse,
         reverseIndex = cfg.reverseIndex,
         cascadeDelete = cfg.cascadeDelete,
         transient = cfg.transient,
         serialize = (cfgAny.serialize),
         deserialize = (cfgAny.deserialize),
         __call = (cfgAny.__call),
      })
   end


   local relationshipStorage = (cfg).storage or
   storage.newTableStorage()


   local cache = setmetatable({}, { __mode = "v" })

   local relContainer = cfg.container or {}
   local relContainerI = relContainer
   relContainer.componentName = name
   relContainer.componentType = relContainer
   relContainer.exclusiveRelationship = isExclusive
   relContainer.relationshipType = relContainer
   relContainer.init = cfg.init or NOOP_INIT
   relContainerI.isContainer = true
   relContainerI.isSparse = isSparse
   relContainerI.reverseIndex = hasReverseIndex
   relContainerI.cascadeDelete = isCascadeDelete
   relContainerI.transient = cfg.transient == true



   local bitset = storage.newBitsetStorage(relContainer)
   relContainerI.storage = bitset
   relContainerI.storageType = bitset.storageType

   local ctor
   local customCall = cfgAny["__call"]
   if relationshipStorage.storageType == "ffi" then
      local relationshipFields = (cfg.fields or {})
      local relationshipAllocator = relationshipStorage:createComponent(relContainer)

      if customCall then
         local relationshipDefaults = cfg.defaults
         ctor = function(id, ...)
            local instance = relationshipAllocator(id)
            applyPositionalDefaults(instance, relationshipFields, relationshipDefaults)
            customCall(instance, id, ...)
            return instance
         end
      else
         ctor = componentcodegen.createCallFn({
            backend = "allocatorCall",
            fields = relationshipFields,
            defaults = cfg.defaults,
            leadingArgCount = 1,
            includeSelfParam = false,
            allocator = relationshipAllocator,
            instanceMt = nil,
         })
      end
   elseif cfg.fields then


      local relationshipFields = cfg.fields
      if customCall then
         local relationshipDefaults = cfg.defaults
         ctor = function(id, ...)
            local instance = {}
            applyPositionalDefaults(instance, relationshipFields, relationshipDefaults)
            customCall(instance, id, ...)
            return instance
         end
      else
         ctor = componentcodegen.createCallFn({
            backend = "tableLiteral",
            fields = relationshipFields,
            defaults = cfg.defaults,
            leadingArgCount = 1,
            includeSelfParam = false,
            instanceMt = nil,
            allocator = nil,
         })
      end
   else
      if customCall then
         ctor = function(id, ...)
            local instance = {}
            customCall(instance, id, ...)
            return instance
         end
      else
         ctor = DEFAULT_RELATIONSHIP_CTOR
      end
   end








   local storageAny = relationshipStorage
   if cfg.transient then
      relContainer.serialize = nil
   elseif cfg.serialize then
      relContainer.serialize = cfg.serialize
   elseif storageAny.serialize then
      relContainer.serialize = function(instance)
         return (storageAny.serialize)(
         relationshipStorage, instance)
      end
   elseif cfg.fields then




      local declaredFields = cfg.fields
      relContainer.serialize = function(instance)
         local inst = instance
         local data = { target = inst.target }
         for i = 1, #declaredFields do
            local f = declaredFields[i]
            data[f] = inst[f]
         end
         return data
      end
   else



      relContainer.serialize = function(instance)
         local data = {}
         for k, v in pairs(instance) do
            if type(k) == "string" and
               not (k):match("^component") and
               not INSTANCE_METADATA_KEYS[k] then
               local vtype = type(v)
               if vtype == "number" or vtype == "string" or vtype == "boolean" or vtype == "table" then
                  data[k] = v
               end
            end
         end
         return data
      end
   end






   if cfg.new then
      local userNew = cfg.new
      relContainer.new = function(data)
         return userNew(data)
      end
   elseif cfg.fields then
      relContainer.new = componentcodegen.createNewFn(
      relContainer,
      cfg.fields,
      { "target" },
      { target = "Relationship .new: missing 'target' field" })

   else
      relContainer.new = function(data)
         local target = data.target
         assert(target, "Relationship .new: missing 'target' field")
         return (relContainer)(target, data)
      end
   end

   if (cfg).deserialize then
      relContainer.deserialize = (cfg).deserialize
   else
      relContainer.deserialize = function(_world, data)
         return relContainer.new(data)
      end
   end






   if relationshipStorage.storageType == "ffi" then
      local setMeta = storageAny.setMetadata
      setMeta(relationshipStorage, "serialize", relContainer.serialize)
      setMeta(relationshipStorage, "deserialize", relContainer.deserialize)
   end

   local instance_mt = {
      __index = relContainer,
      __tostring = function(self)
         return table_concat({ self.componentName, " -> ", self.target })
      end,
   }

   setmetatable(relContainer, {
      __tostring = function(self)
         return self.componentName
      end,
      __call = function(self, id, ...)
         assert(id, "Missing entity ID")
         local instance = cache[id]
         if not instance then
            instance = assert(ctor(id, ...), "Relationship allocation returned nil")
            if cfg.init and not customCall then
               cfg.init(instance, id, ...)
            end
            local mt = getmetatable(instance)
            if type(mt) == "string" then


               cache[id] = instance
            elseif isSparse then


               local instanceI = instance
               instance.target = id
               instance.componentName = self.componentName .. "->" .. id
               instance.componentType = self
               instance.exclusiveRelationship = self.exclusiveRelationship
               instance.relationshipType = self
               instanceI.wildcardContainer = self
               instanceI.isContainer = false
               instanceI.isSparseInstance = true
               instanceI.storage = relationshipStorage
               instanceI.storageType = relationshipStorage.storageType
               instanceI.transient = relContainerI.transient
               setmetatable(instance, instance_mt)
               cache[id] = instance
            else
               local instanceI = instance
               instance.target = id
               instance.componentName = self.componentName .. "->" .. id
               instance.componentType = instance
               instance.exclusiveRelationship = self.exclusiveRelationship
               instance.relationshipType = self
               instanceI.wildcardContainer = self
               instanceI.isContainer = false
               instanceI.storage = relationshipStorage
               instanceI.storageType = relationshipStorage.storageType
               instanceI.transient = relContainerI.transient
               setmetatable(instance, instance_mt)
               components.registerComponent(instance)
               cache[id] = instance
            end
         end
         return instance
      end,
   })


   if not isSparse then
      relContainer.targeting = function(self, targetId)
         assert(targetId, "Missing target entity ID")
         if cfg.container then

            return self(targetId).componentType
         else

            return self(targetId)
         end
      end
   end

   if isSparse then
      relContainerI.frameworkBehavior = behavior.SparseRelationship
      relContainerI.frameworkBehaviorBits = behavior.sparseRelationshipBits()
   else



      relContainerI.frameworkBehavior = behavior.DenseRelationship
      if hasReverseIndex then
         relContainerI.frameworkBehaviorBits = behavior.denseReverseIndexRelationshipBits()
      elseif isExclusive then
         relContainerI.frameworkBehaviorBits = behavior.denseExclusiveRelationshipBits()
      else
         relContainerI.frameworkBehaviorBits = behavior.densePlainRelationshipBits()
      end
   end

   components.registerComponent(relContainer)
   storage.syncMetadataToFFI(relationshipStorage, relContainer)
   return relContainer
end

function components.newFFIRelationship(config)
   local cfg = assert(config, "Missing FFI relationship config")
   local name = assert(cfg.name, "Missing FFI relationship name")
   local container = assert(cfg.container, "Missing FFI relationship container")
   local fields = assert(cfg.fields, "Missing FFI relationship fields")




   local allFields = { { "target", "double" } }
   for i = 1, #fields do
      table.insert(allFields, fields[i])
   end

   local isSparse = cfg.sparse or false

   local ffiStorage = storage.newFFIStorage({
      name = name .. "_FFIRelationship",
      bindingName = name,
      fields = allFields,
      metatable = cfg.metatable,
      perEntityComponent = not isSparse,
   })





   local fieldNames = {}
   for i = 1, #fields do
      fieldNames[i] = fields[i][1]
   end



   return (components.newRelationship)({
      name = name,
      container = container,
      fields = fieldNames,
      defaults = cfg.defaults,
      init = cfg.init,
      __call = (cfg)["__call"],
      new = cfg.new,
      exclusive = cfg.exclusive,
      sparse = cfg.sparse,
      reverseIndex = cfg.reverseIndex,
      cascadeDelete = cfg.cascadeDelete,
      transient = cfg.transient,
      serialize = (cfg).serialize,
      deserialize = (cfg).deserialize,
      storage = ffiStorage,
      __internalStorageToken = INTERNAL_STORAGE_TOKEN,
   })
end





function components.newTagComponent(options)
   if options.transient and (options).serialize then
      error("Tag component " .. tostring(options.name) .. ": `transient` cannot be combined with `serialize`")
   end
   local container = options.container or {}
   return (components.newComponent)({
      name = assert(options.name, "Missing tag component name"),
      container = container,
      storage = storage.newBitsetStorage(container),
      __internalStorageToken = INTERNAL_STORAGE_TOKEN,
      requires = options.requires,
      transient = options.transient,
   })
end

function components.newScalarComponent(
   options)

   local opts = assert(options, "Missing scalar component options")
   if opts.transient and (opts).serialize then
      error("Scalar component " .. tostring(opts.name) .. ": `transient` cannot be combined with `serialize`")
   end


   local container = {}
   local kind = assert(opts.kind, "Missing scalar component kind")
   local defaultValue = opts.default


   if kind ~= "number" and kind ~= "boolean" and kind ~= "string" then
      error("Scalar component " .. tostring(opts.name) ..
      ": `kind` must be one of 'number', 'boolean', or 'string'")
   end


   if defaultValue == nil then
      if kind == "number" then
         defaultValue = 0
      elseif kind == "boolean" then
         defaultValue = false
      else
         defaultValue = ""
      end
   end



   local component = ((components.newComponent)({
      name = assert(opts.name, "Missing scalar component name"),
      container = container,
      storage = storage.newScalarStorage(kind, defaultValue),
      __internalStorageToken = INTERNAL_STORAGE_TOKEN,
      requires = opts.requires,
      transient = opts.transient,
   }))

   local cAny = component
   cAny.scalarKind = kind
   cAny.scalarDefault = defaultValue
   return component
end





function components.newFFIComponent(options)
   local opts = assert(options, "Missing FFI component options")
   assert(opts.name, "Missing component name")
   assert(opts.container, "Missing component container")
   assert(opts.fields, "Missing FFI fields definition")

   local componentStorage = storage.newFFIStorage({
      name = opts.name,
      bindingName = opts.name,
      fields = opts.fields,
      metatable = opts.metatable,
   })



   local newFn = opts.new
   if not newFn then
      local fieldNames = opts.fields
      local container = opts.container
      local names = {}
      for i = 1, #fieldNames do
         names[i] = fieldNames[i][1]
      end
      newFn = componentcodegen.createNewFn(container, names)
   end



   local component = (components.newComponent)({
      name = opts.name,
      container = opts.container,
      fields = opts.fields,
      defaults = opts.defaults,
      __call = (opts)["__call"],
      init = opts.init,
      storage = componentStorage,
      __internalStorageToken = INTERNAL_STORAGE_TOKEN,
      serialize = opts.serialize,
      deserialize = opts.deserialize,
      new = newFn,
      requires = opts.requires,
      transient = opts.transient,
   })











   local anyStorage = componentStorage
   local componentI = component
   if anyStorage.serializeRaw and anyStorage.deserializeRaw and
      not opts.serialize and not opts.deserialize and not opts.transient then

      componentI.serializeRaw = function(inst, buf)
         (anyStorage.serializeRaw)(componentStorage, inst, buf)
      end
      componentI.deserializeRaw = function(buf)
         return (anyStorage.deserializeRaw)(componentStorage, buf)
      end
   end





   if anyStorage._fingerprint then
      (component).fingerprint = anyStorage._fingerprint;
      (component).structSize = anyStorage._structSize
   end

   return component
end

return components
