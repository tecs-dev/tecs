-- Internal one-shot completion state for worker and native producers.
--
-- This is not a public execution model. Direct engine calls return values.
-- A pending call parks its system through taskruntime, while the same call
-- outside a system advances its source synchronously. Completion exists only
-- to connect producers to those two consumers.
--
-- `_watchers` counts holds, and a hold is what keeps the producer working. A
-- fresh completion carries none: a consumer takes one through `subscribe` and
-- releases it through the function that returns, and a producer that retains
-- its completion beyond one consumer takes one through `retain`. Cancellation
-- releases exactly one hold, and reaches the source only when the last hold
-- goes. So a consumer that gives up can never settle a completion another
-- consumer, or the producer itself, still holds.

local log <const> = require("tecs.log")
local time <const> = require("tecs.platform.time")

-- Logger names are externally typed configuration. Keep the historical name
-- even though the public Future API no longer exists.
local LOGGER <const> = log.get("tecs.future")

local DEFAULT_WAIT_MS <const> = 5000
local DEFAULT_SLICE_MS <const> = 16

local now <const> = function(): number return time.now() * 1000.0 end

local record Completion<T>
    type Listener = function(completion: Completion<any>)

    record Source
        poll: function(self: Source): integer
        advance: function(self: Source, ms: number): integer
        sliceMs: number
        defaultWaitMs: number
        cancel: function(self: Source, completion: Completion<any>)
    end

    status: string
    value: T
    error: string
    _source: Source
    _listeners: {Listener}
    _listenerCount: integer
    _delivered: integer
    _watchers: integer

    onSettle: function(self: Completion<T>, listener: function(completion: Completion<T>)): Completion<T>
    wait: function(self: Completion<T>, timeoutMs?: number): Completion<T>
    complete: function(self: Completion<T>, value: T)
    fail: function(self: Completion<T>, reason: string)
    abandon: function(self: Completion<T>, reason: string)
    cancel: function(self: Completion<T>)
    retain: function(self: Completion<T>)
    subscribe: function(self: Completion<T>, listener: function(completion: Completion<T>)): function()

    pending: function<U>(source?: Source): Completion<U>
    failed: function<U>(reason: string): Completion<U>
end

local CompletionMT <const>: metatable<Completion<any>> = {__index = Completion}

-- Listener delivery uses a flat drain so settling one completion from another
-- listener cannot grow the Lua stack. Reentrant subscriptions join this drain.
local draining = false
local queued: {Completion<any>} = {}
local queuedCount = 0

local function runListeners(completion: Completion<any>)
    local listeners = completion._listeners
    if listeners == nil then
        return
    end
    local index = completion._delivered
    while index < completion._listenerCount do
        index = index + 1
        completion._delivered = index
        local listener = listeners[index]
        listeners[index] = nil
        if listener ~= nil then
            local ok, reason = pcall(listener, completion) as (boolean, any)
            if not ok then
                LOGGER:error("a completion listener raised: %s", tostring(reason))
            end
        end
    end
    -- Producers such as processes may retain their settled completion for the
    -- resource lifetime. Do not let that retain the suspended task closure.
    completion._listeners = nil
    completion._listenerCount = 0
    completion._delivered = 0
end

local function drain(completion: Completion<any>)
    queuedCount = queuedCount + 1
    queued[queuedCount] = completion
    if draining then
        return
    end

    draining = true
    local index = 1
    while index <= queuedCount do
        local queuedCompletion = queued[index]
        queued[index] = nil
        index = index + 1
        runListeners(queuedCompletion)
    end
    queuedCount = 0
    draining = false
end

local function settle(completion: Completion<any>, status: string, value: any, reason: string)
    if completion.status ~= "pending" then
        return
    end
    completion.status = status
    completion.value = value
    completion.error = reason
    drain(completion)
end

local function newCompletion(source: Completion.Source): Completion<any>
    return setmetatable(
        {
            status = "pending",
            value = nil,
            error = nil,
            _source = source,
            _listeners = nil,
            _listenerCount = 0,
            _delivered = 0,
            _watchers = 0,
        } as Completion<any>,
        CompletionMT
    )
