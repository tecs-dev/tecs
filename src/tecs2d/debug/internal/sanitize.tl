--- JSON-safe deep copies of live Lua values for debugger command output.
--- Scalars pass through, tables recurse (cycle-guarded, depth-capped), and
--- everything else (functions, userdata, cdata, threads) becomes its
--- tostring form. Command results must serialize to JSON for MCP, and game
--- state routinely holds live objects.

local record sanitize
    --- Deep-copy `v` into JSON-safe data.
    value: function(v: any): any
end

local MAX_DEPTH <const> = 6

local function walk(v: any, depth: integer, seen: {any: boolean}): any
    local t = type(v)
    if v == nil or t == "number" or t == "string" or t == "boolean" then
        return v
    end
    if t ~= "table" then
        return tostring(v)
    end
    if seen[v] then return "<cycle>" end
    if depth >= MAX_DEPTH then return tostring(v) end
    seen[v] = true
    local out: {any: any} = {}
    for k, val in pairs(v as {any: any}) do
        local key: any = k
        local kt = type(k)
        if kt ~= "string" and kt ~= "number" then key = tostring(k) end
        out[key] = walk(val, depth + 1, seen)
    end
    seen[v] = false
    return out
end

function sanitize.value(v: any): any
    return walk(v, 0, {})
end

return sanitize
