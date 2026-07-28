local types <const> = require("tecs.types")
local internal <const> = require("tecs.internal.types")
local storage <const> = require("tecs.internal.storage")
local componentcodegen <const> = require("tecs.internal.componentcodegen")
local componentids <const> = require("tecs.internal.componentids")
local behavior <const> = require("tecs.internal.behavior")
local bit <const> = require("bit")

local assert, table_concat <const> = assert, table.concat
local rshift <const> = bit.rshift

local type Relationship = types.components.Relationship
local type Component = types.components.Component
local type ComponentInternal = internal.ComponentInternal
local type Storage = storage.Storage
local type ComponentAllocator = types.components.ComponentAllocator
local type ComponentOptions<C is Component> = types.components.ComponentOptions<C>
local type TagComponentOptions = types.components.TagComponentOptions
local type FFIComponentOptions<C is Component> = types.components.FFIComponentOptions<C>
local type ScalarComponentOptions<T> = types.components.ScalarComponentOptions<T>
local type RelationshipOptions<R is Relationship> = types.components.RelationshipOptions<R>
local type FFIRelationshipOptions<R is Relationship> = types.components.FFIRelationshipOptions<R>

-- Internal implementation shape. Public Tealdoc lives on `tecs` and
-- `types.components`.
local record components
    newComponent: function<C is Component>(options: ComponentOptions<C>): C

    newTagComponent: function(options: TagComponentOptions): Component

    newFFIComponent: function<C is Component>(options: FFIComponentOptions<C>): C

    newScalarComponent: function<T>(options: ScalarComponentOptions<T>): types.components.ScalarComponent<T>

    newRelationship: function<R is Relationship>(config: RelationshipOptions<R>): R

    newFFIRelationship: function<R is Relationship>(config: FFIRelationshipOptions<R>): R

    -- Internal registration hook used after factories install storage and
    -- constructors.
    registerComponent: function<T is Component>(container: Component): T

    -- Mutable only inside this module.
    registeredComponents: {string: Component}
    componentsById: {integer: Component}
end

components.registeredComponents = {}
components.componentsById = setmetatable(
    {} as {integer: Component}, {__newindex = function() error("componentsById is read-only") end}
)

-------------------------------------------------------------------------------
-- Component creation
-------------------------------------------------------------------------------

function components.registerComponent<T is Component>(container: Component): T
    assert(container.componentName, "Missing component name when registering component")
    assert(container.componentType, "Missing component type when registering component")

    if components.registeredComponents[container.componentName] then
        error("Component " .. container.componentName .. " already registered")
    end

    -- Own-field check: dense relationship instances resolve the container
    -- through their metatable, and inheriting the container's id would give
    -- every instance one shared signature bit and clobber componentsById.
    if not rawget(container as {any: any}, "componentId") then
        container.componentId = componentids.allocate()
    end

    local componentI = container as ComponentInternal
    local signatureIndex = container.componentId - 1
    componentI.signatureIndex = signatureIndex
    componentI.signatureWordIndex = rshift(signatureIndex, 5)

    components.registeredComponents[container.componentName] = container
    rawset(components.componentsById, container.componentId, container)
    return container
end

-- Table component instances do not store `componentType`; their metatable
-- resolves it through the container. This keeps each instance one field
-- smaller while preserving the public shape.
-- Module-local sentinel: internal factories (`newTagComponent`,
-- `newFFIComponent`, `newScalarComponent`, and the relationship variants)
-- pass this as `opts.__internalStorageToken` alongside their chosen
-- `storage`. Public `newComponent` rejects any user-supplied `opts.storage`
-- that doesn't include the sentinel. Keeps storage a fully internal
-- extension point; users pick a component kind via the factories instead.
local INTERNAL_STORAGE_TOKEN <const> = {} as any
local NOOP_INIT <const> = function(_instance: any) end

-- Metadata the relationship machinery stamps on table instances; the
-- fallback instance serializer excludes these (plus the `component*`
-- family) from payloads.
local INSTANCE_METADATA_KEYS <const>: {string: boolean} = {
    storage = true,
    storageType = true,
    relationshipType = true,
    exclusiveRelationship = true,
    wildcardContainer = true,
    isContainer = true,
    isSparseInstance = true,
    transient = true,
}

