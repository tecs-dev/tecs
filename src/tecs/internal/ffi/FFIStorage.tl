--- FFI-backed component storage. Columns are contiguous cdata arrays, which
--- enables bulk copies, raw snapshot IO, and optional GPU-uploadable backing.

local types <const> = require("tecs.types")
local storage <const> = require("tecs.internal.storage")
local componentids <const> = require("tecs.internal.componentids")
local C <const> = require("ffi")
local schema <const> = require("tecs.internal.ffi.schema")
local StringBuffer <const> = require("string.buffer")

-- string.buffer methods live on one shared metatable; bind them once so
-- the raw per-instance codec paths skip a method fetch per call.
local BUF_PROBE <const> = StringBuffer.new()
local BUF_PUTCDATA <const> = (BUF_PROBE as {string: function}).putcdata as function(any, any, integer)
local BUF_REF <const> = (BUF_PROBE as {string: function}).ref as function(any): any
local BUF_SKIP <const> = (BUF_PROBE as {string: function}).skip as function(any, integer)

local max <const> = math.max
local min <const> = math.min
local select <const> = select

-- Maps a column pointer to the opaque holder that owns its backing memory
-- (set only for columns allocated through a per-storage allocator, see
-- `setColumnAllocator`). Weak keys so the entry, and the backing, drop when the
-- column pointer is no longer referenced.
local byteDataByColumn <const> = setmetatable({}, {__mode = "k"}) as {any: any}

local record FFIStorage
    interface Storage is storage.Storage
        --- Install an allocator whose returned transferable backing owns each
        --- FFI column. Used by GPU-mirrored component storage.
        setColumnAllocator: function(self, fn: function(integer, string): (any, any))
    end

    record StructDefinition
        --- Optional struct name (auto-generated if not provided)
        name: string
        --- Field tuples {name, type} where type can include array syntax like "float[16]"
        fields: {{string, string}}
        --- Optional metatable to apply to instances (for instance methods)
        metatable: {any: any}
        --- If true, each instance is its own component type (for dense relationships)
        perEntityComponent: boolean
        --- Stable ECS component name used to recognize an insulated module reload.
        bindingName: string
    end

    new: function(def: StructDefinition): Storage

    --- Define a C struct and return its ctype plus size. Reusing a name is
    --- allowed only with the same layout. Snapshot migration uses this to
    --- materialise saved schemas without creating a full storage object.
    defineStruct: function(name: string, fields: {{string, string}}): any, integer

    --- The opaque holder owning a column pointer's backing memory, or nil if
    --- the column was allocated through the default `C.new` path. Used by the
    --- renderer to upload a column's backing straight to its SSBO.
    getColumnByteData: function(column: any): any
end

local type Storage = FFIStorage.Storage

-- Minimum logical capacity for a new FFI column. Columns allocate one extra
-- element at index 0 because archetype rows are 1-based.
local INITIAL_CAPACITY <const> = 64

local record FieldInfo
    name: string
    isArray: boolean
    arraySize: integer
end

local record StructRegistryEntry
    cdef: string
    metadataFields: {string: any}
    instanceIds: {any: integer}
    metatypeInstalled: boolean
end

