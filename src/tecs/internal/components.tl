local types <const> = require("tecs.types")
local internal <const> = require("tecs.internal.types")
local storage <const> = require("tecs.internal.storage")
local ComponentCodegen <const> = require("tecs.internal.ComponentCodegen")
local componentIds <const> = require("tecs.internal.componentIds")
local bit <const> = require("bit")

local assert, table_concat <const> = assert, table.concat
local rshift <const> = bit.rshift

local type Relationship = types.components.Relationship
local type Component = types.components.Component
local type ComponentInternal = internal.ComponentInternal
local type ArchetypeInternal = internal.ArchetypeInternal
local type Storage = storage.Storage
local type ComponentAllocator = types.components.ComponentAllocator
local type ComponentOptions<C is Component> = types.components.ComponentOptions<C>
local type TagComponentOptions = types.components.TagComponentOptions
local type FFIComponentOptions<C is Component> = types.components.FFIComponentOptions<C>
local type ScalarComponentOptions<T> = types.components.ScalarComponentOptions<T>
local type RelationshipOptions<R is Relationship> = types.components.RelationshipOptions<R>
local type TagRelationshipOptions = types.components.TagRelationshipOptions
local type FFIRelationshipOptions<R is Relationship> = types.components.FFIRelationshipOptions<R>

--- The components module defines ECS components and methods for creating them.
local record components
    --- Create a new component.
    ---
    --- Constructors must return a plain Lua table (no metatable) or FFI cdata. The framework
    --- applies its own instance metatable so component fields fall back to the container for
    --- shared data.
    ---
    --- Raises an error if a component of the same name has already been registered.
    ---
    --- @param options Component configuration including name, container, and optional init/storage.
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

    --- Create a scalar component backed by raw Lua array values.
    newScalarComponent: function<T>(options: ScalarComponentOptions<T>): types.components.ScalarComponent<T>

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

    --- Manually register a new component that is already configured with a metatable and construction functions.
    ---
    --- This method is called by `newComponent` to register the component with the world. It will automatically
    --- assign an auto-incremented component ID to the component. This method might be useful for totally custom
    --- component creation, including FFIs, CTypes, etc.
    ---
    --- @container The component container to register.
    --- @return the registered component.
    registerComponent: function<T is Component>(container: Component): T

    --- The globally registered components.
    ---
    --- Don't modify this. It's used to detect conflicts between component names.
    registeredComponents: {string: Component}
    componentsById: {integer: Component}
end

components.registeredComponents = {}
components.componentsById = setmetatable({} as {integer: Component}, {
    __newindex = function()
        error("componentsById is read-only")
    end
})

-------------------------------------------------------------------------------
-- Component creation
-------------------------------------------------------------------------------

function components.registerComponent<T is Component>(container: Component): T
    assert(container.componentName, "Missing component name when registering component")
    assert(container.componentType, "Missing component type when registering component")

    if components.registeredComponents[container.componentName] then
        error("Component " .. container.componentName .. " already registered")
    end

    if not container.componentId then
        container.componentId = componentIds.allocate()
    end

    local componentI = container as ComponentInternal
    local signatureIndex = container.componentId - 1
    componentI.signatureIndex = signatureIndex
    componentI.signatureWordIndex = rshift(signatureIndex, 5)

    components.registeredComponents[container.componentName] = container
    rawset(components.componentsById, container.componentId, container)
    return container
end

-- Hook attachment payload — fields mirror `internal.ComponentInternal`.
-- Module-local: only the built-in factories below (newRelationship sparse
-- and exclusive/reverseIndex paths) call attachHooks. Not exposed.
local interface HookSet
    deferSet: function(world: types.World, id: integer, componentType: Component, value: any)
    deferRemove: function(world: types.World, id: integer, componentType: Component)
    onRemove: function(world: types.World, id: integer, componentType: Component, arch: types.Archetype, row: integer)
    onDespawn: function(world: types.World, id: integer, componentType: Component, arch: types.Archetype, row: integer)
    mustDeferSet: boolean
    mustDeferRemove: boolean
    noBulkBatch: boolean
end

local function attachHooks(container: Component, hooks: HookSet)
    assert(container, "attachHooks: container is required")
    assert(hooks, "attachHooks: hooks is required")
    local cAny = container as {string:any}
    if hooks.deferSet then
        cAny.deferSet = hooks.deferSet
        cAny._hasDeferSet = true
    end
    if hooks.deferRemove then
        cAny.deferRemove = hooks.deferRemove
        cAny._hasDeferRemove = true
    end
    if hooks.onRemove then
        cAny.onRemove = hooks.onRemove
        cAny._hasOnRemove = true
    end
    if hooks.onDespawn then
        cAny.onDespawn = hooks.onDespawn
        cAny._hasOnDespawn = true
    end
    if hooks.mustDeferSet then cAny._mustDeferSet = true end
    if hooks.mustDeferRemove then cAny._mustDeferRemove = true end
    if hooks.noBulkBatch then cAny._noBulkBatch = true end
end