local function applyPositionalDefaults(instance: {string: any}, fields: {string}, defaults: {any})
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

function components.newComponent<C is Component>(options: ComponentOptions<C>): C
    local opts = assert(options, "Missing component options")
    local name = assert(opts.name, "Missing component name")
    local container = assert(opts.container, "Missing component container")
    local optsAny = opts as {string: any}
    local userStorage = optsAny.storage
    if userStorage ~= nil and optsAny.__internalStorageToken ~= INTERNAL_STORAGE_TOKEN then
        error(
            "Component "
                .. name
                .. ": `storage` is not a user option. "
                .. "Use one of newComponent / newTagComponent / newFFIComponent "
                .. "/ newScalarComponent (or the relationship variants) to pick "
                .. "a component layout."
        )
    end
    local componentStorage = userStorage as Storage or storage.newTableStorage()

    if opts.defaults and not opts.fields then
        error("Component " .. name .. ": `defaults` requires `fields`")
    end
    if opts.transient and opts.serialize then
        error("Component " .. name .. ": `transient` cannot be combined with `serialize`")
    end

    -- `init` without `fields` or `new` leaves `.new` with no way to
    -- unpack a table into positional args -- the fallback would forward the
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
    container.componentId = componentids.allocate()
    container.init = opts.init or NOOP_INIT
    containerI.requires = opts.requires
    containerI._hasRequires = opts.requires ~= nil and #opts.requires > 0
    containerI.transient = opts.transient == true
    -- `_requiresClosure` is built lazily on first use (first
    -- `world:set` / `world:spawn` that mentions this component) so
    -- late-registered dependencies are captured correctly.

    containerI.storage = componentStorage
    containerI.storageType = componentStorage.storageType

    local anyStorage = componentStorage as {string: any}

    -- Serialization priority: user-provided > storage-provided > default.
    if opts.transient then
        container.serialize = nil
    elseif opts.serialize then
        container.serialize = opts.serialize
    elseif componentStorage.storageType == "scalar" then
        -- `instance` may be either the raw column value (snapshot writer
        -- reads `col[row]` and hands it in directly) or a wrapper produced
        -- by `__call` (when callers serialize a freshly-constructed
        -- instance). Detect the wrapper shape and unwrap so the on-disk
        -- representation is always `{value = <raw>}`.
        container.serialize = function(instance: C): {string: any}
            if type(instance) == "table" and (instance as {string: any}).componentType == container then
                return {value = (instance as {string: any}).value}
            end
            return {value = instance as any}
        end
    elseif anyStorage.serialize then
        container.serialize = function(instance: C): {string: any}
            return (anyStorage.serialize as function(Storage, C): {string: any})(componentStorage, instance)
        end
    else
        -- Default table form: copy serializable user fields and skip ECS metadata.
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
            if data ~= nil then
                v = data.value
            end
            return (container as function(...: any): C)(v)
        end
    elseif anyStorage.deserialize then
        container.deserialize = function(_world: types.World, data: {string: any}): C
            return (anyStorage.deserialize as function(Storage, {string: any}): C)(componentStorage, data)
        end
    end
    -- Default deserialize (when neither user nor storage provides one) is
    -- installed below, after `.new` is ready -- it routes through `.new(data)`.

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
        -- while unreferenced entries get collected. Numeric/boolean kinds skip the cache -- arbitrary float keys
        -- would grow unbounded, and booleans aren't worth a cache lookup.
        local scalarDefault = (anyStorage._scalarDefault) as any
        local kind = (anyStorage._scalarKind) as string
        if kind == "string" then
            local cache = setmetatable({} as {string: any}, {__mode = "v"})
            callFn = function(_c: C, value?: any): C
                if value == nil then
                    value = scalarDefault
                end
                local hit = cache[value as string]
                if hit then
                    return hit as C
                end
                local w = {componentType = container, value = value}
                cache[value as string] = w
                return w as C
            end
        else
            callFn = function(_c: C, value?: any): C
                if value == nil then
                    value = scalarDefault
                end
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
                applyPositionalDefaults(instance as {string: any}, ffiFields, ffiDefaults)
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
        -- Fields codegen beats the storage default. `init` runs after the base
        -- instance has been allocated and populated.
        if customCall then
            local tableFields = opts.fields
            local tableDefaults = opts.defaults
            callFn = function(_c: C, ...: any): C
                local instance = setmetatable({} as {string: any}, tableInstanceMt as metatable<{string: any}>) as C
                applyPositionalDefaults(instance as {string: any}, tableFields, tableDefaults)
                customCall(instance, ...)
                return instance
            end
        else
            local baseCall: function(C, ...: any): C
            if opts.fields then
                local tableFields = opts.fields
                local generated = componentcodegen.createCallFn({
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

    -- Install `.new(data)`, the table-form constructor used by deserialize.
    -- Table-storage components wrap user-provided results with the same
    -- instance metatable used by `__call`.
    if opts.new then
        local userNew <const> = opts.new
        if tableInstanceMt then
            container.new = function(data: {string: any}): C return setmetatable(userNew(data), tableInstanceMt) end
        else
            container.new = userNew
        end
    elseif opts.fields then
        container.new = componentcodegen.createNewFn(container, opts.fields) as function(data: {string: any}): C
    elseif storageType == "scalar" then
        -- `.new({value=...})` routes through `__call` so it produces the
        -- same wrapper the positional form does.
        container.new = function(data: {string: any}): C
            local v: any
            if data ~= nil then
                v = data.value
            end
            return (container as function(...: any): C)(v)
        end
    else
        container.new = function(data: {string: any}): C return (container as function({string: any}): C)(data) end
    end

    -- If no explicit deserialize, route through `.new` for uniform table-form
    -- reconstruction. Storage-provided and user-provided paths already set
    -- container.deserialize above; this overrides only the default fallback.
    if not opts.deserialize and not anyStorage.deserialize then
        container.deserialize = function(_world: types.World, data: {string: any}): C return container.new(data) end
    end

    return components.registerComponent(container)
end

-------------------------------------------------------------------------------
-- Relationships
-------------------------------------------------------------------------------

local DEFAULT_RELATIONSHIP_CTOR <const> = function(_id: integer, _: any): Relationship return {} end

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
    if cfg.transient and cfg.serialize then
        error("Relationship " .. name .. ": `transient` cannot be combined with `serialize`")
    end

    -- Reject user-supplied `storage` on the public factory (only internal
    -- callers pass it, authenticated via the sentinel token).
    local cfgAny = cfg as {string: any}
    if cfgAny.storage ~= nil and cfgAny.__internalStorageToken ~= INTERNAL_STORAGE_TOKEN then
        error(
            "Relationship "
                .. name
                .. ": `storage` is not a user option. "
                .. "Use newRelationship / newFFIRelationship "
                .. "to pick a relationship layout."
        )
    end

    -- `init` without `fields` or `new` leaves `.new` with no way to
    -- unpack a table into positional args. Match the behavior of newComponent.
    if cfg.init and not cfg.fields and not cfg.new then
        error(
            "Relationship " .. name .. ": `init` requires either `fields` (auto-codegens `.new`) or an explicit `new`"
        )
    end

    -- Target-only edge (name plus flags, no data): the only datum is the
    -- target id, so route to the compact FFI layout instead of a Lua table
    -- per instance. Data-carrying relationships (with `container`/`fields`,
    -- a custom `new`, or internal `storage`) fall through to the paths below.
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
            serialize = (cfgAny.serialize as function(R): {string: any}),
            deserialize = (cfgAny.deserialize as function(types.World, {string: any}): R),
            __call = (cfgAny.__call as function(R, ...: any)),
        }) as R
    end

    -- `storage` is an internal options field (see newComponent). Cast.
    local relationshipStorage = (cfg as {string: any}).storage as Storage or storage.newTableStorage()

    -- Cache one relationship instance per target id.
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
    relContainerI.transient = cfg.transient == true

    -- The container is the wildcard/tag component; concrete relationship
    -- instances use relationshipStorage for their payload.
    local bitset = storage.newBitsetStorage(relContainer)
    relContainerI.storage = bitset
    relContainerI.storageType = bitset.storageType

    local ctor: function(integer, ...: any): R
    local customCall = cfgAny["__call"] as function(R, ...: any)
    if relationshipStorage.storageType == "ffi" then
        local relationshipFields = (cfg.fields or {}) as {string}
        local relationshipAllocator = relationshipStorage:createComponent(relContainer as Component) as function(
            ...: any
        ): any
        if customCall then
            local relationshipDefaults = cfg.defaults
            ctor = function(id: integer, ...: any): R
                local instance = relationshipAllocator(id) as R
                applyPositionalDefaults(instance as {string: any}, relationshipFields, relationshipDefaults)
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
                applyPositionalDefaults(instance as {string: any}, relationshipFields, relationshipDefaults)
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
    -- use it -- it knows the field layout. Otherwise iterate plain-table
    -- instances, skipping component metadata.
    local storageAny = relationshipStorage as {string: any}
    if cfg.transient then
        relContainer.serialize = nil
    elseif cfg.serialize then
        relContainer.serialize = cfg.serialize
    elseif storageAny.serialize then
        relContainer.serialize = function(instance: R): {string: any}
            return (storageAny.serialize as function(Storage, R): {string: any})(relationshipStorage, instance)
        end
    elseif cfg.fields then
        -- Declared fields ARE the payload: serialize exactly them plus
        -- the target. An allowlist cannot leak instance metadata, no
        -- matter what the relationship machinery stamps on instances
        -- later.
        local declaredFields <const> = cfg.fields as {string}
        relContainer.serialize = function(instance: R): {string: any}
            local inst = instance as {string: any}
            local data: {string: any} = {target = inst.target}
            for i = 1, #declaredFields do
                local f = declaredFields[i]
                data[f] = inst[f]
            end
            return data
        end
    else
        -- Custom `new` without declared fields: the instance shape is
        -- unknown, so fall back to scanning it minus the stamped
        -- metadata.
        relContainer.serialize = function(instance: R): {string: any}
            local data: {string: any} = {}
            for k, v in pairs(instance as {string: any}) do
                if
                    type(k) == "string"
                    and not (k as string):match("^component")
                    and not INSTANCE_METADATA_KEYS[k as string]
                then
                    local vtype = type(v)
                    if vtype == "number" or vtype == "string" or vtype == "boolean" or vtype == "table" then
                        data[k] = v
                    end
                end
            end
            return data
        end
    end

    -- Install `.new(data)` -- the table-form constructor.
    -- `data.target` is mandatory (relationships need a target); field values
    -- come from either `cfg.new` (user override) or unpacked by `cfg.fields`.
    -- Routes through `__call(target, ...)` so instance caching, registration,
    -- and target-stamping still happen the same way as for positional calls.
    if cfg.new then
        local userNew <const> = cfg.new
        relContainer.new = function(data: {string: any}): R return userNew(data) end
    elseif cfg.fields then
        relContainer.new = componentcodegen.createNewFn(
            relContainer, cfg.fields as {string}, {"target"}, {target = "Relationship .new: missing 'target' field"}
        ) as function(data: {string: any}): R
    else
        relContainer.new = function(data: {string: any}): R
            local target = data.target as integer
            assert(target, "Relationship .new: missing 'target' field")
            return (relContainer as function(integer, any): R)(target, data)
        end
    end

    if (cfg as {string: any}).deserialize then
        relContainer.deserialize = (cfg as {string: any}).deserialize as function(types.World, {string: any}): R
    else
        relContainer.deserialize = function(_world: types.World, data: {string: any}): R
            return relContainer.new(data)
        end
    end

    -- FFI-backed instances resolve metadata through a shared metatype,
    -- not a per-instance `__index = relContainer`; push the container's
    -- serializers into the metatype so snapshot save sees instance
    -- columns as serializable (nil for transient relationships keeps
    -- them excluded).
    if relationshipStorage.storageType == "ffi" then
        local setMeta = storageAny.setMetadata as function(Storage, string, any)
        setMeta(relationshipStorage, "serialize", relContainer.serialize)
        setMeta(relationshipStorage, "deserialize", relContainer.deserialize)
    end

    local instance_mt <const> = {
        __index = relContainer,
        __tostring = function(self: Relationship): string
            return table_concat({self.componentName, " -> ", self.target})
        end,
    }

    setmetatable(
        relContainer,
        {
            __tostring = function(self: R): string return self.componentName end,
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
                        -- FFI relationship metadata is installed on the storage
                        -- metatype, so cdata instances don't need table stamping.
                        cache[id] = instance
                    elseif isSparse then
                        -- Sparse table instances live in sparse storage, not in
                        -- archetype columns, so they are not registered.
                        local instanceI = instance as ComponentInternal
                        instance.target = id
                        instance.componentName = self.componentName .. "->" .. id
                        instance.componentType = self -- points to container, not self
                        instance.exclusiveRelationship = self.exclusiveRelationship
                        instance.relationshipType = self
                        instanceI.wildcardContainer = self as Component
                        instanceI.isContainer = false -- shadow the container's true via __index
                        instanceI.isSparseInstance = true
                        instanceI.storage = relationshipStorage
                        instanceI.storageType = relationshipStorage.storageType
                        instanceI.transient = relContainerI.transient
                        setmetatable(instance, instance_mt)
                        cache[id] = instance
                    else
                        local instanceI = instance as ComponentInternal
                        instance.target = id
                        instance.componentName = self.componentName .. "->" .. id
                        instance.componentType = instance
                        instance.exclusiveRelationship = self.exclusiveRelationship
                        instance.relationshipType = self
                        instanceI.wildcardContainer = self as Component
                        instanceI.isContainer = false -- shadow the container's true via __index
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
        }
    )

    -- Dense relationships can expose a concrete component type for queries.
    if not isSparse then
        relContainer.targeting = function(self: R, targetId: integer): R
            assert(targetId, "Missing target entity ID")
            if cfg.container then
                -- Data relationship: return component type for queries.
                return self(targetId).componentType as R
            else
                -- Target-only relationship: the instance is the component.
                return self(targetId)
            end
        end
    end

    if isSparse then
        relContainerI.frameworkBehavior = behavior.SparseRelationship
        relContainerI.frameworkBehaviorBits = behavior.sparseRelationshipBits()
    else
        -- Every dense relationship dispatches removes so the wildcard
        -- container drops with the last sibling instance, matching
        -- sparse semantics (marker present == at least one target).
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

