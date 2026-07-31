--[=[
A lexical lifetime for explicitly owned resources.

`scoped` creates one scope for a synchronous callback. Calling `scope:own`
with an open [`Closeable`](tealdoc:tecs.Closeable) registers that value and
returns it unchanged, so its concrete type is preserved:

```teal
tecs.scoped(function(scope: tecs.Scope)
    local input <const> = scope:own(assert(io.open("save.bin", "rb")))
    local output <const> = scope:own(assert(io.open("save.copy", "wb")))

    assert(tecs.io.transfer(input, output))
end)
```

The scope closes registrations in reverse order after the callback returns or
raises. It attempts every close even when one raises. A callback failure stays
the primary failure, with cleanup failures appended as secondary context; when
the callback succeeds, cleanup failures make `scoped` raise.

The scope owns each registration rather than each distinct value. Registering
one value twice closes it twice. A scope becomes inactive before cleanup starts
and cannot be captured for later registration.

The callback must not yield. LuaJIT has no hook that can unwind a suspended
coroutine which its owner abandons, so no library function can guarantee
cleanup for that exit path.
]=]

local type types = require("tecs.types")
local type Closeable = types.Closeable

local record Registration
    value: Closeable | FILE
    close: function(any)
end

local interface Scope
    --- Registers one owned value for cleanup and returns it unchanged.
    ---
    --- The scope is active only inside the callback passed to `scoped`.
    --- Calling a captured scope after that callback returns, raises, or begins
    --- cleanup raises instead of creating an ownership obligation nobody will
    --- run.
    ---
    --- @param self The active scope that will own the value.
    --- @param value An open [`Closeable`](tealdoc:tecs.Closeable) or Lua file.
    ---     Each call adds one cleanup obligation, including repeated calls
    ---     with the same value.
    --- @return The same value with its concrete type unchanged.
    own: function<T>(self, value: T): T
end

local record ScopeImpl is Scope
    active: boolean
    registrations: {Registration}
    count: integer
end

local SCOPE_MT <const>: metatable<ScopeImpl> = {__index = ScopeImpl}

local record scope
    --- `Scope` owns resources while preserving each concrete type.
    type Scope = Scope

    --- Runs a callback inside a fresh resource scope.
    ---
    --- The callback runs synchronously and must not yield. Every value it
    --- registers closes in reverse order before this function returns or
    --- propagates a failure. Cleanup begins by making the scope inactive, and
    --- one failing close does not prevent the remaining closes.
    ---
    --- @param body The callback that receives the only active [`Scope`](tealdoc:tecs.Scope)
    ---     for this invocation. Returned values are ignored, and registered
    ---     resources must not be used after the callback ends.
    scoped: function(body: function(Scope))
end

local function traceback(reason: any): string
    return debug.traceback(tostring(reason), 2)
end

local function appendCleanupFailures(primary: string, failures: {string}): string
    if #failures == 0 then
        return primary
    end
    return primary .. "\n\nScoped cleanup also failed:\n" .. table.concat(failures, "\n\n")
end

function scope.scoped(body: function(Scope))
    if type(body) ~= "function" then
        error("tecs: scoped needs a function", 2)
    end

    local owned <const> = setmetatable(
        {
            active = true,
            registrations = {},
            count = 0,
        } as ScopeImpl,
        SCOPE_MT
    )

    local ok <const>, bodyFailure = xpcall(function() body(owned) end, traceback) as (boolean, string)

    -- Invalidate before calling user cleanup. A close function cannot extend
    -- a scope whose callback has already ended, and a captured scope cannot be
    -- used after this function returns.
    owned.active = false

    local cleanupFailures: {string} = {}
    for index = owned.count, 1, -1 do
        local registration <const> = owned.registrations[index]
        owned.registrations[index] = nil
        local closed <const>, closeFailure = xpcall(
            function() registration.close(registration.value) end, traceback
        ) as (boolean, string)
        if not closed then
            cleanupFailures[#cleanupFailures + 1] = ("Resource %d failed to close:\n%s"):format(index, closeFailure)
        end
    end

    if not ok then
        error(appendCleanupFailures(bodyFailure, cleanupFailures), 0)
    end
    if #cleanupFailures > 0 then
        error("Scoped cleanup failed:\n" .. table.concat(cleanupFailures, "\n\n"), 0)
    end
end

function ScopeImpl:own<T>(value: T): T
    if not self.active then
        error("tecs: Scope is no longer active", 2)
    end

    -- Teal proves this at typed call sites. Validate the same boundary for a
    -- Lua caller now rather than letting an invalid value fail after the body
    -- has already completed.
    local kind <const> = type(value as any)
    if kind ~= "table" and kind ~= "userdata" and kind ~= "cdata" then
        error("tecs: Scope needs a value with a close method", 2)
    end
    local close <const> = (value as {string: any}).close
    if type(close) ~= "function" then
        error("tecs: Scope needs a value with a close method", 2)
    end

    self.count = self.count + 1
    self.registrations[self.count] = {
        value = value as Closeable | FILE,
        close = close as function(any),
    }
    return value
end

return scope
