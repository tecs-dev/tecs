---
url: /modules/net.md
description: >-
  Nonblocking TCP streams and UDP datagrams, with asynchronous hostname
  resolution and connection
---

# tecs.net

`tecs.net` is the engine's transport layer over SDL3\_net. It resolves hostnames, connects and listens with TCP,
and sends whole UDP datagrams. It does not add a message protocol: a TCP stream is bytes in order, and framing
those bytes into messages belongs to the game.

A protocol built on that is a namespace one level down, and [`tecs.net.http`](/modules/net/http) is the one there
is. Naming this module loads no protocol: HTTP resolves libcurl when it is read, so a program that only opens a
socket never links one.

The surface follows the game loop rather than hiding one:

* resolution and client connection return [`Future`](/modules/future) values;
* `net.poll()` advances those futures without waiting;
* accept, read, write, send and receive return immediately;
* `wait` and `drain` are explicit, bounded calls for startup, tools, tests and background work.

There are no Lua callbacks crossing into C. SDL3\_net performs DNS and socket work internally, and Lua polls the
result on the thread that owns the future.

## The loop

`resolve` and `connect` start work and return at once. Advance them once per frame:

```teal
local address <const> = net.resolve("game.example")
local connection: tecs.future.Future<net.Stream>

function update()
    net.poll()

    if address.status == "ready" and connection == nil then
        connection = net.connect(address.value, 7777)
    end

    if connection ~= nil and connection.status == "ready" then
        local bytes, reason = connection.value:read()
        if bytes ~= nil then
            consume(bytes)
        elseif reason ~= nil then
            connection.value:close()
        end
    end
end
```

`Future:wait(timeoutMs)` advances the same source when blocking is appropriate:

```teal
local address <const> = net.resolve("127.0.0.1"):wait(2000)
if address.status == "failed" then
    print(address.error)
end
```

A wait defaults to 5000 milliseconds. A timeout leaves the future `"pending"`; it does not cancel the work.
`Future:cancel()` releases a pending native resolution or connection when its last watcher gives up.

`net.poll()` is explicit rather than installed into every application. A game that opens no sockets has no
network work in its frame, and a server or tool using the ECS without `Application` can drive the same surface.

## Errors and timeouts

Invalid arguments raise before a native call: ports outside their documented range, negative timeouts, oversized
buffers and a hostname containing NUL are programming errors.

Operational failures are values:

* asynchronous resolution and connection settle their future as `"failed"` with `future.error`;
* synchronous operations return `false, reason` or `nil, reason`;
* a nonblocking read, accept or receive with nothing ready returns `nil` with no reason;
* a bounded `wait` or `drain` that times out returns `false` with no reason.

A TCP connection that reports an I/O failure is no longer usable. Close it rather than retrying the same stream.

## Resource lifetime

`Address`, `Stream`, `Server` and `DatagramSocket` each own a native handle. Call `close()` when finished. Closing
twice is safe, and operations on a closed value return a failure.

`Packet.address` is also owned. It remains valid after `receive` releases SDL's native packet, and the caller
closes it:

```teal
local packet <const> = socket:receive()
if packet ~= nil then
    route(packet.address, packet.port, packet.bytes)
    packet:close()
end
```

`net.quit()` releases this module's SDL3\_net initialisation. It refuses while an asynchronous operation or owned
object remains live, so it cannot invalidate a handle behind its owner. Most games can leave the module
initialised until process exit; the explicit call is useful to tests and hosts with a restartable runtime.

## Hostname resolution

### resolve

Begins resolving a hostname.

```teal
function net.resolve(host: string): Future<Address>
```

`host` may be a DNS name or a numeric address such as `"127.0.0.1"` or `"::1"`. The returned future carries an
owned `Address`.

### Address

| Field  | Type     | Description                                                                     |
| ------ | -------- | ------------------------------------------------------------------------------- |
| `host` | `string` | The hostname passed to `resolve`, or the numeric source obtained from a socket. |
| `text` | `string` | SDL3\_net's printable numeric representation of the resolved address.            |

```teal
function Address:isClosed(): boolean
function Address:close()
```

