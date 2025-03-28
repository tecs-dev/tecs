--- FFI-based component storage implementation for high performance.
--- Provides zero-copy batch operations and efficient memory management.

local types <const> = require("tecs.types")
local storage <const> = require("tecs.internal.storage")
local libffi = require("tecs.internal.ffi.libffi")

-- Check FFI availability first
local ffiAvailable <const> = libffi.isFFIAvailable()
local ffi_native = ffiAvailable and libffi.getFFI() or nil
local max <const> = math.max

local ffi_new = ffiAvailable and ffi_native.new or nil
local ffi_copy = ffiAvailable and ffi_native.copy or nil
local ffi_fill = ffiAvailable and ffi_native.fill or nil
local ffi_sizeof = ffiAvailable and ffi_native.sizeof or nil
local ffi_typeof = ffiAvailable and ffi_native.typeof or nil

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
        --- Enable struct recycling to reuse components
        recycle: boolean
        --- Size of the recycle pool (defaults to 64 if not specified)
        recyclePoolSize: integer
    end

    new: function(def: StructDefinition): types.Storage
end

-- Growth constants for component storage
local INITIAL_CAPACITY <const> = 64

-- Keep track of defined structs to avoid redefinition
local definedStructs: {string: boolean} = {}

-- Counter for auto-generated struct names
local structCounter = 0

-- Cache for FFI array types
local arrayTypeCache: {string: any} = {}

-- Metadata record for component storage arrays
local record StorageMeta
    capacity: integer
    structSize: integer
    arrayType: any
    structType: any
end

-- Global metadata table for component storage arrays
local storageMetadata: {any: StorageMeta} = {}


-- Generate C struct definition from field tuples
local function generateStructDef(name: string, fieldTuples: {{string, string}}): string, {string}
    local cdef = "typedef struct { "
    local fieldNames: {string} = {}

    for _, tuple in ipairs(fieldTuples) do
        local fieldName = tuple[1]
        local fieldType = tuple[2]

        -- Parse array syntax from the type (e.g., "float[16]" or "int32_t[4]")
        local baseType, arraySize = fieldType:match("^([^%[]+)%[(%d+)%]$")

        -- Add to C definition
        if baseType and arraySize then
            -- Fixed-size array
            cdef = cdef .. baseType .. " " .. fieldName .. "[" .. arraySize .. "]; "
        else
            -- Regular field
            cdef = cdef .. fieldType .. " " .. fieldName .. "; "
        end

        -- Track field name
        table.insert(fieldNames, fieldName)
    end

    cdef = cdef .. "} " .. name .. ";"
    return cdef, fieldNames
end

