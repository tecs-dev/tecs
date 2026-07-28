--- A value that settles once, and the combinators over it.
---
--- Three subsystems in this tree used to own a private settle-once cell with
--- four states, a failure string, a blocking wait that pumped a worker, and a
--- word of its own for each state. They were the same object written more than
--- once. This is that object, written here, and what a subsystem returns
--- instead: `Future<proc.Result>` rather than a `Proc`. No subsystem exports an
--- alias for this type; callers write `Future`.
---
--- ## Four states
---
--- `status` is `"pending"`, `"ready"`, `"failed"` or `"cancelled"`, and it is a
--- plain string field rather than a method, because several call sites read it
--- once a frame and a field read plus a string compare is what that should
--- cost.
---
--- `"cancelled"` is separate from `"failed"` because `recover` must not run for
--- it: a caller who cancelled a load did not ask for a fallback value. An
--- unwelcome answer is also not `"failed"`: a child process that exits 1 and an
--- HTTP response that is 404 both settle `"ready"`, because the code is the
--- answer rather than an error. `"failed"` means the work never produced one.
---
--- ## One thread
---
--- Futures are created and settled on the thread that pumps their source, and
--- there is no synchronisation anywhere below. That is what removes the atomics
--- a general-purpose future library carries, so it is load-bearing rather than
--- incidental: **a source must settle its futures on the thread that pumps
--- it.** The only cross-thread boundary any source here has is
--- `Channel:receive`, which copies the bytes out before anything decodes them,
--- so no worker-owned memory and no worker thread reaches a listener. If a
--- second thread ever pumps a source, the answer is a queue handing
--- settlements back to the pumping thread, not a lock-free stack.
---
--- ## Order
---
--- Listeners run in registration order, and futures settled during one drain
--- are drained in the order they settled. Neither is arbitrary: a listener that
--- registers an image allocates through a shelf packer whose coordinates depend
--- on arrival order and end up in a `Sprite` component, which a snapshot
--- stores. Order being fixed does not make the system deterministic, because
--- two decodes still race on the worker and arrive in whatever order they
--- finish; it means a given arrival order always produces the same result,
--- which is the part that is in this design's gift.
---
--- ## Snapshots
---
--- A future is never in a snapshot. It holds listeners, a source and, through
--- its source, a native handle. What is snapshotted is a sequence cursor parked
--- on one, which stores a provider name, an entity and a key. So after a load
--- the wait survives and the future does not: nothing has been tracked,
--- `isPending` answers false, and the parked cursor resumes on the next fixed
--- step. That is why the sequence bridge looks a future up by
--- `(world, entity, key)` and never by object identity. A game that wants the
--- wait to mean something after a restore re-issues the work and re-tracks it
--- under the same key.

local log <const> = require("tecs.log")
local clock <const> = require("tecs.platform.clock")
local ecs <const> = require("tecs.ecs")
local Context <const> = require("tecs.internal.Context")
local seqawaitables <const> = require("tecs.sequence.internal.awaitables")

local type World = ecs.World

local LOGGER <const> = log.get("tecs.future")

--- Reads the monotonic counter, in milliseconds.
---
--- Through `clock.now` rather than the binding, because a wait's budget is
--- wall time and `clock.now` is documented as the one reading a replay
--- provider does not reach. A recorded run must not shorten or lengthen how
--- long a decode is waited for.
local now <const> = function(): number return clock.now() * 1000.0 end

--- Milliseconds a wait spends when neither the caller nor the source says.
local DEFAULT_WAIT_MS <const> = 5000

--- Milliseconds one blocking slice costs when the source does not say.
local DEFAULT_SLICE_MS <const> = 16

