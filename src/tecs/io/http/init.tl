--[=[
Asynchronous HTTP and HTTPS.

```teal no-format
local endpoint <const> = tecs.io.URI.new(
    "https://example.com/manifest.json"
)
tecs.io.http.newClient({userAgent = "mygame/1.0"})
    :send({url = endpoint})
    :map(function(response: tecs.io.http.Response): string
        local body <const> = response.body
        if body is tecs.io.ReadableStream then
            return body:readAll()
        end
        error("the response destination is not readable")
    end)
    :onSettle(function(manifest: tecs.Future<string>)
        print(manifest.value)
    end)
```

The process runtime turns every open client once per iteration, so requests
advance without game code pumping them.

An HTTP error status still produces a ready response. A failed future means
that DNS, connection, TLS, timeout, or streaming produced no response.

Call `Client:close` when you no longer need its connection pool. Losing the
last Lua reference does not cancel its requests. A headless tool calls
[`tecs.runtime.poll`](/modules/runtime/#tecs.runtime.poll);
[`Application`](tealdoc:tecs.Application) calls it once per frame.
]=]

-- Implementation details:
-- Reqwest owns connection pools and drives sockets on Tokio. Rustls provides
-- TLS, and the application loop drains completed transfers into Lua futures.

local client <const> = require("tecs.io.http.client")
local clients <const> = require("tecs.io.http.clients")
local plugin <const> = require("tecs.io.http.plugin")
local type coretypes = require("tecs.types")
local type Closeable = coretypes.Closeable
local type Future = require("tecs.Future")

local record http
    --- Settings copied when an HTTP client is built.
    ---
    --- `userAgent` and `headers` set request defaults. `timeoutMs` defaults to
    --- 30000, `connectTimeoutMs` to 10000, and `stallTimeoutMs` to zero, which
    --- disables the no-progress timeout. `maxRedirects` defaults to five,
    --- `maxConnections` to 16, and `maxConnectionsPerHost` to six. `maxBytes`
    --- defaults to zero for no response limit. `compressed` defaults to true.
    ---
    --- `insecureHosts` disables certificate verification for named hosts and
    --- logs a warning for each. `proxy` follows environment variables when
    --- nil, forces a direct connection when empty, or supplies a proxy URI.
    --- `noProxy` uses Reqwest's exclusion syntax, and `proxyCredentials` uses
    --- `user:password`.
    type ClientOptions = client.Options

    --- `Request` describes one request and requires only
    --- `url`.
    type Request = client.Request

    --- `Response` describes what a completed transfer
    --- settles to regardless of status code.
    type Response = client.Response

    --- A `Client` owns one connection pool and the futures using it.
    ---
    --- Closing the client cancels every pending request, releases the pool,
    --- and remains safe to repeat. A client also drives its futures as their
    --- source, but an application or `tecs.runtime.poll` normally performs
    --- that work rather than game code calling `poll` or `advance` directly.
    interface Client is Closeable
        --- Engine-owned. Sets the maximum duration of one blocking future
        --- wait slice. Ordinary game code should ignore it.
        sliceMs: number

        --- Engine-owned. Sets the timeout used when `Future:wait` receives no
        --- explicit timeout. Ordinary game code should ignore it.
        defaultWaitMs: number

        --- Starts one HTTP transfer and returns immediately.
        ---
        --- A transport failure settles the future as failed. An HTTP error
        --- status settles it as ready with that status in the response.
        --- @param self The open client that owns the request.
        --- @param request The caller supplies the URL and optional method,
        ---     headers, body, destination, timeouts, and byte limit.
        --- @return Returns a future settled by the process runtime.
        send: function(self: Client, request: Request): Future<Response>

        --- Drains every response event currently ready without blocking.
        ---
        --- Application code normally lets the process runtime call this.
        --- @param self The open client to advance.
        --- @return Returns the number of response events processed.
        pump: function(self: Client): integer

        --- Returns the number of unsettled requests.
        ---
        --- @param self The client to inspect.
        --- @return Returns zero after every request settles or is canceled.
        pending: function(self: Client): integer

        --- Cancels the request belonging to a future.
        ---
        --- A settled future or a future from another source changes nothing.
        --- @param self The client that owns the request.
        --- @param future The caller supplies the request future to cancel.
        cancel: function(self: Client, future: Future<any>)

        --- Polls this client as a future source without blocking.
        ---
        --- Application code normally lets the process runtime call this.
        --- @param self The open client to poll.
        --- @return Returns the number of response events processed.
        poll: function(self: Client): integer

        --- Waits briefly for an event and drains the events then ready.
        ---
        --- `Future:wait` calls this through its source. Application code
        --- normally does not call it directly.
        --- @param self The open client to advance.
        --- @param ms The caller supplies the maximum milliseconds to wait.
        --- @return Returns the number of response events processed.
        advance: function(self: Client, ms: number): integer
    end

    --- Read-only. `plugin` exposes requests and responses as ECS components.
    plugin: plugin

    --- Builds a client.
    ---
    --- @param options The caller supplies client defaults or omits this record
    ---     to use every default. Each `insecureHosts` entry logs a warning.
    --- @return Returns an open client that remains active until `close`.
    newClient: function(options?: ClientOptions): Client

    --- Returns the open-client count.
    ---
    --- @return Returns the process-wide count of clients not yet closed.
    getOpenClientCount: function(): integer
end

http.plugin = plugin
http.newClient = client.newClient as function(options?: http.ClientOptions): http.Client
http.getOpenClientCount = clients.count

return http
