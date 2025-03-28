--[[
FFI schema utilities for components and events.
Provides fallback constructors and type defaults for FFI-based systems.
]]--

local libffi = require("tecs.internal.ffi.libffi")

local min <const> = math.min

local record schema
    --- Common FFI type defaults for fallback constructors
    TYPE_DEFAULTS: {string: any}

    --- Field definition tuple: {name, type}
    type FieldDef = {string, string}

    --- Constructor function type
    type Constructor<T> = function(...: any): T

    --- Checks if FFI is available.
    --- @return true if FFI is available.
    isFFIAvailable: function(): boolean

    --- Validate field definitions for FFI schema
    --- @param fields The field definitions to validate.
    --- @param allowEventId Whether to allow the eventId field.
    validateFields: function(fields: {FieldDef}, allowEventId?: boolean)

    --- Create a fallback table-based constructor from field schema
    --- @param fields The field definitions to use for the constructor.
    --- @return A constructor function that creates instances with the specified fields.
    createFallbackConstructor: function<T>(fields: {FieldDef}): Constructor<T>
end

-- Default value lookup table for common FFI types
schema.TYPE_DEFAULTS = {
    ["float"] = 0.0,
    ["double"] = 0.0,
    ["bool"] = false,
    ["boolean"] = false,
    ["char"] = 0,
    ["unsigned char"] = 0,
    ["int"] = 0,
    ["int8_t"] = 0,
    ["int16_t"] = 0,
    ["int32_t"] = 0,
    ["int64_t"] = 0,
    ["uint8_t"] = 0,
    ["uint16_t"] = 0,
    ["uint32_t"] = 0,
    ["uint64_t"] = 0,
    ["size_t"] = 0,
    ["ssize_t"] = 0,
    ["ptrdiff_t"] = 0,
    ["uintptr_t"] = 0,
    ["short"] = 0,
    ["long"] = 0,
    ["unsigned"] = 0,
    ["unsigned int"] = 0,
    ["unsigned short"] = 0,
    ["unsigned long"] = 0,
}

function schema.isFFIAvailable(): boolean
    return libffi.isFFIAvailable()
end

function schema.validateFields(fields: {schema.FieldDef}, allowEventId?: boolean)
    for i = 1, #fields do
        local field <const> = fields[i]
        local fieldName, fieldType <const> = field[1], field[2]

        if fieldName == "eventId" and not allowEventId then
            error("eventId field is automatically injected and should not be specified manually")
        end

        if not fieldName or fieldName == "" then
            error("Field name cannot be empty")
        end

        if not fieldType or fieldType == "" then
            error("Field type cannot be empty for field: " .. fieldName)
        end
    end
end

function schema.createFallbackConstructor<T>(fields: {schema.FieldDef}): schema.Constructor<T>
    -- Pre-compute field information
    local fieldNames: {string} = {}
    local defaultKeys: {string} = {}
    local defaultValues: {any} = {}
    local fieldCount = #fields

    -- Setup mapping of field names to their default values
    for i = 1, fieldCount do
        local field <const> = fields[i]
        local fieldName, fieldType <const> = field[1], field[2]
        table.insert(fieldNames, fieldName)
        local defaultValue <const> = schema.TYPE_DEFAULTS[fieldType]
        if defaultValue ~= nil then
            table.insert(defaultKeys, fieldName)
            table.insert(defaultValues, defaultValue)
        elseif fieldType:match("u?int") then
            table.insert(defaultKeys, fieldName)
            table.insert(defaultValues, 0)
        end
    end

    local defaultSize = #defaultKeys

    -- Return optimized constructor function
    return function(...: any): T
        local nargs = select('#', ...)
        local instance: {string: any} = {}

        -- Apply default values first
        for i = 1, defaultSize do
            instance[defaultKeys[i]] = defaultValues[i]
        end

        -- Override defaults with provided arguments
        if nargs == 1 and type((...)) == "table" then
            -- Single table argument: copy all given properties
            local value = (...) as {string: any}
            for k, v in pairs(value) do
                instance[k] = v
            end
        elseif nargs > 0 then
            -- Multiple arguments: assign positionally (overrides defaults)
            for i = 1, min(nargs, fieldCount) do
                instance[fieldNames[i]] = select(i, ...)
            end
        end

        return instance as T
    end
end

return schema