end

-- A fresh completion holds nothing. Its consumers take their own holds through
-- `subscribe`, so the producer stops when the last of them releases, and a
-- producer that outlives one consumer keeps its own hold through `retain`.
function Completion.pending<U>(source?: Completion.Source): Completion<U>
    return newCompletion(source) as Completion<U>
end

function Completion.failed<U>(reason: string): Completion<U>
    local completion = newCompletion(nil) as Completion<U>
    completion.status = "failed"
    completion.error = reason or "failed"
    return completion
end

local function listen(completion: Completion<any>, listener: function(Completion<any>)): integer
    local listeners = completion._listeners
    if listeners == nil then
        listeners = {}
        completion._listeners = listeners
    end
    local at <const> = completion._listenerCount + 1
    completion._listenerCount = at
    listeners[at] = listener
    if completion.status ~= "pending" then
        drain(completion)
    end
    return at
end

function Completion:onSettle(listener: function(completion: Completion<T>)): Completion<T>
    if type(listener) ~= "function" then
        error("tecs: completion settlement needs a listener", 2)
    end
    listen(self as Completion<any>, listener as function(Completion<any>))
    return self
end

local function unlisten(completion: Completion<any>, at: integer)
    if completion._listeners ~= nil and at ~= nil then
        -- Listener indices are stable because cancellation records one index.
        completion._listeners[at] = nil
    end
end

-- Subscriptions are consumer views over a shared producer completion. They add
-- no second completion allocation, and cancellation releases exactly one hold.
-- A method rather than a module function, so a consumer that holds a completion
-- takes its hold without requiring this module and the load order it carries.
function Completion:subscribe(listener: function(completion: Completion<T>)): function()
    if type(listener) ~= "function" then
        error("tecs: completion subscription needs a listener", 2)
    end
    local completion <const> = self as Completion<any>
    completion._watchers = completion._watchers + 1
    local active = true
    local at: integer
    at = listen(
        completion,
        function(settled: Completion<any>)
            if not active then
                return
            end
            active = false
            listener(settled as Completion<T>)
        end
    )
    return function()
        if not active then
            return
        end
        active = false
        unlisten(completion, at)
        completion:cancel()
    end
end

function Completion:complete(value: T)
    settle(self as Completion<any>, "ready", value, nil)
end

function Completion:fail(reason: string)
    settle(self as Completion<any>, "failed", nil, reason or "failed")
end

function Completion:abandon(reason: string)
    settle(self as Completion<any>, "canceled", nil, reason or "canceled")
end

function Completion:wait(timeoutMs?: number): Completion<T>
    local source = self._source
    if self.status ~= "pending" or source == nil then
        return self
    end

    local budget <const> = timeoutMs or source.defaultWaitMs or DEFAULT_WAIT_MS
    local deadline <const> = now() + budget
    while self.status == "pending" do
        local remaining <const> = deadline - now()
        if remaining <= 0 then
            break
        end
        local slice = source.sliceMs or DEFAULT_SLICE_MS
        if slice > remaining then
            slice = remaining
        end
        source:advance(slice)
    end
    return self
end

--- Takes a hold for a producer that retains this completion.
---
--- A process keeps its exit completion for the whole of the child's life, so
--- every consumer wait is one hold above this one and a consumer that gives up
--- releases only its own. A producer that hands its completion to consumers and
--- keeps nothing takes no hold, and the last consumer to leave stops its work.
function Completion:retain()
    self._watchers = self._watchers + 1
end

-- Releases one hold, and settles this completion once the last one goes. A
-- completion nothing holds cancels outright, which is how an owner that never
-- took a hold stops work it alone started.
function Completion:cancel()
    if self.status ~= "pending" then
        return
    end
    self._watchers = self._watchers - 1
    if self._watchers > 0 then
        return
    end

    self.status = "canceled"
    self.error = "canceled"
    local source = self._source
    if source ~= nil and source.cancel ~= nil then
        source:cancel(self as Completion<any>)
    end
    drain(self as Completion<any>)
end

return Completion
