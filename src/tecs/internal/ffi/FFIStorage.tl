--- FFI-based component storage implementation for high performance.
--- Provides zero-copy batch operations and efficient memory management.

local types <const> = require("tecs.types")
local storage <const> = require("tecs.internal.storage")
local componentIds <const> = require("tecs.internal.componentIds")
local C <const> = require("ffi")
local schema <const> = require("tecs.internal.ffi.schema")

local type Storage = storage.Storage

local max <const> = math.max
local min <const> = math.min
local select <const> = select

-- Maps a column pointer to the opaque holder that owns its backing memory
-- (set only for columns allocated through a per-storage allocator, see
-- `setColumnAllocator`). Weak keys so the entry, and the backing, drop when the
-- column pointer is no longer referenced.
local byteDataByColumn <const> = setmetatable({}, {__mode = "k"}) as {any: any}

-- Module definition
local record FFIStorage
    --- Configuration options for FFI storage.
    record StructDefinition
        --- Optional struct name (auto-generated if not provided)
        name: string
        --- Field tuples {name, type} where type can include array syntax like "float[16]"
        fields: {{string, string}}
        --- Size of the struct in bytes
        sizeof: integer
        --- Optional metatable to apply to instances (for instance methods)
        metatable: {any:any}
        --- If true, each instance is its own component type (for dense relationships)
        perEntityComponent: boolean
    end

    new: function(def: StructDefinition): Storage

    --- Define a C struct from a (name, fields) pair, cdef it with FFI
    --- (idempotent on same layout), and return the resolved ctype + size
    --- in bytes. Used by snapshot migration to materialise saved-schema
    --- structs at load time without going through the full storage setup.
    defineStruct: function(name: string, fields: {{string, string}}): any, integer

    --- The opaque holder owning a column pointer's backing memory, or nil if
    --- the column was allocated through the default `C.new` path. Used by the
    --- renderer to upload a column's backing straight to its SSBO.
    getColumnByteData: function(column: any): any
end

-- Growth constants for component storage
local INITIAL_CAPACITY <const> = 64

-- Keep track of defined structs with their definitions to detect collisions
local definedStructs: {string: string} = {}

-- Counter for auto-generated struct names
local structCounter = 0

-- Cache for FFI array ctypes (actual ctype objects, not strings)
local arrayTypeCache: {string: any} = {}

local record FieldInfo
    name: string
    isArray: boolean
    arraySize: integer
end

local record StructRegistryEntry
    cdef: string
    metadataFields: {string:any}
    instanceIds: {any: integer}
    metatypeInstalled: boolean
end

local structRegistry: {string: StructRegistryEntry} = {}

-- Metadata record for component storage arrays
local record StorageMeta
    capacity: integer
    structSize: integer
    arrayType: any
    structType: any
end

-- Global metadata table for component storage arrays
-- Weak keys allow GC to clean up old FFI cdata references
local storageMetadata: {any: StorageMeta} = setmetatable({}, {__mode = "k"})


-- Generate C struct definition from field tuples
local function generateStructDef(name: string, fieldTuples: {{string, string}}): string, {string}
    local parts: {string} = {"typedef struct { "}
    local fieldNames: {string} = {}
    local nFields = #fieldTuples

    for i = 1, nFields do
        local tuple = fieldTuples[i]
        local fieldName = tuple[1]
        local fieldType = tuple[2]

        -- Parse array syntax from the type (e.g., "float[16]" or "int32_t[4]")
        local baseType, arraySize = fieldType:match("^([^%[]+)%[(%d+)%]$")

        -- Add to C definition
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
    local field = (dst as {string:any})[fieldInfo.name] as {integer: any}
    for i = 0, fieldInfo.arraySize - 1 do
        local item = (value as {integer: any})[i]
        if item == nil then
            item = (value as {integer: any})[i + 1]
        end
        if item == nil then
            break
        end
        field[i] = item
    end
end

