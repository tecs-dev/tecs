--[=[
Nonblocking TCP and UDP networking.

This module provides transport, not a protocol. A stream is an
ordered sequence of bytes: one write may take several reads to receive,
several writes may arrive in one read, and message framing belongs to the
caller. A datagram preserves one send as one packet, but the network may lose,
duplicate or reorder it.

HTTP and HTTPS live under `tecs.net.http`.

Resolution and client connection return asynchronous
[`Future`](tealdoc:tecs.Future) values.
Call `net.poll` once per frame while either is
pending, or use the future's bounded `wait` method outside a frame.
Listening, accepting, reading, writing and receiving are nonblocking.

```teal
local address <const> = tecs.net.resolve("game.example"):wait()
if address.status == "ready" then
    local stream <const> = tecs.net.connect(address.value, 7777):wait()
    if stream.status == "ready" then
        stream.value:write("ping\n")
        print(stream.value:read())
        stream.value:close()
    end
    address.value:close()
end
```

`wait` is for startup, tools and tests. A frame starts the same two calls,
calls `tecs.net.poll` once an iteration, and reads `status` instead.

Every address, stream, server and datagram socket owns a resource.
Close it explicitly. Closing is idempotent; using a closed value returns a
failure.
]=]

-- Implementation details:
-- Rust's standard library owns the sockets. Workers resolve host names and
-- establish client connections, then Lua polls their results. No native
-- callback enters LuaJIT.
--
-- Reading `tecs.net` does not initialize a protocol. The HTTP runtime starts
-- only when `tecs.net.http` is read.

local binding <const> = require("tecs.ffi.rust")
local loader <const> = require("tecs.ffi.loader")
local Future <const> = require("tecs.Future")

-- Type-only, so nothing loads here and HTTP is not initialized by a program
-- that only opens a socket: the field below declares the name and `tecs.init`
-- fills it in on the first read of it. The edge runs this way round and only
-- this way. Nothing under `http` requires this module, which is what keeps
-- naming its type from being a require cycle Teal rejects.
local type http = require("tecs.net.http")

local type FutureType<T> = Future<T>
local type Source = Future.Source

local C <const> = binding.C

-- Enum values are ABI declarations rather than preprocessor constants, so the
-- generated constants table does not carry them.
local STATUS_FAILURE <const> = -1
local STATUS_WAITING <const> = 0

local DEFAULT_READ_BYTES <const> = 16384
local MAX_READ_BYTES <const> = 65536
local MAX_WRITE_BYTES <const> = 16 * 1024 * 1024
local MAX_DATAGRAM_BYTES <const> = 65507
local MAX_HOST_BYTES <const> = 253
local MAX_TIMEOUT_MS <const> = 2147483647
local DEFAULT_WAIT_MS <const> = 5000
local WAIT_SLICE_MS <const> = 16

