local types <const> = require("tecs.types")

-- Internal implementation shape. Public Tealdoc lives on `tecs` and
-- `types.Context`.
local record ContextModule
    newKey: function<T>(name?: string, forType?: T): types.Context.Key<T>
    findKey: function<T>(name: string): types.Context.Key<T> | nil
    listKeys: function(): {string: integer}
    new: function(): types.Context
end

local KEY_COUNTER = 0
local NAMED_KEYS <const>: {string: integer} = {}

function ContextModule.newKey<T>(name?: string, _forType?: T): types.Context.Key<T>
    if name then
        -- Named keys are idempotent so module re-execution under hot reload
        -- keeps the same identity (and therefore the same stored values).
        local existing = NAMED_KEYS[name]
        if existing then
            return existing as types.Context.Key<T>
        end
        KEY_COUNTER = KEY_COUNTER + 1
        NAMED_KEYS[name] = KEY_COUNTER
        return KEY_COUNTER as types.Context.Key<T>
    end
    KEY_COUNTER = KEY_COUNTER + 1
    -- Required here rather than at the top. Logging is SDL's, reached through
    -- the FFI, and this module loads with the ECS: a tool that only wants
    -- worlds and queries would be made to find SDL to build one. An unnamed
    -- key is a cold path, so the lookup costs nothing that matters.
    local log <const> = require("tecs.log")
    log.get("tecs.context"):warn(
        "Context key #%d created without a name; pass a name to newKey so "
            .. "tools (MCP inspect, tecs info --keys) can find it",
        KEY_COUNTER)
    -- Cast the numeric key as a kind of phantom type.
    -- It doesn't matter that it's actually a number as long as Teal thinks it's Key<T>.
    return KEY_COUNTER as types.Context.Key<T>
end

function ContextModule.findKey<T>(name: string): types.Context.Key<T> | nil
    local id = NAMED_KEYS[name]
    if id == nil then return nil end
    return id as types.Context.Key<T>
end

function ContextModule.listKeys(): {string: integer}
    local out: {string: integer} = {}
    for name, id in pairs(NAMED_KEYS) do
        out[name] = id
    end
    return out
end

function ContextModule.new(): types.Context
    return {} as types.Context
end

return ContextModule