local record Future<T>
    --- Where a future's settlements come from, and what a blocking wait spends
    --- its time in.
    ---
    --- Every source in this tree is something that can be told to block for up
    --- to N milliseconds and hand over whatever arrived, which is the whole of
    --- what a future needs from the work behind it. An asset decode and a child
    --- process are a worker channel; an HTTP transfer is a curl multi handle,
    --- whose `curl_multi_poll` is the same shape.
    record Source
        --- Takes everything ready and settles what it belongs to.
        ---
        --- Called once per frame per source, and costs a non-blocking receive
        --- that answers nil on any frame where nothing finished.
        --- @return How many settled.
        poll: function(self: Source): integer

        --- Blocks up to `ms` for one settlement and takes it.
        ---
        --- What `Future:wait` spends a slice in, so it must not block for
        --- longer than it is asked to.
        --- @return How many settled.
        advance: function(self: Source, ms: number): integer

        --- Milliseconds one `wait` slice blocks for. Optional; 16 by default.
        sliceMs: number

        --- Milliseconds `wait` spends when the caller names nothing. Optional;
        --- 5000 by default. It lives here rather than on `wait` so a subprocess
        --- can keep a longer default than a decode without a second
        --- convention.
        defaultWaitMs: number

        --- Stops the work behind a root future whose last watcher has gone.
        ---
        --- Optional. A source with no hook leaves the work running and stops
        --- caring, which is what a future over something uncancellable can
        --- honestly do.
        cancel: function(self: Source, future: Future<any>)
    end

    --- "pending", "ready", "failed", or "cancelled".
    status: string
    --- What settled. Valid only on "ready".
    value: T
    --- Why it did not. Set on "failed" and on "cancelled".
    error: string

    --- Where settlements come from. Rewritten when a `flatMap` moves the chain
    --- onto the inner future's source, which is why `wait` re-reads it every
    --- slice rather than caching it.
    _source: Source
    --- Registered dependents, in registration order. Allocated on the first.
    _listeners: {function(Future<any>)}
    --- How many listeners have been registered. Counted rather than measured,
    --- because cancelling a link clears its slot and `#` over an array with a
    --- hole in it is not defined.
    _listenerCount: integer
    --- How many of them have run. A future already settled when a listener is
    --- added is queued again, and this is what stops the earlier listeners
    --- running a second time.
    _delivered: integer
    --- Consumers of this future while it is pending. A deduped load hands the
    --- same future to a second caller and counts it; each derived future counts
    --- as one; the source's cancel hook runs when the count reaches zero.
    _watchers: integer
    --- Whether the source has work of its own behind this future, so the cancel
    --- hook is worth calling. True for a future the source made and false for
    --- every derived one, which inherits the source only so a `wait` on it
    --- knows what to advance. Without this a `map` link giving up would stop
    --- the decode its upstream is still waiting for.
    _owned: boolean
    --- The future this one derives from, so cancelling a link can drop its
    --- listener and decrement what it was watching.
    _upstream: Future<any>
    --- Index of this future's listener in `_upstream._listeners`.
    _upstreamAt: integer
    --- Every input of a join, which has no single upstream. Cancelling the join
    --- decrements all of them.
    _upstreams: {Future<any>}

    --- Registers a dependent, and returns this future.
    ---
    --- The primitive the others are built on. A listener on a future that has
    --- already settled runs on the next drain rather than inline, which is what
    --- keeps a chain built one link at a time from growing the Lua stack. A
    --- listener that raises is logged and does not stop the others.
    onSettle: function(self: Future<T>, listener: function(Future<T>)): Future<T>

    --- A future carrying `transform` applied to this one's value.
    ---
    --- `transform` runs only on "ready". A "failed" or "cancelled" upstream
    --- propagates without calling it, and a raise inside it becomes this link's
    --- failure.
    map: function<U>(self: Future<T>, transform: function(T): U): Future<U>

    --- A future carrying whatever the future `transform` starts settles to.
    ---
    --- The one combinator that expresses a dependent second request. Two things
    --- follow from `transform` starting work rather than transforming work
    --- already done: the derived future's source becomes the inner future's, so
    --- a chain can begin on a worker and end somewhere else; and cancelling
    --- before the outer settles stops `transform` from ever being called, since
    --- there is nothing yet to cancel afterwards.
    flatMap: function<U>(self: Future<T>, transform: function(T): Future<U>): Future<U>

    --- A future that turns this one's failure into a value.
    ---
    --- `recovery` runs only on "failed". A "cancelled" upstream is not
    --- recovered, which is the whole reason the two are distinct states.
    recover: function(self: Future<T>, recovery: function(string): T): Future<T>

    --- Blocks until this future settles, advancing its source.
    ---
    --- For startup, tools and tests; a frame polls `status` instead. Never a
    --- busy loop: the time is spent inside the source's blocking receive. The
    --- budget is wall clock rather than a count of slices, so a source that
    --- answers faster than its slice size does not shorten the wait.
    ---
    --- A future with no source cannot be advanced and returns at once.
    --- @param timeoutMs How long to wait. Defaults to the source's
    ---     `defaultWaitMs`, or 5000. Running out leaves it "pending".
    --- @return This future.
    wait: function(self: Future<T>, timeoutMs?: number): Future<T>

    --- Gives up this consumer's interest in the work.
    ---
    --- Reference counted, because a shared root is real: two loads of one path
    --- that overlap get the same future, and one of them cancelling must not
    --- break the other. So this decrements, and only the last one settles the
    --- future "cancelled" and asks the source to stop the work. Cancelling a
    --- derived future drops its listener and decrements its upstream, which may
    --- in turn reach zero.
    ---
    --- Cancelling a settled future is a no-op.
    cancel: function(self: Future<T>)

    --- Settles this future with a value, if nothing has settled it yet.
    ---
    --- The producer half. Whoever created a future through `Future.pending`
    --- owns this and its sibling `fail`; a future handed out by a subsystem is
    --- settled by that subsystem's source, and calling this on one is a caller
    --- settling work it does not own. Settling twice is a no-op, so the first
    --- answer wins.
    complete: function(self: Future<T>, value: T)

    --- Settles this future as failed, if nothing has settled it yet.
    fail: function(self: Future<T>, err: string)

    --- Settles this future as cancelled, if nothing has settled it yet.
    ---
    --- The producer half of the third terminal state, and the counterpart of
    --- `cancel` rather than a spelling of it: `cancel` is a consumer saying it
    --- no longer wants the work and counts the others who might, while this
    --- states an outcome that has already happened. A child killed on request
    --- or at its deadline reaches its future through here, as does a transfer
    --- taken off the multi.
    abandon: function(self: Future<T>, err: string)

    ---------------------------------------------------------------------------
    -- Statics
    ---------------------------------------------------------------------------

    --- Creates a future nothing has settled yet.
    ---
    --- The producer half, for a source settling its own work and for a test
    --- that decides when something finishes. `source` is what a `wait` on it
    --- advances; omitted, the future can only be settled by whoever holds it
    --- and a `wait` on it returns at once.
    pending: function<U>(source?: Source): Future<U>

    --- A future already carrying a value.
    settled: function<U>(value: U): Future<U>

    --- A future already carrying a failure.
    failed: function<U>(err: string): Future<U>

    --- A future carrying every input's value, in input order.
    ---
    --- Settles when the last input does, whatever order they settle in. A
    --- failed or cancelled input fails the join with that input's error; the
    --- rest are left running, because an input shared with something outside
    --- the join is not this join's to stop.
    ---
    --- Fan-in does not nest: each listener decrements a counter and only the
    --- last input settles the join, so a join over five hundred loads is two
    --- deep rather than five hundred.
    all: function<U>(inputs: {Future<U>}): Future<{U}>

    --- Makes a future something a sequence can wait for.
    ---
    --- The sequencer has a registry for waiting on work outside it, and this
    --- module is its one engine registrant, under the name `"tecs.future"`. So
    --- a program parks on a decode, a subprocess or a request with
    ---
    ---     sequence.await("tecs.future", sequence.bind("loader"), "level1")
    ---
    --- against a future tracked here under that same entity and key.
    ---
    --- Three properties of the machinery underneath, none of them this
    --- function's to change. An await needs a live bound entity, because the VM
    --- releases a cursor whose entity is dead rather than stranding it, so the
    --- key is a pair and the entity is the game's own loader. The key is a
    --- program constant, so a future is awaited by the name it was tracked
    --- under rather than by identity, which is what lets the wait survive a
    --- snapshot the future cannot. And only the fixed clock delivers awaits, so
    --- a program on the frame or presentation clock parked on a future is
    --- released by a fixed step; that is already true of every awaitable.
    ---
    --- The entry is dropped when the future settles, so a program that reaches
    --- its await after the work finished carries on rather than hanging, and
    --- nothing accumulates. Tracking a second future under one entity and key
    --- replaces the first.
    ---
    --- There is no `setPaused`: a decode in flight cannot be paused, and the
    --- contract says a provider that cannot pause its work does not offer it.
    track: function<U>(world: World, entity: integer, key: string, future: Future<U>)
