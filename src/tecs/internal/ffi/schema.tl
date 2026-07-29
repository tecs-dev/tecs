--[=[
FFI schema utilities for components and events.
]=]
local record schema
    --- Field definition tuple: {name, type}
    type FieldDef = {string, string}

    --- Validate field definitions for FFI schema.
    --- @param fields The field definitions to validate.
    --- @param reservedFields Optional set of field names that are reserved and must not be specified.
    validateFields: function(fields: {FieldDef}, reservedFields?: {string: boolean})
end

local function isValidCIdent(name: string): boolean
    return name:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

function schema.validateFields(fields: {schema.FieldDef}, reservedFields?: {string: boolean})
    local seen: {string: boolean} = {}
    local reserved = reservedFields or {}

    for i = 1, #fields do
        local field <const> = fields[i]
        local fieldName, fieldType <const> = field[1], field[2]

        if not fieldName or fieldName == "" then
            error("Field #" .. i .. ": field name cannot be empty")
        end

        if reserved[fieldName] then
            error("Field #" .. i .. ": '" .. fieldName .. "' is reserved and must not be specified manually")
        end

        if not isValidCIdent(fieldName) then
            error("Field #" .. i .. ": invalid C identifier: " .. fieldName)
        end

        if seen[fieldName] then
            error("Field #" .. i .. ": duplicate field name: " .. fieldName)
        end
        seen[fieldName] = true

        if not fieldType or fieldType == "" then
            error("Field #" .. i .. ": field type cannot be empty for field: " .. fieldName)
        end
    end
end

return schema
