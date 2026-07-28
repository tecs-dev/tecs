--- Worker threads and channels.
---
--- This is the only sanctioned way to run work off the main thread. Raw
--- thread creation is deliberately not exposed: a LuaJIT FFI callback invoked
--- from a thread the VM did not create is unsafe, and a thread entry point
--- written in Lua is exactly that mistake. The native side does nothing but
--- start a thread with a fresh `lua_State` and move bytes between queues.
---
--- LuaJIT has no shared mutable heap across threads, so a worker cannot see
--- the spawning state's objects at all. Values cross as serialized bytes,
--- encoded here with `string.buffer` rather than in C, which keeps the native
--- side ignorant of what a message contains.
---
--- What can cross is therefore what `string.buffer` can encode: numbers,
--- strings, booleans, and tables of those. Not functions, not userdata, and
--- not cdata pointers into another state's heap.

local ffi <const> = require("ffi")
local buffer <const> = require("string.buffer")
local loader <const> = require("tecs.ffi.loader")

loader.declare("worker")

local C <const>, libraryPath <const> = loader.library("tecsworker", "tecs", "TECS_WORKER_PATH", "worker")

--- Waits indefinitely in `receive`.
local FOREVER <const> = -1

--- A queue of serialized messages, shared between two states.
---
--- Values are copied across, never shared, so what comes out on the far side is a separate
--- object and mutating either one is invisible to the other. A `nil` is encodable and does
--- cross, but `receive` also answers nil for "nothing here", so nil is not usable as a
--- message a reader can recognize.
local record Channel
    --- The native queue this wraps. Nil once `destroy` has run.
    handle: loader.CPtr

    --- Private. True when the native queue has been released, and also true from the start
    --- for a channel obtained through `wrap`, which does not own what it points at.
    _destroyed: boolean
end

--- A thread with a Lua state of its own, and the two channels reaching it.
---
--- Nothing is shared with the spawning state: no globals, no upvalues, no loaded modules.
--- The worker reruns its own requires against `luaPath`.
local record Worker
    --- Messages the worker has not taken yet.
    --- Sampled during `send` and not refreshed afterwards, so between sends it is the count
    --- as of the last one and not what the queue holds now.
    pending: integer

    --- Private. The native thread handle. Nil once `stop` has joined it.
    _handle: loader.CPtr

    --- Private. Spawner to worker.
    _toWorker: Channel

    --- Private. Worker to spawner.
    _fromWorker: Channel

    --- Private. True once `stop` has run, which makes a second `stop` a no-op.
    _joined: boolean
end

--- Worker threads and channels.
---
--- What crosses a channel is what `string.buffer` encodes: numbers, strings, booleans and
--- tables of those, nested no deeper than 32 levels. Anything else is refused at `send`
--- with a message naming the path to the offending value, rather than being handed to the
--- encoder to fail on.
local record workers
    --- A worker thread and its channels.
    Worker: Worker

    --- A message queue between two states.
    Channel: Channel

    --- Absolute path of the loaded native library.
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

--- Creates a channel.
---
--- @return An owning handle: `destroy` on it releases the native queue, so exactly one
---     state should hold it. Raises rather than returning nil when the queue cannot be
---     made.
function Channel.create(): Channel
    local handle = C.tecsChannelCreate()
    if handle == nil then
        error("tecs: cannot create channel", 2)
    end
    local self = setmetatable({} as Channel, ChannelMT)
    self.handle = handle
    self._destroyed = false
    return self
end

--- Wraps a channel pointer handed over by the native side.
---
--- @param handle Must outlive the wrapper; nothing here keeps it alive.
--- @return A borrowing handle. `destroy` on it does nothing, so the state that created the
---     queue stays the one that releases it.
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

--- Serializes `value` and queues it.
---
--- Does not block: the queue has no bound, so a reader that has stopped taking messages
--- grows it rather than pushing back on the writer.
---
--- @param value Copied at this point, so mutating it afterwards does not change what the
---     reader gets. A function, userdata, cdata, a table nested past 32 levels or a table
---     with a key of any of those raises, naming the path to it.
function Channel:send(value: any)
    local rejected = unsendable(value, "value", 0)
    if rejected ~= nil then
        error(("tecs: cannot send to a worker: %s"):format(rejected), 2)
    end

    -- The cast is to satisfy the buffer type declaration, which names only
    -- scalars; the encoder handles tables of scalars fine.
    local encoded = buffer.encode(value as string) as string
    if not C.tecsChannelPush(self.handle, encoded, #encoded) then
        error("tecs: channel send failed", 2)
    end
end

--- Takes the next value, or nil if none arrived.
---
--- `timeoutMs` of zero polls, a negative value waits indefinitely, and any
--- other value waits that long.
---
--- @param timeoutMs Milliseconds. Omitted polls, which is the opposite of the worker-side
---     `receive`, where omitting it waits.
--- @return The next value, or nil. Nil covers an empty queue, a timeout, and a closed and
---     drained channel alike; it is also what a sent nil decodes to, so the three are not
---     distinguishable and nil should not be used as a message.
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
--- sees nil. A `send` after this still enqueues, and nothing will ever take it.
function Channel:close()
    C.tecsChannelClose(self.handle)
end

--- Releases the channel. Safe to call more than once.
---
--- Undelivered messages are dropped. A channel from `wrap` is not owned here, so this does
--- nothing to it. Every other method is unsafe afterwards, since `handle` is gone.
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
    --- Lua source the worker runs. It reaches its channels through
    --- `workers.current()`.
    --- Required; nil raises. Source text, not a path, and it runs in a state that shares
    --- nothing with this one, so it cannot close over anything here.
    source: string
    --- `package.path` for the worker's state. Defaults to this state's, so a
    --- worker resolves the same modules the spawner does.
    luaPath: string
end

--- Starts a worker running `options.source` on its own thread and state.
---
--- Returns as soon as the thread is started, not when the source has run, so a failure
--- inside the source surfaces as `stop`'s status rather than here.
---
--- @return A worker that must be stopped: nothing joins the thread or releases its channels
---     on collection.
function workers.spawn(options: SpawnOptions): Worker
    if options.source == nil then
        error("tecs: a worker needs source", 2)
    end

    local toWorker = Channel.create()
    local fromWorker = Channel.create()

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

--- Queues a value for the worker.
---
--- Refreshes `pending` as a side effect, which is the only thing that does.
---
--- @param value Subject to the same limits as `Channel:send`, and raises the same way.
function Worker:send(value: any)
    self._toWorker:send(value)
    self.pending = self._toWorker:count()
end

--- Takes a result, or nil if none is ready.
---
--- @param timeoutMs Milliseconds. Omitted polls and returns at once; a negative value
---     blocks the calling thread until something arrives, which on the main thread stalls
---     the frame.
--- @return Nil for an empty queue and for a worker that has already exited alike. Whether
---     the worker is still alive is answered by `stop`, not by this.
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
--- A worker is expected to leave its loop when `receive` returns nil on a
--- closed channel, so closing is how it is asked to stop.
---
--- Blocks until the thread exits, with no timeout: a worker that never leaves its loop
--- hangs the caller. Both channels are released afterwards, so results the worker sent and
--- nothing took are dropped; drain them before calling this.
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

--- The worker's own two ends of its channels, as `workers.current` returns them.
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
    --- @param value Subject to the same limits as `Channel:send`, and raises the same way.
    ---     Nothing bounds the queue, so a worker outrunning its spawner grows it.
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

--- The channels of the worker this code is running inside.
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