-- Generate a fused `__call` function for field-based table components. The
-- returned function closes over `instance_mt` and, when invoked, allocates
-- a table with literal field assignments and applies the metatable — a
-- single trace-friendly expression LuaJIT can specialize to the exact
-- table shape.
--
-- `componentType` is NOT written on the instance: the instance metatable's
-- `__index = container` fallback resolves `instance.componentType` to
-- `container.componentType` (which is set to the container itself in
-- newComponent). Skipping the write saves one hash slot per instance and
-- cuts one store per spawn — meaningful in hot paths that allocate
-- thousands of instances per frame (bundle spawn, batch spawn, etc).
-- Module-local sentinel: internal factories (`newTagComponent`,
-- `newFFIComponent`, `newScalarComponent`, and the relationship variants)
-- pass this as `opts.__internalStorageToken` alongside their chosen
-- `storage`. Public `newComponent` rejects any user-supplied `opts.storage`
-- that doesn't include the sentinel. Keeps storage a fully internal
-- extension point; users pick a component kind via the factories instead.
local INTERNAL_STORAGE_TOKEN <const> = {} as any
local NOOP_INIT <const> = function(_instance: any) end

local function applyPositionalDefaults(instance: {string:any}, fields: {string}, defaults: {any})
    if not defaults or not fields then
        return
    end
    for i = 1, #fields do
        local value = defaults[i]
        if value ~= nil then
            instance[fields[i]] = value
        end
    end
end

