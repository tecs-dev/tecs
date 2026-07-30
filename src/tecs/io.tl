--[=[
Input, output, and nonblocking network transport.

A [`Stream`](tealdoc:tecs.io.Stream) describes binary storage without keeping
a cursor. A [`Reader`](tealdoc:tecs.io.Reader) and
[`Writer`](tealdoc:tecs.io.Writer) are the caller-owned directional endpoints
opened from it. Strings, buffers, borrowed bytes, paths, and handles all use
that one descriptor contract.

Whole-source operations return futures. A caller outside a frame can use
`value` to wait, raise a transfer error, and take the result:

```teal
local bytes <const> = tecs.io.newFileStream("save.bin"):readBuffer().value
print(bytes:length())
bytes:release()
```

TCP is an ordered byte stream: one write may take several reads to receive,
several writes may arrive in one read, and message framing belongs to the
caller. UDP preserves one send as one datagram, but the network may lose,
duplicate, or reorder it. HTTP and HTTPS live under `tecs.io.http`; the MCP
debug server lives under `tecs.io.mcp`.

Resolution and client connection return asynchronous
[`Future`](tealdoc:tecs.Future) values. An
[`Application`](tealdoc:tecs.Application) polls this module once per
iteration, so a game waits on status without driving I/O itself:

```teal
local address <const> = tecs.io.resolve("game.example")

local function update()
    if address.status == "ready" then
        print(address.value.text)
    end
end
```

A headless program without an application calls `poll` once per loop, or uses
a future's bounded `wait` when blocking is the honest operation. Stream
transfers are cooperative futures too. Listening, accepting, reading, writing,
and receiving are nonblocking.

Every address, TCP connection, server, and datagram socket owns a resource. Close
it explicitly. Closing is idempotent; using a closed value returns a failure.

Naming `tecs.io` loads none of its children. Reading `files`, `http`, `mcp`, or
`watcher` loads only that child.
]=]

-- Implementation details:
-- Rust's standard library owns the sockets. Workers resolve host names and
-- establish client connections, then Lua polls their results. No native
-- callback enters LuaJIT.
--
-- Reading `tecs.io` does not initialize a protocol. The HTTP and MCP runtimes
-- start only when their respective subordinate modules are read.

local binding <const> = require("tecs.ffi.rust")
local loader <const> = require("tecs.ffi.loader")
local Future <const> = require("tecs.Future")
local stream <const> = require("tecs.io.stream")
local type types = require("tecs.io.types")
local type IOBuffer = types.Buffer

-- Type-only, so nothing loads here and HTTP is not initialized by a program
-- that only opens a socket: the field below declares the name and `tecs.init`
-- fills it in on the first read of it. The edge runs this way round and only
-- this way. Neither protocol child requires this module, which is what keeps
-- naming either type from being a require cycle Teal rejects.
local type files = require("tecs.io.files")
local type http = require("tecs.io.http")
local type mcp = require("tecs.io.mcp")
local type watcher = require("tecs.io.watcher")

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

