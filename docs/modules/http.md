---
description: "An HTTP client driven from a frame, where every request is a future and nothing ever blocks the loop"
outline: deep
---

# tecs.http

`tecs.http` fetches things over HTTP and HTTPS without stopping the frame it was called from. Every request
returns a [`Future`](/modules/Future), the loop pumps, and the answer arrives when it arrives.

It is libcurl's multi interface underneath. The easy interface's `curl_easy_perform` runs a whole transfer
before it returns, which in a game is a frame that does not end until the network answers; the multi interface
does as much as can be done without waiting and reports what is still in flight, which is the same shape
[`assets`](/modules/assets) and [`proc`](/modules/proc) already use.

libcurl writes response bodies and raw headers into a native response buffer. Headers have their own allocation
cap, and a nonzero `maxBytes` caps the body. Its callbacks stay in C because LuaJIT cannot re-enter a Lua FFI
callback from a compiled pump loop. Lua reads the completed buffer, then parses only the final response's
headers, so interim and redirect headers never appear in `Response.headers`.

## Requiring it

```teal
local tecs <const> = require("tecs")
```

The whole surface is `require("tecs")` and every module is a field on it, so this module is `tecs.http`. `tecs`
is also set as a global, which makes the require line optional, and engine modules are resolved lazily on first
field access, so a program that never mentions `tecs.http` never loads libcurl.

```teal
local client <const> = tecs.http.client({ userAgent = "mygame/1.0" })

local manifest <const> = client:send({
    url = "https://example.com/manifest.json",
    headers = { accept = "application/json" },
})

-- once per frame, from wherever the loop already runs
client:pump()

if manifest.status == "ready" then
    print(manifest.value.status, manifest.value.body)
end
```

`tecs.http.client` is callable and is also the namespace: calling it builds a `Client`, and `client.Request`,
`client.Response` and `client.Options` are the records around it.

## Every call returns a future

There is no `sendSync` and no `blocking = true`, because blocking is something done _to_ a future rather than a
mode a request is issued in.

```teal
local config <const> = client:send({ url = url })
    :map(function(response: tecs.http.client.Response): string return response.body end)
    :recover(function(): string return DEFAULTS end)
    :wait(2000)
```

::: tip Always name the timeout
The number at the call site is the whole guard. A reviewer who sees `wait(2000)` asks why a frame is being held
for two seconds, which is a question a boolean never prompts. A `wait` with no argument is bounded by the
client's own `timeoutMs` rather than by an unrelated default, but write the number anyway.
:::

## A response is not a failure

A 404 settles `"ready"` with `status` 404. `"failed"` means the transfer did not complete: the name did not
resolve, the connection was refused, TLS did not verify, the deadline passed. `"cancelled"` means this process
stopped it.

This is the same reasoning [`proc`](/modules/proc) applies to an exit code. A status code is the answer to the
request, and making it a failure would propagate a 404 through `map` as though the transfer broke.
`Response:ok()` is the separate question about the answer.

## Bodies do not default to strings

Omitting `into` returns the body as a string, which is right for a manifest and wrong for a patch. `into` names
a path to write it to instead, leaving `Response.body` nil, so the large case has a spelling of its own and a
500 MB download is not the path of least resistance. The write goes through
[`filesystem`](/modules/filesystem), so a port that replaced the storage backend gets it without this module
knowing.

::: warning `into` is not yet a memory bound
It buys the file and the storage seam. The body is still assembled in memory and written once, because the
storage backend has `write` and no append. Until that changes, `maxBytes` is the real ceiling: it is checked as
the bytes arrive and again against a declared `Content-Length`, and a transfer that reaches it fails rather than
growing.
:::

## TLS verification is on

Peer and host verification are set explicitly on every handle rather than left to the library's default, and the
protocol set is narrowed to `http` and `https` for the request and for anything it redirects to.

There is no `insecure = true`. What exists is `insecureHosts`, an explicit list of host names whose certificates
are not checked, each of which logs a warning when the client is built. No wildcard, port, scheme or URL is
accepted in that list.

```teal
local client <const> = tecs.http.client({ insecureHosts = { "dev.example.com" } })
```

