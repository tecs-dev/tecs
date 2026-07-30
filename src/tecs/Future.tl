--[=[
A value that settles once, and the combinators over it.

Assets, child processes, and HTTP requests return
[`Future`](tealdoc:tecs.Future)`<T>`. Compose their
results without blocking a frame:

```teal no-format
tecs.platform.os.runProcess({args = {"git", "rev-parse", "HEAD"}})
    :map(function(result: tecs.platform.os.ProcessResult): string
        return result.output
    end)
    :recover(function(): string
        return "unknown"
    end)
    :onSettle(function(revision: tecs.Future<string>)
        print(revision.value)
    end)
```

## Settlement

`status` starts as `"pending"` and moves once to `"ready"`, `"failed"`, or
`"canceled"`. A process exit code or HTTP error status still produces a ready
result because the operation returned an answer. Failure means the operation
produced none.

Reading `value` is the blocking dereference. It advances a pending future for
its source's default wait budget, returns a ready result, and raises on failure,
cancellation, or a budget that expires first. Successful non-nil results are
stored directly, so reads after settlement are ordinary field reads. Use
`status` and `error` when inspecting an outcome without raising.

`map` transforms a ready value. `flatMap` starts dependent work and adopts its
future. `recover` turns failure into a value. Canceled futures skip all three
transforms except cancellation propagation.

Listeners run in registration order. With no delivery in progress, registering
a listener after settlement runs it before `onSettle` returns. During delivery,
a new listener joins the current drain instead of growing the Lua stack. It may
run after that nested `onSettle` returns, but before the outermost drain returns.

## Pumping and waiting

A future advances when its subsystem pumps the source.
[`Application`](tealdoc:tecs.Application) frames do
that automatically. `wait` pumps in blocking slices for startup, tools, and
tests:

```teal no-format
local result <const> = tecs.platform.os.runProcess({
    args = {"git", "status", "--porcelain"},
})
    :wait(2000)

if result.status == "ready" then
    print(result.value.output)
end
```

Do not call `wait` or read a pending `value` from a frame. A timeout leaves the
future pending. A listener must not wait on another pending future driven by the
same non-reentrant source.

Waiting until a subsystem has nothing outstanding is that subsystem's own drain
rather than a join over futures a caller holds. `Future.all` reads its inputs
once and holds each one, so it answers for a set fixed at the call and not for a
set that work started during the wait joins.

A source must settle its futures on the same thread that pumps it.

Canceling releases one consumer's interest. Shared operations stop only after
their last consumer releases the root future.

## Snapshots

A snapshot never stores a future because it contains runtime listeners and
source state. A saved sequence cursor retains only its provider, entity, and
key. Reissue and track the work under the same key after load when the wait
must continue.

So a future is not a component field. Keep it in a table beside the world,
keyed by the entity waiting on it, and give that entity a transient marker
instead. A snapshot writer that reaches a future walks its listener graph
rather than refusing the component, so the save fails without naming either.
]=]

-- Implementation details: Worker-backed sources copy serialized results
-- through a channel. The pumping thread decodes those results and settles the
-- futures, so a worker thread never reaches a listener.

local log <const> = require("tecs.log")
local time <const> = require("tecs.platform.time")
local type types = require("tecs.types")
local Context <const> = require("tecs.internal.Context")
local seqawaitables <const> = require("tecs.sequence.internal.awaitables")

local type World = types.World

-- A logger name is what `SDL_SetLogPriority` filters on, so it is configuration
-- a developer types into a shell rather than a name this tree can rename in one
-- commit. It stays `"tecs.future"` now that the public name is `tecs.Future`.
local LOGGER <const> = log.get("tecs.future")

--- Reads the monotonic counter, in milliseconds.
---
--- Through `time.now` rather than the binding, because a wait's budget is
--- wall time, and `time.now` defines the clock that a replay
--- provider does not reach. A recorded run must not shorten or lengthen how
--- long code waits for a decode.
local now <const> = function(): number return time.now() * 1000.0 end

--- Milliseconds a wait spends when neither the caller nor the source says.
local DEFAULT_WAIT_MS <const> = 5000

--- Milliseconds one blocking slice costs when the source does not say.
local DEFAULT_SLICE_MS <const> = 16

