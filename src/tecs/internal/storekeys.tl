local type Store = require("tecs.data.Store")

-- Internal implementation shape. Public documentation lives on `tecs.data`.
local record storekeys
    newKey: function<T>(name?: string, forType?: T): Store.Key<T>
    findKey: function<T>(name: string): Store.Key<T> | nil
    listKeys: function(): {string: integer}
end

local record KeyValue
    id: integer
end

local KeyMethods: {string: any} = {}
local KeyMT <const>: metatable<KeyValue> = {__index = KeyMethods}
local KEY_COUNTER = 0
local NAMED_KEYS <const>: {string: KeyValue} = {}

local function createKey<T>(): Store.Key<T>
    KEY_COUNTER = KEY_COUNTER + 1
    return setmetatable({id = KEY_COUNTER} as KeyValue, KeyMT) as Store.Key<T>
end

function storekeys.newKey<T>(name?: string, _forType?: T): Store.Key<T>
    if name then
        -- Named keys are idempotent so module re-execution under hot reload
        -- keeps the same identity and therefore the same stored values.
        local existing = NAMED_KEYS[name]
        if existing then
            return existing as Store.Key<T>
        end
        local key <const> = createKey() as KeyValue
        NAMED_KEYS[name] = key
        return key as Store.Key<T>
    end

    local key <const> = createKey()
    -- Required here rather than at the top. Logging is SDL's, reached through
    -- the FFI, while named keys and stores also work in a headless process
    -- with no native libraries. An unnamed key is a cold path, so the lookup
    -- costs nothing that matters. The logger name is an externally typed
    -- compatibility surface and remains `tecs.context`.
    local log <const> = require("tecs.log")
    log.get("tecs.context"):warn(
        "Store key #%d created without a name; pass a name to newKey so tools can find it", KEY_COUNTER
    )
    -- The object is a phantom type token. Lua compares its process-wide
    -- identity while Teal remembers the value type associated with this key.
    return key
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
    for name, key in pairs(NAMED_KEYS) do
        out[name] = key.id
    end
    return out
end

KeyMethods.listKeys = storekeys.listKeys

return storekeys