An address is deliberately opaque beyond its printable form. IPv4 and IPv6 selection stays with SDL3\_net rather
than leaking platform socket structures into a game.

## TCP clients

### connect

Begins a nonblocking client connection.

```teal
function net.connect(address: Address, port: integer): Future<Stream>
```

`port` is from 1 through 65535. The address must be open and already resolved.

## TCP servers

### listen

Binds a TCP listener.

```teal
function net.listen(port: integer, address?: Address): Server, string
```

Omit `address` to listen on all local interfaces. `port` is from 0 through 65535; zero asks the operating system
to choose a port, but SDL3\_net does not expose that selected port, so a game that advertises its listener should
name one.

### Server

| Field  | Type      | Description                  |
| ------ | --------- | ---------------------------- |
| `port` | `integer` | The port passed to `listen`. |

```teal
function Server:accept(): Stream, string
function Server:wait(timeoutMs?: integer): boolean, string
function Server:isClosed(): boolean
function Server:close()
```

`accept` takes at most one waiting client. It returns nil with no reason when none is ready. `wait` only waits for
readiness; it does not accept, so call `accept` afterwards. A timeout is nonnegative milliseconds and defaults to
zero.

An accepted stream is owned by the caller and survives closing its server.

## TCP streams

```teal
function Stream:read(maxBytes?: integer): string, string
function Stream:write(bytes: string): boolean, string
function Stream:pendingWrites(): integer, string
function Stream:drain(timeoutMs?: integer): boolean, string
function Stream:wait(timeoutMs?: integer): boolean, string
function Stream:peer(): Address, string
function Stream:isClosed(): boolean
function Stream:close()
```

`read` takes whatever has arrived without waiting, up to `maxBytes`. The default is 16 KiB and the accepted range
is 1 byte through 64 KiB. A successful result may be shorter than requested.

::: warning A stream has no messages
One `write("abc")` can arrive as `"a"` then `"bc"`, and `write("a")` followed by `write("bc")` can arrive as
`"abc"`. Length prefixes, delimiters, serialization and maximum message sizes belong to the protocol above this
module.
:::

`write` queues the whole supplied chunk or fails; one call accepts at most 16 MiB. Acceptance means SDL3\_net owns
the bytes for delivery, not that the peer has read them. `pendingWrites` reports what is still queued, and
`drain` waits up to its timeout for that count to reach zero. `drain` defaults to 5000 milliseconds.

`wait` sleeps until input or disconnection is ready, then leaves it for `read`. It defaults to a zero-millisecond
poll. Do not put a positive wait in a frame.

`peer` returns a newly owned `Address`; close it separately.

Closing a stream can discard queued output. Drain first when sending the last bytes matters, while remembering
that a drained local queue still does not prove the remote application consumed them.

## UDP datagrams

### bind

Binds a UDP socket.

```teal
function net.bind(port: integer, address?: Address): DatagramSocket, string
```

Omit `address` to bind all local interfaces. Port zero asks the operating system to choose a source port and is
useful for clients that only need to receive replies.

### DatagramSocket

```teal
function DatagramSocket:send(
    address: Address,
    port: integer,
    bytes: string
): boolean, string
function DatagramSocket:receive(): Packet, string
function DatagramSocket:wait(timeoutMs?: integer): boolean, string
function DatagramSocket:isClosed(): boolean
function DatagramSocket:close()
```

`send` transmits one packet to an open address and a port from 1 through 65535. A packet is at most 65,507 bytes;
real protocols should normally stay below the path MTU to avoid IP fragmentation.

`receive` takes one whole packet or returns nil when none is ready. `wait` waits for readiness without consuming a
packet and defaults to a zero-millisecond poll.

UDP does not promise arrival, uniqueness or order. Sequence numbers, acknowledgements, retransmission and
congestion behaviour belong to the game protocol rather than this transport wrapper.

### Packet

| Field     | Type      | Description                                 |
| --------- | --------- | ------------------------------------------- |
| `address` | `Address` | Owned source address; the caller closes it. |
| `port`    | `integer` | Source port.                                |
| `bytes`   | `string`  | One complete datagram.                      |

```teal
function Packet:close()
```