-- LuaJIT owns cdefs and metatypes for the lifetime of the VM, which is longer
-- than a Lua module under loaders that isolate `package.loaded` (notably
-- Busted's default per-spec-file insulation). Keep the registry beside the FFI
-- runtime as well: a reloaded FFIStorage module must update the metadata table
-- captured by the already-installed metatype, not a new unreachable table.
local record RuntimeRegistry
    structCounter: integer
    structRegistry: {string: StructRegistryEntry}
    arrayTypeCache: {string: any}
end

local CAny <const> = C as {string: any}
local RUNTIME_REGISTRY_KEY <const> = "__tecsFFIStorageRegistry"
local runtimeRegistry = CAny[RUNTIME_REGISTRY_KEY] as RuntimeRegistry
if not runtimeRegistry then
    runtimeRegistry = {
        structCounter = 0,
        structRegistry = {},
        arrayTypeCache = {},
    }
    CAny[RUNTIME_REGISTRY_KEY] = runtimeRegistry
end
local structRegistry <const> = runtimeRegistry.structRegistry
local arrayTypeCache <const> = runtimeRegistry.arrayTypeCache

local record StorageMeta
    capacity: integer
    structSize: integer
    arrayType: any
    structType: any
end

-- Per-column metadata keyed by cdata pointer. Weak keys let resized or dropped
-- columns disappear without explicit cleanup on every path.
local storageMetadata: {any: StorageMeta} = setmetatable({}, {__mode = "k"})

local function generateStructDef(name: string, fieldTuples: {{string, string}}): string, {string}
    local parts: {string} = {"typedef struct { "}
    local fieldNames: {string} = {}
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

local function buildFieldInfo(fieldTuples: {{string, string}}): {FieldInfo}
    local infos: {FieldInfo} = {}
    for i = 1, #fieldTuples do
        local tuple = fieldTuples[i]
        local baseType, arraySize = tuple[2]:match("^([^%[]+)%[(%d+)%]$")
        infos[i] = {
            name = tuple[1],
            isArray = baseType ~= nil,
            arraySize = arraySize and (tonumber(arraySize) as integer) or 0,
        }
    end
    return infos
end

local function copyArrayField(dst: any, fieldInfo: FieldInfo, value: any)
    local field = (dst as {string: any})[fieldInfo.name] as {integer: any}
    local src = value as {integer: any}
    -- Sources are 0-based (FFI arrays) or 1-based (Lua tables, including
    -- serializeArrayField output). Pick the base once; probing per index
    -- shifts elements when a 1-based source is read at both bases.
    local base = src[0] == nil and 1 or 0
    for i = 0, fieldInfo.arraySize - 1 do
        local item = src[i + base]
        if item == nil then
            break
        end
        field[i] = item
    end
end

local function serializeArrayField(src: any, fieldInfo: FieldInfo): {any}
    local out: {any} = {}
    local field = (src as {string: any})[fieldInfo.name] as {integer: any}
    for i = 0, fieldInfo.arraySize - 1 do
        out[i + 1] = field[i]
    end
    return out
end

function FFIStorage.defineStruct(name: string, fields: {{string, string}}): any, integer
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
    local size = C.sizeof(structType) as integer
    return structType, size
end

function FFIStorage.new(def: FFIStorage.StructDefinition): Storage
    -- Fields must be in tuple format
    assert(def.fields, "FFI storage requires 'fields' array")
    assert(#def.fields > 0, "FFI storage requires at least one field")
    assert(type(def.fields[1]) == "table", "FFI storage fields must be in tuple format: {{name, type}, ...}")

    schema.validateFields(def.fields as {schema.FieldDef})

    -- Per-storage column allocator. When the renderer marks this component's
    -- storage GPU-uploadable (via the storage's `setColumnAllocator`), columns
    -- are allocated through this `fn(byteCount, structName) -> (ptr, holder)`
    -- so their backing can be memory the GPU side owns rather than this one's.
    -- Default nil keeps `C.new`.
    local columnAllocator: function(integer, string): (any, any) = nil

    local structName = def.name
    if not structName then
        runtimeRegistry.structCounter = runtimeRegistry.structCounter + 1
        structName = "FFIComponent" .. runtimeRegistry.structCounter
    end

    local cdef, fieldNames = generateStructDef(structName, def.fields as {{string, string}})
    local nFields <const> = #fieldNames
    local fieldInfo = buildFieldInfo(def.fields as {{string, string}})

    -- Canonical schema fingerprint: "name1:type1,name2:type2|sizeBytes".
    -- Snapshot compares this across save/load to detect schema drift.
    local schemaParts: {string} = {}
    for i = 1, #def.fields do
        local f = def.fields[i] as {string}
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

    -- Dense relationship instances are component types, so each cdata value
    -- needs a stable component id. Weak keys match cdata lifetime.
    if def.perEntityComponent and not registryEntry.instanceIds then
        registryEntry.instanceIds = setmetatable({}, {__mode = "k"})
    end
    local instanceIds = registryEntry.instanceIds

    if not registryEntry.metatypeInstalled then
        local indexFn: function(any, any): any
        local tostringFn: function(any): string
        if def.perEntityComponent then
            -- Dense relationship instances are their own component type. The
            -- first field is the relationship target id.
            local targetField = fieldNames[1]
            indexFn = function(self: any, key: any): any
                if key == "componentType" then
                    return self
                elseif key == "componentId" then
                    return instanceIds[self]
                end
                return (metadataFields as {any: any})[key]
            end

            tostringFn = function(self: any): string
                local target = (self as {string: integer})[targetField]
                return structName .. "(" .. target .. ")"
            end
        else
            indexFn = function(_self: any, key: any): any return (metadataFields as {any: any})[key] end

            tostringFn = function(_self: any): string return structName end
        end

        local mt: {any: any} = {__tostring = tostringFn, __index = indexFn}

        -- Merge user-provided metatable if present
        if def.metatable then
            for k, v in pairs(def.metatable as {any: any}) do
                if k == "__index" then
                    -- Merge __index tables
                    if type(v) == "table" then
                        for method, impl in pairs(v as {any: any}) do
                            (metadataFields as {any: any})[method] = impl
                        end
                    end
                else
                    -- Other metamethods replace defaults
                    mt[k] = v
                end
            end
        end

        C.metatype(structName, mt as metatable<any>)
        registryEntry.metatypeInstalled = true
    end

    local structSize = C.sizeof(structName) as integer
    local fingerprint = table.concat(schemaParts, ",") .. "|" .. structSize

    local arrayTypeName = structName .. "[?]"
    local arrayType = arrayTypeCache[arrayTypeName]
    if not arrayType then
        arrayType = C.typeof(arrayTypeName)
        arrayTypeCache[arrayTypeName] = arrayType
    end

    local structType = C.typeof(structName)

    local function createInstance(...: any): types.components.Component
        local instance: any = C.new(structType)

        local nargs = select("#", ...)

        if nargs == 0 then
            -- FFI zero-initialization is sufficient.
        elseif nargs == 1 and type(select(1, ...)) == "table" then
            -- Table form: copy only declared struct fields.
            local value = select(1, ...) as {string: any}
            for i = 1, nFields do
                local info = fieldInfo[i]
                local k = info.name
                local v = value[k]
                if v ~= nil then
                    if info.isArray then
                        copyArrayField(instance as {string: any}, info, v)
                    else
                        (instance as {string: any})[k] = v
                    end
                end
            end
        else
            -- Positional form: apply arguments to a zero-initialized instance.
            --
            -- Hardcode 1..4 field unrolls instead of a `for i=1,count do select(i, ...) end` loop.
            -- `select(i, ...)` with a variable index is NYI on LuaJIT traces.
            local inst = instance as {string: any}
            if nFields == 1 then
                local a = ...
                if nargs >= 1 and a ~= nil then
                    local info = fieldInfo[1]
                    if info.isArray then
                        copyArrayField(inst, info, a)
                    else
                        inst[info.name] = a
                    end
                end
            elseif nFields == 2 then
                local a, b = ...
                if nargs >= 1 and a ~= nil then
                    local info = fieldInfo[1]
                    if info.isArray then
                        copyArrayField(inst, info, a)
                    else
                        inst[info.name] = a
                    end
                end
                if nargs >= 2 and b ~= nil then
                    local info = fieldInfo[2]
                    if info.isArray then
                        copyArrayField(inst, info, b)
                    else
                        inst[info.name] = b
                    end
                end
            elseif nFields == 3 then
                local a, b, c = ...
                if nargs >= 1 and a ~= nil then
                    local info = fieldInfo[1]
                    if info.isArray then
                        copyArrayField(inst, info, a)
                    else
                        inst[info.name] = a
                    end
                end
                if nargs >= 2 and b ~= nil then
                    local info = fieldInfo[2]
                    if info.isArray then
                        copyArrayField(inst, info, b)
                    else
                        inst[info.name] = b
                    end
                end
                if nargs >= 3 and c ~= nil then
                    local info = fieldInfo[3]
                    if info.isArray then
                        copyArrayField(inst, info, c)
                    else
                        inst[info.name] = c
                    end
                end
            elseif nFields == 4 then
                local a, b, c, d = ...
                if nargs >= 1 and a ~= nil then
                    local info = fieldInfo[1]
                    if info.isArray then
                        copyArrayField(inst, info, a)
                    else
                        inst[info.name] = a
                    end
                end
                if nargs >= 2 and b ~= nil then
                    local info = fieldInfo[2]
                    if info.isArray then
                        copyArrayField(inst, info, b)
                    else
                        inst[info.name] = b
                    end
                end
                if nargs >= 3 and c ~= nil then
                    local info = fieldInfo[3]
                    if info.isArray then
                        copyArrayField(inst, info, c)
                    else
                        inst[info.name] = c
                    end
                end
                if nargs >= 4 and d ~= nil then
                    local info = fieldInfo[4]
                    if info.isArray then
                        copyArrayField(inst, info, d)
                    else
                        inst[info.name] = d
                    end
                end
            else
                -- Fallback for 5+ fields: collect varargs into a table (one alloc) and index by loop index.
                -- Still traceable because `args[i]` has static-type semantics unlike `select(i, ...)`.
                local args = {...}
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

        return instance as types.components.Component
    end

    -- Allocate a resized column and copy the live prefix, including index 0.
    local function growArray<T>(oldArray: C.CData, usedCount: integer, neededCapacity: integer): T
        local newCapacity = neededCapacity
        local newArray: C.CData
        if columnAllocator then
            local ptr, holder = columnAllocator((newCapacity + 1) * structSize, structName)
            byteDataByColumn[ptr] = holder
            newArray = ptr as C.CData
        else
            newArray = C.new(arrayType as C.CType, newCapacity + 1)
        end

        if oldArray and usedCount > 0 then
            local copyCount = min(usedCount, newCapacity)
            C.copy(newArray, oldArray, (copyCount + 1) * structSize)
        end

        storageMetadata[newArray] = {
            capacity = newCapacity, structSize = structSize, arrayType = arrayType, structType = structType
        }

        if oldArray then
            storageMetadata[oldArray] = nil
        end

        return newArray as T
    end

    return {
        storageType = "ffi",

        createColumn = function(_self: Storage, size: integer): {types.components.Component}
            local capacity = max(INITIAL_CAPACITY, size * 2)
            local data: C.CData
            if columnAllocator then
                local ptr, holder = columnAllocator((capacity + 1) * structSize, structName)
                byteDataByColumn[ptr] = holder
                data = ptr as C.CData
            else
                data = C.new(arrayType as C.CType, capacity + 1) -- +1 for padding at index 0
            end

            storageMetadata[data] = {
                capacity = capacity, structSize = structSize, arrayType = arrayType, structType = structType
            }

            return data as {types.components.Component}
        end,

        clear = function(_self: Storage, column: {types.components.Component})
            -- Keep retained capacity but clear stale values.
            local meta = storageMetadata[column]
            if meta then
                C.fill(column as C.CData, (meta.capacity + 1) * meta.structSize, 0)
            end
        end,

        -- Grow the column to EXACTLY the requested capacity. Any over-
        -- allocation policy (geometric, power-of-two padding, etc.) is
        -- applied at the Archetype layer in reserveCapacity, which calls
        -- us with the already-batched target size. Duplicating the grow
        -- factor here would waste memory.
        ensureCapacity = function(
            _self: Storage, column: {types.components.Component}, needed: integer
        ): {types.components.Component}
            local meta = storageMetadata[column]
            if meta and needed > meta.capacity then
                local usedCount = min(needed - 1, meta.capacity)
                return growArray(column as C.CData, usedCount, needed)
            end
            return column
        end,

        -- Shrink an over-allocated column. Only fires when the column is
        -- big enough to be worth shrinking AND usage fell below a fraction
        -- of capacity. This avoids thrashing for workloads that grow and drop
        -- a handful of entities. Thresholds mirror `ffi.adjustCapacityDouble`.
        adjustCapacity = function(
            _self: Storage, column: {types.components.Component}, usedCount: integer
        ): {types.components.Component}
            local meta = storageMetadata[column]
            if meta and meta.capacity >= 2048 and usedCount <= meta.capacity / 8 then
                local newCapacity = max(512, usedCount * 2)
                return growArray(column as C.CData, usedCount, newCapacity)
            end
            return column
        end,

        -- Route this storage's column allocation through `fn`, so its columns
        -- can be backed by GPU-uploadable memory (see `byteDataByColumn` /
        -- `getColumnByteData`). Set by the renderer for GPU-mirrored
        -- components. Columns created before this is set keep their backing
        -- until they next grow.
        setColumnAllocator = function(_self: Storage, fn: function(integer, string): (any, any))
            columnAllocator = fn
        end,

        createComponent = function(_self: Storage, container: types.components.Component): function(
            ...: any
        ): types.components.Component
            -- Shared fields exposed by every instance through the metatype.
            if container then
                -- The metatype is shared per struct name; a second
                -- component binding it would silently hijack the first's
                -- instances (world:set routes by instance.componentType).
                local bound = metadataFields.componentType as types.components.Component
                if bound ~= nil and bound ~= container then
                    -- An insulated module reload reconstructs the same named
                    -- component with a new Lua-table identity. Rebind it so
                    -- the VM-global metatype resolves current-generation
                    -- metadata. A differently named component is still a
                    -- real struct-name collision and must not steal it.
                    local nextName = def.bindingName or container.componentName
                    if bound.componentName ~= nextName then
                        error(
                            "FFI struct '"
                                .. structName
                                .. "' is already bound to component '"
                                .. tostring(bound.componentName)
                                .. "'; use a distinct struct name",
                            0
                        )
                    end
                end
                metadataFields.componentType = container
                metadataFields.componentName = structName
                metadataFields.componentId = (container as {string: any}).componentId
                metadataFields.storage = (container as {string: any}).storage
                metadataFields.storageType = (container as {string: any}).storageType
                -- Cdata relationship instances serve as archetype column
                -- keys; move plans and snapshot bulk paths classify FFI
                -- columns by `structSize`, so instances must expose it
                -- like plain FFI containers do.
                metadataFields.structSize = structSize
                metadataFields.fingerprint = fingerprint
            end
            -- The allocator is called for every FFI construction; hand out
            -- createInstance directly instead of a vararg forwarder.
            return createInstance
        end,

        _sizeof = structSize,
        -- Field names are used by debug/introspection tooling.
        fieldNames = fieldNames,
        -- Marker for raw cdata copy paths.
        _ffiConstructor = true,
        -- Canonical schema fingerprint, copied to the container by
        -- `registerComponent`. Snapshot uses this to detect schema drift.
        _fingerprint = fingerprint,
        _structSize = structSize,

        -- Set shared metadata read by FFI instances through their metatype.
        setMetadata = function(_self: Storage, key: string, value: any) metadataFields[key] = value end,

        -- Convert an FFI instance to a plain table for JSON-compatible snapshots.
        serialize = function(_self: Storage, instance: types.components.Component): {string: any}
            local data: {string: any} = {}
            for i = 1, nFields do
                local info = fieldInfo[i]
                if info.isArray then
                    data[info.name] = serializeArrayField(instance as {string: any}, info)
                else
                    data[info.name] = (instance as {string: any})[info.name]
                end
            end
            return data
        end,

        -- Rebuild an FFI instance from the table form.
        deserialize = function(_self: Storage, data: {string: any}): types.components.Component
            return createInstance(data)
        end,

        -- Buffer-direct raw serialize: append the struct's bytes straight
        -- into a LuaJIT `string.buffer` via `buf:putcdata`. No intermediate
        -- Lua-string allocation, no per-field boxing. POD structs only;
        -- portable across LuaJIT on the same architecture.
        serializeRaw = function(_self: Storage, instance: types.components.Component, buf: any)
            BUF_PUTCDATA(buf, instance, structSize)
        end,

        -- Buffer-direct raw deserialize: allocate a blank instance of the
        -- struct type and blit the next `structSize` bytes from the buffer
        -- into it. Uses `buf:ref()` + `buf:skip()` so no Lua string is
        -- materialised on the read path either.
        deserializeRaw = function(_self: Storage, buf: any): types.components.Component
            local instance: any = C.new(structType)
            local ptr = BUF_REF(buf)
            C.copy(instance, ptr as C.CData, structSize)
            BUF_SKIP(buf, structSize)
            if instanceIds then
                local componentId = componentids.allocate()
                instanceIds[instance] = componentId
            end
            return instance as types.components.Component
        end,
    } as Storage
end

function FFIStorage.getColumnByteData(column: any): any
    return byteDataByColumn[column]
end

return FFIStorage
