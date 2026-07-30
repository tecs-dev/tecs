local type Store = require("tecs.data.Store")

-- Internal implementation shape. Public documentation lives on `tecs.data`.
local record storekeys
    newKey: function<T>(name?: string, forType?: T): Store.Key<T>
    findKey: function<T>(name: string): Store.Key<T> | nil
    listKeys: function(): {string: integer}
end

local KEY_COUNTER = 0
local NAMED_KEYS <const>: {string: integer} = {}

function storekeys.newKey<T>(name?: string, _forType?: T): Store.Key<T>
    if name then
        -- Named keys are idempotent so module re-execution under hot reload
        -- keeps the same identity and therefore the same stored values.
        local existing = NAMED_KEYS[name]
        if existing then
            return existing as Store.Key<T>
        end
        KEY_COUNTER = KEY_COUNTER + 1
        NAMED_KEYS[name] = KEY_COUNTER
        return KEY_COUNTER as Store.Key<T>
    end

    KEY_COUNTER = KEY_COUNTER + 1
    -- Required here rather than at the top. Logging is SDL's, reached through
    -- the FFI, while named keys and stores also work in a headless process
    -- with no native libraries. An unnamed key is a cold path, so the lookup
    -- costs nothing that matters. The logger name is an externally typed
    -- compatibility surface and remains `tecs.context`.
    local log <const> = require("tecs.log")
    log.get("tecs.context"):warn(
        "Store key #%d created without a name; pass a name to newKey so tools can find it", KEY_COUNTER
    )
    -- The number is a phantom type token. Lua sees an integer while Teal
    -- remembers the value type associated with this key.
    return KEY_COUNTER as Store.Key<T>
end

function storekeys.findKey<T>(name: string): Store.Key<T> | nil
    local id = NAMED_KEYS[name]
    if id == nil then
        return nil
    end
    return id as Store.Key<T>
end

function storekeys.listKeys(): {string: integer}
    local out: {string: integer} = {}
    for name, id in pairs(NAMED_KEYS) do
        out[name] = id
    end
    return out
end

return storekeys
