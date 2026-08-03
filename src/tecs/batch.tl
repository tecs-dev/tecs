--[=[
Several waits at one call site.

`batch` runs its callbacks at the same time and returns their results in the
order they were given, so a system that needs three unrelated answers waits
about as long as the slowest one rather than as long as all three:

```teal
local pages <const> = tecs.batch({
    function(): string return client:send({url = manifest}).body:readAll(1 << 20) end,
    function(): string return tecs.io.files.read("save.json") end,
    function(): tecs.assets.Image return tecs.assets.loadImage("sprites/player.png") end,
})
```

Each callback runs as its own cooperative task, so one that waits releases the
others to run. The call itself behaves like every other finite operation: it
suspends the calling system until every callback settles, and outside a system
it blocks while driving the producers the callbacks wait on.

## Failure and cancellation

The first callback that raises cancels the callbacks still running, waits for
them to unwind their scopes, and raises that failure from `batch`. Later
callbacks that had already succeeded are discarded with it. A callback that
wants a failure to be a value rather than an outcome returns `nil, reason`
itself, or catches the failure and returns a result the caller can inspect.

Canceling the calling system, which world shutdown does, cancels every callback
the same way.

## Mutation belongs to the caller

Callbacks read, compute, and return. Apply their results to the world after
`batch` returns rather than spawning or setting components inside a callback:
entity identifiers are handed out when a callback stages a spawn, so staging
from callbacks makes identifiers, and therefore snapshots and replays, depend
on which wait finished first. Returning values and applying them in the caller
keeps that order fixed.
]=]

local taskruntime <const> = require("tecs.internal.taskruntime")
local runtime <const> = require("tecs.internal.runtime")
local time <const> = require("tecs.platform.time")

local type Task = taskruntime.Task
local type Scope = taskruntime.Scope

-- The blocking driver sleeps only when a turn advanced nothing at all, so an
-- idle wait costs a millisecond of latency instead of a spinning core.
local IDLE_DELAY_MS <const> = 1

local record batch
    --- Runs callbacks at the same time and returns their results in order.
    ---
    --- Inside a system the call suspends until every callback settles, and
    --- outside one it blocks while driving the producers they wait on. The
    --- first callback that raises cancels the rest, waits for them to unwind,
    --- and raises that failure. Callbacks return values for the caller to
    --- apply; staging world mutations inside them makes entity identifiers
    --- depend on completion order.
    ---
    --- @param bodies The caller supplies an array of functions that take no
    ---     arguments. An empty array returns an empty array without waiting.
    --- @return Returns one result per callback, at the callback's index. A
    ---     batch mixes types freely, so the caller casts each result to what
    ---     its own callback returned.
    batch: function(bodies: {function(): any}): {any}
end

-- Cancellation reaches a parked task through its resume tag, so a canceled
-- sibling settles on a later turn rather than inside `cancel`. Waiting for
-- each one keeps the promise that `batch` returns nothing while a callback of
-- its own is still running.
local function settleRemaining(tasks: {Task<any>}, count: integer)
    for index = 1, count do
        local child <const> = tasks[index]
        if child.status == "pending" then
            child:cancel("a batch callback failed")
        end
    end
    for index = 1, count do
        local child <const> = tasks[index]
        if child.status == "pending" then
            pcall(child.join, child)
        end
    end
end

local function runCooperatively(bodies: {function(): any}, count: integer): {any}
    local caller <const> = taskruntime.current()
    local scope <const> = caller.scope as Scope

    local tasks <const>: {Task<any>} = {}
    for index = 1, count do
        tasks[index] = scope:spawn(bodies[index] as function(Scope): any)
    end

    local results <const>: {any} = {}
    for index = 1, count do
        local child <const> = tasks[index]
        local ok <const>, value = pcall(child.join, child)
        if not ok then
            settleRemaining(tasks, count)
            -- The private cancellation signal travels as a value rather than a
            -- string, so it has to pass through unchanged for the runtime to
            -- keep telling cancellation and failure apart.
            error(value, 0)
        end
        results[index] = value
    end
    return results
end

local function runBlocking(bodies: {function(): any}, count: integer): {any}
    local scheduler <const> = taskruntime.newScheduler()
    local root <const> = scheduler:spawn(function(): {any} return runCooperatively(bodies, count) end)

    while root.status == "pending" do
        local settled <const> = runtime.poll()
        local resumed <const> = scheduler:step()
        if settled == 0 and resumed == 0 then
            time.delay(IDLE_DELAY_MS)
        end
    end

    if root.status == "ready" then
        return root.value as {any}
    end
    if root.status == "canceled" then
        error("tecs: batch was canceled: " .. (root.error or "canceled"), 3)
    end
    error(root.error, 3)
end

function batch.batch(bodies: {function(): any}): {any}
    if type(bodies) ~= "table" then
        error("tecs: batch needs an array of functions", 2)
    end

    local count <const> = #bodies
    for index = 1, count do
        if type(bodies[index]) ~= "function" then
            error(("tecs: batch needs a function at index %d"):format(index), 2)
        end
    end
    if count == 0 then
        return {}
    end

    if taskruntime.active() then
        taskruntime.checkSuspension("batch")
        return runCooperatively(bodies, count)
    end
    return runBlocking(bodies, count)
end

return batch
