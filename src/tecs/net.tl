--- Nonblocking TCP and UDP networking over SDL3_net, and the protocols above
--- it.
---
--- What sits directly here is the transport, not a protocol. A stream is an
--- ordered sequence of bytes: one write may take several reads to receive,
--- several writes may arrive in one read, and message framing belongs to the
--- caller. A datagram preserves one send as one packet, but may be lost,
--- duplicated or reordered by the network.
---
--- A protocol built on that is a namespace one level down, and `http` is the
--- one there is. Reading this module's name loads no protocol: the Reqwest
--- runtime starts only when `tecs.net.http` is read.
---
--- Resolution and client connection are asynchronous and return
--- [`Future`](Future) values. Call `net.poll` once per frame while either is
--- pending, or use the future's bounded `wait` method outside a frame.
--- Listening, accepting, reading, writing and receiving are nonblocking.
---
--- Every address, stream, server and datagram socket owns a native resource.
--- Close it explicitly. Closing is idempotent; using a closed value returns a
--- failure instead of reaching a stale native handle.

local sdl <const> = require("tecs.ffi.sdl3")
local binding <const> = require("tecs.ffi.sdl3net")
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
    --- HTTP and HTTPS, over Reqwest and Rustls. The one protocol namespace here: this
    --- module is the transport, and framing bytes into messages is what a
    --- protocol above it does.
    http: http

    --- A resolved network address.
    record Address
        --- The hostname passed to `resolve`, or the numeric peer address for
        --- an address obtained from a socket or packet.
        host: string
        --- SDL's printable numeric form of the address.
        text: string
        _handle: loader.CPtr
        _closed: boolean

        --- Whether this address has been closed.
        --- @return True once `close` has run. `connect`, `listen`, `bind` and `DatagramSocket:send`
        ---     then refuse this address with a reason rather than raising.
        isClosed: function(self: Address): boolean
        --- Releases the address. Safe to call repeatedly.
        close: function(self: Address)
    end

    --- One connected TCP byte stream.
    record Stream
        _handle: loader.CPtr
        _buffer: loader.CArray
        _wait: loader.CArray
        _closed: boolean

        --- Whether this stream has been closed.
        --- @return True once `close` has run. Every other method then answers `"stream is closed"`
        ---     rather than reaching SDL.
        isClosed: function(self: Stream): boolean
        --- A newly owned address for the remote peer.
        ---
        --- The caller closes the returned address.
        --- @return A reference of its own, separate from the one the stream holds, so it stays valid
        ---     after the stream is closed. Nil when the stream is closed or SDL could not report the
        ---     peer, and nil here always carries a reason.
        --- @return Why there is no address.
        peer: function(self: Stream): Address, string
        --- Reads up to `maxBytes` without waiting.
        ---
        --- Returns nil with no error when no bytes are ready. Returns nil with
        --- an error after the peer disconnects or the read fails. A successful
        --- read may contain fewer bytes than requested.
        --- @param maxBytes A ceiling rather than a request: 16384 by default, and from 1 to 65536,
        ---     outside which this raises rather than clamping.
        --- @return Whatever had already arrived, copied out of the stream's own reusable buffer into a
        ---     fresh string. Nil means one of two things, which the second return tells apart: nothing
        ---     has arrived yet, or the read failed.
        --- @return Set only when the read failed or the peer disconnected. Nothing having arrived is
        ---     not a failure and leaves this nil.
        read: function(self: Stream, maxBytes?: integer): string, string
        --- Queues one chunk for reliable ordered delivery.
        ---
        --- This accepting the bytes does not mean the peer has received them;
        --- use `pendingWrites` or `drain` when that distinction matters.
        --- @param bytes At most 16777216 in one call; larger, or not a string, raises. An empty string
        ---     succeeds and queues nothing.
        --- @return True when SDL has taken the whole chunk; there is no partial acceptance. False when
        ---     the stream is closed or SDL refused it.
        --- @return Why not. Set on every false return, unlike `drain` and `wait`, where false is also
        ---     how a timeout reads.
        write: function(self: Stream, bytes: string): boolean, string
        --- Bytes SDL has accepted but not yet sent.
        --- @return Zero once the queue has gone to the operating system, which is what `drain` waits
        ---     for. Nil rather than a count when the stream is closed or the query failed.
        --- @return Why there is no count.
        pendingWrites: function(self: Stream): integer, string
        --- Waits up to `timeoutMs` for queued writes to be sent.
        ---
        --- Returns false without an error on timeout.
        --- @param timeoutMs Milliseconds, 5000 by default and 0 to test the queue without blocking.
        ---     From 0 to 2147483647, outside which this raises. Anything positive blocks the calling
        ---     thread for that long.
        --- @return True when the queue reached zero inside the budget. The queue that drains is the
        ---     local one: the bytes are with the operating system, not read by the peer.
        --- @return Set only when the stream is closed or the wait itself failed; a timeout is false
        ---     with no reason.
        drain: function(self: Stream, timeoutMs?: integer): boolean, string
        --- Waits up to `timeoutMs` for input or disconnection.
        ---
        --- Returns false without an error on timeout. This does not consume
        --- input; call `read` afterwards.
        --- @param timeoutMs Milliseconds, 0 by default, which polls without blocking. From 0 to
        ---     2147483647, outside which this raises. A frame passes 0; anything positive blocks the
        ---     calling thread for that long.
        --- @return True when the stream has input or has disconnected. The two are not told apart
        ---     here, and `read` is what distinguishes them.
        --- @return Set only when the stream is closed or the wait itself failed.
        wait: function(self: Stream, timeoutMs?: integer): boolean, string
        --- Releases the stream. Queued writes may be discarded; drain first
        --- when delivery matters. Safe to call repeatedly.
        close: function(self: Stream)
    end

    --- A TCP listener.
    record Server
        --- The port passed to `listen`, unchanged. Zero stays zero rather than becoming the port the
        --- operating system chose, which SDL3_net does not report back.
        port: integer
        _handle: loader.CPtr
        _wait: loader.CArray
        _closed: boolean

        --- Whether this listener has been closed.
        --- @return True once `close` has run. `accept` and `wait` then answer `"server is closed"`.
        isClosed: function(self: Server): boolean
        --- Takes one pending client without waiting.
        ---
        --- Returns nil with no error when nobody is waiting. The returned
        --- stream is owned by the caller.
        --- @return One client, and at most one per call. It outlives this listener, so closing the
        ---     server does not close it. Nil with no reason means nobody was waiting.
        --- @return Set only when the server is closed or the accept failed.
        accept: function(self: Server): Stream, string
        --- Waits up to `timeoutMs` for a client to become ready to accept.
        ---
        --- Returns false without an error on timeout. This does not accept the
        --- client; call `accept` afterwards.
        --- @param timeoutMs Milliseconds, 0 by default, which polls without blocking. From 0 to
        ---     2147483647, outside which this raises. A frame passes 0; anything positive blocks the
        ---     calling thread for that long.
        --- @return True when at least one client is waiting; it says nothing about how many.
        --- @return Set only when the server is closed or the wait itself failed.
        wait: function(self: Server, timeoutMs?: integer): boolean, string
        --- Stops listening. Existing accepted streams are unaffected. Safe to
        --- call repeatedly.
        close: function(self: Server)
    end

    --- One received UDP packet.
    record Packet
        --- Source address. Owned by this record; close it when the packet is no
        --- longer needed.
        address: Address
        --- The remote port the datagram came from, which is where a reply goes.
        port: integer
        --- One whole datagram, already copied out of SDL's packet. A zero-length datagram reads as an
        --- empty string rather than nil.
        bytes: string

        --- Releases the packet's source address. Safe to call repeatedly.
        close: function(self: Packet)
    end

    --- One bound UDP socket.
    record DatagramSocket
        --- The port passed to `bind`, unchanged. Zero stays zero rather than becoming the port the
        --- operating system chose, which SDL3_net does not report back.
        port: integer
        _handle: loader.CPtr
        _wait: loader.CArray
        _closed: boolean

        --- Whether this socket has been closed.
        --- @return True once `close` has run. `send`, `receive` and `wait` then answer
        ---     `"datagram socket is closed"`.
        isClosed: function(self: DatagramSocket): boolean
        --- Sends one packet without waiting.
        --- @param address Must be open, and must have come from `net.resolve`, `Stream:peer` or a
        ---     received packet; anything else raises. A closed one returns false with a reason.
        --- @param port The remote port, from 1 to 65535. Outside that raises, zero included.
        --- @param bytes One datagram, at most 65507 bytes, which is the largest a UDP payload can be.
        ---     Larger, or not a string, raises. An empty string sends a zero-length datagram.
        --- @return True when SDL took the datagram. That is handing it to the network rather than
        ---     delivering it: it may still be lost, duplicated or reordered.
        --- @return Why not. Set on every false return.
        send: function(self: DatagramSocket, address: Address, port: integer, bytes: string): boolean, string
        --- Takes one packet without waiting.
        ---
        --- Returns nil with no error when no packet is ready. The packet owns
        --- its source address, which the caller closes.
        --- @return One whole datagram, never part of one and never two joined. Its bytes are copied and
        ---     its address referenced before SDL's own packet is released inside this call, so the
        ---     result outlives both that packet and this socket.
        --- @return Set only when the socket is closed or the receive failed; nothing having arrived
        ---     leaves this nil.
        receive: function(self: DatagramSocket): Packet, string
        --- Waits up to `timeoutMs` for a packet.
        ---
        --- Returns false without an error on timeout. This does not consume a
        --- packet; call `receive` afterwards.
        --- @param timeoutMs Milliseconds, 0 by default, which polls without blocking. From 0 to
        ---     2147483647, outside which this raises. A frame passes 0; anything positive blocks the
        ---     calling thread for that long.
        --- @return True when at least one packet is waiting; it says nothing about how many.
        --- @return Set only when the socket is closed or the wait itself failed.
        wait: function(self: DatagramSocket, timeoutMs?: integer): boolean, string
        --- Releases the socket. Safe to call repeatedly.
        close: function(self: DatagramSocket)
    end

    --- Starts SDL3_net for this module. Safe to call repeatedly.
    ---
    --- `resolve`, `connect`, `listen` and `bind` each start it themselves, so a caller reaches for
    --- this only to learn early whether the library is there.
    --- @return True when SDL3_net is running, including when this module had already started it.
    --- @return Why it could not start. Nothing here changed in that case.
    init: function(): boolean, string
    --- Stops this module's SDL3_net instance.
    ---
    --- Refuses while a public object or asynchronous operation is live, so no
    --- native handle is invalidated behind its owner.
    --- @return True when SDL3_net has been stopped, and also when this module never started it. False
    ---     releases nothing and leaves the module started.
    --- @return Which held it back, a pending operation or an open object, and how many of them.
    quit: function(): boolean, string
    --- Begins resolving a hostname.
    --- @param host A DNS name or a numeric address such as "127.0.0.1" or "::1". At most 253 bytes;
    ---     empty, not a string, or containing a NUL raises.
    --- @return A future over an address the caller owns and closes. Already "failed" when SDL3_net
    ---     could not start or the lookup could not be begun, and otherwise pending until `net.poll` or
    ---     `Future:wait` settles it. Canceling it releases the lookup and drops it from `net.pending`.
    resolve: function(host: string): FutureType<Address>
    --- Begins connecting to a resolved address.
    --- @param address Must have come from `net.resolve`, `Stream:peer` or a received packet; nil or
    ---     anything else raises. A closed one gives an already-failed future instead.
    --- @param port From 1 to 65535. Outside that raises, zero included.
    --- @return A future over a stream the caller owns and closes. Already "failed" when the address is
    ---     closed, SDL3_net could not start, or the connection could not be begun, and otherwise
    ---     pending until `net.poll` or `Future:wait` settles it. Canceling it destroys the half-open
    ---     socket.
    connect: function(address: Address, port: integer): FutureType<Stream>
    --- Binds a TCP listener. A nil address listens on all local interfaces.
    --- @param port From 0 to 65535. Zero asks the operating system to choose one, which SDL3_net does
    ---     not report back, so `Server.port` stays zero and the listener cannot advertise itself.
    --- @param address A local address to bind to. A closed one returns nil with a reason; anything
    ---     that is not an address from this module raises.
    --- @return An open listener the caller closes, or nil when the address is closed, SDL3_net could
    ---     not start, or the bind failed.
    --- @return Why there is no listener.
    listen: function(port: integer, address?: Address): Server, string
    --- Binds a UDP socket. A nil address listens on all local interfaces.
    --- @param port From 0 to 65535. Zero asks the operating system to choose one, which suits a socket
    ---     that only receives replies; SDL3_net does not report the choice back, so
    ---     `DatagramSocket.port` stays zero.
    --- @param address A local address to bind to. A closed one returns nil with a reason; anything
    ---     that is not an address from this module raises.
    --- @return An open socket the caller closes, or nil when the address is closed, SDL3_net could not
    ---     start, or the bind failed.
    --- @return Why there is no socket.
    bind: function(port: integer, address?: Address): DatagramSocket, string
    --- Advances every pending resolution and client connection without
    --- waiting. Call once per frame while asynchronous network work exists.
    --- @return How many futures settled on this call, failures counted, since a failure is a
    ---     settlement. One canceled between polls left the queue without being counted here.
    poll: function(): integer
    --- Number of unresolved or connecting futures.
    --- @return Zero once every resolution and connection has settled or been canceled, which is when
    ---     `net.poll` has nothing left to advance and `net.quit` stops refusing over them.
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
    if not C.NET_Init() then
        return false, sdl.error()
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
    local text = C.NET_GetAddressString(handle)
    local address = setmetatable({} as net.Address, AddressMT)
    address.host = host
    address.text = text ~= nil and loader.toString(text) or host
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
    C.NET_UnrefAddress(self._handle)
    self._handle = nil
    closed()