local record net
    --- Read-only. `http` provides asynchronous HTTP and HTTPS clients.
    http: http

    --- An `Address` owns one resolved network address.
    record Address
        --- Read-only. Networking sets `host` at resolution or peer lookup. It
        --- contains the requested hostname or numeric peer address.
        host: string
        --- Read-only. Networking sets `text` to the printable numeric address
        --- when it creates the object.
        text: string
        _handle: loader.CPtr
        _closed: boolean

        --- Returns whether `close` has released this address.
        ---
        --- @return Returns true after `close`.
        isClosed: function(self: Address): boolean
        --- Releases the address. Safe to call repeatedly.
        close: function(self: Address)
    end

    --- A `Stream` owns one connected TCP byte stream.
    record Stream
        _handle: loader.CPtr
        _buffer: loader.CArray
        _closed: boolean

        --- Returns whether `close` has released this stream.
        ---
        --- @return Returns true after `close`.
        isClosed: function(self: Stream): boolean
        --- Returns a newly owned address for the remote peer.
        ---
        --- The caller closes the returned address.
        --- @return Returns a caller-owned address that outlives the stream, or
        ---     nil on failure.
        --- @return Returns the reason when the first return is nil.
        peer: function(self: Stream): Address, string
        --- Reads up to `maxBytes` without waiting.
        ---
        --- Returns nil with no error when no bytes are ready. Returns nil with
        --- an error after the peer disconnects or the read fails. A successful
        --- read may contain fewer bytes than requested.
        --- @param maxBytes The caller supplies a ceiling from 1 to 65536 bytes
        ---     or omits it for 16384. Invalid values raise.
        --- @return Returns a fresh string of available bytes, or nil when no
        ---     bytes arrived or the read failed.
        --- @return Returns the reason only when reading fails or the peer
        ---     disconnects.
        read: function(self: Stream, maxBytes?: integer): string, string
        --- Queues one chunk for reliable ordered delivery.
        ---
        --- This accepting the bytes does not mean the peer has received them;
        --- use `pendingWrites` or `drain` when that distinction matters.
        --- @param bytes The caller supplies at most 16777216 bytes. Larger
        ---     values raise; an empty string succeeds without queuing data.
        --- @return Returns true only when the stream accepts the whole chunk.
        --- @return Returns the reason when the first return is false.
        write: function(self: Stream, bytes: string): boolean, string
        --- Returns bytes accepted but not yet sent.
        ---
        --- @return Returns the queued byte count, zero after sending, or nil on
        ---     failure.
        --- @return Returns the reason when the first return is nil.
        pendingWrites: function(self: Stream): integer, string
        --- Waits up to `timeoutMs` for queued writes to be sent.
        ---
        --- Returns false without an error on timeout.
        --- @param timeoutMs The caller supplies 0 to 2147483647 milliseconds or
        ---     omits it for 5000. Zero polls without blocking.
        --- @return Returns true when the local send queue reaches zero before
        ---     timeout.
        --- @return Returns the reason on failure. Timeout returns false without
        ---     a reason.
        drain: function(self: Stream, timeoutMs?: integer): boolean, string
        --- Waits up to `timeoutMs` for input or disconnection.
        ---
        --- Returns false without an error on timeout. This does not consume
        --- input; call `read` afterwards.
        --- @param timeoutMs The caller supplies 0 to 2147483647 milliseconds or
        ---     omits it for zero. Zero polls without blocking.
        --- @return Returns true when input arrives or the peer disconnects.
        --- @return Returns the reason on failure. Timeout returns false without
        ---     a reason.
        wait: function(self: Stream, timeoutMs?: integer): boolean, string
        --- Releases the stream. `close` may discard queued writes, so call
        --- `drain` first when delivery matters. Repeated calls remain safe.
        close: function(self: Stream)
    end

    --- A `Server` listens for TCP clients.
    record Server
        --- Read-only. Networking sets `port` from the value passed to `listen`
        --- and never changes it. Zero remains zero.
        port: integer
        _handle: loader.CPtr
        _closed: boolean

        --- Returns whether `close` has released this listener.
        ---
        --- @return Returns true after `close`.
        isClosed: function(self: Server): boolean
        --- Takes one pending client without waiting.
        ---
        --- Returns nil with no error when nobody waits. The caller owns the
        --- returned stream.
        --- @return Returns one caller-owned client, or nil when none waits or
        ---     acceptance fails.
        --- @return Returns the reason only when acceptance fails.
        accept: function(self: Server): Stream, string
        --- Waits up to `timeoutMs` for a client to become ready to accept.
        ---
        --- Returns false without an error on timeout. This does not accept the
        --- client; call `accept` afterwards.
        --- @param timeoutMs The caller supplies 0 to 2147483647 milliseconds or
        ---     omits it for zero. Zero polls without blocking.
        --- @return Returns true when at least one client waits.
        --- @return Returns the reason on failure. Timeout returns false without
        ---     a reason.
        wait: function(self: Server, timeoutMs?: integer): boolean, string
        --- Stops listening and leaves accepted streams open. Repeated calls
        --- remain safe.
        close: function(self: Server)
    end

    --- A `Packet` owns one received UDP datagram and its source address.
    record Packet
        --- Read-only. Networking sets `address` when receiving the packet. The
        --- packet owns it until `close`.
        address: Address
        --- Read-only. Networking sets `port` to the remote source port when
        --- receiving the packet.
        port: integer
        --- Read-only. Networking sets `bytes` to one complete datagram when
        --- receiving the packet. A zero-length datagram uses an empty string.
        bytes: string

        --- Releases the packet's source address. Safe to call repeatedly.
        close: function(self: Packet)
    end

    --- A `DatagramSocket` sends and receives UDP packets.
    record DatagramSocket
        --- Read-only. Networking sets `port` from the value passed to `bind`
        --- and never changes it. Zero remains zero.
        port: integer
        _handle: loader.CPtr
        _closed: boolean

        --- Returns whether `close` has released this socket.
        ---
        --- @return Returns true after `close`.
        isClosed: function(self: DatagramSocket): boolean
        --- Sends one packet without waiting.
        --- @param address The caller supplies an open address from this module.
        --- @param port The caller supplies a remote port from 1 to 65535.
        --- @param bytes The caller supplies one datagram of at most 65507 bytes.
        --- @return Returns true when the network accepts the complete datagram.
        --- @return Returns the reason when the first return is false.
        send: function(self: DatagramSocket, address: Address, port: integer, bytes: string): boolean, string
        --- Takes one packet without waiting.
        ---
        --- Returns nil with no error when no packet is ready. The packet owns
        --- its source address, which the caller closes.
        --- @return Returns one caller-owned complete packet, or nil when none
        ---     waits or reception fails.
        --- @return Returns the reason only when reception fails.
        receive: function(self: DatagramSocket): Packet, string
        --- Waits up to `timeoutMs` for a packet.
        ---
        --- Returns false without an error on timeout. This does not consume a
        --- packet; call `receive` afterwards.
        --- @param timeoutMs The caller supplies 0 to 2147483647 milliseconds or
        ---     omits it for zero. Zero polls without blocking.
        --- @return Returns true when at least one packet waits.
        --- @return Returns the reason on failure. Timeout returns false without
        ---     a reason.
        wait: function(self: DatagramSocket, timeoutMs?: integer): boolean, string
        --- Releases the socket. Safe to call repeatedly.
        close: function(self: DatagramSocket)
    end

    --- Starts networking for this module. Safe to call repeatedly.
    ---
    --- `resolve`, `connect`, `listen` and `bind` start it automatically.
    ---
    --- @return Returns true when networking runs.
    --- @return Returns the startup reason when the first return is false.
    init: function(): boolean, string
    --- Stops this module's networking instance.
    ---
    --- It refuses while an address, stream, server, socket, packet or
    --- asynchronous operation remains live.
    ---
    --- @return Returns true after shutdown or when networking never started.
    --- @return Returns the live-resource reason when shutdown refuses.
    quit: function(): boolean, string
    --- Begins resolving a hostname.
    --- @param host The caller supplies a DNS name or numeric address of at most
    ---     253 bytes. Empty strings and embedded NUL bytes raise.
    --- @return Returns a future over a caller-owned address. `net.poll` or
    ---     `Future:wait` settles it.
    resolve: function(host: string): FutureType<Address>
    --- Begins connecting to a resolved address.
    --- @param address The caller supplies an address from this module. A closed
    ---     address returns an already-failed future.
    --- @param port The caller supplies a remote port from 1 to 65535.
    --- @return Returns a future over a caller-owned stream. `net.poll` or
    ---     `Future:wait` settles it.
    connect: function(address: Address, port: integer): FutureType<Stream>
    --- Binds a TCP listener. A nil address listens on all local interfaces.
    --- @param port The caller supplies a local port from 0 to 65535. Zero lets
    ---     the platform choose one but leaves `Server.port` at zero.
    --- @param address The caller supplies a local address or omits it for all
    ---     interfaces.
    --- @return Returns a caller-owned listener, or nil on failure.
    --- @return Returns the reason when the first return is nil.
    listen: function(port: integer, address?: Address): Server, string
    --- Binds a UDP socket. A nil address listens on all local interfaces.
    --- @param port The caller supplies a local port from 0 to 65535. Zero lets
    ---     the platform choose one but leaves `DatagramSocket.port` at zero.
    --- @param address The caller supplies a local address or omits it for all
    ---     interfaces.
    --- @return Returns a caller-owned socket, or nil on failure.
    --- @return Returns the reason when the first return is nil.
    bind: function(port: integer, address?: Address): DatagramSocket, string
    --- Advances every pending resolution and client connection without
    --- waiting. Call once per frame while asynchronous network work exists.
    --- @return Returns how many futures settled during this call, including
    ---     failures.
    poll: function(): integer
    --- Returns the number of unresolved or connecting futures.
    ---
    --- @return Returns zero after every operation settles or cancels.
    pending: function(): integer