local record binaryIO
    --- Read-only. `files` provides path resolution and synchronous file
    --- operations.
    files: files

    --- Read-only. `http` provides asynchronous HTTP and HTTPS clients.
    http: http

    --- Read-only. `mcp` provides the debug server and tool registry.
    mcp: mcp

    --- Read-only. `watcher` provides loaded-content polling and reload
    --- notifications.
    watcher: watcher

    --- A `Reader` supplies bytes in order and releases its source on `close`.
    type Reader = types.Reader

    --- A `Writer` accepts bytes in order and finishes its destination on
    --- `close`.
    type Writer = types.Writer

    --- A `Stream` describes binary storage without retaining a cursor.
    type Stream = types.Stream

    --- A `ReadableStream` opens readers and supplies whole-source transfers.
    type ReadableStream = types.ReadableStream

    --- A `WritableStream` opens writers and supplies whole-destination
    --- transfers.
    type WritableStream = types.WritableStream

    --- A `ReadWriteStream` supports both directional interfaces.
    type ReadWriteStream = types.ReadWriteStream

    --- A `Buffer` is owned growable FFI-backed byte storage.
    type Buffer = IOBuffer

    --- Creates an owned growable byte buffer.
    ---
    --- @param initial The caller supplies a non-negative zero-filled logical
    ---     length, a string to copy, or nil for an empty buffer.
    --- @return Returns a caller-owned buffer.
    newBuffer: function(initial?: integer | string): IOBuffer

    --- Creates a replayable readable empty stream.
    ---
    --- @param contentType The caller supplies optional media type metadata.
    --- @return Returns a source whose length is zero.
    newEmptyStream: function(contentType?: string): types.ReadableStream

    --- Creates a replayable read-only string stream.
    ---
    --- The stream retains the immutable string without copying it.
    --- @param bytes The caller supplies complete binary contents.
    --- @param contentType The caller supplies optional media type metadata.
    --- @return Returns a readable stream.
    newStringStream: function(bytes: string, contentType?: string): types.ReadableStream

    --- Creates a stream sharing an owned growable buffer.
    ---
    --- `readBuffer` returns the same retained object. Releasing or mutating it
    --- affects both caller and stream.
    --- @param buffer The caller supplies an open buffer.
    --- @param contentType The caller supplies optional media type metadata.
    --- @return Returns a readable and writable stream.
    newBufferStream: function(buffer: IOBuffer, contentType?: string): types.ReadWriteStream

    --- Creates a replayable read-only stream over borrowed FFI bytes.
    ---
    --- @param pointer The caller keeps the backing allocation alive and
    ---     unchanged until every reader and transfer future settles.
    --- @param length The caller supplies the non-negative byte count.
    --- @param contentType The caller supplies optional media type metadata.
    --- @return Returns a readable stream.
    newByteStream: function(pointer: loader.CValue, length: integer, contentType?: string): types.ReadableStream

    --- Creates a replayable file stream.
    ---
    --- Readers open the current path through `tecs.io.files`; writers replace
    --- it. A descriptor keeps no open file between endpoints.
    --- @param path The caller supplies the source or destination path.
    --- @param contentType The caller supplies optional media type metadata.
    --- @return Returns a readable and writable stream.
    newFileStream: function(path: string, contentType?: string): types.ReadWriteStream

    --- Creates a one-shot stream over a borrowed Lua file handle.
    ---
    --- The first reader or writer claims its current cursor. Closing the
    --- stream or endpoint does not close the caller's handle.
    --- @param handle The caller keeps the Lua file handle open through the
    ---     endpoint's close.
    --- @param length The caller supplies the remaining byte count when known.
    --- @param contentType The caller supplies optional media type metadata.
    --- @return Returns a non-replayable readable and writable stream.
    newHandleStream: function(handle: FILE, length?: integer, contentType?: string): types.ReadWriteStream

    --- Returns a lazy metadata view over a stream.
    ---
    --- Nil inherits each value from `source`. The view retains and delegates
    --- to the source, preserves its static and runtime directional interface,
    --- and closes the source when it closes. If every supplied value already
    --- matches, this returns `source` itself.
    --- @param source The caller supplies any structural stream
    ---     implementation.
    --- @param contentType The caller overrides the media type or omits it.
    --- @param contentLength The caller overrides the non-negative byte length
    ---     or omits it.
    --- @param isReplayable The caller overrides replayability or omits it.
    --- @return Returns a metadata view with the same type as `source`.
    withMetadata: function<T is types.Stream>(
        source: T, contentType?: string, contentLength?: integer, isReplayable?: boolean
    ): T

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

    --- A `Connection` owns one connected TCP byte stream.
    record Connection
        _handle: loader.CPtr
        _buffer: loader.CArray
        _closed: boolean

        --- Returns whether `close` has released this connection.
        ---
        --- @return Returns true after `close`.
        isClosed: function(self: Connection): boolean
        --- Returns a newly owned address for the remote peer.
        ---
        --- The caller closes the returned address.
        --- @return Returns a caller-owned address that outlives the connection, or
        ---     nil on failure.
        --- @return Returns the reason when the first return is nil.
        peer: function(self: Connection): Address, string
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
        read: function(self: Connection, maxBytes?: integer): string, string
        --- Queues one chunk for reliable ordered delivery.
        ---
        --- This accepting the bytes does not mean the peer has received them;
        --- use `pendingWrites` or `drain` when that distinction matters.
        --- @param bytes The caller supplies at most 16777216 bytes. Larger
        ---     values raise; an empty string succeeds without queuing data.
        --- @return Returns true only when the connection accepts the whole chunk.
        --- @return Returns the reason when the first return is false.
        write: function(self: Connection, bytes: string): boolean, string
        --- Returns bytes accepted but not yet sent.
        ---
        --- @return Returns the queued byte count, zero after sending, or nil on
        ---     failure.
        --- @return Returns the reason when the first return is nil.
        pendingWrites: function(self: Connection): integer, string
        --- Waits up to `timeoutMs` for queued writes to be sent.
        ---
        --- Returns false without an error on timeout.
        --- @param timeoutMs The caller supplies 0 to 2147483647 milliseconds or
        ---     omits it for 5000. Zero polls without blocking.
        --- @return Returns true when the local send queue reaches zero before
        ---     timeout.
        --- @return Returns the reason on failure. Timeout returns false without
        ---     a reason.
        drain: function(self: Connection, timeoutMs?: integer): boolean, string
        --- Waits up to `timeoutMs` for input or disconnection.
        ---
        --- Returns false without an error on timeout. This does not consume
        --- input; call `read` afterwards.
        --- @param timeoutMs The caller supplies 0 to 2147483647 milliseconds or
        ---     omits it for zero. Zero polls without blocking.
        --- @return Returns true when input arrives or the peer disconnects.
        --- @return Returns the reason on failure. Timeout returns false without
        ---     a reason.
        wait: function(self: Connection, timeoutMs?: integer): boolean, string
        --- Releases the connection. `close` may discard queued writes, so call
        --- `drain` first when delivery matters. Repeated calls remain safe.
        close: function(self: Connection)
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
        accept: function(self: Server): Connection, string
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
    --- @return Returns a future over a caller-owned address. `binaryIO.poll` or
    ---     `Future:wait` settles it.
    resolve: function(host: string): FutureType<Address>
    --- Begins connecting to a resolved address.
    --- @param address The caller supplies an address from this module. A closed
    ---     address returns an already-failed future.
    --- @param port The caller supplies a remote port from 1 to 65535.
    --- @return Returns a future over a caller-owned connection. `binaryIO.poll` or
    ---     `Future:wait` settles it.
    connect: function(address: Address, port: integer): FutureType<Connection>
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
    --- Advances every pending stream transfer, resolution, and client
    --- connection without waiting. Call once per frame while asynchronous I/O
    --- work exists.
    --- @return Returns how many futures settled during this call, including
    ---     failures.
    poll: function(): integer
    --- Returns the number of pending stream, resolution, or connection
    --- futures.
    ---
    --- @return Returns zero after every operation settles or cancels.
    pending: function(): integer
