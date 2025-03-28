local rawget, rawset <const> = rawget, rawset

--- Context is a type-safe bag of data.
---
--- Context keys are used to access data in a context object using type-safe sentinel values.
---
--- Example:
---
--- ```
--- local context = Context.new()
--- local MY_KEY: Context.Key<number> = context.newKey()
--- context[MY_KEY] = 42
--- assert(context[MY_KEY] == 42)
--- ```
local record Context
    --- Type-safe Key interface.
    record Key<T> end

    --- Get a context value using a type-safe key.
    ---
    --- @param key The key to use to access the value.
    --- @return The value associated with the key, or nil if the key is not set.
    metamethod __index: function<T>(Context, key: Key<T>): T

    --- Set a context value using a type-safe key.
    ---
    --- @param key The key to use to access the value.
    --- @param value The value to set, or nil to remove the key.
    metamethod __newindex: function<T>(Context, key: Key<T>, value: T)

    --- Create a new type-safe key used to access context values.
    ---
    --- @param keyType The type of the value associated with the key or nil explicitly type the key.
    --- @return A new key that can be used to access context values.
    newKey: function<T>(forType?: T): Key<T>

    --- Create a new Context instance.
    ---
    --- @return A new Context instance.
    new: function(): Context
end

local KEY_COUNTER = 0

function Context.newKey<T>(_forType?: T): Context.Key<T>
    KEY_COUNTER = KEY_COUNTER + 1
    -- Cast the numeric key as a kind of phantom type.
    -- It doesn't matter that it's actually a number as long as Teal thinks it's Key<T>.
    return KEY_COUNTER as Context.Key<T>
end

function Context.new(): Context
    local data = {}
    return setmetatable(data, {
        __index = function<T>(_self: Context, key: Context.Key<T>): T
            return rawget(data, key) as T
        end,
        __newindex = function<T>(_self: Context, key: Context.Key<T>, value: T)
            rawset(data, key, value)
        end
    })
end

return Context