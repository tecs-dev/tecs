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
keeps rendering while the worker computes.

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

    --- Reports how many `Worker:receive` calls are suspended.
    ---
    --- A suspended receiver is a system parked on a worker result. The count
    --- exists for tests and debug tooling that need to see the wait rather
    --- than infer it; ordinary game code has no use for it.
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

function Channel:send(value: any)
    local rejected = unsendable(value, "value", 0)
    if rejected ~= nil then
        error(("tecs: cannot send to a worker: %s"):format(rejected), 2)
    end

    -- The cast is to satisfy the buffer type declaration, which names only
    -- scalars; the encoder handles tables of scalars fine.
    local encoded = buffer.encode(value as string) as string
    if not C.tecsChannelPush(self.handle, encoded, #encoded) then
        error("tecs: channel is closed or its bounded queue is full", 2)
    end
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
-- Suspended receivers
-------------------------------------------------------------------------------

-- A cooperative `Worker:receive` parks here and the runtime source below
-- advances it. Nothing native calls back into Lua: the poll runs on the Lua
-- thread and takes results with a zero timeout, which is the same pop a game
-- would write itself.

--- One suspended `Worker:receive`.
local record Parked
    --- The worker whose results this receiver is waiting for.
    worker: Worker

    --- Monotonic milliseconds after which the receiver gives up, or nil to
    --- wait until a result or the worker's end.
    deadline: number

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
    local result <const> = worker._fromWorker:receive(0)
    if result ~= nil then
        return result, true
    end
    -- Closed and drained is the worker's end: its source returned or raised,
    -- and no later poll can produce anything.
    if worker._fromWorker:isClosed() then
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
    -- work and a poll stays exactly what it was.
    local ready <const> = self._fromWorker:receive(0)
    if ready ~= nil or wanted == 0 then
        return ready
    end

    -- Outside a task the caller owns its own thread, so the native wait is
    -- both correct and free of the pump's frame of latency.
    if task.checkWait("worker receive") == "blocking" then
        return self._fromWorker:receive(wanted)
    end
    if self._fromWorker:isClosed() then
        return nil
    end

    local deadline <const> = wanted > 0 and time.now() * 1000.0 + wanted or nil
    return task.awaitCallback(function(resume: function(any)): function()
        if parkedCount >= MAX_PARKED then
            error("tecs: too many worker receives are waiting", 3)
        end
        local entry <const>: Parked = {
            worker = self,
            deadline = deadline,
            active = true,
            resume = resume,
        }
        parkedCount = parkedCount + 1
        parked[parkedCount] = entry
        retainSource()
        return function() unpark(entry) end
    end)
end

--- Results waiting to be taken.
---
--- @return A count that is stale as soon as it is read; the worker may push more at any
---     moment.
function Worker:available(): integer
    return self._fromWorker:count()
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

    return {
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
    }
end

return workers