end

binaryIO.newBuffer = stream.newBuffer
binaryIO.newEmptyStream = stream.newEmptyStream
binaryIO.newStringStream = stream.newStringStream
binaryIO.newBufferStream = stream.newBufferStream
binaryIO.newByteStream = stream.newByteStream
binaryIO.newFileStream = stream.newFileStream
binaryIO.newHandleStream = stream.newHandleStream
binaryIO.withMetadata = stream.withMetadata

local AddressMT <const>: metatable<binaryIO.Address> = {__index = binaryIO.Address}
local ConnectionMT <const>: metatable<binaryIO.Connection> = {__index = binaryIO.Connection}
local ServerMT <const>: metatable<binaryIO.Server> = {__index = binaryIO.Server}
local PacketMT <const>: metatable<binaryIO.Packet> = {__index = binaryIO.Packet}
local DatagramSocketMT <const>: metatable<binaryIO.DatagramSocket> = {__index = binaryIO.DatagramSocket}

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

local function validAddress(address: binaryIO.Address, optional: boolean, level: integer): boolean, string
    if address == nil then
        if optional then
            return true
        end
        error("tecs: an address is required", level)
    end
    if getmetatable(address) ~= AddressMT then
        error("tecs: expected an address returned by tecs.io.resolve or Connection:peer", level)
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