end

local type Source = Future.Source

local FutureMT <const>: metatable<Future<any>> = {__index = Future}

-------------------------------------------------------------------------------
-- The drain
-------------------------------------------------------------------------------

-- Settling a future runs its dependents, and a dependent may settle another
-- future. Calling into that recursively makes the Lua stack as deep as the
-- chain, and a chain is not bounded by anything in the source text: a paginated
-- fetch written as a recursive `flatMap` builds link N inside the settlement of
-- link N-1, so its depth is the number of pages. Appending instead means the
-- depth is two frames whatever the chain length, and it is why registering a
-- listener on an already-settled future queues rather than firing inline.
--
-- It also makes re-entrancy legal by construction rather than by a rule a
-- caller has to remember: a listener may settle, cancel or register on anything
-- it likes, including the future it is being called from.
local draining = false
local queued: {Future<any>} = {}
local queuedCount = 0

local function runListeners(future: Future<any>)
    local listeners = future._listeners
    if listeners == nil then
        return
    end
    -- Re-read the count each turn: a listener may register another.
    local index = future._delivered
    while index < future._listenerCount do
        index = index + 1
        future._delivered = index
        local listener = listeners[index]
        if listener ~= nil then
            local ok, err = pcall(listener, future) as (boolean, any)
            if not ok then
                LOGGER:error("a future listener raised: %s", tostring(err))
            end
        end
    end