end

local function streamFrom(handle: loader.CPtr): net.Stream
    local stream = setmetatable({} as net.Stream, StreamMT)
    stream._handle = handle
    stream._buffer = loader.newArray("uint8_t[?]", MAX_READ_BYTES)
    stream._wait = loader.newArray("void *[1]")
    stream._wait[0] = handle
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
    local borrowed = C.NET_GetStreamSocketAddress(self._handle)
    if borrowed == nil then
        return nil, sdl.error()
    end
    local handle = C.NET_RefAddress(borrowed)
    if handle == nil then
        return nil, sdl.error()
    end
    local text = C.NET_GetAddressString(handle)
    local host <const> = text ~= nil and loader.toString(text) or ""
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
    local read <const> = tonumber(C.NET_ReadFromStreamSocket(self._handle, self._buffer, count)) as integer
    if read < 0 then
        return nil, sdl.error()
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
    if not C.NET_WriteToStreamSocket(self._handle, bytes, #bytes) then
        return false, sdl.error()
    end
    return true
end

function net.Stream:pendingWrites(): integer, string
    if self._closed then
        return nil, "stream is closed"
    end
    local pending <const> = tonumber(C.NET_GetStreamSocketPendingWrites(self._handle)) as integer
    if pending < 0 then
        return nil, sdl.error()
    end
    return pending
end

function net.Stream:drain(timeoutMs?: integer): boolean, string
    if self._closed then
        return false, "stream is closed"
    end
    local timeout <const> = validTimeout(timeoutMs or DEFAULT_WAIT_MS, 2)
    local status <const> = tonumber(C.NET_WaitUntilStreamSocketDrained(self._handle, timeout)) as integer
    if status < 0 then
        return false, sdl.error()
    end
    return status == 0
end

local function waitFor(handle: loader.CArray, timeoutMs: integer): boolean, string
    local ready <const> = tonumber(C.NET_WaitUntilInputAvailable(handle, 1, timeoutMs)) as integer
    if ready < 0 then
        return false, sdl.error()
    end
    return ready > 0
end

function net.Stream:wait(timeoutMs?: integer): boolean, string
    if self._closed then
        return false, "stream is closed"
    end
    return waitFor(self._wait, validTimeout(timeoutMs or 0, 2))
end

function net.Stream:close()
    if self._closed then
        return
    end
    self._closed = true
    C.NET_DestroyStreamSocket(self._handle)
    self._handle = nil
    self._wait[0] = nil
    closed()
end

function net.Server:isClosed(): boolean
    return self._closed
end

function net.Server:accept(): net.Stream, string
    if self._closed then
        return nil, "server is closed"
    end
    local out <const> = loader.newArray("NET_StreamSocket *[1]")
    if not C.NET_AcceptClient(self._handle, out) then
        return nil, sdl.error()
    end
    if out[0] == nil then
        return nil
    end
    return streamFrom(out[0] as loader.CPtr)
end

function net.Server:wait(timeoutMs?: integer): boolean, string
    if self._closed then
        return false, "server is closed"
    end
    return waitFor(self._wait, validTimeout(timeoutMs or 0, 2))
end

function net.Server:close()
    if self._closed then
        return
    end
    self._closed = true
    C.NET_DestroyServer(self._handle)
    self._handle = nil
    self._wait[0] = nil
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
    if not C.NET_SendDatagram(self._handle, address._handle, port, bytes, #bytes) then
        return false, sdl.error()
    end
    return true
end

function net.DatagramSocket:receive(): net.Packet, string
    if self._closed then
        return nil, "datagram socket is closed"
    end
    local out <const> = loader.newArray("NET_Datagram *[1]")
    if not C.NET_ReceiveDatagram(self._handle, out) then
        return nil, sdl.error()
    end
    local datagram = out[0]
    if datagram == nil then
        return nil
    end

    local fields = datagram as loader.CStruct
    local source = C.NET_RefAddress(fields.addr as loader.CPtr)
    if source == nil then
        C.NET_DestroyDatagram(datagram)
        return nil, sdl.error()
    end
    local text = C.NET_GetAddressString(source)
    local host <const> = text ~= nil and loader.toString(text) or ""
    local packet <const> = setmetatable({
        address = addressFrom(source, host),
        port = tonumber(fields.port) as integer,
        bytes = loader.toBytes(fields.buf as loader.CValue, tonumber(fields.buflen) as integer),
    } as net.Packet, PacketMT)
    C.NET_DestroyDatagram(datagram)
    return packet
end

function net.DatagramSocket:wait(timeoutMs?: integer): boolean, string
    if self._closed then
        return false, "datagram socket is closed"
    end
    return waitFor(self._wait, validTimeout(timeoutMs or 0, 2))
end

function net.DatagramSocket:close()
    if self._closed then
        return
    end
    self._closed = true
    C.NET_DestroyDatagramSocket(self._handle)
    self._handle = nil
    self._wait[0] = nil
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

local function finish(operation: Operation, waited: boolean): integer
    local status: integer
    if operation.kind == "resolve" then
        if waited then
            status = tonumber(C.NET_WaitUntilResolved(operation.handle, 0)) as integer
        else
            status = tonumber(C.NET_GetAddressStatus(operation.handle)) as integer
        end
    else
        if waited then
            status = tonumber(C.NET_WaitUntilConnected(operation.handle, 0)) as integer
        else
            status = tonumber(C.NET_GetConnectionStatus(operation.handle)) as integer
        end
    end

    if status == STATUS_WAITING then
        return 0
    end

    removeOperation(operation)
    local handle <const> = operation.handle
    operation.handle = nil
    if status == STATUS_FAILURE then
        local reason <const> = sdl.error()
        if operation.kind == "resolve" then
            C.NET_UnrefAddress(handle)
        else
            C.NET_DestroyStreamSocket(handle)
        end
        operation.future:fail(reason)
        return 1
    end

    if operation.kind == "resolve" then
        operation.future:complete(addressFrom(handle, operation.host))
    else
        operation.future:complete(streamFrom(handle))
    end
    return 1
end

function Operation:poll(): integer
    if self.at == 0 then
        return 0
    end
    return finish(self, false)
end

function Operation:advance(ms: number): integer
    if self.at == 0 then
        return 0
    end
    local timeout <const> = math.floor(ms) as integer
    local status: integer
    if self.kind == "resolve" then
        status = tonumber(C.NET_WaitUntilResolved(self.handle, timeout)) as integer
    else
        status = tonumber(C.NET_WaitUntilConnected(self.handle, timeout)) as integer
    end
    if status == STATUS_WAITING then
        return 0
    end
    return finish(self, true)
end

function Operation:cancel(future: FutureType<any>)
    if self.at == 0 or self.future ~= future then
        return
    end
    removeOperation(self)
    if self.kind == "resolve" then
        C.NET_UnrefAddress(self.handle)
    else
        C.NET_DestroyStreamSocket(self.handle)
    end
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
    local handle = C.NET_ResolveHostname(host)
    if handle == nil then
        return Future.failed(sdl.error()) as FutureType<net.Address>
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
    local handle = C.NET_CreateClient(address._handle, port, 0)
    if handle == nil then
        return Future.failed(sdl.error()) as FutureType<net.Stream>
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
    local handle = C.NET_CreateServer(address ~= nil and address._handle or nil, port, 0)
    if handle == nil then
        return nil, sdl.error()
    end
    local server = setmetatable({} as net.Server, ServerMT)
    server.port = port
    server._handle = handle
    server._wait = loader.newArray("void *[1]")
    server._wait[0] = handle
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
    local handle = C.NET_CreateDatagramSocket(address ~= nil and address._handle or nil, port, 0)
    if handle == nil then
        return nil, sdl.error()
    end
    local socket = setmetatable({} as net.DatagramSocket, DatagramSocketMT)
    socket.port = port
    socket._handle = handle
    socket._wait = loader.newArray("void *[1]")
    socket._wait[0] = handle
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
    C.NET_Quit()
    started = false
    return true
end

return net