end

local AddressMT <const>: metatable<net.Address> = {__index = net.Address}
local StreamMT <const>: metatable<net.Stream> = {__index = net.Stream}
local ServerMT <const>: metatable<net.Server> = {__index = net.Server}
local PacketMT <const>: metatable<net.Packet> = {__index = net.Packet}
local DatagramSocketMT <const>: metatable<net.DatagramSocket> = {__index = net.DatagramSocket}

local enum OperationKind
    "resolve"
    "connect"
end

local record Operation
    kind: OperationKind
    host: string
    handle: loader.CPtr
    future: FutureType<any>
    at: integer
    sliceMs: number
    defaultWaitMs: number

    poll: function(self: Operation): integer
    advance: function(self: Operation, ms: number): integer
    cancel: function(self: Operation, future: FutureType<any>)
end

local OperationMT <const>: metatable<Operation> = {__index = Operation}

local started = false
local liveObjects = 0
local operations: {Operation} = {}

local function validPort(port: integer, allowZero: boolean, level: integer)
    local minimum <const> = allowZero and 0 or 1
    if type(port) ~= "number" or port ~= math.floor(port) or port < minimum or port > 65535 then
        error(("tecs: port must be an integer from %d to 65535"):format(minimum), level)
    end
end

local function validTimeout(timeoutMs: integer, level: integer): integer
    local timeout <const> = timeoutMs or 0
    if type(timeout) ~= "number" or timeout ~= math.floor(timeout) or timeout < 0 or timeout > MAX_TIMEOUT_MS then
        error(("tecs: timeout must be an integer from 0 to %d milliseconds"):format(MAX_TIMEOUT_MS), level)
    end
    return timeout