end

--- Queues a settled future's listeners, and runs the queue if nothing else is.
local function drain(future: Future<any>)
    queuedCount = queuedCount + 1
    queued[queuedCount] = future
    if draining then
        return
    end

    draining = true
    local index = 1
    while index <= queuedCount do
        local settledFuture = queued[index]
        queued[index] = nil
        index = index + 1
        runListeners(settledFuture)
    end
    queuedCount = 0
    draining = false
end

--- Writes a settlement and drains, if nothing has settled this already.
local function settle(future: Future<any>, status: string, value: any, err: string)
    if future.status ~= "pending" then
        return
    end
    future.status = status
    future.value = value
    future.error = err
    drain(future)
end

-------------------------------------------------------------------------------
-- Creation
-------------------------------------------------------------------------------

local function newFuture(source: Source): Future<any>
    local self = setmetatable({} as Future<any>, FutureMT)
    self.status = "pending"
    self._source = source
    self._listenerCount = 0
    self._delivered = 0
    self._watchers = 1
    return self
end

function Future.pending<U>(source?: Source): Future<U>
    local self = newFuture(source)
    self._owned = source ~= nil
    return self as Future<U>
end

function Future.settled<U>(value: U): Future<U>
    local self = newFuture(nil)
    self.status = "ready"
    self.value = value
    return self as Future<U>
end

function Future.failed<U>(err: string): Future<U>
    local self = newFuture(nil)
    self.status = "failed"
    self.error = err or "failed"
    return self as Future<U>
end

-------------------------------------------------------------------------------
-- Listening
-------------------------------------------------------------------------------

--- Appends a listener and answers where it landed, so a cancel can drop it.
local function listen(future: Future<any>, listener: function(Future<any>)): integer
    local listeners = future._listeners
    if listeners == nil then
        listeners = {}
        future._listeners = listeners
    end
    local at = future._listenerCount + 1
    future._listenerCount = at
    listeners[at] = listener

    -- Already settled: the listener still runs, on the next turn of the drain
    -- rather than from here. `_delivered` is what keeps the earlier listeners
    -- from running a second time when this future comes round again.
    if future.status ~= "pending" then
        drain(future)
    end
    return at