function components.newComponent<C is Component>(options: ComponentOptions<C>): C
    local opts = assert(options, "Missing component options")
    local name = assert(opts.name, "Missing component name")
    local container = assert(opts.container, "Missing component container")
    local optsAny = opts as {string:any}
    local userStorage = optsAny.storage
    if userStorage ~= nil and optsAny.__internalStorageToken ~= INTERNAL_STORAGE_TOKEN then
        error("Component " .. name .. ": `storage` is not a user option. "
            .. "Use one of newComponent / newTagComponent / newFFIComponent "
            .. "/ newScalarComponent (or the relationship variants) to pick "
            .. "a component layout.")
    end
    local componentStorage = userStorage as Storage
        or storage.newTableStorage()

    if opts.defaults and not opts.fields then
        error("Component " .. name .. ": `defaults` requires `fields`")
    end

    -- `init` without `fields` or `new` leaves `.new` with no way to
    -- unpack a table into positional args — the fallback would forward the
    -- whole table as arg #1, which is almost never what the author wanted.
    -- Require one of them so `.new(data)` is always well-defined.
    if opts.init and not opts.fields and not opts.new then
        error("Component " .. name .. ": `init` requires either `fields` (auto-codegens `.new`) or an explicit `new`")
    end

    local storageConstructor = componentStorage:createComponent(container) as ComponentAllocator<C>

    if components.registeredComponents[name] then
        error("Component " .. name .. " already registered")
    end

    local containerI = container as ComponentInternal
    container.componentType = container
    container.componentName = name
    container.componentId = componentIds.allocate()
    container.init = opts.init or NOOP_INIT
    containerI.requires = opts.requires
    containerI._hasRequires = opts.requires ~= nil and #opts.requires > 0
    -- `_requiresClosure` is built lazily on first use (first
    -- `world:set` / `world:spawn` that mentions this component) so
    -- late-registered dependencies are captured correctly.

    containerI.storage = componentStorage
    containerI.storageType = componentStorage.storageType

    -- Check for storage-provided serialization methods
    local anyStorage = componentStorage as {string:any}

    -- Set up serialization functions
    -- Priority: user-provided > storage-provided > default
    if opts.serialize then
        container.serialize = opts.serialize
    elseif componentStorage.storageType == "scalar" then
        -- `instance` may be either the raw column value (snapshot writer
        -- reads `col[row]` and hands it in directly) or a wrapper produced
        -- by `__call` (when callers serialize a freshly-constructed
        -- instance). Detect the wrapper shape and unwrap so the on-disk
        -- representation is always `{value = <raw>}`.
        container.serialize = function(instance: C): {string: any}
            if type(instance) == "table" and (instance as {string:any}).componentType == container then
                return { value = (instance as {string:any}).value }
            end
            return { value = instance as any }
        end
    elseif anyStorage.serialize then
        container.serialize = function(instance: C): {string: any}
            return (anyStorage.serialize as function(Storage, C): {string: any})(componentStorage, instance)
        end
    else
        -- Default: iterate table fields, skip internal metadata
        container.serialize = function(instance: C): {string: any}
            local data: {string: any} = {}
            for k, v in pairs(instance as {string: any}) do
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
        -- Route through `__call` so the deserialized value is wrapped for
        -- spawn (`comp.componentType` lookup), matching the in-process API.
        container.deserialize = function(_world: types.World, data: {string: any}): C
            local v: any
            if data ~= nil then v = data.value end
            return (container as function(...: any): C)(v)
        end
    elseif anyStorage.deserialize then
        container.deserialize = function(_world: types.World, data: {string: any}): C
            return (anyStorage.deserialize as function(Storage, {string: any}): C)(componentStorage, data)
        end
    end
    -- Default deserialize (when neither user nor storage provides one) is
    -- installed below, after `.new` is ready — it routes through `.new(data)`.

    local tostringFn <const> = function(_self: C): string return name end

    -- Pick the __call strategy once, at construction time, so the hot path has zero branching.
    -- `__call` is positional-only; use `.new(data)` for the table form.
    local callFn: function(C, ...: any): C
    local storageType = componentStorage.storageType or "table"
    local tableInstanceMt: metatable<C> = nil
    local customCall = optsAny["__call"] as function(C, ...: any)
    if storageType == "tag" then
        -- Tag: container is the instance. Constructor is a no-op.
        callFn = function(_c: C): C return container end
    elseif storageType == "scalar" then
        -- Scalars are stored raw in columns (`col[row] = "Frank"`), but `world:spawn(...)` and 2-arg `world:set`
        -- need each component argument to expose `componentType` so the dispatcher can route it. `Name("Frank")`
        -- therefore returns a tiny wrapper carrying both the value and the component type. The wrapper is unwrapped
        -- at the spawn/set boundary; internals never see it.
        --
        -- For string scalars we cache wrappers in a weak-valued table: repeated `Name("Frank")` reuses one wrapper
        -- while unreferenced entries get collected. Numeric/boolean kinds skip the cache — arbitrary float keys
        -- would grow unbounded, and booleans aren't worth a cache lookup.
        local scalarDefault = (anyStorage._scalarDefault) as any
        local kind = (anyStorage._scalarKind) as string
        if kind == "string" then
            local cache = setmetatable({} as {string: any}, {__mode = "v"})
            callFn = function(_c: C, value?: any): C
                if value == nil then value = scalarDefault end
                local hit = cache[value as string]
                if hit then return hit as C end
                local w = {componentType = container, value = value}
                cache[value as string] = w
                return w as C
            end
        else
            callFn = function(_c: C, value?: any): C
                if value == nil then value = scalarDefault end
                return {componentType = container, value = value} as C
            end
        end
    elseif storageType == "ffi" then
        -- FFI: cdata carries its own metatype; return as-is.
        local ffiFields: {string} = {}
        local rawFfiFields = opts.fields as {{string}}
        if rawFfiFields then
            for i = 1, #rawFfiFields do
                ffiFields[i] = rawFfiFields[i][1]
            end
        end
        local ffiDefaults = optsAny.defaults as {any}
        local ffiAllocator = storageConstructor as function(...: any): any
        if customCall then
            callFn = function(_c: C, ...: any): C
                local instance = ffiAllocator() as C
                applyPositionalDefaults(instance as {string:any}, ffiFields, ffiDefaults)
                customCall(instance, ...)
                return instance
            end
        else
            local ffiAlloc = ComponentCodegen.createCallFn({
                backend = "allocatorCall",
                fields = ffiFields,
                defaults = ffiDefaults,
                leadingArgCount = 0,
                includeSelfParam = true,
                allocator = ffiAllocator,
                instanceMt = nil,
            }) as function(C, ...: any): C
            if opts.init then
                local userInit <const> = opts.init
                callFn = function(_c: C, ...: any): C
                    local instance = ffiAlloc(container, ...)
                    userInit(instance, ...)
                    return instance
                end
            else
                callFn = ffiAlloc
            end
        end
    else
        -- Plain table: apply the instance metatable so `instance.componentType`
        -- (and any other container-level fields) resolve via __index = container.
        -- No need to stamp componentType on the instance itself.
        tableInstanceMt = {__index = container, __tostring = tostringFn}
        -- Priority for __call: `fields` codegen beats storage default.
        -- `init` can coexist with either path; it runs after the base instance
        -- has been allocated and populated.
        if customCall then
            local tableFields = opts.fields
            local tableDefaults = opts.defaults
            callFn = function(_c: C, ...: any): C
                local instance = setmetatable({} as {string:any}, tableInstanceMt as metatable<{string:any}>) as C
                applyPositionalDefaults(instance as {string:any}, tableFields, tableDefaults)
                customCall(instance, ...)
                return instance
            end
        else
            local baseCall: function(C, ...: any): C
            if opts.fields then
                local tableFields = opts.fields
                local generated = ComponentCodegen.createCallFn({
                    backend = "tableLiteral",
                    fields = tableFields,
                    defaults = opts.defaults,
                    leadingArgCount = 0,
                    includeSelfParam = true,
                    instanceMt = tableInstanceMt as metatable<any>,
                    allocator = nil,
                })
                baseCall = generated as function(C, ...: any): C
            else
                baseCall = function(_c: C, ...: any): C
                    return setmetatable(storageConstructor(...), tableInstanceMt)
                end
            end

            local userInit <const> = opts.init
            if opts.init then
                callFn = function(_c: C, ...: any): C
                    local instance = baseCall(container, ...)
                    userInit(instance, ...)
                    return instance
                end
            else
                callFn = baseCall
            end
        end
    end

    setmetatable(container, {__tostring = tostringFn, __call = callFn} as metatable<C>)

    -- Install `.new(data)` — the table-form constructor.
    -- * User-provided `opts.new` wins, but for table-storage components the
    --   framework wraps the return value with the instance metatable so
    --   `componentType` etc. resolve via `__index = container` (identical to
    --   what `__call` does).
    -- * `opts.fields` codegens a table-by-name unpacker that routes through
    --   `__call` — metatable applied there.
    -- * Fallback for `init`-only components with no `new`: forward
    --   the table verbatim via `__call`.
    if opts.new then
        local userNew <const> = opts.new
        if tableInstanceMt then
            container.new = function(data: {string: any}): C
                return setmetatable(userNew(data), tableInstanceMt)
            end
        else
            container.new = userNew
        end
    elseif opts.fields then
        container.new = ComponentCodegen.createNewFn(container, opts.fields) as function(data: {string: any}): C
    elseif storageType == "scalar" then
        -- `.new({value=...})` routes through `__call` so it produces the
        -- same wrapper the positional form does.
        container.new = function(data: {string: any}): C
            local v: any
            if data ~= nil then v = data.value end
            return (container as function(...: any): C)(v)
        end
    else
        container.new = function(data: {string: any}): C
            return (container as function({string: any}): C)(data)
        end
    end

    -- If no explicit deserialize, route through `.new` for uniform table-form
    -- reconstruction. Storage-provided and user-provided paths already set
    -- container.deserialize above; this overrides only the default fallback.
    if not opts.deserialize and not anyStorage.deserialize then
        container.deserialize = function(_world: types.World, data: {string: any}): C
            return container.new(data)
        end
    end

    return components.registerComponent(container)
