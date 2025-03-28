local types <const> = require("tecs.types")
local storage <const> = require("tecs.internal.storage")
local compat <const> = require("tecs.internal.utils.compat")
local schema <const> = require("tecs.internal.ffi.schema")

local bxor, tobit, rshift <const> = compat.bxor, compat.tobit, compat.rshift
local assert, table_concat <const> = assert, table.concat

local type Relationship = types.Relationship
local type Component = types.Component
local type Storage = types.Storage
local type ComponentConstructor = types.ComponentConstructor
local type OnAdd = types.OnAdd
local type OnRemove = types.OnRemove

--- The components module defines ECS components and methods for creating them.
local record components

    --- Shared options for creating different components.
    interface BasicComponentOptions<C is Component>
        --- The name of the component (required).
        name: string

        --- Hook called when this component is added (optional).
        onAdd: OnAdd<C>

        --- Hook called when this component is removed (optional).
        onRemove: OnRemove<C>
    end

    --- Shared options for creating different components.
    interface ContainerComponentOptions<C is Component> is BasicComponentOptions<C>
        --- The component container/type to use (required).
        container: C
    end

    --- Options for creating a new component.
    interface ComponentOptions<C is Component> is ContainerComponentOptions<C>
        --- Storage implementation for component data (optional).
        storage: Storage

        --- Constructor function for creating instances (optional).
        constructor: ComponentConstructor<C>
    end

    interface TagComponentOptions is BasicComponentOptions<Component> end

    --- Options for creating an FFI-based component with high performance storage.
    interface FFIComponentOptions<C is Component> is ContainerComponentOptions<C>
        --- Field definitions for the FFI struct.
        fields: {{string, string}}

        --- Enable struct recycling to reuse components (optional).
        recycle: boolean

        --- Size of the recycle pool (defaults to 64 if not specified).
        recyclePoolSize: integer

        --- Has an opportunity to validate and initialize constructor arguments before calling the actual constructor.
        --- @param constructor Constructor to call with initialized arguments.
        --- @param ... Arguments to initialize and send to the constructor.
        initializer: function(constructor: ComponentConstructor<C>, ...: any)
    end

    --- Relationship component configuration.
    interface BaseRelationshipOptions<R is Relationship> is ContainerComponentOptions<R>
        --- Whether or not the relationship is exclusive (e.g., can only be the child of one parent).
        exclusive: boolean
    end

    --- Relationship component configuration.
    interface RelationshipOptions<R is Relationship> is BaseRelationshipOptions<R>, ComponentOptions<R> end

    --- Tag relationship component configuration.
    interface TagRelationshipOptions is RelationshipOptions<Relationship> end

    --- FFI relationship component configuration.
    interface FFIRelationshipOptions<R is Relationship> is BaseRelationshipOptions<R>, FFIComponentOptions<R> end

    --- Create a new component.
    ---
    --- If the constructor returns a table that has its own metatable, that metatable is for each instance, and
    --- if the __index fails to return a value, it will fall back to the component container.
    ---
    --- Raises an error if a component of the same name has already been registered.
    ---
    --- @param options Component configuration including name, container, and optional constructor/storage.
    --- @return the new component.
    newComponent: function<C is Component>(options: ComponentOptions<C>): C

    --- Create a tag component that uses bitset storage for efficiency.
    ---
    --- Tags are components with no data. Their presence alone carries meaning.
    ---
    --- @param options Tag component options.
    --- @return The created tag component.
    newTagComponent: function(options: TagComponentOptions): Component

    --- Create an FFI-based component with high performance storage.
    ---
    --- FFI components use LuaJIT's FFI for efficient memory layout and batch operations.
    --- They provide zero-copy performance for data-heavy components.
    ---
    --- @param options Configuration including name, container, fields, and optional recycling.
    --- @return The created FFI component.
    newFFIComponent: function<C is Component>(options: FFIComponentOptions<C>): C

    --- Create a new relationship component.
    ---
    --- @param config The configuration for the relationship component including name and options.
    --- @return the created relationship component.
    newRelationship: function<R is Relationship>(config: RelationshipOptions<R>): R

    --- Create a new relationship component that stores no additional data.
    ---
    --- @param config The configuration for the relationship component including name and options.
    --- @return the created relationship component.
    newTagRelationship: function(config: TagRelationshipOptions): Relationship

    --- Create a new relationship component that stores additional data in FFI structs.
    ---
    --- @param config The configuration for the relationship component including name and options.
    --- @return the created relationship component.
    newFFIRelationship: function<R is Relationship>(config: FFIRelationshipOptions<R>): R

    --- Manually register a new component that is already configured with a metatable and constructor functions.
    ---
    --- This method is called by `newComponent` to register the component with the world. It will automatically
    --- assign an auto-incremented component ID to the component. This method might be useful for totally custom
    --- component creation, including FFIs, CTypes, etc.
    ---
    --- @container The component container to register.
    --- @return the registered component.
    registerComponent: function<T is Component>(container: Component): T

    --- Computes the hash contribution for a component ID.
    --- Used for pre-computing component hashes and as a fallback.
    ---
    --- @param componentId The component ID to hash.
    --- @return The hash contribution for the component.
    computeComponentHash: function(componentId: integer): integer

    --- The globally registered components.
    ---
    --- Don't modify this. It's used to detect conflicts between component names.
    registeredComponents: {string: Component}