end

function Future:onSettle(listener: function(Future<T>)): Future<T>
    if listener == nil then
        error("tecs: onSettle needs something to call", 2)
    end
    listen(self as Future<any>, listener as function(Future<any>))
    return self
end

--- A future derived from this one: same source, and watching it.
---
--- Built and attached in two steps, because attaching to an upstream that has
--- already settled runs the listener from inside `listen`, and a listener needs
--- the future it settles to exist before it can be called.
local function derive(upstream: Future<any>): Future<any>
    local derived = newFuture(upstream._source)
    derived._upstream = upstream
    upstream._watchers = upstream._watchers + 1
    return derived
end

local function attach(derived: Future<any>, upstream: Future<any>, listener: function(Future<any>))
    derived._upstreamAt = listen(upstream, listener)
end

-------------------------------------------------------------------------------
-- Combinators
-------------------------------------------------------------------------------

--- Copies a non-ready upstream's outcome onto a derived future.
---
--- @return Whether the upstream was ready, so the caller's transform runs.
local function propagate(derived: Future<any>, upstream: Future<any>): boolean
    if upstream.status == "ready" then
        return true
    end
    settle(derived, upstream.status, nil, upstream.error)
    return false
end

function Future:map<U>(transform: function(T): U): Future<U>
    if transform == nil then
        error("tecs: map needs something to transform with", 2)
    end
    local upstreamOf <const> = self as Future<any>
    local derived <const> = derive(upstreamOf)
    attach(
        derived,
        upstreamOf,
        function(upstream: Future<any>)
            -- Cancelled while the upstream was still going: this link is settled
            -- and there is nothing left to transform for.
            if derived.status ~= "pending" then
                return
            end
            if not propagate(derived, upstream) then
                return
            end
            local ok, result = pcall(transform, upstream.value as T) as (boolean, any)
            if ok then
                settle(derived, "ready", result, nil)
            else
                settle(derived, "failed", nil, tostring(result))
            end
        end
    )
    return derived as Future<U>
end

function Future:flatMap<U>(transform: function(T): Future<U>): Future<U>
    if transform == nil then
        error("tecs: flatMap needs something to continue with", 2)
    end
    local upstreamOf <const> = self as Future<any>
    local derived <const> = derive(upstreamOf)
    attach(
        derived,
        upstreamOf,
        function(upstream: Future<any>)
            -- The window this combinator is alone in having. `transform` starts
            -- work rather than transforming work already done, so a chain cancelled
            -- before its outer settled has to stop the inner from ever existing;
            -- there is no inner to cancel afterwards. The settled status is that
            -- flag, checked here, before the call.
            if derived.status ~= "pending" then
                return
            end
            if not propagate(derived, upstream) then
                return
            end

            local ok, result = pcall(transform, upstream.value as T) as (boolean, any)
            if not ok then
                settle(derived, "failed", nil, tostring(result))
                return
            end
            local inner = result as Future<any>
            if inner == nil then
                settle(derived, "failed", nil, "tecs: flatMap returned no future")
                return
            end

            -- The chain moves. A manifest read that starts on the asset worker and
            -- finishes on an HTTP transfer is one future whose source changed
            -- underneath it, which is why `wait` re-reads the source each slice.
            derived._source = inner._source
            derived._upstream = inner
            inner._watchers = inner._watchers + 1
            derived._upstreamAt = listen(
                inner,
                function(settledInner: Future<any>)
                    if derived.status ~= "pending" then
                        return
                    end
                    settle(derived, settledInner.status, settledInner.value, settledInner.error)
                end
            )
        end
    )
    return derived as Future<U>
end