`close` releases the packet's source address and is safe to call repeatedly.

## Limits

`tecs.net` intentionally does not provide:

* HTTP, WebSocket or TLS;
* message framing or serialization;
* reliable UDP, replication, prediction or rollback;
* socket access from multiple Lua threads;
* broadcast and address-reuse configuration.

Those are distinct layers or policy decisions. The exposed surface keeps TCP and UDP semantics visible so a
protocol does not accidentally rely on boundaries or delivery guarantees the transport never had.

## Reference

Every function and type this module carries, rendered from `src/tecs/net.tl`.

### tecs.net.Address

A resolved network address.


### tecs.net.Address.host

The hostname passed to `resolve`, or the numeric peer address for
an address obtained from a socket or packet.


### tecs.net.Address.text

SDL's printable numeric form of the address.


### tecs.net.Address.isClosed

Whether this address has been closed.

#### Parameters

| Type                                                       | Name                    | Description |
| ---------------------------------------------------------- | ----------------------- | ----------- |
| Address | self |             |

#### Returns

| Type                       | Description                                                                                                                                  |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| boolean | True once `close` has run. `connect`, `listen`, `bind` and `DatagramSocket:send` then refuse this address with a reason rather than raising. |

### tecs.net.Address.close

Releases the address. Safe to call repeatedly.

#### Parameters

| Type                                                       | Name                    | Description |
| ---------------------------------------------------------- | ----------------------- | ----------- |
| Address | self |             |

### tecs.net.DatagramSocket

One bound UDP socket.


### tecs.net.DatagramSocket.port

The port passed to `bind`, unchanged. Zero stays zero rather than becoming the port the
operating system chose, which SDL3\_net does not report back.


### tecs.net.DatagramSocket.isClosed

Whether this socket has been closed.

#### Parameters

| Type                                                                     | Name                    | Description |
| ------------------------------------------------------------------------ | ----------------------- | ----------- |
| DatagramSocket | self |             |

#### Returns

| Type                       | Description                                                                                        |
| -------------------------- | -------------------------------------------------------------------------------------------------- |
| boolean | True once `close` has run. `send`, `receive` and `wait` then answer `"datagram socket is closed"`. |

### tecs.net.DatagramSocket.send

Sends one packet without waiting.

#### Parameters

| Type                                                                     | Name                       | Description                                                                                                                                                  |
| ------------------------------------------------------------------------ | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| DatagramSocket | self    |                                                                                                                                                              |
| Address               | address | Must be open, and must have come from `net.resolve`, `Stream:peer` or a received packet; anything else raises. A closed one returns false with a reason.     |
| integer                                               | port    | The remote port, from 1 to 65535. Outside that raises, zero included.                                                                                        |
| string                                                | bytes   | One datagram, at most 65507 bytes, which is the largest a UDP payload can be. Larger, or not a string, raises. An empty string sends a zero-length datagram. |

#### Returns

| Type                       | Description                                                                                                                                  |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| boolean | True when SDL took the datagram. That is handing it to the network rather than delivering it: it may still be lost, duplicated or reordered. |
| string  | Why not. Set on every false return.                                                                                                          |

### tecs.net.DatagramSocket.receive

Takes one packet without waiting.

Returns nil with no error when no packet is ready. The packet owns
its source address, which the caller closes.

#### Parameters

| Type                                                                     | Name                    | Description |
| ------------------------------------------------------------------------ | ----------------------- | ----------- |
| DatagramSocket | self |             |

#### Returns

| Type                                                     | Description                                                                                                                                                                                                                |
| -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Packet | One whole datagram, never part of one and never two joined. Its bytes are copied and its address referenced before SDL's own packet is released inside this call, so the result outlives both that packet and this socket. |
| string                                | Set only when the socket is closed or the receive failed; nothing having arrived leaves this nil.                                                                                                                          |

### tecs.net.DatagramSocket.wait

Waits up to `timeoutMs` for a packet.

Returns false without an error on timeout. This does not consume a
packet; call `receive` afterwards.

#### Parameters