end

-------------------------------------------------------------------------------
-- Relationships
-------------------------------------------------------------------------------

local DEFAULT_RELATIONSHIP_CTOR <const> = function(_id: integer, _: any): Relationship
    return {}
end

function components.newRelationship<R is Relationship>(config: RelationshipOptions<R>): R
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

    -- Reject user-supplied `storage` on the public factory (only internal
    -- callers pass it, authenticated via the sentinel token).
    local cfgAny = cfg as {string:any}
    if cfgAny.storage ~= nil and cfgAny.__internalStorageToken ~= INTERNAL_STORAGE_TOKEN then
        error("Relationship " .. name .. ": `storage` is not a user option. "
            .. "Use newRelationship / newTagRelationship / newFFIRelationship "
            .. "to pick a relationship layout.")
    end

    -- `init` without `fields` or `new` leaves `.new` with no way to
    -- unpack a table into positional args. Match the behavior of newComponent.
    if cfg.init and not cfg.fields and not cfg.new then
        error("Relationship " .. name .. ": `init` requires either `fields` (auto-codegens `.new`) or an explicit `new`")
    end

    -- `storage` is an internal options field (see newComponent). Cast.
    local relationshipStorage = (cfg as {string:any}).storage as Storage
        or storage.newTableStorage()

    -- Each time a relationship from the container to a target is created, the same relationship container is created.
    local cache: {number: R} = setmetatable({}, {__mode = "v"})

    local relContainer = cfg.container or {}
    local relContainerI = relContainer as ComponentInternal
    relContainer.componentName = name
    relContainer.componentType = relContainer
    relContainer.exclusiveRelationship = isExclusive
    relContainer.relationshipType = relContainer
    relContainer.init = cfg.init or NOOP_INIT
    relContainerI.isContainer = true
    relContainerI.isSparse = isSparse
    relContainerI.reverseIndex = hasReverseIndex
    relContainerI.cascadeDelete = isCascadeDelete

    -- The container (wildcard) uses bitset storage for efficient presence tracking.
    -- Instances use relationshipStorage (which may be FFI, table, etc.)
    local bitset = storage.newBitsetStorage(relContainer)
    relContainerI.storage = bitset
    relContainerI.storageType = bitset.storageType

    local ctor: function(integer, ...: any): R
    local customCall = cfgAny["__call"] as function(R, ...: any)
    if relationshipStorage.storageType == "ffi" then
        local relationshipFields = (cfg.fields or {}) as {string}
        local relationshipAllocator = relationshipStorage:createComponent(relContainer as Component)
            as function(...: any): any
        if customCall then
            local relationshipDefaults = cfg.defaults
            ctor = function(id: integer, ...: any): R
                local instance = relationshipAllocator(id) as R
                applyPositionalDefaults(instance as {string:any}, relationshipFields, relationshipDefaults)
                customCall(instance, id, ...)
                return instance
            end
        else
            ctor = ComponentCodegen.createCallFn({
                backend = "allocatorCall",
                fields = relationshipFields,
                defaults = cfg.defaults,
                leadingArgCount = 1,
                includeSelfParam = false,
                allocator = relationshipAllocator,
                instanceMt = nil,
            }) as function(integer, ...: any): R
        end
    elseif cfg.fields then
        -- Codegen a plain-table constructor (no metatable; the relationship
        -- system applies instance_mt after stamping target/componentName/etc).
        local relationshipFields = cfg.fields as {string}
        if customCall then
            local relationshipDefaults = cfg.defaults
            ctor = function(id: integer, ...: any): R
                local instance = {} as R
                applyPositionalDefaults(instance as {string:any}, relationshipFields, relationshipDefaults)
                customCall(instance, id, ...)
                return instance
            end
        else
            ctor = ComponentCodegen.createCallFn({
                backend = "tableLiteral",
                fields = relationshipFields,
                defaults = cfg.defaults,
                leadingArgCount = 1,
                includeSelfParam = false,
                instanceMt = nil,
                allocator = nil,
            }) as function(integer, ...: any): R
        end
    else
        if customCall then
            ctor = function(id: integer, ...: any): R
                local instance = {} as R
                customCall(instance, id, ...)
                return instance
            end
        else
            ctor = DEFAULT_RELATIONSHIP_CTOR as function(integer, ...: any): R
        end
    end

    -- Serialize: emit target + instance fields (skip internal metadata).
    -- Deserialize: rebuild via the container's __call, which routes through
    -- the instance constructor.
    --
    -- If the underlying storage has a serialize method (e.g., FFIStorage),
    -- use it — it knows the field layout. Otherwise iterate plain-table
    -- instances, skipping component metadata.
    local storageAny = relationshipStorage as {string: any}
    if storageAny.serialize then
        relContainer.serialize = function(instance: R): {string: any}
            return (storageAny.serialize as function(Storage, R): {string: any})(
                relationshipStorage, instance)
        end
    else
        relContainer.serialize = function(instance: R): {string: any}
            local data: {string: any} = {}
            for k, v in pairs(instance as {string: any}) do
                if type(k) == "string"
                        and not (k as string):match("^component")
                        and k ~= "storage"
                        and k ~= "relationshipType"
                        and k ~= "exclusiveRelationship" then
                    local vtype = type(v)
                    if vtype == "number" or vtype == "string" or vtype == "boolean" or vtype == "table" then
                        data[k] = v
                    end
                end
            end
            return data
        end
    end

    -- Install `.new(data)` — the table-form constructor.
    -- `data.target` is mandatory (relationships need a target); field values
    -- come from either `cfg.new` (user override) or unpacked by `cfg.fields`.
    -- Routes through `__call(target, ...)` so instance caching, registration,
    -- and target-stamping still happen the same way as for positional calls.
    if cfg.new then
        local userNew <const> = cfg.new
        relContainer.new = function(data: {string: any}): R
            return userNew(data)
        end
    elseif cfg.fields then
        relContainer.new = ComponentCodegen.createNewFn(
            relContainer,
            cfg.fields as {string},
            {"target"},
            {target = "Relationship .new: missing 'target' field"}
        ) as function(data: {string: any}): R
    else
        relContainer.new = function(data: {string: any}): R
            local target = data.target as integer
            assert(target, "Relationship .new: missing 'target' field")
            return (relContainer as function(integer, any): R)(target, data)
        end
    end

    relContainer.deserialize = function(_world: types.World, data: {string: any}): R
        return relContainer.new(data)
    end

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
                instance = assert(ctor(id, ...), "Relationship allocation returned nil")
                if cfg.init and not customCall then
                    cfg.init(instance, id, ...)
                end
                local mt = getmetatable(instance)
                if type(mt) == "string" then
                    -- FFI cdata returns string metatable names, not tables.
                    -- For sparse: instance is used as the VALUE in sparse storage, not as an archetype component.
                    -- For dense: container is already registered, instances share its presence.
                    cache[id] = instance
                elseif isSparse then
                    -- Sparse: don't register per-target component (no unique componentId.
                    -- The instance is used as the value in sparse storage.
                    local instanceI = instance as ComponentInternal
                    instance.target = id
                    instance.componentName = self.componentName .. "->" .. id
                    instance.componentType = self  -- points to container, not self
                    instance.exclusiveRelationship = self.exclusiveRelationship
                    instance.relationshipType = self
                    instanceI.wildcardContainer = self as Component
                    instanceI.isContainer = false  -- shadow the container's true via __index
                    instanceI.isSparseInstance = true
                    instanceI.storage = relationshipStorage
                    instanceI.storageType = relationshipStorage.storageType
                    setmetatable(instance, instance_mt)
                    -- NOT registered — sparse instances don't get unique component IDs
                    cache[id] = instance
                else
                    local instanceI = instance as ComponentInternal
                    instance.target = id
                    instance.componentName = self.componentName .. "->" .. id
                    instance.componentType = instance
                    instance.exclusiveRelationship = self.exclusiveRelationship
                    instance.relationshipType = self
                    instanceI.wildcardContainer = self as Component
                    instanceI.isContainer = false  -- shadow the container's true via __index
                    instanceI.storage = relationshipStorage
                    instanceI.storageType = relationshipStorage.storageType
                    setmetatable(instance, instance_mt)
                    components.registerComponent(instance)
                    cache[id] = instance
                end
            end
            return instance
        end,
    })

    -- Add targeting method to the container
    if not isSparse then
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
    end

    -- Sparse relationships carry their per-entity payload outside the
    -- archetype (in `world.sparseSets` → flushed to `relationshipStores`
    -- at drain). The archetype only records presence via the wildcard
    -- container as a tag. Both set and remove route through dedicated
    -- behavior hooks so the core defer/instant paths stay free of sparse
    -- special cases.
    --
    -- mustDefer* = true: sparse staging buffer only flushes at drain, so
    -- eager instant execution is unsafe — instant routes synthetic-scope.
    -- noBulkBatch = true: per-entity staging state makes bulk column
    -- writes incorrect; batch paths fall back to per-entity routing.
    if isSparse then
        local relContainerC = relContainer as types.components.Component
        attachHooks(relContainerC, {
            deferSet = function(world: types.World, id: integer, _ct: types.components.Component, value: any)
                local wImpl = world as {string:any}
                local setSparse = wImpl.setSparseRaw as function(any, integer, any)
                local deferSetRawFn = wImpl.deferSetRaw as function(any, integer, types.components.Component, any)
                -- The wildcard container itself is dense-only presence
                -- state. Only concrete sparse instances (which carry a
                -- target) belong in the sparse store.
                if (value as {string:any}).target ~= nil then
                    setSparse(wImpl, id, value)
                end
                deferSetRawFn(wImpl, id, relContainerC, relContainer)
            end,
            deferRemove = function(world: types.World, id: integer, component: types.components.Component)
                local wImpl = world as {string:any}
                if component == relContainer then
                    local removeAll = wImpl.removeSparseRaw as function(any, integer, types.components.Component)
                    removeAll(wImpl, id, relContainerC)
                else
                    local removeOne = wImpl.removeSparseOneRaw as function(any, integer, types.components.Component, integer)
                    removeOne(wImpl, id, relContainerC, component.target)
                end
            end,
            mustDeferSet = true,
            mustDeferRemove = true,
            noBulkBatch = true,
        })
    elseif isExclusive or hasReverseIndex then
        -- Dense relationships with behavior hooks for two concerns:
        --
        --   Exclusive (isExclusive=true): sibling eviction — adding
        --     Follows(l2) to an entity that already has Follows(l1) must
        --     first remove Follows(l1). Handled by deferSet hook iterating
        --     siblings BEFORE calling setRaw.
        --
        --   ReverseIndex (hasReverseIndex=true): per-container inverse-index
        --     store kept in sync with forward archetype state across all four
        --     mutation kinds.
        --       deferSet → link(id, new.target)       after default set runs
        --       deferRemove → unlink(id, old.target)  read before default remove
        --       onRemove → unlink(id, old.target)     column transition (e.g.
        --                                              exclusive sibling evict)
        --       onDespawn → unlink(id, old.target)    entity going away
        --
        -- INVARIANT for the unlink-before-teardown paths: the old column
        -- value carrying the target must still be readable when the hook
        -- fires. deferRemove reads it via oldValueOf BEFORE invoking the
        -- Raw call. onRemove/onDespawn are dispatched by the drain path
        -- before the row is torn down.
        --
        -- noBulkBatch = true: batch set/remove can't invoke per-entity hooks,
        -- so route through the per-entity path.
        local storeKey = relContainer as types.components.Component
        attachHooks(storeKey, {
            deferSet = function(
                world: types.World, id: integer, componentType: types.components.Component, value: any
            )
                local wImpl = world as {string:any}
                -- Exclusive sibling eviction: read current archetype and
                -- remove any existing relationship in the same container.
                -- Runs BEFORE setRaw so the archetype transition adds to a
                -- clean slate.
                if isExclusive then
                    local currentArchFn = wImpl.currentArchetype as function(any, integer): types.Archetype
                    local arch = currentArchFn(wImpl, id)
                    if arch then
                        -- Use world:remove (public dispatcher) so the
                        -- sibling's own hooks fire — e.g. reverse-index
                        -- unlink on Follows(l1) when reparenting to l2.
                        local removeFn = wImpl.remove as function(any, integer, types.components.Component)
                        for existingComp in pairs((arch as ArchetypeInternal).columns as {types.components.Component:any}) do
                            local existContainer = (existingComp as ComponentInternal).wildcardContainer
                            if existContainer == storeKey and existingComp ~= componentType then
                                removeFn(wImpl, id, existingComp)
                            end
                        end
                    end
                end
                -- setRaw picks defer/instant Raw based on current scope depth
                -- so the hook behaves correctly whether called from _deferSet
                -- or the instant-path dispatcher.
                local setRawFn = wImpl.setRaw as function(any, integer, types.components.Component, any)
                setRawFn(wImpl, id, componentType, value)
                if hasReverseIndex then
                    local stores = wImpl.relationshipStores as {types.components.Component: {string:any}}
                    local store = stores[storeKey]
                    if store then
                        local linkFn = store.link as function(any, integer, integer)
                        linkFn(store, id, (value as {string:integer}).target)
                    end
                end
            end,
            deferRemove = function(
                world: types.World, id: integer, component: types.components.Component
            )
                local wImpl = world as {string:any}
                if hasReverseIndex then
                    -- Ordering invariant: read old target BEFORE the Raw call
                    -- mutates state, so the unlink sees the correct target.
                    local oldValueFn = wImpl.oldValueOf as function(any, integer, types.components.Component): any
                    local oldValue = oldValueFn(wImpl, id, component)
                    local removeRawFn = wImpl.removeRaw as function(any, integer, types.components.Component)
                    removeRawFn(wImpl, id, component)
                    if oldValue ~= nil then
                        local stores = wImpl.relationshipStores as {types.components.Component: {string:any}}
                        local store = stores[storeKey]
                        if store then
                            local unlinkFn = store.unlink as function(any, integer, integer)
                            unlinkFn(store, id, (oldValue as {string:integer}).target)
                        end
                    end
                else
                    local removeRawFn = wImpl.removeRaw as function(any, integer, types.components.Component)
                    removeRawFn(wImpl, id, component)
                end
            end,
            onRemove = hasReverseIndex and function(
                world: types.World, id: integer, componentType: types.components.Component,
                arch: types.Archetype, row: integer
            )
                local col = (arch as ArchetypeInternal).columns[componentType] as {any}
                if col == nil then return end
                local oldValue = col[row + 1]
                if oldValue == nil then return end
                local wImpl = world as {string:any}
                local stores = wImpl.relationshipStores as {types.components.Component: {string:any}}
                local store = stores[storeKey]
                if store then
                    local unlinkFn = store.unlink as function(any, integer, integer)
                    unlinkFn(store, id, (oldValue as {string:integer}).target)
                end
            end or nil,
            onDespawn = hasReverseIndex and function(
                world: types.World, id: integer, componentType: types.components.Component,
                arch: types.Archetype, row: integer
            )
                local col = (arch as ArchetypeInternal).columns[componentType] as {any}
                if col == nil then return end
                local oldValue = col[row + 1]
                if oldValue == nil then return end
                local wImpl = world as {string:any}
                local stores = wImpl.relationshipStores as {types.components.Component: {string:any}}
                local store = stores[storeKey]
                if store then
                    local unlinkFn = store.unlink as function(any, integer, integer)
                    unlinkFn(store, id, (oldValue as {string:integer}).target)
                end
            end or nil,
            noBulkBatch = true,
        })
    end

    components.registerComponent(relContainer)
    storage.propagateHooksToFFI(relationshipStorage, relContainer)
    return relContainer