local record Future<T>
    --- Receives a settled future.
    type Listener = function(future: Future<any>)

    --- Defines how a future receives settlements and advances a blocking wait.
    ---
    --- Every source in this tree is something that can be told to block for up
    --- to N milliseconds and hand over whatever arrived, which is the whole of
    --- what a future needs from the work behind it. An asset decode and a child
    --- process are a worker channel; an HTTP transfer is a Reqwest task whose
    --- bounded event queue has the same shape.
    record Source
        --- Caller-writable. Takes every ready result and settles its future.
        ---
        --- Called once per frame per source, and costs a non-blocking receive
        --- that answers nil on any frame where nothing finished.
        --- @param self The source to poll.
        --- @return Returns the number of futures settled by this poll.
        poll: function(self: Source): integer

        --- Caller-writable. Blocks up to `ms` for one result and settles its
        --- future.
        ---
        --- What `Future:wait` spends a slice in, so it must not block for
        --- longer than the requested duration.
        --- @param self The source to advance.
        --- @param ms The maximum number of milliseconds to block.
        --- @return Returns the number of futures settled while advancing.
        advance: function(self: Source, ms: number): integer

        --- Caller-writable. Sets the maximum milliseconds one `wait` slice
        --- blocks. The source may omit it to use 16.
        sliceMs: number

        --- Caller-writable. Sets the milliseconds `wait` spends when its caller
        --- supplies no timeout. The source may omit it to use 5000.
        defaultWaitMs: number

        --- Caller-writable. Stops the work behind a root future after its last
        --- watcher leaves.
        ---
        --- Optional. A source with no hook leaves the work running and stops
        --- caring, which is what a future over something uncancelable can
        --- honestly do.
        --- @param self The source that owns the work.
        --- @param future The root future whose last watcher left.
        cancel: function(self: Source, future: Future<any>)
    end

    --- Read-only. Reports `"pending"`, `"ready"`, `"failed"` or `"canceled"`.
    --- The source changes it once, and game code should not assign it.
    status: string
    --- Read-only. Returns the result, waiting for it when necessary.
    ---
    --- A pending read advances the source for its default wait budget. A
    --- `"failed"` or `"canceled"` result raises with `error`, as does a future
    --- that remains pending after that budget. A pending future with no source
    --- raises immediately because nothing can advance it. Waiting here has the
    --- same frame and source-reentrancy constraints as `wait`.
    ---
    --- The source writes this field, and game code should not assign it.
    value: T
    --- Read-only. Explains a `"failed"` or `"canceled"` result. The source
    --- writes it, and game code should not assign it.
    error: string

    --- Engine-owned. Stores the current settlement source. Ordinary game code
    --- should ignore this field.
    _source: Source
    --- Engine-owned. Stores registered dependents in delivery order. Ordinary
    --- game code should ignore this field.
    _listeners: {Listener}
    --- Engine-owned. Records the number of registered listeners without using
    --- the length of a sparse array. Ordinary game code should ignore it.
    _listenerCount: integer
    --- Engine-owned. Records how many listeners have run. Ordinary game code
    --- should ignore this field.
    _delivered: integer
    --- Engine-owned. Counts consumers while this future remains pending.
    --- Ordinary game code should ignore this field.
    _watchers: integer
    --- Engine-owned. Reports whether this future owns source work that can be
    --- canceled. Ordinary game code should ignore this field.
    _owned: boolean
    --- Engine-owned. Stores the upstream future for a derived link. Ordinary
    --- game code should ignore this field.
    _upstream: Future<any>
    --- Engine-owned. Stores this link's listener index in the upstream future.
    --- Ordinary game code should ignore this field.
    _upstreamAt: integer
    --- Engine-owned. Stores every upstream future in a join. Ordinary game
    --- code should ignore this field.
    _upstreams: {Future<any>}

    --- Registers a dependent, and returns this future.
    ---
    --- The primitive the others are built on. With no delivery in progress, a
    --- listener on a future that has already settled runs before this call
    --- returns. During delivery, a new listener joins the current drain instead
    --- of growing the Lua stack. It may run after this nested call returns, but
    --- before the outermost drain returns. A listener that raises writes to the
    --- log and does not stop the others.
    ---
    --- @param self The future on which to register the listener.
    --- @param listener Called once, with this future, whichever of the three terminal
    ---     states it reached; read `status` rather than assuming a value. Nil raises.
    --- @return This same future, not a derived one, so chaining `onSettle` registers
    ---     several listeners on one thing rather than building a chain.
    onSettle: function(self: Future<T>, listener: function(future: Future<T>)): Future<T>

    --- Returns a future carrying `transform` applied to this future's value.
    ---
    --- `transform` runs only on "ready". A "failed" or "canceled" upstream
    --- propagates without calling it, and a raise inside it becomes this link's
    --- failure.
    ---
    --- @param self The future whose ready value to transform.
    --- @param transform Called at most once, with the upstream value. Nil raises here and
    ---     now rather than at settlement.
    --- @return A new future watching this one. Canceling it gives up this link's interest
    ---     in the upstream and does not settle the upstream unless nothing else wants it.
    map: function<U>(self: Future<T>, transform: function(value: T): U): Future<U>

    --- Returns a future that adopts the future started by `transform`.
    ---
    --- The one combinator that expresses a dependent second request. Two things
    --- follow from `transform` starting work rather than transforming work
    --- already done: the derived future's source becomes the inner future's, so
    --- a chain can begin on a worker and end somewhere else; and canceling
    --- before the outer settles prevents any call to `transform`, since
    --- there is nothing yet to cancel afterwards.
    ---
    --- @param self The future whose ready value starts the dependent work.
    --- @param transform Called at most once, on "ready" only. Returning nil rather than a
    ---     future fails this link; nil for `transform` itself raises here and now.
    --- @return A new future settling to whatever the inner one settles to, status and all,
    ---     so canceling an inner leaves this future canceled and not failed.
    flatMap: function<U>(self: Future<T>, transform: function(value: T): Future<U>): Future<U>

    --- Returns a future that turns this future's failure into a value.
    ---
    --- `recovery` runs only on "failed". A "canceled" upstream is not
    --- recovered, which is the whole reason the two are distinct states.
    ---
    --- @param self The future whose failure to recover.
    --- @param recovery Given the upstream's error string. Raising inside it fails this
    ---     link with that raise instead, so a recovery cannot fail silently. Nil raises
    ---     here and now.
    --- @return A new future watching this one, carrying the same type: a recovery
    ---     produces a value where the upstream produced an error, so a ready
    ---     upstream passes through untouched.
    recover: function(self: Future<T>, recovery: function(err: string): T): Future<T>

    --- Blocks until this future settles, advancing its source.
    ---
    --- For startup, tools and tests; a frame polls `status` instead. Never a
    --- busy loop: the time is spent inside the source's blocking receive. The
    --- budget is wall clock rather than a count of slices, so a source that
    --- answers faster than its slice size does not shorten the wait.
    ---
    --- A future with no source cannot advance and returns at once.
    --- @param self The future to wait for.
    --- @param timeoutMs How long to wait. Defaults to the source's
    ---     `defaultWaitMs`, or 5000. Running out leaves it "pending".
    --- @return This future.
    wait: function(self: Future<T>, timeoutMs?: number): Future<T>

    --- Gives up this consumer's interest in the work.
    ---
    --- Reference counted, because a shared root is real: two loads of one path
    --- that overlap get the same future, and one of them canceling must not
    --- break the other. So this decrements, and only the last one settles the
    --- future "canceled" and asks the source to stop the work. Canceling a
    --- derived future drops its listener and decrements its upstream, which may
    --- in turn reach zero.
    ---
    --- Canceling a settled future is a no-op.
    --- @param self The future whose consumer interest to release.
    cancel: function(self: Future<T>)

    --- Settles this future with a value, if nothing has settled it yet.
    ---
    --- The producer half. Whoever created a future through `Future.pending`
    --- owns this and its sibling `fail`; a future handed out by a subsystem is
    --- settled by that subsystem's source, and calling this on one is a caller
    --- settling work it does not own. Settling twice is a no-op, so the first
    --- answer wins.
    ---
    --- @param self The future to settle.
    --- @param value Stored as it is, not copied, and read back off `value`. Nil is a legal
    ---     value and still settles "ready", which is how a future over nothing settles.
    complete: function(self: Future<T>, value: T)

    --- Settles this future as failed, if nothing has settled it yet.
    ---
    --- @param self The future to fail.
    --- @param err A sentence for a log, not something to match on. Nil becomes "failed",
    ---     so `error` is set on every failed future.
    fail: function(self: Future<T>, err: string)

    --- Settles this future as canceled, if nothing has settled it yet.
    ---
    --- The producer half of the third terminal state, and the counterpart of
    --- `cancel` rather than a spelling of it: `cancel` is a consumer saying it
    --- no longer wants the work and counts the others who might, while this
    --- states an outcome that has already happened. A child killed on request
    --- or at its deadline reaches its future through here, as does a transfer
    --- taken off the multi.
    ---
    --- @param self The future to settle as canceled.
    --- @param err Nil becomes "canceled". No watcher counting happens here: this settles
    ---     the future outright, whoever else was waiting on it.
    abandon: function(self: Future<T>, err: string)

    ---------------------------------------------------------------------------
    -- Statics
    ---------------------------------------------------------------------------

    --- Creates a future nothing has settled yet.
    ---
    --- The producer half, for a source settling its own work and for a test
    --- that decides when something finishes. `source` is what a `wait` on it
    --- advances. When omitted, only code that holds the future can settle it,
    --- and a `wait` on it returns at once.
    ---
    --- @param source The optional source that advances blocking waits.
    --- @return A future at "pending" with one watcher, so a single `cancel` on it settles
    ---     it "canceled" and calls the source's hook.
    pending: function<U>(source?: Source): Future<U>

    --- Creates a future that already carries a value.
    ---
    --- @param value The value to store without copying.
    --- @return A future at "ready" with no source, so `wait` on it returns at once and
    ---     `cancel` does nothing. A listener added to it follows the synchronous
    ---     and reentrant delivery contract documented on `onSettle`.
    settled: function<U>(value: U): Future<U>

    --- Creates a future that already carries a failure.
    ---
    --- @param err Nil becomes "failed".
    --- @return A future at "failed" with no source, so `wait` on it returns at once
    ---     and `cancel` does nothing. `map` on it propagates without running the
    ---     transform, while `recover` on it is the one thing that still runs.
    failed: function<U>(err: string): Future<U>

    --- Joins every input value into one future in input order.
    ---
    --- Settles when the last input does, whatever order they settle in. A
    --- failed or canceled input fails the join with that input's error; the
    --- rest are left running, because an input shared with something outside
    --- the join is not this join's to stop. A caller that wants every outcome
    --- rather than the first failure puts a `recover` on each input, which is
    --- the shape a value that may be missing already uses.
    ---
    --- Fan-in does not nest: each listener decrements a counter and only the
    --- last input settles the join, so a join over five hundred loads is two
    --- deep rather than five hundred.
    ---
    --- Joining takes a hold on every input, so an input the join is still
    --- waiting for is not abandoned while the join lives, and canceling the join
    --- releases every one of those holds. A join dropped without being canceled
    --- keeps them, which is why a barrier over work another subsystem started is
    --- a drain on that subsystem rather than a join here: the hold would outlive
    --- the wait and leave that subsystem's own `cancel` unable to reach zero.
    ---
    --- An input that settles "ready" carrying nil fails the join rather than
    --- filling its slot, because nil is a legal value and an array cannot hold
    --- one: the slot would read as absent and every index past it would be
    --- past a hole. A caller with a value that may be missing recovers to
    --- something rather than to nil.
    ---
    --- @param inputs Read once; adding to the list afterwards changes nothing. Empty gives
    ---     an already-ready future over an empty array. Nil raises.
    --- @return A future whose value is a fresh array in `inputs` order. The join
    ---     settles "ready" only after every slot contains a value, so no hole can appear.
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
    --- program constant, so a program awaits a future by the name used to track it
    --- under rather than by identity, which is what lets the wait survive a
    --- snapshot the future cannot. And only the fixed clock delivers awaits, so
    --- a program on the frame or presentation clock parked on a future is
    --- released by a fixed step; that is already true of every awaitable.
    ---
    --- Tecs drops the entry when the future settles, so a program that reaches
    --- its await after the work finished carries on rather than hanging, and
    --- nothing accumulates. Tracking a second future under one entity and key
    --- replaces the first.
    ---
    --- There is no `setPaused`: the asset worker cannot pause a decode in flight, and the
    --- contract says a provider that cannot pause its work does not offer it.
    ---
    --- @param world The world that owns the bound entity.
    --- @param entity What the await binds to, and it must still be alive when the program
    ---     parks; the VM releases a cursor whose entity is dead.
    --- @param key A program constant, not something derived per call, since the await
    ---     names it. Nil or empty raises.
    --- @param future Nil raises. One that has already settled is deliberately not written
    ---     down, so a later await on that key carries straight on rather than hanging.
    track: function<U>(world: World, entity: integer, key: string, future: Future<U>)
