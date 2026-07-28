---
description: "Nonblocking TCP streams and UDP datagrams, with asynchronous hostname resolution and connection"
outline: deep
---

# tecs.net

`tecs.net` is the engine's transport layer over SDL3_net. It resolves hostnames, connects and listens with TCP,
and sends whole UDP datagrams. It does not add a message protocol: a TCP stream is bytes in order, and framing
those bytes into messages belongs to the game.

A protocol built on that is a namespace one level down, and [`tecs.net.http`](/modules/net/http) is the one there
is. Naming this module loads no protocol: HTTP resolves libcurl when it is read, so a program that only opens a
socket never links one.

The surface follows the game loop rather than hiding one:

- resolution and client connection return [`Future`](/modules/future) values;
- `net.poll()` advances those futures without waiting;
- accept, read, write, send and receive return immediately;
- `wait` and `drain` are explicit, bounded calls for startup, tools, tests and background work.

There are no Lua callbacks crossing into C. SDL3_net performs DNS and socket work internally, and Lua polls the
result on the thread that owns the future.

## The loop

`resolve` and `connect` start work and return at once. Advance them once per frame:

```teal
local address <const> = net.resolve("game.example")
local connection: tecs.Future<net.Stream>

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

- asynchronous resolution and connection settle their future as `"failed"` with `future.error`;
- synchronous operations return `false, reason` or `nil, reason`;
- a nonblocking read, accept or receive with nothing ready returns `nil` with no reason;
- a bounded `wait` or `drain` that times out returns `false` with no reason.

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

`net.quit()` releases this module's SDL3_net initialization. It refuses while an asynchronous operation or owned
object remains live, so it cannot invalidate a handle behind its owner. Most games can leave the module
initialized until process exit; the explicit call is useful to tests and hosts with a restartable runtime.

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
| `text` | `string` | SDL3_net's printable numeric representation of the resolved address.            |

```teal
function Address:isClosed(): boolean
function Address:close()
```

An address is deliberately opaque beyond its printable form. IPv4 and IPv6 selection stays with SDL3_net rather
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
to choose a port, but SDL3_net does not expose that selected port, so a game that advertises its listener should
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

`write` queues the whole supplied chunk or fails; one call accepts at most 16 MiB. Acceptance means SDL3_net owns
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
congestion behavior belong to the game protocol rather than this transport wrapper.

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

- HTTP, WebSocket or TLS;
- message framing or serialization;
- reliable UDP, replication, prediction or rollback;
- socket access from multiple Lua threads;
- broadcast and address-reuse configuration.

Those are distinct layers or policy decisions. The exposed surface keeps TCP and UDP semantics visible so a
protocol does not accidentally rely on boundaries or delivery guarantees the transport never had.
<!-- @generated by docs/scripts/reference.py from src/tecs/net.tl. Do not edit below this line. -->

## Reference

Every function and type this module carries, rendered from `src/tecs/net.tl`.

<a id="tecs.net.Address"></a>

### tecs.net.Address

<pre><code v-pre>record <a href="#tecs.net.Address">tecs.net.Address</a>
</code></pre>

A resolved network address.

<a id="tecs.net.Address.host"></a>

### tecs.net.Address.host

<pre><code v-pre><a href="#tecs.net.Address.host">tecs.net.Address.host</a>: string
</code></pre>

The hostname passed to `resolve`, or the numeric peer address for
an address obtained from a socket or packet.

<a id="tecs.net.Address.text"></a>

### tecs.net.Address.text

<pre><code v-pre><a href="#tecs.net.Address.text">tecs.net.Address.text</a>: string
</code></pre>

SDL's printable numeric form of the address.

<a id="tecs.net.Address.isClosed"></a>

### tecs.net.Address.isClosed

<pre><code v-pre>function <a href="#tecs.net.Address.isClosed">tecs.net.Address.isClosed</a>(self: <a href="#tecs.net.Address">Address</a>): boolean
</code></pre>

Whether this address has been closed.

#### Parameters

| Type                                                       | Name                    | Description |
| ---------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.net.Address">Address</a></code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description                                                                                                                                  |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | True once `close` has run. `connect`, `listen`, `bind` and `DatagramSocket:send` then refuse this address with a reason rather than raising. |

<a id="tecs.net.Address.close"></a>

### tecs.net.Address.close

<pre><code v-pre>function <a href="#tecs.net.Address.close">tecs.net.Address.close</a>(self: <a href="#tecs.net.Address">Address</a>)
</code></pre>

Releases the address. Safe to call repeatedly.

#### Parameters

| Type                                                       | Name                    | Description |
| ---------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.net.Address">Address</a></code> | <code v-pre>self</code> |             |

<a id="tecs.net.DatagramSocket"></a>

### tecs.net.DatagramSocket

<pre><code v-pre>record <a href="#tecs.net.DatagramSocket">tecs.net.DatagramSocket</a>
</code></pre>

One bound UDP socket.

<a id="tecs.net.DatagramSocket.port"></a>

### tecs.net.DatagramSocket.port

<pre><code v-pre><a href="#tecs.net.DatagramSocket.port">tecs.net.DatagramSocket.port</a>: integer
</code></pre>

The port passed to `bind`, unchanged. Zero stays zero rather than becoming the port the
operating system chose, which SDL3_net does not report back.

<a id="tecs.net.DatagramSocket.isClosed"></a>

### tecs.net.DatagramSocket.isClosed

<pre><code v-pre>function <a href="#tecs.net.DatagramSocket.isClosed">tecs.net.DatagramSocket.isClosed</a>(self: <a href="#tecs.net.DatagramSocket">DatagramSocket</a>): boolean
</code></pre>

Whether this socket has been closed.

#### Parameters

| Type                                                                     | Name                    | Description |
| ------------------------------------------------------------------------ | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.net.DatagramSocket">DatagramSocket</a></code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description                                                                                        |
| -------------------------- | -------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | True once `close` has run. `send`, `receive` and `wait` then answer `"datagram socket is closed"`. |

<a id="tecs.net.DatagramSocket.send"></a>

### tecs.net.DatagramSocket.send

<pre><code v-pre>function <a href="#tecs.net.DatagramSocket.send">tecs.net.DatagramSocket.send</a>(self: <a href="#tecs.net.DatagramSocket">DatagramSocket</a>, address: <a href="#tecs.net.Address">Address</a>, port: integer, bytes: string): boolean, string
</code></pre>

Sends one packet without waiting.

#### Parameters

| Type                                                                     | Name                       | Description                                                                                                                                                  |
| ------------------------------------------------------------------------ | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre><a href="#tecs.net.DatagramSocket">DatagramSocket</a></code> | <code v-pre>self</code>    |                                                                                                                                                              |
| <code v-pre><a href="#tecs.net.Address">Address</a></code>               | <code v-pre>address</code> | Must be open, and must have come from `net.resolve`, `Stream:peer` or a received packet; anything else raises. A closed one returns false with a reason.     |
| <code v-pre>integer</code>                                               | <code v-pre>port</code>    | The remote port, from 1 to 65535. Outside that raises, zero included.                                                                                        |
| <code v-pre>string</code>                                                | <code v-pre>bytes</code>   | One datagram, at most 65507 bytes, which is the largest a UDP payload can be. Larger, or not a string, raises. An empty string sends a zero-length datagram. |

#### Returns

| Type                       | Description                                                                                                                                  |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | True when SDL took the datagram. That is handing it to the network rather than delivering it: it may still be lost, duplicated or reordered. |
| <code v-pre>string</code>  | Why not. Set on every false return.                                                                                                          |

<a id="tecs.net.DatagramSocket.receive"></a>

### tecs.net.DatagramSocket.receive

<pre><code v-pre>function <a href="#tecs.net.DatagramSocket.receive">tecs.net.DatagramSocket.receive</a>(self: <a href="#tecs.net.DatagramSocket">DatagramSocket</a>): <a href="#tecs.net.Packet">Packet</a>, string
</code></pre>

Takes one packet without waiting.

Returns nil with no error when no packet is ready. The packet owns
its source address, which the caller closes.

#### Parameters

| Type                                                                     | Name                    | Description |
| ------------------------------------------------------------------------ | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.net.DatagramSocket">DatagramSocket</a></code> | <code v-pre>self</code> |             |

#### Returns

| Type                                                     | Description                                                                                                                                                                                                                |
| -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.net.Packet">Packet</a></code> | One whole datagram, never part of one and never two joined. Its bytes are copied and its address referenced before SDL's own packet is released inside this call, so the result outlives both that packet and this socket. |
| <code v-pre>string</code>                                | Set only when the socket is closed or the receive failed; nothing having arrived leaves this nil.                                                                                                                          |

<a id="tecs.net.DatagramSocket.wait"></a>

### tecs.net.DatagramSocket.wait

<pre><code v-pre>function <a href="#tecs.net.DatagramSocket.wait">tecs.net.DatagramSocket.wait</a>(self: <a href="#tecs.net.DatagramSocket">DatagramSocket</a>, timeoutMs: integer): boolean, string
</code></pre>

Waits up to `timeoutMs` for a packet.

Returns false without an error on timeout. This does not consume a
packet; call `receive` afterwards.

#### Parameters

| Type                                                                     | Name                         | Description                                                                                                                                                                             |
| ------------------------------------------------------------------------ | ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.net.DatagramSocket">DatagramSocket</a></code> | <code v-pre>self</code>      |                                                                                                                                                                                         |
| <code v-pre>integer</code>                                               | <code v-pre>timeoutMs</code> | Milliseconds, 0 by default, which polls without blocking. From 0 to 2147483647, outside which this raises. A frame passes 0; anything positive blocks the calling thread for that long. |

#### Returns

| Type                       | Description                                                               |
| -------------------------- | ------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | True when at least one packet is waiting; it says nothing about how many. |
| <code v-pre>string</code>  | Set only when the socket is closed or the wait itself failed.             |

<a id="tecs.net.DatagramSocket.close"></a>

### tecs.net.DatagramSocket.close

<pre><code v-pre>function <a href="#tecs.net.DatagramSocket.close">tecs.net.DatagramSocket.close</a>(self: <a href="#tecs.net.DatagramSocket">DatagramSocket</a>)
</code></pre>

Releases the socket. Safe to call repeatedly.

#### Parameters

| Type                                                                     | Name                    | Description |
| ------------------------------------------------------------------------ | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.net.DatagramSocket">DatagramSocket</a></code> | <code v-pre>self</code> |             |

<a id="tecs.net.Packet"></a>

### tecs.net.Packet

<pre><code v-pre>record <a href="#tecs.net.Packet">tecs.net.Packet</a>
</code></pre>

One received UDP packet.

<a id="tecs.net.Packet.address"></a>

### tecs.net.Packet.address

<pre><code v-pre><a href="#tecs.net.Packet.address">tecs.net.Packet.address</a>: <a href="#tecs.net.Address">Address</a>
</code></pre>

Source address. Owned by this record; close it when the packet is no
longer needed.

<a id="tecs.net.Packet.port"></a>

### tecs.net.Packet.port

<pre><code v-pre><a href="#tecs.net.Packet.port">tecs.net.Packet.port</a>: integer
</code></pre>

The remote port the datagram came from, which is where a reply goes.

<a id="tecs.net.Packet.bytes"></a>

### tecs.net.Packet.bytes

<pre><code v-pre><a href="#tecs.net.Packet.bytes">tecs.net.Packet.bytes</a>: string
</code></pre>

One whole datagram, already copied out of SDL's packet. A zero-length datagram reads as an
empty string rather than nil.

<a id="tecs.net.Packet.close"></a>

### tecs.net.Packet.close

<pre><code v-pre>function <a href="#tecs.net.Packet.close">tecs.net.Packet.close</a>(self: <a href="#tecs.net.Packet">Packet</a>)
</code></pre>

Releases the packet's source address. Safe to call repeatedly.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.net.Packet">Packet</a></code> | <code v-pre>self</code> |             |

<a id="tecs.net.Server"></a>

### tecs.net.Server

<pre><code v-pre>record <a href="#tecs.net.Server">tecs.net.Server</a>
</code></pre>

A TCP listener.

<a id="tecs.net.Server.port"></a>

### tecs.net.Server.port

<pre><code v-pre><a href="#tecs.net.Server.port">tecs.net.Server.port</a>: integer
</code></pre>

The port passed to `listen`, unchanged. Zero stays zero rather than becoming the port the
operating system chose, which SDL3_net does not report back.

<a id="tecs.net.Server.isClosed"></a>

### tecs.net.Server.isClosed

<pre><code v-pre>function <a href="#tecs.net.Server.isClosed">tecs.net.Server.isClosed</a>(self: <a href="#tecs.net.Server">Server</a>): boolean
</code></pre>

Whether this listener has been closed.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.net.Server">Server</a></code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description                                                                      |
| -------------------------- | -------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | True once `close` has run. `accept` and `wait` then answer `"server is closed"`. |

<a id="tecs.net.Server.accept"></a>

### tecs.net.Server.accept

<pre><code v-pre>function <a href="#tecs.net.Server.accept">tecs.net.Server.accept</a>(self: <a href="#tecs.net.Server">Server</a>): <a href="#tecs.net.Stream">Stream</a>, string
</code></pre>

Takes one pending client without waiting.

Returns nil with no error when nobody is waiting. The returned
stream is owned by the caller.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.net.Server">Server</a></code> | <code v-pre>self</code> |             |

#### Returns

| Type                                                     | Description                                                                                                                                            |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre><a href="#tecs.net.Stream">Stream</a></code> | One client, and at most one per call. It outlives this listener, so closing the server does not close it. Nil with no reason means nobody was waiting. |
| <code v-pre>string</code>                                | Set only when the server is closed or the accept failed.                                                                                               |

<a id="tecs.net.Server.wait"></a>

### tecs.net.Server.wait

<pre><code v-pre>function <a href="#tecs.net.Server.wait">tecs.net.Server.wait</a>(self: <a href="#tecs.net.Server">Server</a>, timeoutMs: integer): boolean, string
</code></pre>

Waits up to `timeoutMs` for a client to become ready to accept.

Returns false without an error on timeout. This does not accept the
client; call `accept` afterwards.

#### Parameters

| Type                                                     | Name                         | Description                                                                                                                                                                             |
| -------------------------------------------------------- | ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.net.Server">Server</a></code> | <code v-pre>self</code>      |                                                                                                                                                                                         |
| <code v-pre>integer</code>                               | <code v-pre>timeoutMs</code> | Milliseconds, 0 by default, which polls without blocking. From 0 to 2147483647, outside which this raises. A frame passes 0; anything positive blocks the calling thread for that long. |

#### Returns

| Type                       | Description                                                               |
| -------------------------- | ------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | True when at least one client is waiting; it says nothing about how many. |
| <code v-pre>string</code>  | Set only when the server is closed or the wait itself failed.             |

<a id="tecs.net.Server.close"></a>

### tecs.net.Server.close

<pre><code v-pre>function <a href="#tecs.net.Server.close">tecs.net.Server.close</a>(self: <a href="#tecs.net.Server">Server</a>)
</code></pre>

Stops listening. Existing accepted streams are unaffected. Safe to
call repeatedly.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.net.Server">Server</a></code> | <code v-pre>self</code> |             |

<a id="tecs.net.Stream"></a>

### tecs.net.Stream

<pre><code v-pre>record <a href="#tecs.net.Stream">tecs.net.Stream</a>
</code></pre>

One connected TCP byte stream.

<a id="tecs.net.Stream.isClosed"></a>

### tecs.net.Stream.isClosed

<pre><code v-pre>function <a href="#tecs.net.Stream.isClosed">tecs.net.Stream.isClosed</a>(self: <a href="#tecs.net.Stream">Stream</a>): boolean
</code></pre>

Whether this stream has been closed.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.net.Stream">Stream</a></code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description                                                                                               |
| -------------------------- | --------------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | True once `close` has run. Every other method then answers `"stream is closed"` rather than reaching SDL. |

<a id="tecs.net.Stream.peer"></a>

### tecs.net.Stream.peer

<pre><code v-pre>function <a href="#tecs.net.Stream.peer">tecs.net.Stream.peer</a>(self: <a href="#tecs.net.Stream">Stream</a>): <a href="#tecs.net.Address">Address</a>, string
</code></pre>

A newly owned address for the remote peer.

The caller closes the returned address.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.net.Stream">Stream</a></code> | <code v-pre>self</code> |             |

#### Returns

| Type                                                       | Description                                                                                                                                                                                                         |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.net.Address">Address</a></code> | A reference of its own, separate from the one the stream holds, so it stays valid after the stream is closed. Nil when the stream is closed or SDL could not report the peer, and nil here always carries a reason. |
| <code v-pre>string</code>                                  | Why there is no address.                                                                                                                                                                                            |

<a id="tecs.net.Stream.read"></a>

### tecs.net.Stream.read

<pre><code v-pre>function <a href="#tecs.net.Stream.read">tecs.net.Stream.read</a>(self: <a href="#tecs.net.Stream">Stream</a>, maxBytes: integer): string, string
</code></pre>

Reads up to `maxBytes` without waiting.

Returns nil with no error when no bytes are ready. Returns nil with
an error after the peer disconnects or the read fails. A successful
read may contain fewer bytes than requested.

#### Parameters

| Type                                                     | Name                        | Description                                                                                                             |
| -------------------------------------------------------- | --------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.net.Stream">Stream</a></code> | <code v-pre>self</code>     |                                                                                                                         |
| <code v-pre>integer</code>                               | <code v-pre>maxBytes</code> | A ceiling rather than a request: 16384 by default, and from 1 to 65536, outside which this raises rather than clamping. |

#### Returns

| Type                      | Description                                                                                                                                                                                                      |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | Whatever had already arrived, copied out of the stream's own reusable buffer into a fresh string. Nil means one of two things, which the second return tells apart: nothing has arrived yet, or the read failed. |
| <code v-pre>string</code> | Set only when the read failed or the peer disconnected. Nothing having arrived is not a failure and leaves this nil.                                                                                             |

<a id="tecs.net.Stream.write"></a>

### tecs.net.Stream.write

<pre><code v-pre>function <a href="#tecs.net.Stream.write">tecs.net.Stream.write</a>(self: <a href="#tecs.net.Stream">Stream</a>, bytes: string): boolean, string
</code></pre>

Queues one chunk for reliable ordered delivery.

This accepting the bytes does not mean the peer has received them;
use `pendingWrites` or `drain` when that distinction matters.

#### Parameters

| Type                                                     | Name                     | Description                                                                                                 |
| -------------------------------------------------------- | ------------------------ | ----------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.net.Stream">Stream</a></code> | <code v-pre>self</code>  |                                                                                                             |
| <code v-pre>string</code>                                | <code v-pre>bytes</code> | At most 16777216 in one call; larger, or not a string, raises. An empty string succeeds and queues nothing. |

#### Returns

| Type                       | Description                                                                                                                 |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | True when SDL has taken the whole chunk; there is no partial acceptance. False when the stream is closed or SDL refused it. |
| <code v-pre>string</code>  | Why not. Set on every false return, unlike `drain` and `wait`, where false is also how a timeout reads.                     |

<a id="tecs.net.Stream.pendingWrites"></a>

### tecs.net.Stream.pendingWrites

<pre><code v-pre>function <a href="#tecs.net.Stream.pendingWrites">tecs.net.Stream.pendingWrites</a>(self: <a href="#tecs.net.Stream">Stream</a>): integer, string
</code></pre>

Bytes SDL has accepted but not yet sent.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.net.Stream">Stream</a></code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description                                                                                                                                                   |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | Zero once the queue has gone to the operating system, which is what `drain` waits for. Nil rather than a count when the stream is closed or the query failed. |
| <code v-pre>string</code>  | Why there is no count.                                                                                                                                        |

<a id="tecs.net.Stream.drain"></a>

### tecs.net.Stream.drain

<pre><code v-pre>function <a href="#tecs.net.Stream.drain">tecs.net.Stream.drain</a>(self: <a href="#tecs.net.Stream">Stream</a>, timeoutMs: integer): boolean, string
</code></pre>

Waits up to `timeoutMs` for queued writes to be sent.

Returns false without an error on timeout.

#### Parameters

| Type                                                     | Name                         | Description                                                                                                                                                                         |
| -------------------------------------------------------- | ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.net.Stream">Stream</a></code> | <code v-pre>self</code>      |                                                                                                                                                                                     |
| <code v-pre>integer</code>                               | <code v-pre>timeoutMs</code> | Milliseconds, 5000 by default and 0 to test the queue without blocking. From 0 to 2147483647, outside which this raises. Anything positive blocks the calling thread for that long. |

#### Returns

| Type                       | Description                                                                                                                                                |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | True when the queue reached zero inside the budget. The queue that drains is the local one: the bytes are with the operating system, not read by the peer. |
| <code v-pre>string</code>  | Set only when the stream is closed or the wait itself failed; a timeout is false with no reason.                                                           |

<a id="tecs.net.Stream.wait"></a>

### tecs.net.Stream.wait

<pre><code v-pre>function <a href="#tecs.net.Stream.wait">tecs.net.Stream.wait</a>(self: <a href="#tecs.net.Stream">Stream</a>, timeoutMs: integer): boolean, string
</code></pre>

Waits up to `timeoutMs` for input or disconnection.

Returns false without an error on timeout. This does not consume
input; call `read` afterwards.

#### Parameters

| Type                                                     | Name                         | Description                                                                                                                                                                             |
| -------------------------------------------------------- | ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.net.Stream">Stream</a></code> | <code v-pre>self</code>      |                                                                                                                                                                                         |
| <code v-pre>integer</code>                               | <code v-pre>timeoutMs</code> | Milliseconds, 0 by default, which polls without blocking. From 0 to 2147483647, outside which this raises. A frame passes 0; anything positive blocks the calling thread for that long. |

#### Returns

| Type                       | Description                                                                                                                 |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | True when the stream has input or has disconnected. The two are not told apart here, and `read` is what distinguishes them. |
| <code v-pre>string</code>  | Set only when the stream is closed or the wait itself failed.                                                               |

<a id="tecs.net.Stream.close"></a>

### tecs.net.Stream.close

<pre><code v-pre>function <a href="#tecs.net.Stream.close">tecs.net.Stream.close</a>(self: <a href="#tecs.net.Stream">Stream</a>)
</code></pre>

Releases the stream. Queued writes may be discarded; drain first
when delivery matters. Safe to call repeatedly.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.net.Stream">Stream</a></code> | <code v-pre>self</code> |             |

<a id="tecs.net.bind"></a>

### tecs.net.bind

<pre><code v-pre>function <a href="#tecs.net.bind">tecs.net.bind</a>(port: integer, address: <a href="#tecs.net.Address">Address</a>): <a href="#tecs.net.DatagramSocket">DatagramSocket</a>, string
</code></pre>

Binds a UDP socket. A nil address listens on all local interfaces.

#### Parameters

| Type                                                       | Name                       | Description                                                                                                                                                                                    |
| ---------------------------------------------------------- | -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code>                                 | <code v-pre>port</code>    | From 0 to 65535. Zero asks the operating system to choose one, which suits a socket that only receives replies; SDL3_net does not report the choice back, so `DatagramSocket.port` stays zero. |
| <code v-pre><a href="#tecs.net.Address">Address</a></code> | <code v-pre>address</code> | A local address to bind to. A closed one returns nil with a reason; anything that is not an address from this module raises.                                                                   |

#### Returns

| Type                                                                     | Description                                                                                                        |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| <code v-pre><a href="#tecs.net.DatagramSocket">DatagramSocket</a></code> | An open socket the caller closes, or nil when the address is closed, SDL3_net could not start, or the bind failed. |
| <code v-pre>string</code>                                                | Why there is no socket.                                                                                            |

<a id="tecs.net.connect"></a>

### tecs.net.connect

<pre><code v-pre>function <a href="#tecs.net.connect">tecs.net.connect</a>(address: <a href="#tecs.net.Address">Address</a>, port: integer): FutureType&lt;<a href="#tecs.net.Stream">Stream</a>&gt;
</code></pre>

Begins connecting to a resolved address.

#### Parameters

| Type                                                       | Name                       | Description                                                                                                                                              |
| ---------------------------------------------------------- | -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.net.Address">Address</a></code> | <code v-pre>address</code> | Must have come from `net.resolve`, `Stream:peer` or a received packet; nil or anything else raises. A closed one gives an already-failed future instead. |
| <code v-pre>integer</code>                                 | <code v-pre>port</code>    | From 1 to 65535. Outside that raises, zero included.                                                                                                     |

#### Returns

| Type                                                                       | Description                                                                                                                                                                                                                                                                     |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>FutureType&lt;<a href="#tecs.net.Stream">Stream</a>&gt;</code> | A future over a stream the caller owns and closes. Already "failed" when the address is closed, SDL3_net could not start, or the connection could not be begun, and otherwise pending until `net.poll` or `Future:wait` settles it. Canceling it destroys the half-open socket. |

<a id="tecs.net.http"></a>

### tecs.net.http

<pre><code v-pre><a href="#tecs.net.http">tecs.net.http</a>: http
</code></pre>

HTTP and HTTPS, over libcurl. The one protocol namespace here: this
module is the transport, and framing bytes into messages is what a
protocol above it does.

<a id="tecs.net.init"></a>

### tecs.net.init

<pre><code v-pre>function <a href="#tecs.net.init">tecs.net.init</a>(): boolean, string
</code></pre>

Starts SDL3_net for this module. Safe to call repeatedly.

`resolve`, `connect`, `listen` and `bind` each start it themselves, so a caller reaches for
this only to learn early whether the library is there.

#### Returns

| Type                       | Description                                                                       |
| -------------------------- | --------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | True when SDL3_net is running, including when this module had already started it. |
| <code v-pre>string</code>  | Why it could not start. Nothing here changed in that case.                        |

<a id="tecs.net.listen"></a>

### tecs.net.listen

<pre><code v-pre>function <a href="#tecs.net.listen">tecs.net.listen</a>(port: integer, address: <a href="#tecs.net.Address">Address</a>): <a href="#tecs.net.Server">Server</a>, string
</code></pre>

Binds a TCP listener. A nil address listens on all local interfaces.

#### Parameters

| Type                                                       | Name                       | Description                                                                                                                                                               |
| ---------------------------------------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code>                                 | <code v-pre>port</code>    | From 0 to 65535. Zero asks the operating system to choose one, which SDL3_net does not report back, so `Server.port` stays zero and the listener cannot advertise itself. |
| <code v-pre><a href="#tecs.net.Address">Address</a></code> | <code v-pre>address</code> | A local address to bind to. A closed one returns nil with a reason; anything that is not an address from this module raises.                                              |

#### Returns

| Type                                                     | Description                                                                                                          |
| -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.net.Server">Server</a></code> | An open listener the caller closes, or nil when the address is closed, SDL3_net could not start, or the bind failed. |
| <code v-pre>string</code>                                | Why there is no listener.                                                                                            |

<a id="tecs.net.pending"></a>

### tecs.net.pending

<pre><code v-pre>function <a href="#tecs.net.pending">tecs.net.pending</a>(): integer
</code></pre>

Number of unresolved or connecting futures.

#### Returns

| Type                       | Description                                                                                                                                                           |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | Zero once every resolution and connection has settled or been canceled, which is when `net.poll` has nothing left to advance and `net.quit` stops refusing over them. |

<a id="tecs.net.poll"></a>

### tecs.net.poll

<pre><code v-pre>function <a href="#tecs.net.poll">tecs.net.poll</a>(): integer
</code></pre>

Advances every pending resolution and client connection without
waiting. Call once per frame while asynchronous network work exists.

#### Returns

| Type                       | Description                                                                                                                                                     |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | How many futures settled on this call, failures counted, since a failure is a settlement. One canceled between polls left the queue without being counted here. |

<a id="tecs.net.quit"></a>

### tecs.net.quit

<pre><code v-pre>function <a href="#tecs.net.quit">tecs.net.quit</a>(): boolean, string
</code></pre>

Stops this module's SDL3_net instance.

Refuses while a public object or asynchronous operation is live, so no
native handle is invalidated behind its owner.

#### Returns

| Type                       | Description                                                                                                                            |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | True when SDL3_net has been stopped, and also when this module never started it. False releases nothing and leaves the module started. |
| <code v-pre>string</code>  | Which held it back, a pending operation or an open object, and how many of them.                                                       |

<a id="tecs.net.resolve"></a>

### tecs.net.resolve

<pre><code v-pre>function <a href="#tecs.net.resolve">tecs.net.resolve</a>(host: string): FutureType&lt;<a href="#tecs.net.Address">Address</a>&gt;
</code></pre>

Begins resolving a hostname.

#### Parameters

| Type                      | Name                    | Description                                                                                                                       |
| ------------------------- | ----------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | <code v-pre>host</code> | A DNS name or a numeric address such as "127.0.0.1" or "::1". At most 253 bytes; empty, not a string, or containing a NUL raises. |

#### Returns

| Type                                                                         | Description                                                                                                                                                                                                                                                                 |
| ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>FutureType&lt;<a href="#tecs.net.Address">Address</a>&gt;</code> | A future over an address the caller owns and closes. Already "failed" when SDL3_net could not start or the lookup could not be begun, and otherwise pending until `net.poll` or `Future:wait` settles it. Canceling it releases the lookup and drops it from `net.pending`. |
