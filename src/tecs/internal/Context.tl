local types <const> = require("tecs.types")

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
local record ContextModule
    --- Create a new type-safe key used to access context values.
    ---
    --- @param keyType The type of the value associated with the key or nil explicitly type the key.
    --- @return A new key that can be used to access context values.
    newKey: function<T>(forType?: T): types.Context.Key<T>

    --- Create a new Context instance.
    ---
    --- @return A new Context instance.
    new: function(): types.Context
end

local KEY_COUNTER = 0

function ContextModule.newKey<T>(_forType?: T): types.Context.Key<T>
    KEY_COUNTER = KEY_COUNTER + 1
    -- Cast the numeric key as a kind of phantom type.
    -- It doesn't matter that it's actually a number as long as Teal thinks it's Key<T>.
    return KEY_COUNTER as types.Context.Key<T>
end

function ContextModule.new(): types.Context
    return {} as types.Context
end

return ContextModule