end

local function validBytes(bytes: string, maximum: integer, what: string, level: integer)
    if type(bytes) ~= "string" then
        error(("tecs: %s needs a byte string"):format(what), level)
    end
    if #bytes > maximum then
        error(("tecs: %s accepts at most %d bytes, not %d"):format(what, maximum, #bytes), level)
    end
end

local function validAddress(address: net.Address, optional: boolean, level: integer): boolean, string
    if address == nil then
        if optional then
            return true
        end
        error("tecs: an address is required", level)
    end
    if getmetatable(address) ~= AddressMT then
        error("tecs: expected an address returned by net.resolve or Stream:peer", level)
    end
    if address._closed then
        return false, "address is closed"
    end
    return true
end

local function ensure(): boolean, string
    if started then
        return true
    end
    started = true
    return true
end

function net.init(): boolean, string
    return ensure()
end

local function opened()
    liveObjects = liveObjects + 1
end

local function closed()
    liveObjects = liveObjects - 1
end

local function addressFrom(handle: loader.CPtr, host: string): net.Address
    local length <const> = loader.newArray("size_t[1]")
    local text <const> = C.tecsNetAddressText(handle, length)
    local address = setmetatable({} as net.Address, AddressMT)
    address.host = host
    address.text = text ~= nil and loader.toBytes(text, tonumber(length[0]) as integer) or host
    address._handle = handle
    address._closed = false
    opened()
    return address
end

function net.Address:isClosed(): boolean
    return self._closed
end

function net.Address:close()
    if self._closed then
        return
    end
    self._closed = true
    C.tecsNetAddressDestroy(self._handle)
    self._handle = nil
    closed()
end

local function streamFrom(handle: loader.CPtr): net.Stream
    local stream = setmetatable({} as net.Stream, StreamMT)
    stream._handle = handle
    stream._buffer = loader.newArray("uint8_t[?]", MAX_READ_BYTES)
    stream._closed = false
    opened()
    return stream
end

function net.Stream:isClosed(): boolean
    return self._closed
end

function net.Stream:peer(): net.Address, string
    if self._closed then
        return nil, "stream is closed"
    end
    local handle = C.tecsNetStreamPeer(self._handle)
    if handle == nil then
        return nil, loader.toString(C.tecsRustError())
    end
    local length <const> = loader.newArray("size_t[1]")
    local text <const> = C.tecsNetAddressText(handle, length)
    local host <const> = text ~= nil and loader.toBytes(text, tonumber(length[0]) as integer) or ""
    return addressFrom(handle, host)
end

function net.Stream:read(maxBytes?: integer): string, string
    if self._closed then
        return nil, "stream is closed"
    end
    local count <const> = maxBytes or DEFAULT_READ_BYTES
    if type(count) ~= "number" or count ~= math.floor(count) or count < 1 or count > MAX_READ_BYTES then
        error(("tecs: stream reads from 1 to %d bytes at a time"):format(MAX_READ_BYTES), 2)
    end
    local read <const> = tonumber(C.tecsNetStreamRead(self._handle, self._buffer, count)) as integer
    if read < 0 then
        return nil, loader.toString(C.tecsRustError())
    end
    if read == 0 then
        return nil
    end
    return loader.toBytes(self._buffer as loader.CValue, read)
end

function net.Stream:write(bytes: string): boolean, string
    if self._closed then
        return false, "stream is closed"
    end
    validBytes(bytes, MAX_WRITE_BYTES, "Stream:write", 2)
    if #bytes == 0 then
        return true
    end
    if tonumber(C.tecsNetStreamWrite(self._handle, bytes, #bytes)) == 0 then
        return false, loader.toString(C.tecsRustError())
    end
    return true
end

function net.Stream:pendingWrites(): integer, string
    if self._closed then
        return nil, "stream is closed"
    end
    local pending <const> = tonumber(C.tecsNetStreamPendingWrites(self._handle)) as integer
    if pending < 0 then
        return nil, loader.toString(C.tecsRustError())
    end
    return pending
end

function net.Stream:drain(timeoutMs?: integer): boolean, string
    if self._closed then
        return false, "stream is closed"
    end
    local timeout <const> = validTimeout(timeoutMs or DEFAULT_WAIT_MS, 2)
    local status <const> = tonumber(C.tecsNetStreamDrain(self._handle, timeout)) as integer
    if status < 0 then
        return false, loader.toString(C.tecsRustError())
    end
    return status > 0
end

function net.Stream:wait(timeoutMs?: integer): boolean, string
    if self._closed then
        return false, "stream is closed"
    end
    local status <const> = tonumber(C.tecsNetStreamWait(self._handle, validTimeout(timeoutMs or 0, 2))) as integer
    if status < 0 then
        return false, loader.toString(C.tecsRustError())
    end
    return status > 0
end

function net.Stream:close()
    if self._closed then
        return
    end
    self._closed = true
    C.tecsNetStreamDestroy(self._handle)
    self._handle = nil
    closed()
end

function net.Server:isClosed(): boolean
    return self._closed
end

function net.Server:accept(): net.Stream, string
    if self._closed then
        return nil, "server is closed"
    end
    local handle <const> = C.tecsNetServerAccept(self._handle)
    if handle == nil then
        return nil
    end
    return streamFrom(handle)
end

function net.Server:wait(timeoutMs?: integer): boolean, string
    if self._closed then
        return false, "server is closed"
    end
    local status <const> = tonumber(C.tecsNetServerWait(self._handle, validTimeout(timeoutMs or 0, 2))) as integer
    if status < 0 then
        return false, loader.toString(C.tecsRustError())
    end
    return status > 0
end

function net.Server:close()
    if self._closed then
        return
    end
    self._closed = true
    C.tecsNetServerDestroy(self._handle)
    self._handle = nil
    closed()
end

function net.DatagramSocket:isClosed(): boolean
    return self._closed
end

function net.Packet:close()
    self.address:close()
end

function net.DatagramSocket:send(address: net.Address, port: integer, bytes: string): boolean, string
    if self._closed then
        return false, "datagram socket is closed"
    end
    local valid, reason <const> = validAddress(address, false, 2)
    if not valid then
        return false, reason
    end
    validPort(port, false, 2)
    validBytes(bytes, MAX_DATAGRAM_BYTES, "DatagramSocket:send", 2)
    if tonumber(C.tecsNetDatagramSend(self._handle, address._handle, port, bytes, #bytes)) == 0 then
        return false, loader.toString(C.tecsRustError())
    end
    return true
end

function net.DatagramSocket:receive(): net.Packet, string
    if self._closed then
        return nil, "datagram socket is closed"
    end
    local datagram = C.tecsNetDatagramReceive(self._handle)
    if datagram == nil then
        return nil
    end

    local source = C.tecsNetPacketTakeAddress(datagram)
    if source == nil then
        C.tecsNetPacketDestroy(datagram)
        return nil, loader.toString(C.tecsRustError())
    end
    local addressLength <const> = loader.newArray("size_t[1]")
    local text <const> = C.tecsNetAddressText(source, addressLength)
    local host <const> = text ~= nil and loader.toBytes(text, tonumber(addressLength[0]) as integer) or ""
    local bytesLength <const> = loader.newArray("size_t[1]")
    local bytes <const> = C.tecsNetPacketBytes(datagram, bytesLength)
    local packet <const> = setmetatable(
        {
            address = addressFrom(source, host),
            port = tonumber(C.tecsNetPacketPort(datagram)) as integer,
            bytes = loader.toBytes(bytes, tonumber(bytesLength[0]) as integer),
        } as net.Packet,
        PacketMT
    )
    C.tecsNetPacketDestroy(datagram)
    return packet
end

function net.DatagramSocket:wait(timeoutMs?: integer): boolean, string
    if self._closed then
        return false, "datagram socket is closed"
    end
    local status <const> = tonumber(C.tecsNetDatagramWait(self._handle, validTimeout(timeoutMs or 0, 2))) as integer
    if status < 0 then
        return false, loader.toString(C.tecsRustError())
    end
    return status > 0
end

function net.DatagramSocket:close()
    if self._closed then
        return
    end
    self._closed = true
    C.tecsNetDatagramDestroy(self._handle)
    self._handle = nil
    closed()
end

local function removeOperation(operation: Operation)
    if operation.at == 0 then
        return
    end
    local at <const> = operation.at
    local last <const> = #operations
    local moved <const> = operations[last]
    operations[last] = nil
    if at < last then
        operations[at] = moved
        moved.at = at
    end
    operation.at = 0
end

local function finish(operation: Operation, waitMs: integer): integer
    local status <const> = tonumber(C.tecsNetOperationStatus(operation.handle, waitMs)) as integer
    if status == STATUS_WAITING then
        return 0
    end

    removeOperation(operation)
    if status == STATUS_FAILURE then
        local reason <const> = loader.toString(C.tecsRustError())
        C.tecsNetOperationDestroy(operation.handle)
        operation.handle = nil
        operation.future:fail(reason)
        return 1
    end

    if operation.kind == "resolve" then
        local handle <const> = C.tecsNetOperationTakeAddress(operation.handle)
        operation.future:complete(addressFrom(handle, operation.host))
    else
        local handle <const> = C.tecsNetOperationTakeStream(operation.handle)
        operation.future:complete(streamFrom(handle))
    end
    C.tecsNetOperationDestroy(operation.handle)
    operation.handle = nil
    return 1
end

function Operation:poll(): integer
    if self.at == 0 then
        return 0
    end
    return finish(self, 0)
end

function Operation:advance(ms: number): integer
    if self.at == 0 then
        return 0
    end
    return finish(self, math.floor(ms) as integer)
end

function Operation:cancel(future: FutureType<any>)
    if self.at == 0 or self.future ~= future then
        return
    end
    removeOperation(self)
    C.tecsNetOperationDestroy(self.handle)
    self.handle = nil
end

local function operation(kind: OperationKind, host: string, handle: loader.CPtr): Operation
    local source = setmetatable({} as Operation, OperationMT)
    source.kind = kind
    source.host = host
    source.handle = handle
    source.at = #operations + 1
    source.sliceMs = WAIT_SLICE_MS
    source.defaultWaitMs = DEFAULT_WAIT_MS
    source.future = Future.pending(source as Source) as FutureType<any>
    operations[source.at] = source
    return source
end

function net.resolve(host: string): FutureType<net.Address>
    if type(host) ~= "string" or host == "" then
        error("tecs: resolve needs a hostname", 2)
    end
    if #host > MAX_HOST_BYTES then
        error(("tecs: a hostname is at most %d bytes"):format(MAX_HOST_BYTES), 2)
    end
    if host:find("\0", 1, true) ~= nil then
        error("tecs: a hostname cannot contain NUL", 2)
    end
    local ok, reason <const> = ensure()
    if not ok then
        return Future.failed(reason) as FutureType<net.Address>
    end
    local handle = C.tecsNetResolve(host, #host)
    if handle == nil then
        return Future.failed(loader.toString(C.tecsRustError())) as FutureType<net.Address>
    end
    return operation("resolve", host, handle).future as FutureType<net.Address>
end

function net.connect(address: net.Address, port: integer): FutureType<net.Stream>
    validPort(port, false, 2)
    local valid, addressReason <const> = validAddress(address, false, 2)
    if not valid then
        return Future.failed(addressReason) as FutureType<net.Stream>
    end
    local ok, reason <const> = ensure()
    if not ok then
        return Future.failed(reason) as FutureType<net.Stream>
    end
    local handle = C.tecsNetConnect(address._handle, port)
    if handle == nil then
        return Future.failed(loader.toString(C.tecsRustError())) as FutureType<net.Stream>
    end
    return operation("connect", address.host, handle).future as FutureType<net.Stream>
end

function net.listen(port: integer, address?: net.Address): net.Server, string
    validPort(port, true, 2)
    local valid, addressReason <const> = validAddress(address, true, 2)
    if not valid then
        return nil, addressReason
    end
    local ok, reason <const> = ensure()
    if not ok then
        return nil, reason
    end
    local handle = C.tecsNetListen(address ~= nil and address._handle or nil, port)
    if handle == nil then
        return nil, loader.toString(C.tecsRustError())
    end
    local server = setmetatable({} as net.Server, ServerMT)
    server.port = port
    server._handle = handle
    server._closed = false
    opened()
    return server
end

function net.bind(port: integer, address?: net.Address): net.DatagramSocket, string
    validPort(port, true, 2)
    local valid, addressReason <const> = validAddress(address, true, 2)
    if not valid then
        return nil, addressReason
    end
    local ok, reason <const> = ensure()
    if not ok then
        return nil, reason
    end
    local handle = C.tecsNetDatagramBind(address ~= nil and address._handle or nil, port)
    if handle == nil then
        return nil, loader.toString(C.tecsRustError())
    end
    local socket = setmetatable({} as net.DatagramSocket, DatagramSocketMT)
    socket.port = port
    socket._handle = handle
    socket._closed = false
    opened()
    return socket
end

function net.poll(): integer
    local settled = 0
    local at = 1
    while at <= #operations do
        local current <const> = operations[at]
        settled = settled + current:poll()
        if current.at ~= 0 then
            at = at + 1
        end
    end
    return settled
end

function net.pending(): integer
    return #operations
end

function net.quit(): boolean, string
    if not started then
        return true
    end
    if #operations > 0 then
        return false, ("%d asynchronous network operation(s) are still pending"):format(#operations)
    end
    if liveObjects > 0 then
        return false, ("%d network object(s) are still open"):format(liveObjects)
    end
    started = false
    return true
end

return net