A self-signed development server is a real need and this serves it. Pinning a development CA through libcurl's
own `CURLOPT_CAINFO` is better still and is what to reach for when the host is not on a developer's own machine.

## Three timeouts

`connectTimeoutMs` bounds getting a socket, `timeoutMs` bounds the whole transfer, and `stallTimeoutMs` bounds
going nowhere. The third is the one that is easy to leave out: a whole-transfer deadline is the wrong bound for
a download, because the number that stops a hung connection is far smaller than the number a large body
legitimately needs. So a long `timeoutMs` beside a short `stallTimeoutMs` is what `into` wants. It is off by
default, because a client that abandoned a request while a server was thinking would be doing something nobody
asked it to.

## Connections are pooled and bounded

One client is one connection pool. It reuses sockets across requests, and `maxConnections` and
`maxConnectionsPerHost` bound how many it opens; requests past the bound are held rather than refused, so a game
that queues two hundred fetches opens six sockets to that host and not two hundred.

That matters more than it might, because a packaged build is HTTP/1.1 only and has no multiplexing to make one
connection carry many requests. A development preset resolves libcurl from the system and may well get HTTP/2,
so this is one of the few places the two differ in behaviour rather than only in what they link.

## DNS does not block

libcurl's multi interface is non-blocking for transfer but resolves names synchronously unless the library was
built with the threaded resolver or c-ares, and a cold lookup is comfortably a dropped frame.

Both builds this tree uses resolve off the calling thread. The packaged libcurl is built with c-ares off, which
is the condition under which libcurl's own build defaults the threaded resolver on, and its generated
configuration carries it. The system library a development preset resolves reports the same. Worth re-checking
on a new target, and the check is one call: `curl_version_info` sets `CURL_VERSION_ASYNCHDNS` in `features` when
the resolver is asynchronous.

## client

Builds a client. Every field is optional.

```teal
local client <const> = tecs.http.client(options?: Options)
```

**`Options` fields:**

| Field                   | Type               | Default | Description                                                                                                     |
| ----------------------- | ------------------ | ------- | --------------------------------------------------------------------------------------------------------------- |
| `userAgent`             | `string`           | none    | Sent as `User-Agent`. Name the game and its version; a server operator reading a log has nothing else to go on. |
| `headers`               | `{string: string}` | none    | Sent on every request, and overridden per request by the same name.                                             |
| `timeoutMs`             | `number`           | `30000` | Milliseconds a whole transfer is given.                                                                         |
| `connectTimeoutMs`      | `number`           | `10000` | Milliseconds the connection is given, inside that.                                                              |
| `stallTimeoutMs`        | `number`           | `0`     | Milliseconds a transfer may make no progress before failing. Measured by libcurl in whole seconds.              |
| `maxRedirects`          | `integer`          | `5`     | Redirects followed. `0` follows none.                                                                           |
| `maxConnections`        | `integer`          | `16`    | Sockets kept open across every host.                                                                            |
| `maxConnectionsPerHost` | `integer`          | `6`     | Sockets kept open to any one host.                                                                              |
| `maxBytes`              | `integer`          | `0`     | Bytes a response body may reach before the transfer fails. `0` is unbounded.                                    |
| `compressed`            | `boolean`          | `true`  | Offer the content encodings libcurl was built with, which is zlib here.                                         |
| `insecureHosts`         | `{string}`         | none    | Host names whose certificates are not verified. Each logs a warning. Anything that is not a plain host raises.  |

## send

Starts a transfer and answers what it will settle to.

```teal
function Client:send(request: Request): Future<Response>
```

