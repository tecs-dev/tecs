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
local loader <const> = require("tecs2d.ffi.loader")

loader.declare("worker")

local C <const>, libraryPath <const> =
    loader.library("tecs2dworker", "tecs2d", "TECS2D_WORKER_PATH", "worker")

--- Waits indefinitely in `receive`.
local FOREVER <const> = -1

local record Channel
    handle: loader.CPtr
    _destroyed: boolean
end

local record Worker
    --- Messages the worker has not taken yet.
    pending: integer
    _handle: loader.CPtr
    _toWorker: Channel
    _fromWorker: Channel
    _joined: boolean
end

local record workers
    Worker: Worker
    Channel: Channel
    --- Absolute path of the loaded native library.
    path: string
end

workers.Channel = Channel
workers.Worker = Worker
workers.path = libraryPath

local ChannelMT <const>: metatable<Channel> = { __index = Channel }
local WorkerMT <const>: metatable<Worker> = { __index = Worker }

local messageOut <const> = loader.newArray("void*[1]")

-------------------------------------------------------------------------------
-- Channels
-------------------------------------------------------------------------------

--- Creates a channel.
function Channel.create(): Channel
    local handle = C.tecs2dChannelCreate()
    if handle == nil then error("tecs2d: cannot create channel", 2) end
    local self = setmetatable({} as Channel, ChannelMT)
    self.handle = handle
    self._destroyed = false
    return self
end

--- Wraps a channel pointer handed over by the native side.
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
    number = true, string = true, boolean = true, ["nil"] = true,
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
    if SENDABLE[kind] then return nil end
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
        local found = unsendable(item, ("%s.%s"):format(path, tostring(key)),
            depth + 1)
        if found ~= nil then return found end
    end
    return nil
end

--- Serializes `value` and queues it.
function Channel:send(value: any)
    local rejected = unsendable(value, "value", 0)
    if rejected ~= nil then
        error(("tecs2d: cannot send to a worker: %s"):format(rejected), 2)
    end

    -- The cast is to satisfy the buffer type declaration, which names only
    -- scalars; the encoder handles tables of scalars fine.
    local encoded = buffer.encode(value as string) as string
    if not C.tecs2dChannelPush(self.handle, encoded, #encoded) then
        error("tecs2d: channel send failed", 2)
    end
end

--- Takes the next value, or nil if none arrived.
---
--- `timeoutMs` of zero polls, a negative value waits indefinitely, and any
--- other value waits that long.
function Channel:receive(timeoutMs?: number): any
    local size = tonumber(
        C.tecs2dChannelPop(self.handle, messageOut, timeoutMs or 0)) as integer
    if size == 0 then return nil end

    local message = messageOut[0]
    local payload = C.tecs2dChannelData(message)
    -- Copied out before the message is freed; the decoded value must not
    -- reference storage the native side is about to release.
    local encoded = ffi.string(payload as string, size) as string
    C.tecs2dChannelFree(message)
    return buffer.decode(encoded) as any
end

--- Messages waiting on the channel.
function Channel:count(): integer
    return tonumber(C.tecs2dChannelCount(self.handle)) as integer
end

--- Wakes anything blocked on this channel so it can stop.
function Channel:close()
    C.tecs2dChannelClose(self.handle)
end

--- Releases the channel. Safe to call more than once.
function Channel:destroy()
    if self._destroyed then return end
    self._destroyed = true
    C.tecs2dChannelDestroy(self.handle)
    self.handle = nil
end

-------------------------------------------------------------------------------
-- Workers
-------------------------------------------------------------------------------

local record SpawnOptions
    --- Lua source the worker runs. It reaches its channels through
    --- `workers.current()`.
    source: string
    --- `package.path` for the worker's state. Defaults to this state's, so a
    --- worker resolves the same modules the spawner does.
    luaPath: string
end

--- Starts a worker running `options.source` on its own thread and state.
function workers.spawn(options: SpawnOptions): Worker
    if options.source == nil then
        error("tecs2d: a worker needs source", 2)
    end

    local toWorker = Channel.create()
    local fromWorker = Channel.create()

    local handle = C.tecs2dWorkerSpawn(options.source,
        options.luaPath or package.path, toWorker.handle, fromWorker.handle)
    if handle == nil then
        toWorker:destroy()
        fromWorker:destroy()
        error("tecs2d: cannot spawn worker", 2)
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
function Worker:send(value: any)
    self._toWorker:send(value)
    self.pending = self._toWorker:count()
end

--- Takes a result, or nil if none is ready.
function Worker:receive(timeoutMs?: number): any
    return self._fromWorker:receive(timeoutMs)
end

--- Results waiting to be taken.
function Worker:available(): integer
    return self._fromWorker:count()
end

--- Closes the worker's inbox and waits for it to finish.
---
--- A worker is expected to leave its loop when `receive` returns nil on a
--- closed channel, so closing is how it is asked to stop.
function Worker:stop(): integer
    if self._joined then return 0 end
    self._joined = true
    self._toWorker:close()
    local status = tonumber(C.tecs2dWorkerJoin(self._handle)) as integer
    self._handle = nil
    self._toWorker:destroy()
    self._fromWorker:destroy()
    return status
end

-------------------------------------------------------------------------------
-- Worker side
-------------------------------------------------------------------------------

local record Self
    --- Takes the next task, or nil when the inbox closes.
    receive: function(self: Self, timeoutMs?: number): any
    --- Returns a result to the spawner.
    send: function(self: Self, value: any)
end

--- The channels of the worker this code is running inside.
---
--- Only valid in a worker's state, where the native entry point installed the
--- pointers as globals before running the source.
function workers.current(): Self
    local globals = _G as {string: any}
    local inbox = globals["__tecs2dWorkerIn"]
    local outbox = globals["__tecs2dWorkerOut"]
    if inbox == nil or outbox == nil then
        error("tecs2d: workers.current is only valid inside a worker", 2)
    end

    local incoming = Channel.wrap(ffi.cast("void *", inbox) as loader.CPtr)
    local results = Channel.wrap(ffi.cast("void *", outbox) as loader.CPtr)

    return {
        receive = function(_self: Self, timeoutMs?: number): any
            return incoming:receive(timeoutMs or FOREVER)
        end,
        send = function(_self: Self, value: any)
            results:send(value)
        end,
    }
end

return workers