end

function components.newTagRelationship(config: TagRelationshipOptions): Relationship
    local cfg = assert(config, "Missing tag relationship config")
    return components.newFFIRelationship({
        name = cfg.name,
        container = {},
        fields = {},
        exclusive = cfg.exclusive,
        sparse = cfg.sparse,
        reverseIndex = cfg.reverseIndex,
        cascadeDelete = cfg.cascadeDelete,
    })
end

function components.newFFIRelationship<R is Relationship>(config: FFIRelationshipOptions<R>): R
    local cfg = assert(config, "Missing FFI relationship config")
    local name = assert(cfg.name, "Missing FFI relationship name")
    local container = assert(cfg.container, "Missing FFI relationship container")
    local fields = assert(cfg.fields, "Missing FFI relationship fields")

    -- Ensure target field is included in the FFI struct
    local allFields = {{"target", "int32_t"}}
    for i = 1, #fields do
        table.insert(allFields, fields[i])
    end

    local isSparse = cfg.sparse or false

    local ffiStorage = storage.newFFIStorage({
        name = name .. "_FFIRelationship",
        fields = allFields,
        metatable = cfg.metatable,
        perEntityComponent = not isSparse,  -- sparse relationships don't need per-instance IDs
    })

    -- Convert FFI field tuples to plain names so newRelationship can
    -- codegen `.new` (unpack-by-name into positional args for the ctor).
    -- `target` is part of the FFI struct but not a user-supplied field —
    -- it's always set by __call, so we skip it in the names list.
    local fieldNames: {string} = {}
    for i = 1, #fields do
        fieldNames[i] = fields[i][1]
    end

    -- Use newRelationship with the container and FFI storage. `storage`
    -- is an internal options field; same any-cast treatment as elsewhere.
    return (components.newRelationship as function(any): R)({
        name = name,
        container = container,
        fields = fieldNames,
        defaults = cfg.defaults,
        init = cfg.init,
        __call = (cfg as {string:any})["__call"],
        new = cfg.new,
        exclusive = cfg.exclusive,
        sparse = cfg.sparse,
        reverseIndex = cfg.reverseIndex,
        cascadeDelete = cfg.cascadeDelete,
        storage = ffiStorage,
        __internalStorageToken = INTERNAL_STORAGE_TOKEN,
    })
