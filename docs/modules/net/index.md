---
description: "Nonblocking TCP streams and UDP datagrams, with asynchronous hostname resolution and connection"
outline: deep
---

# tecs.net

`tecs.net` is the engine's transport layer over Rust's standard networking library. It resolves hostnames, connects and listens with TCP,
and sends whole UDP datagrams. It does not add a message protocol: a TCP stream is bytes in order, and framing
those bytes into messages belongs to the game.

A protocol built on that is a namespace one level down, and [`tecs.net.http`](/modules/net/http) is the one there
is. Naming this module loads no protocol: HTTP starts its Reqwest runtime only when a client is built, so a
program that only opens a socket starts no HTTP workers.

The surface follows the game loop rather than hiding one:

- resolution and client connection return [`Future`](/modules/Future) values;
- `net.poll()` advances those futures without waiting;
- accept, read, write, send and receive return immediately;
- `wait` and `drain` are explicit, bounded calls for startup, tools, tests and background work.

There are no Lua callbacks crossing the native boundary. Rust workers perform DNS and client connection, and Lua
polls ordinary results on the thread that owns the future. TCP and UDP sockets stay nonblocking.

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

`Packet.address` is also owned. It remains valid after `receive` releases Rust's native packet, and the caller
closes it:

```teal
local packet <const> = socket:receive()
if packet ~= nil then
    route(packet.address, packet.port, packet.bytes)
    packet:close()
end
```

`net.quit()` releases this module's networking state. It refuses while an asynchronous operation or owned
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
| `text` | `string` | Rust's printable numeric representation of the resolved address.                |

```teal
function Address:isClosed(): boolean
function Address:close()
```

An address is deliberately opaque beyond its printable form. IPv4 and IPv6 selection stays with Rust rather
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
to choose a port, but this API does not expose that selected port, so a game that advertises its listener should
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
is 1 byte through 64 KiB. A successful result may be shorter than requested. Nil with no reason means no input is
ready; nil with a reason means the peer disconnected or the read failed.

::: warning A stream has no messages
One `write("abc")` can arrive as `"a"` then `"bc"`, and `write("a")` followed by `write("bc")` can arrive as
`"abc"`. Length prefixes, delimiters, serialization and maximum message sizes belong to the protocol above this
module.
:::

`write` queues the whole supplied chunk or fails; one call accepts at most 16 MiB. Acceptance means Rust owns
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