function Future:recover(recovery: function(string): T): Future<T>
    if recovery == nil then
        error("tecs: recover needs something to recover with", 2)
    end
    local upstreamOf <const> = self as Future<any>
    local derived <const> = derive(upstreamOf)
    attach(
        derived,
        upstreamOf,
        function(upstream: Future<any>)
            if derived.status ~= "pending" then
                return
            end
            if upstream.status ~= "failed" then
                settle(derived, upstream.status, upstream.value, upstream.error)
                return
            end
            local ok, result = pcall(recovery, upstream.error) as (boolean, any)
            if ok then
                settle(derived, "ready", result, nil)
            else
                settle(derived, "failed", nil, tostring(result))
            end
        end
    )
    return derived as Future<T>
end

-------------------------------------------------------------------------------
-- Producing
-------------------------------------------------------------------------------

function Future:complete(value: T)
    settle(self as Future<any>, "ready", value, nil)
end

function Future:fail(err: string)
    settle(self as Future<any>, "failed", nil, err or "failed")
end

function Future:abandon(err: string)
    settle(self as Future<any>, "cancelled", nil, err or "cancelled")
end

-------------------------------------------------------------------------------
-- Waiting
-------------------------------------------------------------------------------

function Future:wait(timeoutMs?: number): Future<T>
    if self.status ~= "pending" then
        return self
    end

    local source = self._source
    if source == nil then
        return self
    end

    local budget = timeoutMs
    if budget == nil then
        budget = source.defaultWaitMs or DEFAULT_WAIT_MS
    end
    -- Wall clock, not a count of slices. A source returns from `advance` as
    -- soon as one message arrives, and subtracting the nominal slice size for
    -- it turns "wait 5000 ms" into "wait for at most 312 messages".
    local deadline = now() + budget

    while self.status == "pending" do
        local remaining = deadline - now()
        if remaining <= 0 then
            break
        end
        -- Re-read rather than cache: a `flatMap` link moves it mid-wait.
        source = self._source
        if source == nil then
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

-------------------------------------------------------------------------------
-- Cancelling
-------------------------------------------------------------------------------

--- Drops a link's listener from what it was watching.
local function unlisten(upstream: Future<any>, at: integer)
    if upstream._listeners == nil or at == nil then
        return
    end
    -- Cleared rather than removed: the slot numbers of every later listener are
    -- what their own links recorded, and `runListeners` counts rather than
    -- measures, so a hole costs nothing and moving them would cost correctness.
    upstream._listeners[at] = nil
end

function Future:cancel()
    if self.status ~= "pending" then
        return
    end

    self._watchers = self._watchers - 1
    if self._watchers > 0 then
        return
    end

    self.status = "cancelled"
    self.error = "cancelled"

    local source = self._source
    if self._owned and source ~= nil and source.cancel ~= nil then
        source:cancel(self as Future<any>)
    end

    local upstream = self._upstream
    if upstream ~= nil then
        -- Dropped before decrementing, so an upstream that settles anyway does
        -- not call back into a link that is already cancelled.
        unlisten(upstream, self._upstreamAt)
        self._upstream = nil
        self._upstreamAt = nil
        upstream:cancel()
    end

    local upstreams = self._upstreams
    if upstreams ~= nil then
        self._upstreams = nil
        for index = 1, #upstreams do
            upstreams[index]:cancel()
        end
    end

    drain(self as Future<any>)
end

-------------------------------------------------------------------------------
-- Joining
-------------------------------------------------------------------------------

--- A source that spreads a wait's slices over several.
---
--- Only reached by a join whose inputs come from more than one source, which is
--- no case in this tree today. A join over one source keeps that source, and
--- with it a single blocking receive and its full responsiveness.
local record RoundRobin
    sources: {Source}
    at: integer
    sliceMs: number
    defaultWaitMs: number

    poll: function(self: RoundRobin): integer
    advance: function(self: RoundRobin, ms: number): integer
end

local RoundRobinMT <const>: metatable<RoundRobin> = {__index = RoundRobin}

function RoundRobin:poll(): integer
    local settled = 0
    local sources = self.sources
    for index = 1, #sources do
        settled = settled + sources[index]:poll()
    end
    return settled
end