end

components.registeredComponents = {}

function components.computeComponentHash(componentId: integer): integer
    local id = componentId * 2654435761
    id = tobit(id)
    id = bxor(id, rshift(id, 16))
    return id
end

-------------------------------------------------------------------------------
-- Component creation
-------------------------------------------------------------------------------

-- The auto-incrementing ID for components.
local AUTO_ID = 0

local DEFAULT_COMPONENT_CONSTRUCTOR <const> = function(...: any): Component
    local value = ... as Component
    return value or {} as Component
end

function components.registerComponent<T is Component>(container: Component): T
    assert(container.componentName, "Missing component name when registering component")
    assert(container.componentType, "Missing component type when registering component")

    if components.registeredComponents[container.componentName] then
        error("Component " .. container.componentName .. " already registered")
    end

    if not container.componentId then
        AUTO_ID = AUTO_ID + 1
        container.componentId = AUTO_ID
        -- Pre-compute the hash contribution for this component
        container.componentHash = components.computeComponentHash(AUTO_ID)
    end

    components.registeredComponents[container.componentName] = container
    return container
end

local function createWithCustomMt<C is Component>(
    container: C,
    instance: C,
    customMt: metatable<C>,
    tostringFn: function(self: C): string
): C
    local newMt = {}
    for k, v in pairs(customMt as table) do
        newMt[k] = v
    end

    newMt.__tostring = newMt.__tostring or tostringFn
    newMt.__index = function(_self: C, k: any): any
        local result = (instance as table)[k]
        if result ~= nil then
            return result
        end
        return (container as table)[k]
    end

    -- Create a proxy so that it uses both metatables.
    return setmetatable({
        componentType = container,
        componentName = container.componentName,
        componentId = container.componentId,
    }, newMt as metatable<C>)
end

-- Extracts a component constructor function from storage implementations that provide custom component creation logic
local function getCreateComponent<C is Component>(
    stor: Storage,
    _container: C
): function(Storage, C): ComponentConstructor<C>
    -- Check if this storage has the createComponent method (FFI or pooled storage)
    local anyStorage = stor as {string:any}
    if anyStorage.createComponent and type(anyStorage.createComponent) == "function" then
        return anyStorage.createComponent as function(Storage, Component): ComponentConstructor<C>
    end
    error("Storage does not have createComponent method")
end