end

-------------------------------------------------------------------------------
-- Tags (marker components with no data)
-------------------------------------------------------------------------------

function components.newTagComponent(options: TagComponentOptions): Component
    local container = options.container or {}
    return (components.newComponent as function(any): Component)({
        name = assert(options.name, "Missing tag component name"),
        container = container,
        storage = storage.newBitsetStorage(container),
        __internalStorageToken = INTERNAL_STORAGE_TOKEN,
        requires = options.requires,
    })
end

function components.newScalarComponent<T>(
    options: ScalarComponentOptions<T>
): types.components.ScalarComponent<T>
    local opts = assert(options, "Missing scalar component options")
    -- Scalars hold the raw primitive in the column; there's no instance
    -- shape worth exposing, so we always allocate a fresh handle.
    local container = {} as types.components.ScalarComponent<T>
    local kind = assert(opts.kind, "Missing scalar component kind")
    local defaultValue = opts.default as any

    -- Keep scalar storage truly scalar (no table/object payloads).
    if kind ~= "number" and kind ~= "boolean" and kind ~= "string" then
        error("Scalar component " .. tostring(opts.name) ..
            ": `kind` must be one of 'number', 'boolean', or 'string'")
    end

    -- Zero-value defaults by kind when omitted.
    if defaultValue == nil then
        if kind == "number" then
            defaultValue = 0
        elseif kind == "boolean" then
            defaultValue = false
        else
            defaultValue = ""
        end
    end

    -- `newComponent` provides scalar-specific callFn, `.new`, serialize, and
    -- deserialize for storageType=="scalar" — no need to forward them here.
    local component = ((components.newComponent as function(any): any)({
        name = assert(opts.name, "Missing scalar component name"),
        container = container,
        storage = storage.newScalarStorage(kind, defaultValue),
        __internalStorageToken = INTERNAL_STORAGE_TOKEN,
        requires = opts.requires,
    })) as types.components.ScalarComponent<T>

    local cAny = component as {string:any}
    cAny.scalarKind = kind
    cAny.scalarDefault = defaultValue
    return component
