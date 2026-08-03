--[=[
Worker threads and channels.

A worker is source text and two queues. It shares nothing with the state
that spawned it, so it reaches its own ends through `workers.current`, and
`spawn` pairs with `stop`:

```teal
local worker <const> = tecs.workers.spawn({source = [[
    local tecs <const> = require("tecs")
    local self <const> = tecs.workers.current()
    while true do
        local job = self:receive()
        if job == nil then break end
        self:send({name = job.name, hash = tecs.data.fnv1a64(job.bytes)})
    end
]]})

worker:send({name = "level1", bytes = "..."})
local answer <const> = worker:receive(1000)
worker:stop()
```

A worker that answers requests rather than streaming results is a call
server, and `Worker:call` reads as an ordinary function call on this side
while `Self:serve` runs the loop on the other:

```teal
local worker <const> = tecs.workers.spawn({source = [[
    local tecs <const> = require("tecs")
    tecs.workers.current():serve(function(job)
        return {name = job.name, hash = tecs.data.fnv1a64(job.bytes)}
    end)
]]})

local answer <const> = worker:call({name = "level1", bytes = "..."})
worker:stop()
```

A channel is a stream, so `call` numbers each request and takes the reply
that carries the same number. Messages the worker sends outside a call stay
queued for `receive`, and a reply nobody awaits any more is discarded.

The worker's source writes a require line because it is a separate state
with a separate global table, which is the one place in a game that does.

This is the only sanctioned way to run work off the main thread. Raw
thread creation is deliberately not exposed: a LuaJIT FFI callback invoked
from a thread the VM did not create is unsafe, and a thread entry point
written in Lua is exactly that mistake.

LuaJIT has no shared mutable heap across threads, so a worker cannot see
the spawning state's objects at all. Values cross as serialized bytes,
encoded here with `string.buffer`.

What can cross is therefore what `string.buffer` can encode: numbers,
strings, booleans, and tables of those. Not functions, not userdata, and
not cdata pointers into another state's heap.

## Waiting on each side

The two `receive` calls have opposite defaults, and the asymmetry is
deliberate rather than an oversight.

`Worker:receive` runs on the thread SDL drives, so it polls by default and
never blocks that thread when asked to wait. A timeout suspends the calling
system cooperatively and resumes it where it left off; outside a system it
blocks the caller while the worker makes progress, which is what startup,
shutdown, and headless tools want.

`Self:receive`, the worker side, waits by default. It runs on the worker's own
thread, where blocking costs nothing a frame can see, and an idle worker that
polled instead would spin a core.

A cooperative wait is served by the runtime pump, which runs once per frame, so
a result costs up to one extra frame against the arrival that produced it. That
is the same trade every other Tecs producer makes, and it buys a frame that
keeps rendering while the worker computes. `Worker:call` pays the same frame,
and outside a system it blocks its caller and pays none of it.

## Several calls at once

One wait parks the whole logical update, so two calls written in a row cost the
sum of both. `tecs.batch` runs them at the same time and returns their results
in the order the callbacks were given, whatever order the replies arrive in:

```teal
local answers <const> = tecs.batch({
    function(): any return hashers[1]:call({name = "level1", bytes = first}) end,
    function(): any return hashers[2]:call({name = "level2", bytes = second}) end,
})
```

One worker serves its own requests one at a time, so overlapping the waits buys
time when the calls go to different workers and buys none when they do not.

## Polling and shutdown

Closing the inbox wakes the worker and returns nil after queued messages drain.
The worker closes its outbox when its source ends, so a spawner waiting on a
result learns that no result is coming rather than waiting forever.

`stop` closes the inbox, joins the thread, and releases both channels. Worker
source must leave its receive loop when the inbox closes or shutdown can wait
indefinitely. `stop` also releases every suspended `Worker:receive` on that
worker with nil, so shutting a worker down never strands a system.

Set `TECS_TRACEPROF` to print a worker's trace aborts when its inbox closes.
Repeated `failed to allocate mcode memory` messages identify LuaJIT
machine-code allocation failures.
]=]

-- Implementation details: The native bridge starts a thread with a fresh
-- `lua_State` and moves opaque byte blocks between queues. Lua serializes and
-- validates values on both sides, so the bridge never inspects a message.

local ffi <const> = require("ffi")
local buffer <const> = require("string.buffer")
local loader <const> = require("tecs.ffi.loader")
local runtime <const> = require("tecs.internal.runtime")
local task <const> = require("tecs.internal.taskruntime")
local time <const> = require("tecs.platform.time")
local type Closeable = require("tecs.types").Closeable

loader.declare("worker")

local C <const>, libraryPath <const> = loader.library("tecsworker", "tecs", "TECS_WORKER_PATH", "worker")

--- Waits indefinitely in `receive`.
local FOREVER <const> = -1