function components.newComponent<C is Component>(options: components.ComponentOptions<C>): C
    local opts = assert(options, "Missing component options")
    local name = assert(opts.name, "Missing component name")
    local container = assert(opts.container, "Missing component container")
    local constructor = opts.constructor or DEFAULT_COMPONENT_CONSTRUCTOR
    local componentStorage = opts.storage or storage.newTableStorage()

    if components.registeredComponents[name] then
        error("Component " .. name .. " already registered")
    end

    AUTO_ID = AUTO_ID + 1
    container.componentType = container
    container.componentName = name
    container.componentId = AUTO_ID
    container.onAdd = opts.onAdd
    container.onRemove = opts.onRemove
    -- Pre-compute the hash contribution for this component
    container.componentHash = components.computeComponentHash(AUTO_ID)

    -- Set the storage implementation
    container.getStorage = function(_self: C): Storage
        return componentStorage
    end

    -- If storage provides a createComponent function, use it to get the constructor
    local anyStorage = componentStorage as {string:any}
    if anyStorage.createComponent and not opts.constructor then
        constructor = getCreateComponent(componentStorage, container)(componentStorage, container)
    end

    local tostringFn <const> = function(_self: C): string return name end
    local instance_mt <const>: metatable<C> = {
        __index = container,
        __tostring = tostringFn
    }

    local container_mt <const>: metatable<C> = {
        __tostring = tostringFn,
        __call = function(_container: C, ...: any): C
            local instance = constructor(...)
            if instance == nil then
                error("Component constructor for " .. name .. " returned nil")
            end

            local mt = getmetatable(instance)
            if not mt then
                -- Most common case: regular table components with no metatable
                (instance as {string:any}).componentType = container
                return setmetatable(instance as C, instance_mt)
            elseif type(mt) == "string" then
                -- FFI cdata object - return as is, can't set componentType field
                return instance as C
            else
                -- Custom metatable case
                (instance as {string:any}).componentType = container
                return createWithCustomMt(container, instance as C, mt as metatable<C>, tostringFn)
            end
        end
    }

    setmetatable(container, container_mt)
    return components.registerComponent(container)
end

-------------------------------------------------------------------------------
-- Relationships
-------------------------------------------------------------------------------

local DEFAULT_RELATIONSHIP_CTOR <const> = function(_id: integer, _: any): Relationship
    return {}
end

function components.newRelationship<R is Relationship>(config: components.RelationshipOptions<R>): R
    local cfg = assert(config, "Missing relationship config")
    local name = assert(cfg.name, "Missing relationship name")
    local isExclusive = cfg.exclusive or false

    -- can't have constructor without container
    if not cfg.container and cfg.constructor then
        error("Cannot provide constructor for relationship without a container")
    end

    local ctor = cfg.constructor or DEFAULT_RELATIONSHIP_CTOR
    local relationshipStorage = cfg.storage or storage.newTableStorage()

    -- Each time a relationship from the container to a target is created, the same relationship container is created.
    local cache: {number: R} = setmetatable({}, {__mode = "v"})

    local relContainer = cfg.container or {}
    relContainer.componentName = name
    relContainer.componentType = relContainer
    relContainer.exclusiveRelationship = isExclusive
    relContainer.relationshipType = relContainer

    -- Set the storage implementation
    relContainer.getStorage = function(_self: R): Storage
        return relationshipStorage
    end

    -- Set hooks from config
    relContainer.onAdd = cfg.onAdd
    relContainer.onRemove = cfg.onRemove

    local instance_mt <const> = {
        __index = relContainer,
        __tostring = function(self: Relationship): string
            return table_concat({self.componentName, " -> ", self.target})
        end,
    }

    setmetatable(relContainer, {
        __tostring = function(self: R): string
            return self.componentName
        end,
        __call = function(self: Relationship, id: integer, ...: any): R
            assert(id, "Missing entity ID")
            local instance = cache[id]
            if not instance then -- create if it doesn't exist
                instance = assert(ctor(id, ...), "Relationship constructor returned nil")
                local mt = getmetatable(instance)
                if type(mt) == "string" then
                    -- FFI cdata returns string metatable names, not tables. We don't register them individually,
                    -- the container is already registered.
                    cache[id] = instance
                else
                    instance.target = id
                    instance.componentName = self.componentName .. "->" .. id
                    instance.componentType = instance
                    instance.exclusiveRelationship = self.exclusiveRelationship
                    instance.relationshipType = self
                    instance.getStorage = function(_inst: R): Storage
                        return relationshipStorage
                    end
                    instance.onAdd = cfg.onAdd
                    instance.onRemove = cfg.onRemove
                    setmetatable(instance, instance_mt)
                    components.registerComponent(instance)
                    cache[id] = instance
                end
            end
            return instance
        end,
    })

    -- Add targeting method to the container
    relContainer.targeting = function(self: R, targetId: integer): R
        assert(targetId, "Missing target entity ID")
        if cfg.container then
            -- Data relationship: return component type for queries
            return self(targetId).componentType as R
        else
            -- Basic relationship: return component instance directly
            return self(targetId)
        end
    end

    return components.registerComponent(relContainer)
