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

## Polling and shutdown

The spawner's `receive` polls by default, which suits a frame. Inside the
worker it waits by default, so an idle worker does not spin. Closing the inbox
wakes the worker and returns nil after queued messages drain.

`stop` closes the inbox, joins the thread, and releases both channels. Worker
source must leave its receive loop when the inbox closes or shutdown can wait
indefinitely.

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

    --- Takes a result, or nil if none is ready.
    ---
    --- @param timeoutMs The timeout uses milliseconds. Omit it to poll and
    ---     return immediately; a negative value blocks until something
    ---     arrives and stalls the frame when called from the main thread.
    --- @return Nil means the queue is empty or the worker has exited. Call
    ---     `stop` to learn whether the worker still runs.
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
    return self._fromWorker:receive(timeoutMs)
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
--- @return The thread's exit status. Zero for a worker that ran to the end of its source,
---     one for a worker whose source raised, and also zero for a second call on a worker
---     already stopped, so the two are not distinguishable.
function Worker:stop(): integer
    if self._joined then
        return 0
    end
    self._joined = true
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