function components.newFFIRelationship<R is Relationship>(config: FFIRelationshipOptions<R>): R
    local cfg = assert(config, "Missing FFI relationship config")
    local name = assert(cfg.name, "Missing FFI relationship name")
    local container = assert(cfg.container, "Missing FFI relationship container")
    local fields = assert(cfg.fields, "Missing FFI relationship fields")

    -- Ensure target field is included in the FFI struct. `target` holds a
    -- packed entity id (22-bit slot + 31-bit generation, up to 2^53), so it
    -- needs a double: an int32 truncates targets once generation passes ~512.
    local allFields = {{"target", "double"}}
    for i = 1, #fields do
        table.insert(allFields, fields[i])
    end

    local isSparse = cfg.sparse or false

    local ffiStorage = storage.newFFIStorage(
        {
            name = name .. "_FFIRelationship",
            bindingName = name,
            fields = allFields,
            metatable = cfg.metatable,
            perEntityComponent = not isSparse, -- sparse relationships don't need per-instance IDs
        }
    )

    -- Convert FFI field tuples to plain names so newRelationship can
    -- codegen `.new` (unpack-by-name into positional args for the ctor).
    -- `target` is part of the FFI struct but not a user-supplied field --
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
        __call = (cfg as {string: any})["__call"],
        new = cfg.new,
        exclusive = cfg.exclusive,
        sparse = cfg.sparse,
        reverseIndex = cfg.reverseIndex,
        cascadeDelete = cfg.cascadeDelete,
        transient = cfg.transient,
        serialize = (cfg as {string: any}).serialize,
        deserialize = (cfg as {string: any}).deserialize,
        storage = ffiStorage,
        __internalStorageToken = INTERNAL_STORAGE_TOKEN,
    })