**Returns:** a future that reads `"pending"` until a [`pump`](#pump), or a `wait` on it, takes libcurl's answer.
Nothing here blocks.

Raises when the call itself is malformed: no request, no URL, a body given as bytes with no length. Everything
only the network can judge settles the future instead, since a URL out of a manifest is data rather than a
mistake in the program, so a non-`http` scheme comes back as a failed future.

**`Request` fields:**

| Field            | Type               | Default  | Description                                                                                                                                      |
| ---------------- | ------------------ | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `url`            | `string`           | required | Absolute, with an `http` or `https` scheme.                                                                                                      |
| `method`         | `string`           | `"GET"`  | Any method the server accepts. `POST`, `PUT` and `PATCH` always carry a body, even an empty one.                                                 |
| `headers`        | `{string: string}` | none     | Merged over the client's, matched without case.                                                                                                  |
| `body`           | `string`           | none     | The request body.                                                                                                                                |
| `bodyBytes`      | `CValue`           | none     | The request body as an FFI buffer, with `bodyLength` beside it. libcurl copies during `send`, so the buffer may be reused as soon as it returns. |
| `bodyLength`     | `integer`          | none     | Bytes to send from `bodyBytes`. Required with it.                                                                                                |
| `into`           | `string`           | none     | Where to write the body, instead of returning it as a string.                                                                                    |
| `timeoutMs`      | `number`           | client's | Milliseconds this transfer is given.                                                                                                             |
| `stallTimeoutMs` | `number`           | client's | Milliseconds of no progress this transfer tolerates.                                                                                             |
| `maxBytes`       | `integer`          | client's | Bytes this body may reach.                                                                                                                       |

`body` and `bodyBytes` are two fields rather than one that takes either, because Teal discriminates a union by
`type()` and cdata is neither of the two answers that would tell a string from a buffer.

**`Response` fields:**

| Field     | Type               | Description                                                                                |
| --------- | ------------------ | ------------------------------------------------------------------------------------------ |
| `status`  | `integer`          | The HTTP status code, after any redirects.                                                 |
| `headers` | `{string: string}` | Response headers, with lower-cased names. A redirect's headers replace the ones before it. |
| `body`    | `string`           | The body, when `into` was not given.                                                       |
| `path`    | `string`           | Where the body was written, when `into` was given.                                         |
| `url`     | `string`           | The URL that actually answered, after any redirects.                                       |
| `bytes`   | `integer`          | Body length in bytes, whether it was kept or written.                                      |
| `ok()`    | `boolean`          | Whether `status` is a 2xx.                                                                 |

## pump

Advances every transfer as far as it can go without waiting.

```teal
function Client:pump(): integer
```

Call once per frame. Answers how many transfers settled, so a caller that wants to know whether anything
happened does not have to ask each future.

::: danger Pumping is not re-entrant
`wait` advances this client, and settling a future runs its listeners, so a listener that calls `wait` or `pump`
would re-enter libcurl's multi handle from inside a pump of it. libcurl does not define that, so it raises
rather than being left to chance. Sending from a listener is fine.
:::

## pending

Transfers that have not settled.

```teal
function Client:pending(): integer
```

## cancel

Stops one transfer, whatever state it is in.

```teal
function Client:cancel(future: Future<any>)
```

This is also what `Future:cancel` reaches once the last watcher of a transfer has gone, so prefer that; this
exists for a caller holding the client rather than the future.

## close

Stops every transfer and releases the connection pool.

```teal
function Client:close()
```

Each unsettled future settles `"cancelled"`. A closed client raises on `send` and answers 0 to `pump`, rather
than being silently useless.

## What is not here yet

**No ECS plugin, and it is the intended next step.** A plugin would own a `Client` as a world resource, pump it
once per frame from a system in an early phase, and give a request an entity: an `http.Request` component
carrying the fields of `Request`, spawned by a game and replaced with a `Response` component when the future
settles, so a request is inspectable through the [debug server](/modules/mcp) like everything else. It is not
built yet because its shape is the first real caller's to decide. Everything it needs is on this surface
already.

**No platform adapter.** A console's HTTP stack is not libcurl and belongs beside audio and input behind the
platform seam. `Request` and `Response` are already backend-neutral; `insecureHosts` is the part that is not,
because it is expressed as two libcurl options today.

**No proxy configuration.** libcurl reads `http_proxy` and `https_proxy` from the environment already, which is
what a developer behind one expects.

**No response body handed over as a stream.** A stream the caller must close is a connection held until it does,
which is the one shape a frame-driven client cannot take. `into` is that case answered differently.
