-- Task-facing prototype over the native one-shot TCP reactor.
--
-- Existing public TCPSocket values supply connection setup and ownership. This
-- adapter changes only how an already connected socket waits, keeping the
-- experiment separate from the public I/O contract.

local ffi <const> = require("ffi")
local rust <const> = require("tecs.ffi.rust")
local loader <const> = require("tecs.ffi.loader")
local type binaryIO = require("tecs.io")
local type iotypes = require("tecs.io.types")
local type tasks = require("tecs.internal.taskruntime")
local task <const> = require("tecs.internal.taskruntime")

local C <const> = rust.C

local READABLE <const> = 1
local WRITABLE <const> = 2
local DEFAULT_TIMEOUT_MS <const> = 5000

local record Reactor
    _handle: loader.CPtr
    _closed: boolean
    _nextToken: integer
    _byToken: {integer: Socket}
    _tokenOut: loader.CArray
    _readinessOut: loader.CArray
    _readyNsOut: loader.CArray

    wrap: function(self: Reactor, socket: binaryIO.TCPSocket): Socket
    poll: function(self: Reactor, timeoutMs?: integer): integer, string
    close: function(self: Reactor)
end

local record Socket
    _reactor: Reactor
    _socket: binaryIO.TCPSocket
    _gate: tasks.Gate
    _token: integer
    _armed: boolean
    _readyNs: number
    _cancelError: string

    readInto: function(self: Socket, destination: iotypes.Buffer, offset?: integer, maxBytes?: integer): integer, string
    writeFrom: function(self: Socket, source: iotypes.Buffer, offset?: integer, count?: integer): integer, string
    lastReadyNs: function(self: Socket): number
end

local REACTOR_MT <const>: metatable<Reactor> = {__index = Reactor}
local SOCKET_MT <const>: metatable<Socket> = {__index = Socket}

local function nativeReason(): string
    return loader.toString(C.tecsRustError())
end

local function validTimeout(value: integer, level: integer): integer
    if type(value) ~= "number" or value ~= math.floor(value) or value < 0 or value > 2147483647 then
        error("tecs: reactor timeout must be an integer from 0 to 2147483647", level)
    end
    return value
end

local function arm(socket: Socket, interest: integer): boolean, string
    if socket._armed then
        return false, "socket already has a readiness wait"
    end
    if
        tonumber(C.tecsNetReactorWatch(socket._reactor._handle, socket._socket._handle, socket._token, interest)) == 0
    then
        return false, nativeReason()
    end
    socket._armed = true
    return true
end

function Reactor:wrap(socket: binaryIO.TCPSocket): Socket
    if self._closed then
        error("tecs: reactor is closed", 2)
    end
    if socket == nil or socket:isClosed() then
        error("tecs: reactor needs an open TCP socket", 2)
    end
    local token <const> = self._nextToken
    self._nextToken = token + 1
    local wrapped <const> = setmetatable(
        {
            _reactor = self,
            _socket = socket,
            _gate = task.newGate(),
            _token = token,
            _armed = false,
            _readyNs = 0,
            _cancelError = nil,
        } as Socket,
        SOCKET_MT
    )
    self._byToken[token] = wrapped
    return wrapped
end

function Reactor:poll(timeoutMs?: integer): integer, string
    if self._closed then
        return nil, "reactor is closed"
    end
    local timeout <const> = validTimeout(timeoutMs or 0, 2)
    local count <const> = tonumber(C.tecsNetReactorPoll(self._handle, timeout)) as integer
    if count < 0 then
        return nil, nativeReason()
    end
    local delivered = 0
    while true do
        local nextStatus <const> = tonumber(
            C.tecsNetReactorNext(self._handle, self._tokenOut, self._readinessOut, self._readyNsOut)
        ) as integer
        if nextStatus < 0 then
            return nil, nativeReason()
        end
        if nextStatus == 0 then
            break
        end
        local token <const> = tonumber(self._tokenOut[0]) as integer
        local socket <const> = self._byToken[token]
        if socket == nil or not socket._armed then
            return nil, "reactor delivered an unknown TCP readiness token"
        end
        socket._armed = false
        socket._readyNs = tonumber(self._readyNsOut[0]) as number
        socket._gate:complete(tonumber(self._readinessOut[0]) as integer)
        delivered = delivered + 1
    end
    if delivered ~= count then
        return nil, "reactor readiness count did not match its queue"
    end
    return delivered