end

-------------------------------------------------------------------------------
-- Tags (marker components with no data)
-------------------------------------------------------------------------------

function components.newTagComponent(options: TagComponentOptions): Component
    if options.transient and (options as {string: any}).serialize then
        error("Tag component " .. tostring(options.name) .. ": `transient` cannot be combined with `serialize`")
    end
    local container = options.container or {}
    return (components.newComponent as function(any): Component)({
        name = assert(options.name, "Missing tag component name"),
        container = container,
        storage = storage.newBitsetStorage(container),
        __internalStorageToken = INTERNAL_STORAGE_TOKEN,
        requires = options.requires,
        transient = options.transient,
    })
end

function components.newScalarComponent<T>(options: ScalarComponentOptions<T>): types.components.ScalarComponent<T>
    local opts = assert(options, "Missing scalar component options")
    if opts.transient and (opts as {string: any}).serialize then
        error("Scalar component " .. tostring(opts.name) .. ": `transient` cannot be combined with `serialize`")
    end
    -- Scalar columns store raw primitives. `newComponent` installs the small
    -- wrapper used only at spawn/set boundaries.
    local container = {} as types.components.ScalarComponent<T>
    local kind = assert(opts.kind, "Missing scalar component kind")
    local defaultValue = opts.default as any

    -- Keep scalar storage truly scalar (no table/object payloads).
    if kind ~= "number" and kind ~= "boolean" and kind ~= "string" then
        error("Scalar component " .. tostring(opts.name) .. ": `kind` must be one of 'number', 'boolean', or 'string'")
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
    -- deserialize for storageType=="scalar" -- no need to forward them here.
    local component = (
        (components.newComponent as function(any): any)({
            name = assert(opts.name, "Missing scalar component name"),
            container = container,
            storage = storage.newScalarStorage(kind, defaultValue),
            __internalStorageToken = INTERNAL_STORAGE_TOKEN,
            requires = opts.requires,
            transient = opts.transient,
        })
    ) as types.components.ScalarComponent<T>

    local cAny = component as {string: any}
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

    local componentStorage = storage.newFFIStorage({
        name = opts.name, bindingName = opts.name, fields = opts.fields, metatable = opts.metatable
    })

    -- Default `.new(data)` unpacks FFI field tuples by name and routes through
    -- `__call`, so init-managed runtime state is rebuilt on reconstruction.
    local newFn = opts.new
    if not newFn then
        local fieldNames = opts.fields
        local container = opts.container
        local names: {string} = {}
        for i = 1, #fieldNames do
            names[i] = fieldNames[i][1]
        end
        newFn = componentcodegen.createNewFn(container, names) as function(data: {string: any}): C
    end

    -- Structured serialize/deserialize fall through to FFIStorage unless the
    -- caller provided custom hooks.
    local component = (components.newComponent as function(any): C)({
        name = opts.name,
        container = opts.container,
        fields = opts.fields,
        defaults = opts.defaults,
        __call = (opts as {string: any})["__call"],
        init = opts.init,
        storage = componentStorage,
        __internalStorageToken = INTERNAL_STORAGE_TOKEN,
        serialize = opts.serialize,
        deserialize = opts.deserialize,
        new = newFn,
        requires = opts.requires,
        transient = opts.transient,
    })

    -- Expose FFIStorage's buffer-direct raw path on the container. Binary
    -- writers (e.g. snapshot's BufferWriter) can use these to copy struct
    -- bytes straight into / out of a LuaJIT `string.buffer` with zero
    -- Lua-side allocations per component.
    --
    -- The raw pair is all-or-nothing: snapshot's save side selects the
    -- column encoding by `serializeRaw` presence and its load side by
    -- `deserializeRaw` presence, so a component with only one custom hook
    -- must fall back to structured encoding in BOTH directions or the
    -- binary stream desyncs.
    local anyStorage = componentStorage as {string: any}
    local componentI = component as ComponentInternal
    if
        anyStorage.serializeRaw
        and anyStorage.deserializeRaw
        and not opts.serialize
        and not opts.deserialize
        and not opts.transient
    then
        componentI.serializeRaw = function(inst: Component, buf: any)
            (anyStorage.serializeRaw as function(Storage, Component, any))(componentStorage, inst, buf)
        end
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