--- Carries serialized messages between two states.
---
--- The channel copies every value across and never shares it, so the receiver gets a separate
--- object and mutating either one is invisible to the other. A `nil` is encodable and does
--- cross, but `receive` also answers nil for "nothing here", so nil is not usable as a
--- message a reader can recognize.
local record Channel is Closeable
    --- Engine-owned. Stores the native queue pointer until `destroy` runs.
    --- Ordinary game code should ignore this field.
    handle: loader.CPtr

    --- Engine-owned. Reports whether this wrapper owns a live native queue.
    --- Ordinary game code should ignore this field.
    _destroyed: boolean

    --- Wraps a channel pointer handed over by the native side.
    ---
    --- @param handle The native side keeps this pointer alive for the wrapper's lifetime.
    --- @return A borrowing handle. `destroy` does nothing, so the state that
    ---     created the queue remains responsible for releasing it.
    wrap: function(handle: loader.CPtr): Channel

    --- Serializes `value` and queues it without blocking.
    ---
    --- Each direction accepts at most 1024 messages and 256 MiB of serialized
    --- bytes. The call raises when either bound is full; it never blocks the
    --- sending thread.
    ---
    --- @param value The channel copies this value before returning. A function,
    ---     userdata, cdata, a table nested past 32 levels, or a table with a key
    ---     of any of those raises and names the path to it.
    send: function(self: Channel, value: any)

    --- Takes the next value, or nil if none arrived.
    ---
    --- A zero timeout polls, a negative timeout waits indefinitely, and any
    --- other value waits that many milliseconds.
    ---
    --- @param timeoutMs The timeout uses milliseconds. Omit it to poll, which
    ---     is the opposite of the worker-side `receive`, where omission waits.
    --- @return The next value, or nil. Nil covers an empty queue, a timeout,
    ---     and a closed and drained channel. A sent nil also decodes to nil, so
    ---     callers cannot distinguish those cases and should not send nil.
    receive: function(self: Channel, timeoutMs?: number): any

    --- Reports whether the channel is closed.
    ---
    --- Closed and empty is the one state that will never produce another
    --- value, which is what separates a reader that should give up from one
    --- that should wait. Queued messages still arrive after a close, so a
    --- closed channel that still has a count is not yet finished.
    ---
    --- @return True once `close` has run on either side, whether or not
    ---     messages remain queued. A destroyed channel also reports true.
    isClosed: function(self: Channel): boolean
end

--- Represents a thread with its own Lua state and two message channels.
---
--- The worker shares no globals, upvalues or loaded modules with the spawning state.
--- The worker reruns its own requires against `luaPath`.
local record Worker
    --- Read-only. Reports the messages the worker had not taken after the last
    --- `send`. The value does not refresh between sends.
    pending: integer

    --- Engine-owned. Stores the native thread handle until `stop` joins it.
    --- Ordinary game code should ignore this field.
    _handle: loader.CPtr

    --- Engine-owned. Stores the spawner-to-worker channel. Ordinary game code
    --- should ignore this field.
    _toWorker: Channel

    --- Engine-owned. Stores the worker-to-spawner channel. Ordinary game code
    --- should ignore this field.
    _fromWorker: Channel

    --- Engine-owned. Reports whether `stop` has joined the worker. Ordinary
    --- game code should ignore this field.
    _joined: boolean

    --- Engine-owned. Numbers the next request `call` issues on this worker.
    --- Ordinary game code should ignore this field.
    _nextCallId: integer

    --- Engine-owned. Holds the identifier of every call this worker has issued
    --- and not yet answered, which is what tells a reply somebody awaits from
    --- one nobody does. Ordinary game code should ignore this field.
    _pendingIds: {integer: boolean}

    --- Engine-owned. Holds replies taken off the channel before the call that
    --- issued them read one. Ordinary game code should ignore this field.
    _replies: {integer: any}

    --- Engine-owned. Buffers messages that answer no call until an ordinary
    --- `receive` takes one. Ordinary game code should ignore this field.
    _inbox: {any}

    --- Engine-owned. Indexes the oldest buffered message in `_inbox`.
    --- Ordinary game code should ignore this field.
    _inboxFirst: integer

    --- Engine-owned. Indexes the newest buffered message in `_inbox`, and sits
    --- below `_inboxFirst` when nothing is buffered. Ordinary game code should
    --- ignore this field.
    _inboxLast: integer

    --- Queues a value for the worker and refreshes `pending`.
    ---
    --- @param value The worker applies the same limits and errors as `Channel:send`.
    send: function(self: Worker, value: any)

    --- Takes a result, waiting for one when asked.
    ---
    --- A ready result returns inline. A wait suspends the calling system
    --- cooperatively and resumes it at this call, so other systems, rendering,
    --- and input keep running; outside a system the call blocks its caller
    --- instead. Never blocks the SDL thread from inside a system.
    ---
    --- A suspended wait is served by the runtime pump, which runs once per
    --- frame, so a result can arrive up to one frame after the worker sent it.
    ---
    --- @param timeoutMs The timeout uses milliseconds. Omit it or pass zero to
    ---     poll and return immediately, which is the opposite of the
    ---     worker-side `receive`, where omission waits. A negative value waits
    ---     until a result arrives or the worker ends, and any other value
    ---     waits at most that long.
    --- @return The next result, or nil. Nil covers an empty queue, an expired
    ---     timeout, and a worker that has ended without sending one. A stopped
    ---     worker answers nil without waiting.
    receive: function(self: Worker, timeoutMs?: number): any

    --- Sends a request, waits for its answer, and returns it.
    ---
    --- The call reads as an ordinary function call: the worker runs the
    --- request and the reply arrives at this line. A channel is a stream, so
    --- each call carries an identifier and takes only the reply that carries
    --- the same one. Messages the worker sends outside a call stay queued for
    --- `receive` and are never consumed here.
    ---
    --- A wait suspends the calling system cooperatively and resumes it at this
    --- call, so other systems, rendering, and input keep running; outside a
    --- system the call blocks its own caller instead. A suspended call is
    --- served by the runtime pump, which runs once per frame, so a reply can
    --- arrive up to one frame after the worker sent it. Several calls placed
    --- in `tecs.batch` run at the same time and their results come back in
    --- argument order.
    ---
    --- Both halves cross as serialized bytes, exactly as `send` does, so a
    --- request and a reply carry numbers, strings, booleans, and tables of
    --- those. A live handle, a socket, a file, or cdata cannot cross, and a
    --- worker that returns one has its call fail rather than its thread.
    ---
    --- The worker answers with [`Self:serve`](tealdoc:tecs.workers.Self),
    --- which is the loop that reads a request and sends its handler's result
    --- back under the same identifier.
    ---
    --- @param value The request the worker receives, under the same limits and
    ---     errors as `Worker:send`.
    --- @return The value the worker's handler returned for this request.
    ---     Raises the worker's own reason when its handler failed, and raises
    ---     when the worker ended, was stopped, or had already been stopped,
    ---     because no reply can follow any of those.
    call: function(self: Worker, value: any): any