| Type                                                                     | Name                         | Description                                                                                                                                                                             |
| ------------------------------------------------------------------------ | ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| DatagramSocket | self      |                                                                                                                                                                                         |
| integer                                               | timeoutMs | Milliseconds, 0 by default, which polls without blocking. From 0 to 2147483647, outside which this raises. A frame passes 0; anything positive blocks the calling thread for that long. |

#### Returns

| Type                       | Description                                                               |
| -------------------------- | ------------------------------------------------------------------------- |
| boolean | True when at least one packet is waiting; it says nothing about how many. |
| string  | Set only when the socket is closed or the wait itself failed.             |

### tecs.net.DatagramSocket.close

Releases the socket. Safe to call repeatedly.

#### Parameters

| Type                                                                     | Name                    | Description |
| ------------------------------------------------------------------------ | ----------------------- | ----------- |
| DatagramSocket | self |             |

### tecs.net.Packet

One received UDP packet.


### tecs.net.Packet.address

Source address. Owned by this record; close it when the packet is no
longer needed.


### tecs.net.Packet.port

The remote port the datagram came from, which is where a reply goes.


### tecs.net.Packet.bytes

One whole datagram, already copied out of SDL's packet. A zero-length datagram reads as an
empty string rather than nil.


### tecs.net.Packet.close

Releases the packet's source address. Safe to call repeatedly.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| Packet | self |             |

### tecs.net.Server

A TCP listener.


### tecs.net.Server.port

The port passed to `listen`, unchanged. Zero stays zero rather than becoming the port the
operating system chose, which SDL3\_net does not report back.


### tecs.net.Server.isClosed

Whether this listener has been closed.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| Server | self |             |

#### Returns

| Type                       | Description                                                                      |
| -------------------------- | -------------------------------------------------------------------------------- |
| boolean | True once `close` has run. `accept` and `wait` then answer `"server is closed"`. |

### tecs.net.Server.accept

Takes one pending client without waiting.

Returns nil with no error when nobody is waiting. The returned
stream is owned by the caller.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| Server | self |             |

#### Returns

| Type                                                     | Description                                                                                                                                            |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Stream | One client, and at most one per call. It outlives this listener, so closing the server does not close it. Nil with no reason means nobody was waiting. |
| string                                | Set only when the server is closed or the accept failed.                                                                                               |

### tecs.net.Server.wait

Waits up to `timeoutMs` for a client to become ready to accept.

Returns false without an error on timeout. This does not accept the
client; call `accept` afterwards.

#### Parameters

| Type                                                     | Name                         | Description                                                                                                                                                                             |
| -------------------------------------------------------- | ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Server | self      |                                                                                                                                                                                         |
| integer                               | timeoutMs | Milliseconds, 0 by default, which polls without blocking. From 0 to 2147483647, outside which this raises. A frame passes 0; anything positive blocks the calling thread for that long. |

#### Returns

| Type                       | Description                                                               |
| -------------------------- | ------------------------------------------------------------------------- |
| boolean | True when at least one client is waiting; it says nothing about how many. |
| string  | Set only when the server is closed or the wait itself failed.             |

### tecs.net.Server.close

Stops listening. Existing accepted streams are unaffected. Safe to
call repeatedly.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| Server | self |             |

### tecs.net.Stream

One connected TCP byte stream.


### tecs.net.Stream.isClosed

Whether this stream has been closed.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| Stream | self |             |

#### Returns

| Type                       | Description                                                                                               |
| -------------------------- | --------------------------------------------------------------------------------------------------------- |
| boolean | True once `close` has run. Every other method then answers `"stream is closed"` rather than reaching SDL. |

### tecs.net.Stream.peer

A newly owned address for the remote peer.

The caller closes the returned address.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| Stream | self |             |

#### Returns

| Type                                                       | Description                                                                                                                                                                                                         |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Address | A reference of its own, separate from the one the stream holds, so it stays valid after the stream is closed. Nil when the stream is closed or SDL could not report the peer, and nil here always carries a reason. |
| string                                  | Why there is no address.                                                                                                                                                                                            |

### tecs.net.Stream.read

Reads up to `maxBytes` without waiting.

Returns nil with no error when no bytes are ready. Returns nil with
an error after the peer disconnects or the read fails. A successful
read may contain fewer bytes than requested.