local function serializeArrayField(src: any, fieldInfo: FieldInfo): {any}
    local out: {any} = {}
    local field = (src as {string:any})[fieldInfo.name] as {integer: any}
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
        definedStructs[name] = cdef
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
    -- so their backing can be a love.data.ByteData. Default nil keeps `C.new`.
    local columnAllocator: function(integer, string): (any, any) = nil

    -- Use provided name or generate one
    local structName = def.name
    if not structName then
        structCounter = structCounter + 1
        structName = "FFIComponent" .. structCounter
    end

    -- Generate struct definition from tuples
    local cdef, fieldNames = generateStructDef(structName, def.fields as {{string, string}})
    local nFields <const> = #fieldNames
    local fieldInfo = buildFieldInfo(def.fields as {{string, string}})

    -- Canonical schema fingerprint: "name1:type1,name2:type2|sizeBytes".
    -- Used by snapshot to detect schema drift across save/load. Computed once
    -- here at registration; consumers compare via interned string equality.
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
        definedStructs[structName] = cdef
    end

    local metadataFields = registryEntry.metadataFields

    -- For per-entity components, each instance needs unique componentId
    -- Use a weak-keyed table to map instances to their unique IDs
    if def.perEntityComponent and not registryEntry.instanceIds then
        registryEntry.instanceIds = setmetatable({}, {__mode = "k"})
    end
    local instanceIds = registryEntry.instanceIds

    -- Define the metatype if not already defined
    if not registryEntry.metatypeInstalled then
        -- Construct metatable for the struct type
        -- For per-entity components (dense relationships), instance IS the component type
        local indexFn: function(any, any): any
        local tostringFn: function(any): string
        if def.perEntityComponent then
            -- Per-entity components need unique componentId per target
            -- The first field is the target (either "target" or "entityTarget")
            local targetField = fieldNames[1]
            indexFn = function(self: any, key: any): any
                if key == "componentType" then
                    return self
                elseif key == "componentId" then
                    return instanceIds[self]
                end
                return (metadataFields as {any:any})[key]
            end

            tostringFn = function(self: any): string
                local target = (self as {string:integer})[targetField]
                return structName .. "(" .. target .. ")"
            end
        else
            indexFn = function(_self: any, key: any): any
                return (metadataFields as {any:any})[key]
            end

            tostringFn = function(_self: any): string
                return structName
            end
        end

        local mt: {any:any} = {
            __tostring = tostringFn,
            __index = indexFn
        }

        -- Merge user-provided metatable if present
        if def.metatable then
            for k, v in pairs(def.metatable as {any:any}) do
                if k == "__index" then
                    -- Merge __index tables
                    if type(v) == "table" then
                        for method, impl in pairs(v as {any:any}) do
                            (metadataFields as {any:any})[method] = impl
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

    -- Get struct size
    local structSize = def.sizeof or C.sizeof(structName)

    -- Cache array ctype for fast allocation
    local arrayTypeName = structName .. "[?]"
    local arrayType = arrayTypeCache[arrayTypeName]
    if not arrayType then
        arrayType = C.typeof(arrayTypeName)
        arrayTypeCache[arrayTypeName] = arrayType
    end

    -- Cache struct type for fast instantiation
    local structType = C.typeof(structName)

    -- Create constructor function for this struct type
    local function createInstance(...: any): types.components.Component
        local instance: any = C.new(structType)

        local nargs = select('#', ...)

        if nargs == 0 then
            -- No arguments, FFI zero-initialization is sufficient
        elseif nargs == 1 and type(select(1, ...)) == "table" then
            -- Table argument - copy only known fields
            local value = select(1, ...) as {string:any}
            for i = 1, nFields do
                local info = fieldInfo[i]
                local k = info.name
                local v = value[k]
                if v ~= nil then
                    if info.isArray then
                        copyArrayField(instance as {string:any}, info, v)
                    else
                        (instance as {string:any})[k] = v
                    end
                end
            end
        else
            -- Positional arguments - apply to zero-initialized instance.
            --
            -- Hardcode 1..4 field unrolls instead of a `for i=1,count do select(i, ...) end` loop.
            -- `select(i, ...)` with a variable index is NYI on LuaJIT traces.
            local inst = instance as {string:any}
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

        -- For per-entity components, allocate unique ID
        if instanceIds then
            local componentId = componentIds.allocate()
            instanceIds[instance] = componentId
        end

        return instance as types.components.Component
    end

    -- Fast array growth function
    local function growArray<T>(oldArray: C.CData, usedCount: integer, neededCapacity: integer): T
        local newCapacity = neededCapacity
        -- Allocate new array with padding at index 0
        local newArray: C.CData
        if columnAllocator then
            local ptr, holder = columnAllocator((newCapacity + 1) * structSize, structName)
            byteDataByColumn[ptr] = holder
            newArray = ptr as C.CData
        else
            newArray = C.new(arrayType as C.CType, newCapacity + 1)
        end

        -- Copy old data if exists
        if oldArray and usedCount > 0 then
            -- Copy only used data including padding at index 0
            local copyCount = min(usedCount, newCapacity)
            C.copy(newArray, oldArray, (copyCount + 1) * structSize)
        end

        -- Update metadata
        storageMetadata[newArray] = {
            capacity = newCapacity,
            structSize = structSize,
            arrayType = arrayType,
            structType = structType
        }

        -- Clean up old metadata
        if oldArray then
            storageMetadata[oldArray] = nil
        end

        return newArray as T
    end

    return {
        storageType = "ffi",

        createColumn = function(_self: Storage, size: integer): {types.components.Component}
            -- Allocate FFI array with aggressive initial sizing
            local capacity = max(INITIAL_CAPACITY, size * 2)
            local data: C.CData
            if columnAllocator then
                local ptr, holder = columnAllocator((capacity + 1) * structSize, structName)
                byteDataByColumn[ptr] = holder
                data = ptr as C.CData
            else
                data = C.new(arrayType as C.CType, capacity + 1)  -- +1 for padding at index 0
            end

            -- Store metadata
            storageMetadata[data] = {
                capacity = capacity,
                structSize = structSize,
                arrayType = arrayType,
                structType = structType
            }

            return data as {types.components.Component}
        end,

        clear = function(_self: Storage, column: {types.components.Component})
            -- Zero out the array for consistency
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
            _self: Storage,
            column: {types.components.Component},
            needed: integer
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
        -- of capacity — avoids thrashing for workloads that grow and drop
        -- a handful of entities. Thresholds mirror `ffi.adjustCapacityDouble`.
        adjustCapacity = function(
            _self: Storage,
            column: {types.components.Component},
            usedCount: integer
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

        -- Provide a constructor that will be used by newComponent
        createComponent = function(_self: Storage,container: types.components.Component): function(...: any): types.components.Component
            -- Populate the metadata table with component info
            if container then
                metadataFields.componentType = container
                metadataFields.componentName = structName
                metadataFields.componentId = (container as {string:any}).componentId
                metadataFields.storage = (container as {string:any}).storage
                metadataFields.storageType = (container as {string:any}).storageType
            end
            return function(...: any): types.components.Component
                return createInstance(...)
            end
        end,

        _sizeof = structSize,
        -- Store field names for introspection (public for MCP/debugging)
        fieldNames = fieldNames,
        -- Marker for FFI storage detection in ecs.tl
        _ffiConstructor = true,
        -- Canonical schema fingerprint, copied to the container by
        -- `registerComponent`. Snapshot uses this to detect schema drift.
        _fingerprint = table.concat(schemaParts, ",") .. "|" .. structSize,
        _structSize = structSize,

        -- Set metadata on FFI instances (for lifecycle hooks like onAdd/onRemove)
        setMetadata = function(_self: Storage, key: string, value: any)
            metadataFields[key] = value
        end,

        -- Serialization: convert FFI instance to plain table
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

        -- Deserialization: create FFI instance from plain table
        deserialize = function(_self: Storage, data: {string: any}): types.components.Component
            return createInstance(data)
        end,

        -- Buffer-direct raw serialize: append the struct's bytes straight
        -- into a LuaJIT `string.buffer` via `buf:putcdata`. No intermediate
        -- Lua-string allocation, no per-field boxing. POD structs only;
        -- portable across LuaJIT on the same architecture.
        serializeRaw = function(_self: Storage, instance: types.components.Component, buf: any)
            local put <const> = (buf as {string: function}).putcdata as function(any, any, integer)
            put(buf, instance, structSize)
        end,

        -- Buffer-direct raw deserialize: allocate a blank instance of the
        -- struct type and blit the next `structSize` bytes from the buffer
        -- into it. Uses `buf:ref()` + `buf:skip()` so no Lua string is
        -- materialised on the read path either.
        deserializeRaw = function(_self: Storage, buf: any): types.components.Component
            local instance: any = C.new(structType)
            local ref <const> = (buf as {string: function}).ref as function(any): any
            local skip <const> = (buf as {string: function}).skip as function(any, integer)
            local ptr = ref(buf)
            C.copy(instance, ptr as C.CData, structSize)
            skip(buf, structSize)
            if instanceIds then
                local componentId = componentIds.allocate()
                instanceIds[instance] = componentId
            end
            return instance as types.components.Component
        end
    } as Storage
end

function FFIStorage.getColumnByteData(column: any): any
    return byteDataByColumn[column]
end

return FFIStorage