function binaryIO.init(): boolean, string
    return ensure()
end

local function opened()
    liveObjects = liveObjects + 1
end

local function closed()
    liveObjects = liveObjects - 1
end

local function addressFrom(handle: loader.CPtr, host: string): binaryIO.Address
    local length <const> = loader.newArray("size_t[1]")
    local text <const> = C.tecsNetAddressText(handle, length)
    local address = setmetatable({} as binaryIO.Address, AddressMT)
    address.host = host
    address.text = text ~= nil and loader.toBytes(text, tonumber(length[0]) as integer) or host
    address._handle = handle
    address._closed = false
    opened()
    return address
end

function binaryIO.Address:isClosed(): boolean
    return self._closed
end

function binaryIO.Address:close()
    if self._closed then
        return
    end
    self._closed = true
    C.tecsNetAddressDestroy(self._handle)
    self._handle = nil
    closed()
end

local function connectionFrom(handle: loader.CPtr): binaryIO.Connection
    local connection = setmetatable({} as binaryIO.Connection, ConnectionMT)
    connection._handle = handle
    connection._buffer = loader.newArray("uint8_t[?]", MAX_READ_BYTES)
    connection._closed = false
    opened()
    return connection
end

function binaryIO.Connection:isClosed(): boolean
    return self._closed
end

function binaryIO.Connection:peer(): binaryIO.Address, string
    if self._closed then
        return nil, "connection is closed"
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

function binaryIO.Connection:read(maxBytes?: integer): string, string
    if self._closed then
        return nil, "connection is closed"
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

function binaryIO.Connection:write(bytes: string): boolean, string
    if self._closed then
        return false, "connection is closed"
    end
    validBytes(bytes, MAX_WRITE_BYTES, "Connection:write", 2)
    if #bytes == 0 then
        return true
    end
    if tonumber(C.tecsNetStreamWrite(self._handle, bytes, #bytes)) == 0 then
        return false, loader.toString(C.tecsRustError())
    end
    return true
end

function binaryIO.Connection:pendingWrites(): integer, string
    if self._closed then
        return nil, "connection is closed"
    end
    local pending <const> = tonumber(C.tecsNetStreamPendingWrites(self._handle)) as integer
    if pending < 0 then
        return nil, loader.toString(C.tecsRustError())
    end
    return pending
end

function binaryIO.Connection:drain(timeoutMs?: integer): boolean, string
    if self._closed then
        return false, "connection is closed"
    end
    local timeout <const> = validTimeout(timeoutMs or DEFAULT_WAIT_MS, 2)
    local status <const> = tonumber(C.tecsNetStreamDrain(self._handle, timeout)) as integer
    if status < 0 then
        return false, loader.toString(C.tecsRustError())
    end
    return status > 0
end

function binaryIO.Connection:wait(timeoutMs?: integer): boolean, string
    if self._closed then
        return false, "connection is closed"
    end
    local status <const> = tonumber(C.tecsNetStreamWait(self._handle, validTimeout(timeoutMs or 0, 2))) as integer
    if status < 0 then
        return false, loader.toString(C.tecsRustError())
    end
    return status > 0
end

function binaryIO.Connection:close()
    if self._closed then
        return
    end
    self._closed = true
    C.tecsNetStreamDestroy(self._handle)
    self._handle = nil
    closed()
end

function binaryIO.Server:isClosed(): boolean
    return self._closed
end

function binaryIO.Server:accept(): binaryIO.Connection, string
    if self._closed then
        return nil, "server is closed"
    end
    local handle <const> = C.tecsNetServerAccept(self._handle)
    if handle == nil then
        return nil
    end
    return connectionFrom(handle)
end

function binaryIO.Server:wait(timeoutMs?: integer): boolean, string
    if self._closed then
        return false, "server is closed"
    end
    local status <const> = tonumber(C.tecsNetServerWait(self._handle, validTimeout(timeoutMs or 0, 2))) as integer
    if status < 0 then
        return false, loader.toString(C.tecsRustError())
    end
    return status > 0
end

function binaryIO.Server:close()
    if self._closed then
        return
    end
    self._closed = true
    C.tecsNetServerDestroy(self._handle)
    self._handle = nil
    closed()
end

function binaryIO.DatagramSocket:isClosed(): boolean
    return self._closed
end

function binaryIO.Packet:close()
    self.address:close()
end

function binaryIO.DatagramSocket:send(address: binaryIO.Address, port: integer, bytes: string): boolean, string
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

function binaryIO.DatagramSocket:receive(): binaryIO.Packet, string
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
        } as binaryIO.Packet,
        PacketMT
    )
    C.tecsNetPacketDestroy(datagram)
    return packet