end

local type Source = Future.Source

--- Returns the stored value without invoking the public blocking read.
local function storedValue(future: Future<any>): any
    return rawget(future as table, "value")
end

--- Resolves methods and the one field whose absence means work is pending.
local function futureIndex(self: Future<any>, key: string): any
    if key ~= "value" then
        return (Future as {string: any})[key]
    end

    if self.status == "pending" then
        if self._source == nil then
            error("tecs: cannot read the value of a pending future with no source", 2)
        end
        self:wait()
    end

    if self.status == "ready" then
        return storedValue(self)
    elseif self.status == "failed" then
        error("tecs: future failed: " .. (self.error or "failed"), 2)
    elseif self.status == "canceled" then
        error("tecs: future was canceled: " .. (self.error or "canceled"), 2)
    end
    error("tecs: future remained pending after its wait budget expired", 2)
end

local FutureMT <const>: metatable<Future<any>> = {__index = futureIndex}

-------------------------------------------------------------------------------
-- The drain
-------------------------------------------------------------------------------

-- Settling a future runs its dependents, and a dependent may settle another
-- future. Calling into that recursively makes the Lua stack as deep as the
-- chain, and a chain is not bounded by anything in the source text: a paginated
-- fetch written as a recursive `flatMap` builds link N inside the settlement of
-- link N-1, so its depth is the number of pages. Appending instead means the
-- depth is two frames whatever the chain length, and it is why registering a
-- listener on an already-settled future routes through this queue rather than
-- invoking it directly.
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

    -- Already settled: route the listener through the drain rather than calling
    -- it directly. An idle drain runs before `listen` returns; a reentrant call
    -- joins the active drain. `_delivered` keeps earlier listeners from running
    -- a second time when this future comes round again.
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
--- already settled runs the listener from inside `listen`, and that listener
--- needs the derived future before it runs.
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
            -- Canceled while the upstream was still going: this link is settled
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
            -- work rather than transforming work already done, so a chain canceled
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
                    settle(derived, settledInner.status, storedValue(settledInner), settledInner.error)
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
                settle(derived, upstream.status, storedValue(upstream), upstream.error)
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
    settle(self as Future<any>, "canceled", nil, err or "canceled")
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
-- Canceling
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

    self.status = "canceled"
    self.error = "canceled"

    local source = self._source
    if self._owned and source ~= nil and source.cancel ~= nil then
        source:cancel(self as Future<any>)
    end

    local upstream = self._upstream
    if upstream ~= nil then
        -- Dropped before decrementing, so an upstream that settles anyway does
        -- not call back into a link that is already canceled.
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
    return setmetatable(
        {
            sources = distinct,
            at = 0,
            sliceMs = distinct[1].sliceMs,
            defaultWaitMs = distinct[1].defaultWaitMs,
        } as RoundRobin,
        RoundRobinMT
    ) as Source
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
                local filling = settledInput.value
                if filling == nil then
                    -- The count below is of filled slots and not of
                    -- settlements, which is what makes the promise above true.
                    -- Storing nil fills nothing: the slot would read as absent
                    -- and the array would be short, so the join says so here
                    -- rather than handing back something with a hole in it.
                    settle(joined, "failed", nil, ("tecs: input %d settled with no value"):format(at))
                    return
                end
                values[at] = filling as U
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

--- Futures where a sequence can park, indexed by entity and then key.
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

-- The provider name a program writes into `sequence.await`, so it is reached
-- from a saved program rather than from code this tree can see. It stays
-- `"tecs.future"` now that the public name is `tecs.Future`.
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
