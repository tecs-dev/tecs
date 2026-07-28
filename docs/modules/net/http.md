---
description: "An HTTP client where every request is a future, every body is a stream, and nothing goes in the frame loop"
outline: deep
---

# tecs.net.http

`tecs.net.http` fetches things over HTTP and HTTPS without stopping the frame it was called from. Make a client, send a
request, attach a continuation. Nothing else is yours to do.

```teal
tecs.net.http.newClient({ userAgent = "mygame/1.0" })
    :send({ url = "https://example.com/manifest.json" })
    :map(function(response: tecs.net.http.Response): Manifest
        return tecs.data.decodeJSON(response.body:text()) as Manifest
    end)
    :onSettle(function(manifest: tecs.Future<Manifest>)
        if manifest.status == "ready" then
            world:spawn(Level, manifest.value.firstLevel)
        else
            log:warn("no manifest: %s", manifest.error)
        end
    end)
```

There is no line missing from that. A client is driven by the application from the frame it already runs, the same
way [`assets`](/modules/assets) and [`proc`](/modules/system) are, so a request started anywhere settles on its own.

HTTP sits under [`tecs.net`](/modules/net/) because it is a protocol over the transport that module opens, and it
is flat beneath that one namespace: `Client`, `ClientOptions`, `Request`, `Response` and `DataStream` are all one
segment below `http`, and `newClient` is what builds a client. There is no `tecs.net.http.client` to reach
through.

A headless tool has no application to turn the clients it built, so `tecs.net.http.pumpClients()` turns every open
one and answers how many transfers settled. `tecs.net.http.openClients()` counts the clients built and not yet
closed, which is how a leaked one shows up. A game calls neither.

