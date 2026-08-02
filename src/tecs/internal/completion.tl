-- Internal one-shot completion state for worker and native producers.
--
-- This is not a public execution model. Direct engine calls return values.
-- A pending call parks its system through taskruntime, while the same call
-- outside a system advances its source synchronously. Completion exists only
-- to connect producers to those two consumers.

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

    pending: function<U>(source?: Source): Completion<U>
    failed: function<U>(reason: string): Completion<U>
    subscribe: function<U>(completion: Completion<U>, listener: function(completion: Completion<U>)): function()
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
            _watchers = 1,
        } as Completion<any>,
        CompletionMT
    )
end

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
function Completion.subscribe<U>(completion: Completion<U>, listener: function(completion: Completion<U>)): function()
    if completion == nil or type(listener) ~= "function" then
        error("tecs: completion subscription needs a completion and listener", 2)
    end
    completion._watchers = completion._watchers + 1
    local active = true
    local at: integer
    at = listen(
        completion as Completion<any>,
        function(settled: Completion<any>)
            if not active then
                return
            end
            active = false
            listener(settled as Completion<U>)
        end
    )
    return function()
        if not active then
            return
        end
        active = false
        unlisten(completion as Completion<any>, at)
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