end

function Reactor:close()
    if self._closed then
        return
    end
    self._closed = true
    for _, socket in pairs(self._byToken) do
        if socket._armed then
            socket._armed = false
            socket._gate:fail("reactor closed")
        end
    end
    C.tecsNetReactorDestroy(self._handle)
    self._handle = nil
    self._byToken = {}
end

local function waitReady(socket: Socket, interest: integer): boolean, string
    if socket._cancelError ~= nil then
        local reason <const> = socket._cancelError
        socket._cancelError = nil
        return false, reason
    end

    local gate <const> = task.newGate(function()
        if not socket._armed then
            return
        end
        if tonumber(C.tecsNetReactorUnwatch(socket._reactor._handle, socket._socket._handle, socket._token)) == 0 then
            socket._cancelError = nativeReason()
            return
        end
        socket._armed = false
    end)
    socket._gate = gate
    local watched, watchReason <const> = arm(socket, interest)
    if not watched then
        return false, watchReason
    end
    local _readiness, reason <const> = gate:wait()
    socket._gate = nil
    if reason ~= nil then
        return false, reason
    end
    return true
end

function Socket:readInto(destination: iotypes.Buffer, offset?: integer, maxBytes?: integer): integer, string
    task.checkSuspension("TCP read")
    while true do
        local count, reason <const> = self._socket:readInto(destination, offset, maxBytes)
        if count ~= nil or reason ~= nil then
            return count, reason
        end
        local ready, readyReason <const> = waitReady(self, READABLE)
        if not ready then
            return nil, readyReason
        end
    end
end

function Socket:writeFrom(source: iotypes.Buffer, offset?: integer, count?: integer): integer, string
    task.checkSuspension("TCP write")
    local written, reason <const> = self._socket:writeFrom(source, offset, count)
    if written == nil then
        return nil, reason
    end
    while true do
        local pending, pendingReason <const> = self._socket:pendingWrites()
        if pending == nil then
            return nil, pendingReason
        end
        if pending == 0 then
            return written
        end
        local ready, readyReason <const> = waitReady(self, WRITABLE)
        if not ready then
            return nil, readyReason
        end
    end
end

function Socket:lastReadyNs(): number
    return self._readyNs
end

local record tasknet
    type Reactor = Reactor
    type Socket = Socket

    newReactor: function(): Reactor, string
    run: function<T>(reactor: Reactor, body: function(tasks.Scope, Reactor): T..., timeoutMs?: integer): T
end

function tasknet.newReactor(): Reactor, string
    local handle <const> = C.tecsNetReactorCreate()
    if handle == nil then
        return nil, nativeReason()
    end
    return setmetatable(
        {
            _handle = handle,
            _closed = false,
            _nextToken = 1,
            _byToken = {},
            _tokenOut = ffi.new("uint32_t[1]") as loader.CArray,
            _readinessOut = ffi.new("uint32_t[1]") as loader.CArray,
            _readyNsOut = ffi.new("uint64_t[1]") as loader.CArray,
        } as Reactor,
        REACTOR_MT
    )
end

function tasknet.run<T>(reactor: Reactor, body: function(tasks.Scope, Reactor): T..., timeoutMs?: integer): T
    if reactor == nil or reactor._closed then
        error("tecs: tasknet.run needs an open reactor", 2)
    end
    local timeout <const> = validTimeout(timeoutMs or DEFAULT_TIMEOUT_MS, 2)
    local scheduler <const> = task.newScheduler()
    local root <const> = scheduler:spawn(function(scope: tasks.Scope): T return body(scope, reactor) end)
    while root.status == "pending" do
        local turns <const> = scheduler:step()
        if root.status == "pending" then
            local events, reason <const> = reactor:poll(turns == 0 and timeout or 0)
            if events == nil then
                error(reason, 2)
            end
            if turns == 0 and events == 0 then
                error("tecs: TCP task runtime timed out with no readiness", 2)
            end
        end
    end
    if root.status == "ready" then
        return root.value
    end
    if root.status == "canceled" then
        error("tecs: TCP root task was canceled: " .. root.error, 2)
    end
    error(root.error, 2)
end

return tasknet