function FFIStorage.new(def: FFIStorage.StructDefinition): types.Storage
    if not ffiAvailable then
        error("FFI storage requires FFI support - cannot create FFI storage when FFI is not available")
    end

    -- Fields must be in tuple format
    assert(def.fields, "FFI storage requires 'fields' array")
    assert(#def.fields > 0, "FFI storage requires at least one field")
    assert(type(def.fields[1]) == "table", "FFI storage fields must be in tuple format: {{name, type}, ...}")

    -- Use provided name or generate one
    local structName = def.name
    if not structName then
        structCounter = structCounter + 1
        structName = "FFIComponent" .. structCounter
    end

    -- Generate struct definition from tuples
    local cdef, fieldNames = generateStructDef(structName, def.fields as {{string, string}})

    -- Define the struct if not already defined
    if not definedStructs[structName] then
        ffi_native.cdef(cdef)
        definedStructs[structName] = true
    end

    -- Get struct size
    local structSize = def.sizeof or ffi_sizeof(structName)

    -- Cache array type for fast allocation
    local arrayTypeName = structName .. "[?]"
    local arrayType = arrayTypeCache[arrayTypeName]
    if not arrayType then
        -- Create the array type string directly for ffi.new
        arrayType = arrayTypeName
        arrayTypeCache[arrayTypeName] = arrayType
    end

    -- Cache struct type for fast instantiation
    local structType = ffi_typeof(structName)


    -- Create shared metadata table for fast lookup
    local metadataFields: {string:any} = {}

    -- Recycling pool for FFI components
    local recyclePoolSize = def.recyclePoolSize or 64  -- Default to 64 if not specified
    local recyclePool: {any} = nil
    local recycleCount = 0
    local recycleEnabled = def.recycle or false
    local recycleMaxSize = recyclePoolSize  -- Track max size for dynamic growth

    -- Initialize recycle pool if enabled
    if recycleEnabled then
        recyclePool = {}
        -- Pre-allocate the pool
        for i = 1, recyclePoolSize do
            recyclePool[i] = ffi_new(structName)
        end
        recycleCount = recyclePoolSize
    end

    -- metatable for the struct type
    ffi_native.metatype(structName, {
        __tostring = function(_self: any): string
            return structName
        end,
        __index = metadataFields
    })

    -- Create constructor function for this struct type
    local function createInstance(_storageInstance: any, ...: any): types.Component
        local instance: any

        -- Check if we can use a recycled instance
        if recycleEnabled and recycleCount > 0 then
            instance = recyclePool[recycleCount]
            recycleCount = recycleCount - 1
        else
            -- Allocate a new instance (FFI automatically zero-initializes)
            instance = ffi_new(structName)
        end

        local args = {...}
        local nargs = select('#', ...)

        if nargs == 0 then
            -- No arguments, FFI zero-initialization is sufficient
            -- Do nothing - instance is already properly initialized
        elseif nargs == 1 and type(args[1]) == "table" then
            -- Table argument - apply provided values to zero-initialized instance
            local value = args[1] as {string:any}
            for k, v in pairs(value) do
                (instance as {string:any})[k] = v
            end
        else
            -- Positional arguments - apply to zero-initialized instance
            for i = 1, math.min(nargs, #fieldNames) do
                local fieldName = fieldNames[i]
                (instance as {string:any})[fieldName] = args[i]
            end
        end

        return instance as types.Component
    end

    -- Fast array growth function
    local function growArray<T>(oldArray: libffi.CData, usedCount: integer, neededCapacity: integer): T
        -- neededCapacity is already the calculated optimal capacity, don't recalculate
        local newCapacity = neededCapacity
        -- Allocate new array with padding at index 0
        local newArray = ffi_new(arrayType as string, newCapacity + 1)

        -- Copy old data if exists
        if oldArray and usedCount > 0 then
            -- Copy only used data including padding at index 0
            -- Make sure we don't copy more than what actually exists
            local copyCount = math.min(usedCount, newCapacity)
            ffi_copy(newArray, oldArray, (copyCount + 1) * structSize)
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
        new = function(_self: types.Storage, size: integer): {types.Component}
            -- Allocate FFI array with aggressive initial sizing
            local capacity = max(INITIAL_CAPACITY, size * 2)
            local data = ffi_new(arrayType as string, capacity + 1)  -- +1 for padding at index 0

            -- Store metadata
            storageMetadata[data] = {
                capacity = capacity,
                structSize = structSize,
                arrayType = arrayType,
                structType = structType
            }

            return data as {types.Component}
        end,

        clear = function(_self: types.Storage, column: {types.Component})
            -- Zero out the array for consistency
            local meta = storageMetadata[column]
            if meta then
                ffi_fill(column as libffi.CData, (meta.capacity + 1) * meta.structSize, 0)
            end
        end,

        -- Ensure capacity function for explicit growth
        ensureCapacity = function(
            _self: types.Storage,
            column: {types.Component},
            needed: integer
        ): {types.Component}
            local meta = storageMetadata[column]
            if meta and needed > meta.capacity then
                local newCapacity = storage.calculateOptimalCapacity(needed, meta.capacity)
                -- For dense arrays in archetypes, we preserve data that was actually written
                -- In staging archetypes, elements are filled sequentially, so we preserve
                -- up to the current write position (which is needed - 1 in 1-indexed arrays)
                local usedCount = math.min(needed - 1, meta.capacity)
                return growArray(column as libffi.CData, usedCount, newCapacity)
            end
            return column
        end,


        -- Provide a constructor that will be used by newComponent
        createComponent = function(
            self: types.Storage,
            container: types.Component
        ): function(...: any): types.Component
            -- Store container reference for FFI instances (prevents GC)
            -- Container is stored in metadataFields instead
            if container then
                -- Populate the metadata table with component info
                metadataFields.componentType = container
                metadataFields.componentName = structName
                metadataFields.componentId = (container as {string:any}).componentId
                metadataFields.componentHash = (container as {string:any}).componentHash
                metadataFields.getStorage = (container as {string:any}).getStorage
            end
            -- Create a closure that captures the storage instance
            return function(...: any): types.Component
                return createInstance(self, ...)
            end
        end,

        -- Recycle function to return components to the pool
        recycle = function(_self: types.Storage, component: types.Component)
            if recycleEnabled and recycleCount < recycleMaxSize then
                -- Clear the component by zero-filling its memory
                ffi_fill(component as libffi.CData, structSize, 0)

                -- Add to pool
                recycleCount = recycleCount + 1
                recyclePool[recycleCount] = component
            end
        end,

        -- Batch commit components to archetype column
        commitBatch = function(
            _self: types.Storage,
            column: {types.Component},
            startIndex: integer,
            componentList: {integer: types.Component}
        ): {types.Component}
            -- Count actual components (sparse array)
            local count = 0
            for _ in pairs(componentList) do
                count = count + 1
            end

            -- Ensure capacity
            local needed = startIndex + count - 1
            local meta = storageMetadata[column]

            if not meta then
                -- Initial allocation
                local newCapacity = storage.calculateOptimalCapacity(needed, 0)
                column = growArray(nil, 0, newCapacity)
                meta = storageMetadata[column]
            elseif needed > meta.capacity then
                local newCapacity = storage.calculateOptimalCapacity(needed, meta.capacity)
                local usedCount = startIndex - 1
                column = growArray(column as libffi.CData, usedCount, newCapacity)
                meta = storageMetadata[column]
            end

            -- Copy components directly to column
            -- componentList is a sparse array with entity IDs as keys
            local destIndex = startIndex
            for _, component in pairs(componentList) do
                -- Component is already an FFI struct instance
                local dest = column[destIndex]
                ffi_copy(dest as libffi.CData, component as libffi.CData, meta.structSize)
                destIndex = destIndex + 1
            end

            return column
        end,

        postCommit = function(_self: types.Storage, _dt: number)
            -- Nothing to do
        end,

        -- Bulk copy from arena pages to column
        bulkCopy = function(
            _self: types.Storage,
            column: {types.Component},
            destOffset: integer,
            srcData: any,  -- FFI array
            srcOffset: integer,
            count: integer
        )
            local meta = storageMetadata[column]
            if not meta then
                return
            end

            -- destOffset and srcOffset are 0-based
            -- column uses 1-based indexing with padding at 0
            -- Copy element by element since pointer arithmetic doesn't work directly
            for i = 0, count - 1 do
                local src = (srcData as {integer: any})[1 + srcOffset + i]
                local dest = column[1 + destOffset + i]
                ffi_copy(dest as libffi.CData, src as libffi.CData, meta.structSize)
            end
        end,

        swap = function(_self: types.Storage, column: {types.Component}, indexA: integer, indexB: integer)
            -- FFI swap using the unused index 0 as temporary storage for the swap.
            local meta = assert(storageMetadata[column], "Missing storage metadata")
            if indexA == indexB then return end
            assert(indexA > 0 and indexB > 0, "index 0 is reserved for swap temp")
            local itemA, itemB = column[indexA] as libffi.CData, column[indexB] as libffi.CData
            local temp = column[0] as libffi.CData
            ffi_copy(temp, itemA, meta.structSize)
            ffi_copy(itemA, itemB, meta.structSize)
            ffi_copy(itemB, temp, meta.structSize)
        end,

        -- Store struct type for fast instantiation
        _structType = structType,
        _structName = structName,  -- Store the name for Arena creation
        _sizeof = structSize,
        -- Marker for FFI storage detection in ecs.tl
        _ffiConstructor = true,
        -- Marker for recycle support
        _recycleEnabled = recycleEnabled
    } as types.Storage
end

return FFIStorage