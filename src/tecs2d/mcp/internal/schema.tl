--- Validation for the JSON Schema subset used by kernel MCP tools.

local tools <const> = require("tecs2d.mcp.tools")
local json <const> = require("tecs.utils.json")

local record schema
    validate: function(value: any, definition: tools.Schema,
        path?: string): string
end

local function valueType(value: any): string
    local kind = type(value)
    if kind ~= "table" then return kind end
    local hasKeys = false
    for key in pairs(value as {any: any}) do
        hasKeys = true
        if type(key) == "number" then return "array" end
    end
    if not hasKeys then
        if value == json.NULL then return "null" end
        if value == json.EMPTY_ARRAY then return "array" end
        return getmetatable(value) and "object" or "array"
    end
    return "object"
end

function schema.validate(value: any, definition: tools.Schema,
        path?: string): string
    local here = path or "arguments"
    local expected = definition.type
    if expected then
        local actual = valueType(value)
        if actual ~= expected then
            return here .. " must be " .. expected .. ", got " .. actual
        end
    end

    if expected == "object" then
        local object = value as {any: any}
        local properties = definition.properties or {}
        for i = 1, #(definition.required or {}) do
            local name = definition.required[i]
            if object[name] == nil then
                return here .. "." .. name .. " is required"
            end
        end
        for key, item in pairs(object) do
            if type(key) ~= "string" then
                return here .. " must be an object"
            end
            local child = properties[key as string]
            if not child then
                if definition.additionalProperties == false then
                    return here .. " has unknown property '" ..
                        (key as string) .. "'"
                end
            else
                local err = schema.validate(item, child,
                    here .. "." .. (key as string))
                if err then return err end
            end
        end
    elseif expected == "array" then
        local list = value as {any}
        if definition.items then
            for i = 1, #list do
                local err = schema.validate(list[i], definition.items,
                    here .. "[" .. tostring(i) .. "]")
                if err then return err end
            end
        end
    end

    return nil
end

return schema