#### Parameters

| Type                                                     | Name                        | Description                                                                                                             |
| -------------------------------------------------------- | --------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Stream | self     |                                                                                                                         |
| integer                               | maxBytes | A ceiling rather than a request: 16384 by default, and from 1 to 65536, outside which this raises rather than clamping. |

#### Returns

| Type                      | Description                                                                                                                                                                                                      |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| string | Whatever had already arrived, copied out of the stream's own reusable buffer into a fresh string. Nil means one of two things, which the second return tells apart: nothing has arrived yet, or the read failed. |
| string | Set only when the read failed or the peer disconnected. Nothing having arrived is not a failure and leaves this nil.                                                                                             |

### tecs.net.Stream.write

Queues one chunk for reliable ordered delivery.

This accepting the bytes does not mean the peer has received them;
use `pendingWrites` or `drain` when that distinction matters.

#### Parameters

| Type                                                     | Name                     | Description                                                                                                 |
| -------------------------------------------------------- | ------------------------ | ----------------------------------------------------------------------------------------------------------- |
| Stream | self  |                                                                                                             |
| string                                | bytes | At most 16777216 in one call; larger, or not a string, raises. An empty string succeeds and queues nothing. |

#### Returns

| Type                       | Description                                                                                                                 |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| boolean | True when SDL has taken the whole chunk; there is no partial acceptance. False when the stream is closed or SDL refused it. |
| string  | Why not. Set on every false return, unlike `drain` and `wait`, where false is also how a timeout reads.                     |

### tecs.net.Stream.pendingWrites

Bytes SDL has accepted but not yet sent.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| Stream | self |             |

#### Returns

| Type                       | Description                                                                                                                                                   |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| integer | Zero once the queue has gone to the operating system, which is what `drain` waits for. Nil rather than a count when the stream is closed or the query failed. |
| string  | Why there is no count.                                                                                                                                        |

### tecs.net.Stream.drain

Waits up to `timeoutMs` for queued writes to be sent.

Returns false without an error on timeout.

#### Parameters

| Type                                                     | Name                         | Description                                                                                                                                                                         |
| -------------------------------------------------------- | ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Stream | self      |                                                                                                                                                                                     |
| integer                               | timeoutMs | Milliseconds, 5000 by default and 0 to test the queue without blocking. From 0 to 2147483647, outside which this raises. Anything positive blocks the calling thread for that long. |

#### Returns

| Type                       | Description                                                                                                                                                |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| boolean | True when the queue reached zero inside the budget. The queue that drains is the local one: the bytes are with the operating system, not read by the peer. |
| string  | Set only when the stream is closed or the wait itself failed; a timeout is false with no reason.                                                           |

### tecs.net.Stream.wait

Waits up to `timeoutMs` for input or disconnection.

Returns false without an error on timeout. This does not consume
input; call `read` afterwards.

#### Parameters

| Type                                                     | Name                         | Description                                                                                                                                                                             |
| -------------------------------------------------------- | ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Stream | self      |                                                                                                                                                                                         |
| integer                               | timeoutMs | Milliseconds, 0 by default, which polls without blocking. From 0 to 2147483647, outside which this raises. A frame passes 0; anything positive blocks the calling thread for that long. |

#### Returns

| Type                       | Description                                                                                                                 |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| boolean | True when the stream has input or has disconnected. The two are not told apart here, and `read` is what distinguishes them. |
| string  | Set only when the stream is closed or the wait itself failed.                                                               |

### tecs.net.Stream.close

Releases the stream. Queued writes may be discarded; drain first
when delivery matters. Safe to call repeatedly.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| Stream | self |             |

### tecs.net.bind

Binds a UDP socket. A nil address listens on all local interfaces.

#### Parameters

| Type                                                       | Name                       | Description                                                                                                                                                                                    |
| ---------------------------------------------------------- | -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| integer                                 | port    | From 0 to 65535. Zero asks the operating system to choose one, which suits a socket that only receives replies; SDL3\_net does not report the choice back, so `DatagramSocket.port` stays zero. |
| Address | address | A local address to bind to. A closed one returns nil with a reason; anything that is not an address from this module raises.                                                                   |

