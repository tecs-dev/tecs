local types <const> = require("tecs.types")
local logging <const> = require("tecs.utils.logging")

--- Context is a type-safe bag of data.
---
--- Context keys are used to access data in a context object using type-safe sentinel values.
---
--- Example:
---
--- ```
--- local context = Context.new()
--- local MY_KEY: Context.Key<number> = context.newKey("my.key")
--- context[MY_KEY] = 42
--- assert(context[MY_KEY] == 42)
--- ```
local record ContextModule
    --- Create a new type-safe key used to access context values.
    ---
    --- Always pass a name: named keys are discoverable at runtime through
    --- `findKey`/`listKeys` and the tooling built on them (the MCP `inspect`
    --- tool, `tecs info --keys`), which is how agents and debug tooling read
    --- state stored under the key. A named key is a stable identity: calling
    --- `newKey` again with the same name returns the same key, so values keyed
    --- by it survive module re-execution (hot reload). An unnamed key still
    --- works but logs a warning, stays invisible to name-based lookups, and is
    --- a fresh identity on every call.
    ---
    --- @param name A stable, unique name for the key, e.g. "game.state".
    --- @param keyType The type of the value associated with the key or nil explicitly type the key.
    --- @return A new key that can be used to access context values.
    newKey: function<T>(name?: string, forType?: T): types.Context.Key<T>

    --- Find a named key created by `newKey`.
    ---
    --- @param name The name the key was created with.
    --- @return The key, or nil when no key has that name.
    findKey: function<T>(name: string): types.Context.Key<T>

    --- All named keys, as a fresh name -> numeric key id table.
    listKeys: function(): {string: integer}

    --- Create a new Context instance.
    ---
    --- @return A new Context instance.
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
    logging.getLogger("tecs.context"):warn(
        "Context key #%d created without a name; pass a name to newKey so "
            .. "tools (MCP inspect, tecs info --keys) can find it",
        KEY_COUNTER)
    -- Cast the numeric key as a kind of phantom type.
    -- It doesn't matter that it's actually a number as long as Teal thinks it's Key<T>.
    return KEY_COUNTER as types.Context.Key<T>
end

function ContextModule.findKey<T>(name: string): types.Context.Key<T>
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