function RoundRobin:advance(ms: number): integer
    local sources = self.sources
    local count = #sources
    if count == 0 then
        return 0
    end
    -- One source blocks per slice, taken in turn. Dividing the slice between
    -- them instead would divide the responsiveness of each by their number, and
    -- a join is usually waiting on the slowest of them.
    self.at = self.at % count + 1
    return sources[self.at]:advance(ms)
end

--- The one source every input shares, a round robin over the several they do
--- not, or nil when no input has one.
local function sourceFor(inputs: {Future<any>}): Source
    local distinct: {Source} = {}
    local count = 0
    for index = 1, #inputs do
        local source = inputs[index]._source
        if source ~= nil then
            local seen = false
            for at = 1, count do
                if distinct[at] == source then
                    seen = true
                    break
                end
            end
            if not seen then
                count = count + 1
                distinct[count] = source
            end
        end
    end

    if count == 0 then
        return nil
    end
    if count == 1 then
        return distinct[1]
    end
    return setmetatable({
        sources = distinct,
        at = 0,
        sliceMs = distinct[1].sliceMs,
        defaultWaitMs = distinct[1].defaultWaitMs,
    } as RoundRobin, RoundRobinMT) as Source
end

function Future.all<U>(inputs: {Future<U>}): Future<{U}>
    if inputs == nil then
        error("tecs: all needs a list of futures", 2)
    end
    local watched = inputs as {Future<any>}
    local count = #watched
    local values: {U} = {}
    if count == 0 then
        return Future.settled(values)
    end

    local joined = newFuture(sourceFor(watched))
    joined._upstreams = watched
    local remaining = count

    for index = 1, count do
        local input = watched[index]
        local at = index
        input._watchers = input._watchers + 1
        listen(
            input,
            function(settledInput: Future<any>)
                if joined.status ~= "pending" then
                    return
                end
                if settledInput.status ~= "ready" then
                    settle(joined, settledInput.status, nil, settledInput.error)
                    return
                end
                values[at] = settledInput.value as U
                remaining = remaining - 1
                if remaining == 0 then
                    settle(joined, "ready", values, nil)
                end
            end
        )
    end
    return joined as Future<{U}>
end

-------------------------------------------------------------------------------
-- The sequence bridge
-------------------------------------------------------------------------------

local type Tracked = {integer: {string: Future<any>}}

--- Futures a sequence can be parked on, by entity and then by key.
local TRACKED <const> = Context.newKey("tecs.future.tracked", nil as Tracked)

function Future.track<U>(world: World, entity: integer, key: string, future: Future<U>)
    if world == nil then
        error("tecs: track needs a world to track against", 2)
    end
    if type(key) ~= "string" or key == "" then
        error("tecs: track needs a non-empty key", 2)
    end
    local watched = future as Future<any>
    if watched == nil then
        error("tecs: track needs a future", 2)
    end

    local tracked = world.resources[TRACKED]
    if tracked == nil then
        tracked = {}
        world.resources[TRACKED] = tracked
    end
    local byEntity = tracked[entity]
    if byEntity == nil then
        byEntity = {}
        tracked[entity] = byEntity
    end

    -- A future that has already settled is never written down. `isPending`
    -- answers false for a key it does not know, which is what a program
    -- reaching its await after the work finished should see.
    if watched.status ~= "pending" then
        byEntity[key] = nil
        return
    end

    byEntity[key] = watched
    watched:onSettle(function()
        -- Only if this is still the future under that key: tracking a second
        -- one replaces the first, and the first settling afterwards must not
        -- erase its successor.
        if byEntity[key] == watched then
            byEntity[key] = nil
        end
    end)
end

seqawaitables.register(
    "tecs.future",
    {
        isPending = function(world: World, entity: integer, key: string): boolean
            local tracked = world.resources[TRACKED]
            if tracked == nil then
                return false
            end
            local byEntity = tracked[entity]
            if byEntity == nil then
                return false
            end
            local future = byEntity[key]
            return future ~= nil and future.status == "pending"
        end,
    }
)

return Future
