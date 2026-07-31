--[=[
A typed, in-memory key-value store.

Keys carry the value type while remaining small process-wide identities:

```teal
local SPEED <const>: tecs.data.Key<number> =
    tecs.data.Store.newKey("game.speed")

local store <const> = tecs.data.newStore()
store[SPEED] = 120
print(store[SPEED])
```

Name every key. Repeating a name returns the same key, so values remain
reachable when a module reloads and tools can discover the keys a process has
registered. Stores are independent and do not imply persistence. A world owns
one as `world.resources`, and snapshots omit it unless a snapshot handler saves
its values explicitly.
]=]

--- Stores values under typed keys.
local record Store
    --- Identifies one typed value across every store in the process.
    interface Key<T>
    end

    --- Returns the value associated with a typed key. An unwritten key returns
    --- nil even though the key's phantom type supplies the declared result.
    metamethod __index: function<T>(Store, key: Key<T>): T

    --- Associates a value with a typed key. Assigning nil removes the value.
    metamethod __newindex: function<T>(Store, key: Key<T>, value: T)
end

return Store