#### Returns

| Type                                                                     | Description                                                                                                        |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| DatagramSocket | An open socket the caller closes, or nil when the address is closed, SDL3\_net could not start, or the bind failed. |
| string                                                | Why there is no socket.                                                                                            |

### tecs.net.connect

Begins connecting to a resolved address.

#### Parameters

| Type                                                       | Name                       | Description                                                                                                                                              |
| ---------------------------------------------------------- | -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Address | address | Must have come from `net.resolve`, `Stream:peer` or a received packet; nil or anything else raises. A closed one gives an already-failed future instead. |
| integer                                 | port    | From 1 to 65535. Outside that raises, zero included.                                                                                                     |

#### Returns

| Type                                                                       | Description                                                                                                                                                                                                                                                                      |
| -------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| FutureType\<Stream> | A future over a stream the caller owns and closes. Already "failed" when the address is closed, SDL3\_net could not start, or the connection could not be begun, and otherwise pending until `net.poll` or `Future:wait` settles it. Cancelling it destroys the half-open socket. |

### tecs.net.http

HTTP and HTTPS, over libcurl. The one protocol namespace here: this
module is the transport, and framing bytes into messages is what a
protocol above it does.


### tecs.net.init

Starts SDL3\_net for this module. Safe to call repeatedly.

`resolve`, `connect`, `listen` and `bind` each start it themselves, so a caller reaches for
this only to learn early whether the library is there.

#### Returns

| Type                       | Description                                                                       |
| -------------------------- | --------------------------------------------------------------------------------- |
| boolean | True when SDL3\_net is running, including when this module had already started it. |
| string  | Why it could not start. Nothing here changed in that case.                        |

### tecs.net.listen

Binds a TCP listener. A nil address listens on all local interfaces.

#### Parameters

| Type                                                       | Name                       | Description                                                                                                                                                               |
| ---------------------------------------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| integer                                 | port    | From 0 to 65535. Zero asks the operating system to choose one, which SDL3\_net does not report back, so `Server.port` stays zero and the listener cannot advertise itself. |
| Address | address | A local address to bind to. A closed one returns nil with a reason; anything that is not an address from this module raises.                                              |

#### Returns

| Type                                                     | Description                                                                                                          |
| -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Server | An open listener the caller closes, or nil when the address is closed, SDL3\_net could not start, or the bind failed. |
| string                                | Why there is no listener.                                                                                            |

### tecs.net.pending

Number of unresolved or connecting futures.

#### Returns

| Type                       | Description                                                                                                                                                            |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| integer | Zero once every resolution and connection has settled or been cancelled, which is when `net.poll` has nothing left to advance and `net.quit` stops refusing over them. |

### tecs.net.poll

Advances every pending resolution and client connection without
waiting. Call once per frame while asynchronous network work exists.

#### Returns

| Type                       | Description                                                                                                                                                      |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| integer | How many futures settled on this call, failures counted, since a failure is a settlement. One cancelled between polls left the queue without being counted here. |

### tecs.net.quit

Stops this module's SDL3\_net instance.

Refuses while a public object or asynchronous operation is live, so no
native handle is invalidated behind its owner.

#### Returns

| Type                       | Description                                                                                                                            |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| boolean | True when SDL3\_net has been stopped, and also when this module never started it. False releases nothing and leaves the module started. |
| string  | Which held it back, a pending operation or an open object, and how many of them.                                                       |

### tecs.net.resolve

Begins resolving a hostname.

#### Parameters

| Type                      | Name                    | Description                                                                                                                       |
| ------------------------- | ----------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| string | host | A DNS name or a numeric address such as "127.0.0.1" or "::1". At most 253 bytes; empty, not a string, or containing a NUL raises. |

#### Returns

| Type                                                                         | Description                                                                                                                                                                                                                                                                  |
| ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| FutureType\<Address> | A future over an address the caller owns and closes. Already "failed" when SDL3\_net could not start or the lookup could not be begun, and otherwise pending until `net.poll` or `Future:wait` settles it. Cancelling it releases the lookup and drops it from `net.pending`. |