`onSettle` is handed the future rather than the value, which is what lets one continuation answer both outcomes.
[`map`](/modules/future#map), [`flatMap`](/modules/future#flatmap) and [`recover`](/modules/future#recover) are
the rest of it: everything a request returns is a [`Future`](/modules/future) and behaves like every other one.

Reading `future.status` yourself is fine, and is what a system that wants to check without a callback does. It is
not the shape to reach for first.

## A body is a `DataStream`

One value for bytes, wherever they are. A request takes one, a response carries one, and neither the caller nor
the client has to care which kind it is.

```teal
local DataStream <const> = tecs.net.http.DataStream

DataStream.ofString('{"score":11}', "application/json")
DataStream.ofFile("saves/slot1.bin")            -- a path, written as it arrives
DataStream.ofHandle(io.open("patch.bin", "wb")) -- your handle, and you close it
DataStream.ofBytes(pointer, length)             -- an FFI buffer you keep alive
```

| Field         | Type      | Description                                                                 |
| ------------- | --------- | --------------------------------------------------------------------------- |
| `kind`        | `string`  | `"string"`, `"bytes"`, `"file"` or `"handle"`.                              |
| `length`      | `integer` | Bytes, when something can know before they are read. Nil when nothing can.  |
| `contentType` | `string`  | What the bytes are. Sent as `Content-Type`, and set from one on a response. |
| `path`        | `string`  | Where the bytes are, on a `"file"`.                                         |
| `text()`      | `string`  | The whole thing as a string. Free for a `"string"`, a read for a `"file"`.  |

**A destination is written as the transfer runs.** Each pump hands what has arrived to the destination and drops
it, so a 500 MB download is never a 500 MB string: it is one frame's worth of arrival at a time. Files go through
[`filesystem`](/modules/filesystem/), and so through the storage seam a port replaces; a handle is yours and is
written to directly.

A transfer that fails part way through leaves what had arrived where it was going: a file `into` named holds a
partial body, not nothing. The future is `"failed"` and says why, so the answer to "is this file complete" is the
future rather than the file.

A request body is the other way round: a file or a handle given as `body` is read whole when `send` is called,
and libcurl copies it, so sending one costs twice its size until it completes. Uploading something large is the
case that is not served yet, and it needs the read side moved into C beside the buffering.

`maxBytes` counts every byte a body has been, drained or not, so a destination is not a way around the ceiling.

## newClient

Builds a client. Every field is optional.

```teal
local client <const> = tecs.net.http.newClient(options?: Options)
```

One client is one connection pool. Build one for the game and keep it; **call `close` when you are done with it**,
because losing the last reference to one does not end it. That is deliberate: a request nobody kept a handle to
still lands.

| Field                   | Type               | Default | Description                                                                                                     |
| ----------------------- | ------------------ | ------- | --------------------------------------------------------------------------------------------------------------- |
| `userAgent`             | `string`           | none    | Sent as `User-Agent`. Name the game and its version; a server operator reading a log has nothing else to go on. |
| `headers`               | `{string: string}` | none    | Sent on every request, and overridden per request by the same name.                                             |
| `timeoutMs`             | `number`           | `30000` | Milliseconds a whole transfer is given.                                                                         |
| `connectTimeoutMs`      | `number`           | `10000` | Milliseconds getting a socket is given, inside that.                                                            |
| `stallTimeoutMs`        | `number`           | `0`     | Milliseconds a transfer may make no progress before it fails. `0` never gives up on a quiet connection.         |
| `maxRedirects`          | `integer`          | `5`     | Redirects followed. `0` follows none.                                                                           |
| `maxConnections`        | `integer`          | `16`    | Sockets kept open across every host.                                                                            |
| `maxConnectionsPerHost` | `integer`          | `6`     | Sockets kept open to any one host. Requests past it are held, not refused.                                      |
| `maxBytes`              | `integer`          | `0`     | Bytes a response body may reach before the transfer fails. `0` is unbounded.                                    |
| `compressed`            | `boolean`          | `true`  | Offer the content encodings libcurl was built with.                                                             |
| `insecureHosts`         | `{string}`         | none    | Host names whose certificates are not verified. Each logs a warning.                                            |
| `proxy`                 | `string`           | none    | Proxy URL, as `http://host:3128` or `socks5h://host:1080`. See below.                                           |
| `noProxy`               | `string`           | none    | Hosts the proxy is not used for, comma separated. `*` disables it entirely.                                     |
| `proxyCredentials`      | `string`           | none    | `user:password` for the proxy.                                                                                  |

::: tip Set a long `timeoutMs` and a short `stallTimeoutMs` for a download
A whole-transfer deadline large enough for a big body is far too large to catch a hung connection, and a single
number cannot be both. The pair is what a download wants.
:::

## send

Starts a transfer and answers what it will settle to.

```teal
function Client:send(request: Request): Future<Response>
```

| Field            | Type                   | Default  | Description                                                                       |
| ---------------- | ---------------------- | -------- | --------------------------------------------------------------------------------- |
| `url`            | `string`               | required | Absolute, with an `http` or `https` scheme.                                       |
| `method`         | `string`               | `"GET"`  | Any method the server accepts. `POST`, `PUT` and `PATCH` always carry a body.     |
| `headers`        | `{string: string}`     | none     | Merged over the client's, matched without case.                                   |
| `body`           | `string \| DataStream` | none     | A string is the bytes themselves; a stream is a body from anywhere.               |
| `into`           | `string \| DataStream` | none     | Where the body goes. A string is a path. Left out, it comes back as a string.     |
| `timeoutMs`      | `number`               | client's | Milliseconds this transfer is given.                                              |
| `stallTimeoutMs` | `number`               | client's | Milliseconds of no progress this transfer tolerates.                              |
| `maxBytes`       | `integer`              | client's | Bytes this body may reach before it fails. `0` overrides a client's to unbounded. |

```teal
client:send({ url = url, method = "PUT", body = DataStream.ofFile("saves/slot1.bin") })
client:send({ url = url, into = "downloads/patch.bin" })
```

**`Response` fields:**

| Field     | Type               | Description                                                                                |
| --------- | ------------------ | ------------------------------------------------------------------------------------------ |
| `status`  | `integer`          | The HTTP status code, after any redirects.                                                 |
| `headers` | `{string: string}` | Response headers, with lower-cased names. A redirect's headers replace the ones before it. |
| `body`    | `DataStream`       | The body, wherever it went. `body:text()` is the string, `body.length` the bytes.          |
| `url`     | `string`           | The URL that actually answered, after any redirects.                                       |
| `ok()`    | `boolean`          | Whether `status` is a 2xx.                                                                 |

Response bodies and raw headers are buffered in C, because libcurl's callbacks cannot be Lua ones without
costing the pump loop its compilation. Two things follow that a caller can see: `headers` are the final
response's only, so a redirect's or an interim response's never appear in them, and they have an allocation cap
of their own that a hostile peer cannot talk past.

`send` raises when the call itself is malformed: no URL, or an `into` that is a string in memory rather than
somewhere bytes can go. Everything only the network can judge settles the future instead, since a URL out of a
manifest is data rather than a mistake in the program, so a non-`http` scheme comes back as a failed future.

## A response is not a failure

A 404 settles `"ready"` with `status` 404. `"failed"` means the transfer did not complete: the name did not
resolve, the connection was refused, TLS did not verify, the deadline passed. `"canceled"` means this process
stopped it.

This is the same reasoning [`proc`](/modules/system) applies to an exit code. A status code is the answer to the
request, and making it a failure would propagate a 404 through `map` as though the transfer broke. `Response:ok()`
is the separate question about the answer.

## Blocking, when you mean to

There is no `sendSync` and no `blocking = true`, because blocking is something done _to_ a future rather than a
mode a request is issued in. Startup and tools want it; a frame does not.

```teal
local config <const> = client:send({ url = url })
    :map(function(response: tecs.net.http.Response): string return response.body:text() end)
    :recover(function(): string return DEFAULTS end)
    :wait(2000)
```

::: tip Always name the timeout
The number at the call site is the whole guard. A reviewer who sees `wait(2000)` asks why a frame is being held
for two seconds, which is a question a boolean never prompts.
:::

## TLS verification is on

Peer and host verification are set explicitly on every handle, and the protocol set is narrowed to `http` and
`https` for the request and for anything it redirects to.

There is no `insecure = true`. What exists is `insecureHosts`, an explicit list of host names whose certificates
are not checked, each of which logs a warning when the client is built. No wildcard, port, scheme or URL is
accepted in that list.

```teal
local client <const> = tecs.net.http.newClient({ insecureHosts = { "dev.example.com" } })
```

A self-signed development server is a real need and this serves it. Pinning a development CA through libcurl's own
`CURLOPT_CAINFO` is better still and is what to reach for when the host is not on a developer's own machine.

## Proxies

Unset, libcurl reads `http_proxy` and `https_proxy` from the environment, which is what a developer behind one
expects. `proxy` overrides that, and `proxy = ""` is how a game ignores the environment and talks direct.

```teal
tecs.net.http.newClient({ proxy = "http://cache.internal:3128", noProxy = "localhost,127.0.0.1" })
```

## A request as an entity

A future is the right shape for a loading screen and the wrong one for a request you want to be a thing in the
world. The plugin gives it an entity instead, so it is listed by the [debug server](/modules/mcp), reacted to by a
system, and canceled when whatever asked for it despawns.

```teal
world:addPlugin(tecs.net.http.plugin.install)

world:spawn(tecs.net.http.plugin.Request({ url = "https://example.com/scores" }))
```

Some frames later that entity carries a `Response` instead of a `Request`, so a system with
`include = {http.plugin.Response}` picks it up. `Request` takes the fields [`send`](#send) takes; `Response`
carries `status`, `headers`, `body`, `url` and an `error` that is set only when the transfer did not complete. A
404 is a `status` of 404 and no error, as everywhere else here.

The plugin owns one client per world, reachable as `http.plugin.clientOf(world)` and closed by
`http.plugin.close(world)`. Build a second one with `tecs.net.http.newClient` if a chatty API and a downloader want
different pools.

## Canceling

```teal
local pending = client:send({ url = url })
pending:cancel()
```

Canceling the future is the way; it is reference counted, so a request two things are waiting on stops when the
second of them gives up. `Client:cancel(future)` is the same thing for a caller holding the client rather than the
future, and `Client:close()` cancels everything in flight and releases the pool.