end

-------------------------------------------------------------------------------
-- FFI component logic
-------------------------------------------------------------------------------

function components.newFFIComponent<C is Component>(options: FFIComponentOptions<C>): C
    local opts = assert(options, "Missing FFI component options")
    assert(opts.name, "Missing component name")
    assert(opts.container, "Missing component container")
    assert(opts.fields, "Missing FFI fields definition")

    -- Create FFI storage
    local componentStorage = storage.newFFIStorage({
        name = opts.name,
        fields = opts.fields,
        metatable = opts.metatable
    })

    -- Codegen a default `.new(data)` from `opts.fields` if the caller didn't
    -- supply one. FFI `opts.fields` is `{{name, ctype}, ...}`; we extract the
    -- names and route through `__call` so init-managed runtime state
    -- (GPU slots, etc.) gets freshly allocated on reconstruction.
    local newFn = opts.new
    if not newFn then
        local fieldNames = opts.fields
        local container = opts.container
        local names: {string} = {}
        for i = 1, #fieldNames do
            names[i] = fieldNames[i][1]
        end
        newFn = ComponentCodegen.createNewFn(container, names) as function(data: {string: any}): C
    end

    -- Create the component. `serialize` / `deserialize` fall through to
    -- FFIStorage's field-walk pair (used by the JSON/table writer path).
    local component = (components.newComponent as function(any): C)({
        name = opts.name,
        container = opts.container,
        fields = opts.fields,
        defaults = opts.defaults,
        __call = (opts as {string:any})["__call"],
        init = opts.init,
        storage = componentStorage,
        __internalStorageToken = INTERNAL_STORAGE_TOKEN,
        serialize = opts.serialize,
        deserialize = opts.deserialize,
        new = newFn,
        requires = opts.requires,
    })

    -- Expose FFIStorage's buffer-direct raw path on the container. Binary
    -- writers (e.g. snapshot's BufferWriter) can use these to copy struct
    -- bytes straight into / out of a LuaJIT `string.buffer` with zero
    -- Lua-side allocations per component.
    --
    -- Callers that supplied their own `serialize` / `deserialize` already
    -- signalled "my runtime state doesn't survive a raw memcpy" (e.g. `Text`
    -- needs its init hook to register slab / glyph block state), so skip
    -- the raw install in that case and let the structured path run.
    local anyStorage = componentStorage as {string: any}
    local componentI = component as ComponentInternal
    if anyStorage.serializeRaw and not opts.serialize then
        componentI.serializeRaw = function(inst: Component, buf: any)
            (anyStorage.serializeRaw as function(Storage, Component, any))(componentStorage, inst, buf)
        end
    end
    if anyStorage.deserializeRaw and not opts.deserialize then
        componentI.deserializeRaw = function(buf: any): Component
            return (anyStorage.deserializeRaw as function(Storage, any): Component)(componentStorage, buf)
        end
    end

    -- Schema fingerprint + struct size for FFI components. Snapshot's
    -- `BufferWriter` uses these to bulk-memcpy whole columns and to detect
    -- schema drift between save/load. Non-FFI components leave both nil
    -- and snapshot falls back to per-entity serialize/deserialize.
    if anyStorage._fingerprint then
        (component as {string: any}).fingerprint = anyStorage._fingerprint
        (component as {string: any}).structSize = anyStorage._structSize
    end

    return component
end

return components