end

function binaryIO.DatagramSocket:wait(timeoutMs?: integer): boolean, string
    if self._closed then
        return false, "datagram socket is closed"
    end
    local status <const> = tonumber(C.tecsNetDatagramWait(self._handle, validTimeout(timeoutMs or 0, 2))) as integer
    if status < 0 then
        return false, loader.toString(C.tecsRustError())
    end
    return status > 0
end

function binaryIO.DatagramSocket:close()
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
        operation.future:complete(connectionFrom(handle))
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

function binaryIO.resolve(host: string): FutureType<binaryIO.Address>
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
        return Future.failed(reason) as FutureType<binaryIO.Address>
    end
    local handle = C.tecsNetResolve(host, #host)
    if handle == nil then
        return Future.failed(loader.toString(C.tecsRustError())) as FutureType<binaryIO.Address>
    end
    return operation("resolve", host, handle).future as FutureType<binaryIO.Address>
end

function binaryIO.connect(address: binaryIO.Address, port: integer): FutureType<binaryIO.Connection>
    validPort(port, false, 2)
    local valid, addressReason <const> = validAddress(address, false, 2)
    if not valid then
        return Future.failed(addressReason) as FutureType<binaryIO.Connection>
    end
    local ok, reason <const> = ensure()
    if not ok then
        return Future.failed(reason) as FutureType<binaryIO.Connection>
    end
    local handle = C.tecsNetConnect(address._handle, port)
    if handle == nil then
        return Future.failed(loader.toString(C.tecsRustError())) as FutureType<binaryIO.Connection>
    end
    return operation("connect", address.host, handle).future as FutureType<binaryIO.Connection>
end

function binaryIO.listen(port: integer, address?: binaryIO.Address): binaryIO.Server, string
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
    local server = setmetatable({} as binaryIO.Server, ServerMT)
    server.port = port
    server._handle = handle
    server._closed = false
    opened()
    return server
end

function binaryIO.bind(port: integer, address?: binaryIO.Address): binaryIO.DatagramSocket, string
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
    local socket = setmetatable({} as binaryIO.DatagramSocket, DatagramSocketMT)
    socket.port = port
    socket._handle = handle
    socket._closed = false
    opened()
    return socket
end

function binaryIO.poll(): integer
    local settled = stream.poll()
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

function binaryIO.pending(): integer
    return #operations + stream.pending()
end

function binaryIO.quit(): boolean, string
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

return binaryIO