end

local record workers
    --- Read-only. Exposes the [`Worker`](tealdoc:tecs.workers.Worker) type.
    Worker: Worker

    --- Read-only. Exposes the [`Channel`](tealdoc:tecs.workers.Channel) type.
    Channel: Channel

    --- Creates an independent channel.
    ---
    --- @return An owning handle. `destroy` releases the native queue, so
    ---     exactly one state should hold it. Raises when the queue cannot be
    ---     created.
    newChannel: function(): Channel

    --- Reports how many `Worker:receive` and `Worker:call` waits are suspended.
    ---
    --- A suspended receiver is a system parked on a worker result or a call
    --- reply. The count exists for tests and debug tooling that need to see
    --- the wait rather than infer it; ordinary game code has no use for it.
    ---
    --- @return The number of receivers waiting across every worker. Zero once
    ---     they have all resumed, been canceled, or had their worker stopped.
    parked: function(): integer

    --- Read-only. Contains the absolute path of the loaded native library.
    path: string
end

workers.Channel = Channel
workers.Worker = Worker
workers.path = libraryPath

local ChannelMT <const>: metatable<Channel> = {__index = Channel}
local WorkerMT <const>: metatable<Worker> = {__index = Worker}

local messageOut <const> = loader.newArray("void*[1]")

-------------------------------------------------------------------------------
-- Channels
-------------------------------------------------------------------------------

function workers.newChannel(): Channel
    local handle = C.tecsChannelCreate()
    if handle == nil then
        error("tecs: cannot create channel", 2)
    end
    local self = setmetatable({} as Channel, ChannelMT)
    self.handle = handle
    self._destroyed = false
    return self
end

function Channel.wrap(handle: loader.CPtr): Channel
    local self = setmetatable({} as Channel, ChannelMT)
    self.handle = handle
    -- Not owned: the state that created it destroys it.
    self._destroyed = true
    return self
end

--- Types that survive the trip. A worker shares neither heap nor upvalues
--- with the state that spawned it, so anything holding a reference into this
--- state cannot cross.
local SENDABLE <const>: {string: boolean} = {
    number = true,
    string = true,
    boolean = true,
    ["nil"] = true,
}

--- Reports the path to the first value that cannot cross, or nil.
---
--- Checked rather than left to the encoder. Letting the encoder fail is not
--- only a worse message, it is a path that has proved unsafe: a failure
--- raised out of the C encoder while worker threads are running has
--- intermittently terminated the process rather than surfacing. Refusing to
--- call it with something it will reject keeps that path unreached.
local function unsendable(value: any, path: string, depth: integer): string
    local kind = type(value)
    if SENDABLE[kind] then
        return nil
    end
    if kind ~= "table" then
        return ("%s is a %s"):format(path, kind)
    end
    if depth > 32 then
        return ("%s nests deeper than 32 levels"):format(path)
    end
    for key, item in pairs(value as {any: any}) do
        if not SENDABLE[type(key)] then
            return ("%s has a %s key"):format(path, type(key))
        end
        local found = unsendable(item, ("%s.%s"):format(path, tostring(key)), depth + 1)
        if found ~= nil then
            return found
        end
    end
    return nil
