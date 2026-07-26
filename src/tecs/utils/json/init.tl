--- JSON parser and serializer for LuaJIT.

local type ffi = require("ffi")

local record json
    --- Null sentinel for distinguishing JSON null from Lua nil in arrays.
    NULL: any

    --- Immutable empty table that serializes as [].
    EMPTY_ARRAY: {any}

    --- Empty object sentinel for forcing {} instead of [] for empty tables.
    EMPTY_OBJECT: {any:any}

    --- Parse JSON data from a string.
    ---
    --- @param str string JSON string to parse.
    --- @return any Parsed JSON object.
    parse: function(str: string): any

    --- Parse JSON data from a CData pointer and length.
    ---
    --- Useful for a buffer that is not already a Lua string.
    ---
    --- @param data ffi.CData Pointer to the JSON data.
    --- @param length integer Length of the JSON data in bytes.
    --- @return any Parsed JSON object.
    parseCData: function(data: ffi.CData, length: integer): any

    --- Serialize a Lua value to JSON string.
    ---
    --- @param value any Value to serialize (table, string, number, boolean, nil).
    --- @param sortKeys boolean Optional. Sort object keys for deterministic output (default: false).
    --- @return string JSON string.
    serialize: function(value: any, sortKeys?: boolean): string

    --- Serialize a Lua value to pretty-printed JSON string.
    ---
    --- @param value any Value to serialize (table, string, number, boolean, nil).
    --- @param sortKeys boolean Optional. Sort object keys for deterministic output (default: true).
    --- @param indent string Optional. Indent string to use (default: "  "). Can be spaces or a single tab.
    --- @return string Pretty-printed JSON string.
    serializePretty: function(value: any, sortKeys?: boolean, indent?: string): string
end

local parser <const> = require("tecs.utils.json.internal.parser")
local serializer <const> = require("tecs.utils.json.internal.serializer")

--- NULL sentinel for distinguishing JSON null from Lua nil in arrays.
json.NULL = setmetatable({}, {
    __tostring = function(): string
        return "json.NULL"
    end,
    __newindex = function()
        error("Cannot modify json.NULL sentinel")
    end
})

--- Immutable empty table that serializes as [].
json.EMPTY_ARRAY = setmetatable({}, {
    __tostring = function(): string
        return "json.EMPTY_ARRAY"
    end,
    __newindex = function()
        error("Cannot modify json.EMPTY_ARRAY sentinel")
    end
}) as {any}

--- EMPTY_OBJECT sentinel for forcing {} instead of [] for empty tables.
json.EMPTY_OBJECT = setmetatable({}, {
    __tostring = function(): string
        return "json.EMPTY_OBJECT"
    end,
    __newindex = function()
        error("Cannot modify json.EMPTY_OBJECT sentinel")
    end
}) as {any:any}

parser.setNullSentinel(json.NULL)
serializer.setNullSentinel(json.NULL)
serializer.setEmptyObjectSentinel(json.EMPTY_OBJECT)

-- Empty objects returned by parse carry this marker metatable, so
-- serialize keeps them as {} -- without it, a parse -> serialize round trip
-- turned every empty object into [] (which strict JSON-schema consumers,
-- like MCP clients validating tools/list, reject).
local OBJECT_MARKER <const>: metatable<{string: any}> = {}
parser.setObjectMarker(OBJECT_MARKER)
serializer.setObjectMarker(OBJECT_MARKER)

json.parse = parser.parse
json.parseCData = parser.parseCData
json.serialize = serializer.serialize
json.serializePretty = serializer.serializePretty

return json