end

function components.newTagRelationship(config: components.TagRelationshipOptions): Relationship
    local cfg = assert(config, "Missing tag relationship config")
    return components.newFFIRelationship({
        name = cfg.name,
        container = {},
        fields = {},
        exclusive = cfg.exclusive,
        recycle = true,
        onAdd = cfg.onAdd,
        onRemove = cfg.onRemove
    })
end

function components.newFFIRelationship<R is Relationship>(config: components.FFIRelationshipOptions<R>): R
    local cfg = assert(config, "Missing FFI relationship config")
    local name = assert(cfg.name, "Missing FFI relationship name")
    local container = assert(cfg.container, "Missing FFI relationship container")
    local fields = assert(cfg.fields, "Missing FFI relationship fields")

    -- Ensure target field is included in the FFI struct
    local allFields = {{"target", "int32_t"}}
    for _, field in ipairs(fields) do
        table.insert(allFields, field)
    end

    local ffiStorage = storage.newFFIStorage({
        name = name .. "_FFIRelationship",
        fields = allFields,
        recycle = cfg.recycle
    })

    -- Create constructor that optionally uses initializer
    local constructor: ComponentConstructor<R>
    local storageCreateComponent = getCreateComponent(ffiStorage, container)

    if cfg.initializer then
        constructor = function(...: any): R
            local actualConstructor = storageCreateComponent(ffiStorage, container)
            -- Call initializer with the actual constructor and arguments
            return cfg.initializer(actualConstructor, ...)
        end
    else
        -- Get the actual constructor function from storage
        constructor = storageCreateComponent(ffiStorage, container)
    end

    -- Use newRelationship with the container and FFI storage
    return components.newRelationship({
        name = name,
        container = container,
        constructor = constructor,
        exclusive = cfg.exclusive,
        storage = ffiStorage,
        onAdd = cfg.onAdd,
        onRemove = cfg.onRemove
    })
end

-------------------------------------------------------------------------------
-- Tags (marker components with no data)
-------------------------------------------------------------------------------

function components.newTagComponent(options: components.TagComponentOptions): Component
    return components.newComponent({
        name = assert(options.name, "Missing tag component name"),
        container = {},
        storage = storage.newBitsetStorage()
    })
end

-------------------------------------------------------------------------------
-- FFI component logic
-------------------------------------------------------------------------------

function components.newFFIComponent<C is Component>(options: components.FFIComponentOptions<C>): C
    local opts = assert(options, "Missing FFI component options")
    assert(opts.name, "Missing component name")
    assert(opts.container, "Missing component container")
    assert(opts.fields, "Missing FFI fields definition")

    -- Create storage (with automatic fallback if FFI doesn't exist)
    local componentStorage = storage.newFFIStorage({
        name = opts.name,
        fields = opts.fields,
        recycle = opts.recycle,
        recyclePoolSize = opts.recyclePoolSize
    })

    -- Create constructor that optionally uses initializer
    local constructor: ComponentConstructor<C>
    local ffi = require("tecs.internal.ffi" as string) as {string:any}
    local isFFIAvailable = ffi.isFFIAvailable as function(): boolean

    if isFFIAvailable() then
        local storageCreateComponent = getCreateComponent(componentStorage, opts.container)
        if not opts.initializer then
            constructor = storageCreateComponent(componentStorage, opts.container)
        else
            constructor = function(...: any): C
                local actualConstructor = storageCreateComponent(componentStorage, opts.container)
                return opts.initializer(actualConstructor, ...)
            end
        end
    else
        -- Table storage fallback
        local fallbackConstructor = schema.createFallbackConstructor(opts.fields or {}) as ComponentConstructor<C>
        if not opts.initializer then
            constructor = fallbackConstructor
        else
            constructor = function(...: any): C
                return opts.initializer(fallbackConstructor, ...)
            end
        end
    end

    return components.newComponent({
        name = opts.name,
        container = opts.container,
        constructor = constructor,
        storage = componentStorage,
        onAdd = opts.onAdd,
        onRemove = opts.onRemove
    })
end

return components