end

--- Encodes a value already known to be sendable and queues it.
---
--- Split out so a caller that has run `unsendable` over its own payload does
--- not pay for a second walk of the same tables when it wraps that payload.
local function pushEncoded(channel: Channel, value: any)
    -- The cast is to satisfy the buffer type declaration, which names only
    -- scalars; the encoder handles tables of scalars fine.
    local encoded <const> = buffer.encode(value as string) as string
    if not C.tecsChannelPush(channel.handle, encoded, #encoded) then
        error("tecs: channel is closed or its bounded queue is full", 3)
    end
end

function Channel:send(value: any)
    local rejected = unsendable(value, "value", 0)
    if rejected ~= nil then
        error(("tecs: cannot send to a worker: %s"):format(rejected), 2)
    end
    pushEncoded(self, value)
end

function Channel:receive(timeoutMs?: number): any
    local size = tonumber(C.tecsChannelPop(self.handle, messageOut, timeoutMs or 0)) as integer
    if size == 0 then
        return nil
    end

    local message = messageOut[0]
    local payload = C.tecsChannelData(message)
    -- Copied out before the message is freed; the decoded value must not
    -- reference storage the native side is about to release.
    local encoded = ffi.string(payload as string, size) as string
    C.tecsChannelFree(message)
    return buffer.decode(encoded) as any
end

--- Messages waiting on the channel.
---
--- @return A count that is already stale by the time it is read, since the other thread is
---     free to push or pop in between. Useful for reporting, not for deciding.
function Channel:count(): integer
    return tonumber(C.tecsChannelCount(self.handle)) as integer
end

function Channel:isClosed(): boolean
    if self.handle == nil then
        return true
    end
    -- The FFI hands back a Lua boolean for a C `bool`; the generated cdef
    -- types every return as an opaque C value.
    return C.tecsChannelIsClosed(self.handle) as boolean
end

--- Wakes anything blocked on this channel so it can stop.
---
--- Already-queued messages are still delivered: a reader drains what is there and only then
--- sees nil. A `send` after this raises.
function Channel:close(): boolean, string
    C.tecsChannelClose(self.handle)
    return true
end

--- Releases the channel. Safe to call more than once.
---
--- This method drops undelivered messages. It does nothing to a channel from `wrap`, which
--- owns no queue. Every other method is unsafe afterwards, since `handle` is gone.
function Channel:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    C.tecsChannelDestroy(self.handle)
    self.handle = nil
end

-------------------------------------------------------------------------------
-- Message routing
-------------------------------------------------------------------------------

-- A channel is a stream, so a reply has to name the request it answers. Both
-- states agree on this one key, in both directions, and it is a compatibility
-- surface rather than an identifier: a worker body written against `serve`
-- carries it in every request it reads and every reply it sends, so renaming it
-- silently stops matching answers to callers.
local CALL_ID <const> = "__tecsCallId"

--- Reports the call a message belongs to, or nil when it belongs to none.
---
--- @param message Reads a request on the worker's side and a reply on the
---     spawner's, since both carry the same key.
--- @return The identifier, or nil for an ordinary `send` message.
local function callIdOf(message: any): integer
    if type(message) ~= "table" then
        return nil
    end
    local id <const> = (message as {string: any})[CALL_ID]
    if type(id) ~= "number" then
        return nil
    end
    return id as integer
end

--- Takes the oldest buffered ordinary message, or nil when none is buffered.
local function takeInbox(worker: Worker): any
    local first <const> = worker._inboxFirst
    if first > worker._inboxLast then
        return nil
    end
    local message <const> = worker._inbox[first]
    worker._inbox[first] = nil
    if first == worker._inboxLast then
        worker._inboxFirst = 1
        worker._inboxLast = 0
    else
        worker._inboxFirst = first + 1
    end
    return message
end

--- Takes the reply this call is owed, or nil when none has arrived.
local function takeReply(worker: Worker, id: integer): {string: any}
    local reply <const> = worker._replies[id] as {string: any}
    if reply ~= nil then
        worker._replies[id] = nil
    end
    return reply
end

--- Forgets a call, so a reply that arrives for it later is discarded.
local function forgetCall(worker: Worker, id: integer)
    worker._pendingIds[id] = nil
    worker._replies[id] = nil
end

--- Takes one message off the worker's channel and files it where its reader
--- looks for it.
---
--- Every read path routes through this, so a reply never hides an ordinary
--- message behind it and an ordinary message never sits in front of a reply.
---
--- @param timeoutMs Reaches the channel unchanged: zero polls, and a negative
---     value waits until a message arrives or the channel closes and drains.
--- @return True when a message was taken, whichever kind it was.
local function routeOne(worker: Worker, timeoutMs: number): boolean
    local message <const> = worker._fromWorker:receive(timeoutMs)
    if message == nil then
        return false
    end

    local id <const> = callIdOf(message)
    if id == nil then
        local last <const> = worker._inboxLast + 1
        worker._inbox[last] = message
        worker._inboxLast = last
        return true
    end

    -- A reply whose call is no longer pending is one nobody awaits: its caller
    -- was canceled and dropped the identifier on the way out, so the answer is
    -- discarded by that identifier rather than handed to whoever calls next.
    if worker._pendingIds[id] then
        worker._pendingIds[id] = nil
        worker._replies[id] = message
    end
    return true
end

-------------------------------------------------------------------------------
-- Suspended receivers
-------------------------------------------------------------------------------

-- A cooperative `Worker:receive` or `Worker:call` parks here and the runtime
-- source below advances it. Nothing native calls back into Lua: the poll runs
-- on the Lua thread and takes results with a zero timeout, which is the same
-- pop a game would write itself.

--- One suspended `Worker:receive` or `Worker:call`.
local record Parked
    --- The worker whose results this receiver is waiting for.
    worker: Worker

    --- Monotonic milliseconds after which the receiver gives up, or nil to
    --- wait until a result or the worker's end.
    deadline: number

    --- The call whose reply this receiver is owed, or nil when it is an
    --- ordinary `receive` waiting for any message the worker did not send in
    --- answer to a call.
    callId: integer

    --- False once the receiver has been resumed or canceled, so a snapshot
    --- taken before either still skips it.
    active: boolean

    --- Delivers the result and resumes the suspended caller.
    resume: function(any)
end

local parked <const>: {Parked} = {}
local parkedCount = 0
local turning <const>: {Parked} = {}

-- Registration is tracked with this flag rather than inferred from
-- `parkedCount`, because the count is also what `releaseSource` reads and a
-- second `runtime.register` under the same name raises.
local sourceRegistered = false

local pollParked: function(): integer
local shutdownParked: function()

-- Bounded so a runaway system reports its own mistake rather than growing the
-- poll until the frame does.
local MAX_PARKED <const> = 1024

local function releaseSource()
    if sourceRegistered and parkedCount == 0 then
        sourceRegistered = false
        runtime.unregister("workers")
    end
end

local function retainSource()
    if not sourceRegistered then
        sourceRegistered = true
        runtime.register("workers", 15, pollParked, shutdownParked)
    end
end

local function unpark(entry: Parked)
    if not entry.active then
        return
    end
    entry.active = false
    entry.worker = nil
    local last <const> = parkedCount
    for index = 1, last do
        if parked[index] == entry then
            parked[index] = parked[last]
            parked[last] = nil
            parkedCount = last - 1
            break
        end
    end
    releaseSource()
end

--- Reports the result a parked receiver should be given, and whether it is due.
---
--- @return The result, or nil when the receiver is due for a nil answer.
--- @return True when the receiver should resume now.
local function settleParked(entry: Parked): any, boolean
    local worker <const> = entry.worker
    if worker._joined then
        return nil, true
    end

    local callId <const> = entry.callId
    if callId ~= nil then
        local reply = takeReply(worker, callId)
        local routed = false
        if reply == nil then
            routed = routeOne(worker, 0)
            reply = takeReply(worker, callId)
        end
        if reply ~= nil then
            return reply, true
        end
        -- A turn that routed a message for somebody else says nothing about
        -- whether more are queued, so only an empty turn may read the close.
        if not routed and worker._fromWorker:isClosed() then
            return nil, true
        end
        return nil, false
    end

    -- Buffered first, so a reply routed ahead of an ordinary message does not
    -- leave that message behind it.
    local message = takeInbox(worker)
    if message ~= nil then
        return message, true
    end
    local routed <const> = routeOne(worker, 0)
    message = takeInbox(worker)
    if message ~= nil then
        return message, true
    end
    -- Closed and drained is the worker's end: its source returned or raised,
    -- and no later poll can produce anything.
    if not routed and worker._fromWorker:isClosed() then
        return nil, true
    end
    if entry.deadline ~= nil and time.now() * 1000.0 >= entry.deadline then
        return nil, true
    end
    return nil, false
end

--- Advances every suspended receiver once. Registered as the `workers` runtime
--- source while at least one receiver is parked.
---
--- @return The number of receivers this poll resumed.
pollParked = function(): integer
    -- A snapshot, because resuming a receiver removes it and may park another.
    local turns <const> = parkedCount
    for index = 1, turns do
        turning[index] = parked[index]
    end

    local resumed = 0
    for index = 1, turns do
        local entry <const> = turning[index]
        turning[index] = nil
        if entry.active then
            local result <const>, due <const> = settleParked(entry)
            if due then
                local deliver <const> = entry.resume
                unpark(entry)
                deliver(result)
                resumed = resumed + 1
            end
        end
    end
    return resumed
end

--- Resumes suspended receivers with nil, so nothing stays parked on a worker
--- that is going away.
---
--- @param worker Releases only this worker's receivers. Nil releases every
---     parked receiver, which is what application shutdown needs.
local function releaseParked(worker: Worker)
    local turns <const> = parkedCount
    for index = 1, turns do
        turning[index] = parked[index]
    end
    for index = 1, turns do
        local entry <const> = turning[index]
        turning[index] = nil
        if entry.active and (worker == nil or entry.worker == worker) then
            local deliver <const> = entry.resume
            unpark(entry)
            deliver(nil)
        end
    end
end

--- Suspends the calling system until its message or its reply is due.
---
--- Both waits park the same way, and the only difference is what the poll
--- looks for on their behalf.
---
--- @param callId Names the call awaiting a reply, or nil for an ordinary
---     receive, which takes the next message that answers no call.
--- @param deadline Monotonic milliseconds after which the receiver gives up,
---     or nil to wait until the worker answers or ends.
--- @return The message, the reply, or nil when the wait produced neither.
local function parkFor(worker: Worker, callId: integer, deadline: number): any
    return task.awaitCallback(function(resume: function(any)): function()
        if parkedCount >= MAX_PARKED then
            if callId ~= nil then
                forgetCall(worker, callId)
            end
            error("tecs: too many worker receives are waiting", 3)
        end
        local entry <const>: Parked = {
            worker = worker,
            deadline = deadline,
            callId = callId,
            active = true,
            resume = resume,
        }
        parkedCount = parkedCount + 1
        parked[parkedCount] = entry
        retainSource()
        -- Cancellation reaches here, and a canceled call has to drop its
        -- identifier so the reply it can no longer take is discarded rather
        -- than settling whichever call runs next.
        return function()
            unpark(entry)
            if callId ~= nil then
                forgetCall(worker, callId)
            end
        end
    end)
end

function workers.parked(): integer
    return parkedCount
end

-- Shutdown runs after the world has already canceled its suspended systems, so
-- this is the safety net that keeps a stranded receiver from holding the source
-- open and failing the registry's own end-of-run check.
shutdownParked = function() releaseParked(nil); releaseSource() end

-------------------------------------------------------------------------------
-- Workers
-------------------------------------------------------------------------------

--- Options for `workers.spawn`.
local record SpawnOptions
    --- Caller-writable. Sets the Lua source the worker runs. It reaches its channels through
    --- `workers.current()`.
    --- Required; nil raises. Source text, not a path, and it runs in a state that shares
    --- nothing with this one, so it cannot close over anything here.
    source: string
    --- Caller-writable. Sets `package.path` for the worker's state. Defaults to this state's, so a
    --- worker resolves the same modules the spawner does.
    luaPath: string
end

--- Starts a worker running `options.source` on its own thread and state.
---
--- Returns as soon as the thread starts, not when the source has run, so a failure
--- inside the source surfaces as `stop`'s status rather than here.
---
--- @return A worker the caller must stop. Collection does not join the thread or release
---     its channels.
function workers.spawn(options: SpawnOptions): Worker
    if options.source == nil then
        error("tecs: a worker needs source", 2)
    end

    local toWorker = workers.newChannel()
    local fromWorker = workers.newChannel()

    local handle = C.tecsWorkerSpawn(
        options.source, options.luaPath or package.path, toWorker.handle, fromWorker.handle
    )
    if handle == nil then
        toWorker:destroy()
        fromWorker:destroy()
        error("tecs: cannot spawn worker", 2)
    end

    local self = setmetatable({} as Worker, WorkerMT)
    self._handle = handle
    self._toWorker = toWorker
    self._fromWorker = fromWorker
    self._joined = false
    self.pending = 0
    self._nextCallId = 1
    self._pendingIds = {}
    self._replies = {}
    self._inbox = {}
    self._inboxFirst = 1
    self._inboxLast = 0
    return self
end

function Worker:send(value: any)
    self._toWorker:send(value)
    self.pending = self._toWorker:count()
end

function Worker:receive(timeoutMs?: number): any
    local wanted <const> = timeoutMs or 0
    if type(wanted) ~= "number" then
        error("tecs: a worker receive timeout must be a number of milliseconds", 2)
    end
    if self._joined then
        return nil
    end

    -- Attempted before anything else, so a ready result costs no scheduler
    -- work and a poll stays exactly what it was. Buffered messages come first,
    -- then whatever routing turns up, and a reply routed on the way is filed
    -- for its own caller rather than answered here.
    local ready = takeInbox(self)
    while ready == nil and routeOne(self, 0) do
        ready = takeInbox(self)
    end
    if ready ~= nil or wanted == 0 then
        return ready
    end

    -- Outside a task the caller owns its own thread, so the native wait is
    -- both correct and free of the pump's frame of latency.
    if task.checkWait("worker receive") == "blocking" then
        local expiry <const> = wanted > 0 and time.now() * 1000.0 + wanted or nil
        while true do
            local remaining: number = FOREVER
            if expiry ~= nil then
                remaining = expiry - time.now() * 1000.0
                if remaining <= 0 then
                    return nil
                end
            end
            if not routeOne(self, remaining) then
                return nil
            end
            local message <const> = takeInbox(self)
            if message ~= nil then
                return message
            end
        end
    end
    if self._fromWorker:isClosed() then
        return nil
    end

    local deadline <const> = wanted > 0 and time.now() * 1000.0 + wanted or nil
    return parkFor(self, nil, deadline)
end

function Worker:call(value: any): any
    if self._joined then
        error("tecs: cannot call a worker that has been stopped", 2)
    end
    local rejected <const> = unsendable(value, "value", 0)
    if rejected ~= nil then
        error(("tecs: cannot send to a worker: %s"):format(rejected), 2)
    end

    local id <const> = self._nextCallId
    self._nextCallId = id + 1
    local request <const>: {string: any} = {value = value}
    request[CALL_ID] = id
    pushEncoded(self._toWorker, request)
    self.pending = self._toWorker:count()
    -- Registered after the push and before anything routes: routing runs on
    -- this thread, and no Lua runs between these two lines.
    self._pendingIds[id] = true

    local reply = takeReply(self, id)
    while reply == nil and routeOne(self, 0) do
        reply = takeReply(self, id)
    end

    if reply == nil and task.checkWait("worker call") == "blocking" then
        while reply == nil and routeOne(self, FOREVER) do
            reply = takeReply(self, id)
        end
    elseif reply == nil then
        reply = parkFor(self, id, nil) as {string: any}
    end

    if reply == nil then
        forgetCall(self, id)
        error("tecs: the worker ended before it answered this call", 2)
    end
    local failure <const> = reply.error as string
    if failure ~= nil then
        error(("tecs: a worker call failed: %s"):format(failure), 2)
    end
    return reply.result
end

--- Results waiting to be taken.
---
--- @return A count that is stale as soon as it is read; the worker may push more at any
---     moment. Counts messages already routed into this worker's buffer along
---     with everything still on the channel, so a call reply the worker has
---     sent and nothing has routed yet is counted until a read files it away.
function Worker:available(): integer
    return self._fromWorker:count() + (self._inboxLast - self._inboxFirst + 1)
end

--- Closes the worker's inbox and waits for it to finish.
---
--- The worker should leave its loop when `receive` returns nil on a closed
--- channel. Closing the inbox asks it to stop.
---
--- Blocks until the thread exits, with no timeout: a worker that never leaves its loop
--- hangs the caller. This method releases both channels afterwards and drops unread results;
--- drain them before calling this.
---
--- Every suspended `Worker:receive` on this worker resumes with nil first, so
--- stopping a worker never leaves a system parked on a thread that is gone.
---
--- @return The thread's exit status. Zero for a worker that ran to the end of its source,
---     one for a worker whose source raised, and also zero for a second call on a worker
---     already stopped, so the two are not distinguishable.
function Worker:stop(): integer
    if self._joined then
        return 0
    end
    self._joined = true
    releaseParked(self)
    self._toWorker:close()
    local status = tonumber(C.tecsWorkerJoin(self._handle)) as integer
    self._handle = nil
    self._toWorker:destroy()
    self._fromWorker:destroy()

    -- Nothing can answer an outstanding call now, and nothing can read a
    -- buffered message, so the correlation state goes with the channels.
    for index = self._inboxFirst, self._inboxLast do
        self._inbox[index] = nil
    end
    self._inboxFirst = 1
    self._inboxLast = 0
    for id in pairs(self._pendingIds) do
        self._pendingIds[id] = nil
    end
    for id in pairs(self._replies) do
        self._replies[id] = nil
    end
    return status
end

-------------------------------------------------------------------------------
-- Worker side
-------------------------------------------------------------------------------

--- Contains the worker's two channel endpoints returned by `workers.current`.
local record Self
    --- Takes the next task, or nil when the inbox closes.
    ---
    --- @param timeoutMs Milliseconds. Omitted waits indefinitely, which is the opposite of
    ---     `Channel:receive`; zero polls. Only the waiting form's nil means the spawner has
    ---     asked this worker to stop, since a poll answers nil for a merely empty queue.
    --- @return The next task, decoded into this state's own tables, so it shares
    ---     nothing with what the spawner sent and mutating it is safe. Nil is the
    ---     stop signal or an empty queue, on the terms above.
    receive: function(self: Self, timeoutMs?: number): any

    --- Returns a result to the spawner.
    ---
    --- @param value Subject to the same item and byte limits as
    ---     `Channel:send`, and raises the same way.
    send: function(self: Self, value: any)

    --- Answers `Worker:call` requests until the inbox closes.
    ---
    --- This is the worker side of a call: it reads a request, runs `handler`,
    --- and sends what the handler returned back under the identifier the
    --- request arrived with, which is what lets the spawner match a reply to
    --- the call that is waiting for it.
    ---
    --- Every message reaches `handler`, so a worker that also receives
    --- ordinary `Worker:send` messages serves both from one loop. A message
    --- that is not a call request takes no reply, and the handler's return
    --- value for one is discarded; answer those with `send` instead.
    ---
    --- A handler that raises does not end the worker. Its reason crosses back
    --- and `Worker:call` raises it at the call site, and the loop reads the
    --- next request.
    ---
    --- ```teal
    --- local tecs <const> = require("tecs")
    --- tecs.workers.current():serve(function(job: any): any
    ---     return {hash = tecs.data.fnv1a64(job.bytes)}
    --- end)
    --- ```
    ---
    --- @param handler The worker runs this once per message and sends its
    ---     first return value back as the reply. A return value that cannot be
    ---     serialized reaches the caller as a failure rather than raising on
    ---     this thread. Nil raises.
    serve: function(self: Self, handler: function(any): any)
end

--- Watches this state's trace aborts when `TECS_TRACEPROF` is set, so the
--- question of whether a worker compiles at all has an answer measured from
--- inside it.
---
--- It is worth asking because nothing else reports it. A worker's machine code
--- has to sit within a branch's reach of the interpreter, the host holds a
--- block of that address space open so there is somewhere for it to go, and a
--- state that finds nowhere anyway runs entirely interpreted with
--- `jit.status()` still answering true. Aborts reading `failed to allocate
--- mcode memory` in the tens of thousands are that failure and nothing else.
---
--- Returns a function that writes the report, or nil when nothing is watching.
local function watchTraces(): function()
    if os.getenv("TECS_TRACEPROF") == nil then
        return nil
    end
    local profile <const> = require("tecs.utils.profile")
    local session <const> = profile.trace()
    return function()
        local report <const> = session:stop()
        local lines <const> = {
            ("worker traces: %d aborts, %d blacklisted"):format(report.totalAborts, report.blacklisted)
        }
        for index = 1, math.min(#report.sites, 5) do
            local site <const> = report.sites[index]
            lines[#lines + 1] = ("  %7d  %s  %s"):format(site.count, site.reason, site.location)
        end
        io.stderr:write(table.concat(lines, "\n") .. "\n")
    end
end

--- Returns the channels for the current worker.
---
--- Only valid in a worker's state, where the native entry point installed the
--- pointers as globals before running the source.
---
--- @return A fresh object each call, borrowing channels the spawner owns. Call it once and
---     keep the result: a second call makes a second pair of wrappers over the same two
---     queues, and under `TECS_TRACEPROF` a second trace session, which raises.
function workers.current(): Self
    local globals = _G as {string: any}
    local inbox = globals["__tecsWorkerIn"]
    local outbox = globals["__tecsWorkerOut"]
    if inbox == nil or outbox == nil then
        error("tecs: workers.current is only valid inside a worker", 2)
    end

    local incoming = Channel.wrap(ffi.cast("void *", inbox) as loader.CPtr)
    local results = Channel.wrap(ffi.cast("void *", outbox) as loader.CPtr)
    local reportTraces = watchTraces()

    local self: Self = nil

    --- Sends what a handler produced back under the identifier its request
    --- carried, or the reason it could not be produced.
    local function answer(id: integer, ok: boolean, result: any)
        local reply <const>: {string: any} = {}
        reply[CALL_ID] = id
        if not ok then
            reply.error = tostring(result)
        else
            local rejected <const> = unsendable(result, "result", 0)
            if rejected ~= nil then
                reply.error = ("a call result cannot cross: %s"):format(rejected)
            else
                reply.result = result
            end
        end
        pushEncoded(results, reply)
    end

    self = {
        receive = function(_self: Self, timeoutMs?: number): any
            local value = incoming:receive(timeoutMs or FOREVER)
            -- A wait with no timeout returns nil only when the inbox closes,
            -- which is how a worker is asked to stop; that is where a report
            -- covering the whole run belongs. A polling receive returns nil
            -- whenever the queue is empty and says nothing about the state.
            if value == nil and timeoutMs == nil and reportTraces ~= nil then
                reportTraces()
                reportTraces = nil
            end
            return value
        end,
        send = function(_self: Self, value: any) results:send(value) end,
        serve = function(_self: Self, handler: function(any): any)
            if type(handler) ~= "function" then
                error("tecs: serve needs a handler", 2)
            end
            while true do
                local message <const> = self:receive()
                if message == nil then
                    return
                end
                local id <const> = callIdOf(message)
                if id == nil then
                    handler(message)
                else
                    -- A handler that raises fails its own call and nothing
                    -- else: the reason crosses back, and the loop reads on.
                    local ok <const>, result <const> = pcall(handler, (message as {string: any}).value)
                    answer(id, ok, result)
                end
            end
        end,
    }
    return self
end

return workers
