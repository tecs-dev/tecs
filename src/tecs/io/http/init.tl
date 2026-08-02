--[=[
Cooperative HTTP and HTTPS.

```teal no-format
local client <const> = tecs.io.http.newClient({userAgent = "mygame/1.0"})
local response <const> = client:send({
    url = tecs.io.URI.new("https://example.com/manifest.json"),
})
print(response.status)
print(assert(response.body:readAll(1024 * 1024)))
```

`send` returns when status and headers exist. Inside a system it suspends only
until that boundary; outside an update it blocks its caller. The body is a
one-shot streaming Reader backed by bounded native chunks, so a slow consumer
applies transport backpressure instead of accumulating the full response.

An HTTP error status still returns a response. DNS, connection, TLS, timeout,
or streaming failures raise at the suspended call.

Raw `tecs.io` sockets use the process-wide `mio` readiness reactor. HTTP
deliberately uses Reqwest and Tokio for its connection pool, TLS, redirects,
and protocol work. Both implementations resume the same direct Lua call, and
neither parks one worker thread per waiting socket.

Call `Client:close` when you no longer need its connection pool. Losing the
last Lua reference does not cancel its requests. An
[`Application`](tealdoc:tecs.Application) owns progress; a direct headless call
drives the client while it blocks.
]=]

-- Implementation details:
-- Reqwest owns connection pools and drives sockets on Tokio. Rustls provides
-- TLS, and the application loop drains completed transfers into Lua.

local client <const> = require("tecs.io.http.client")
local clients <const> = require("tecs.io.http.clients")
local plugin <const> = require("tecs.io.http.plugin")
local type coretypes = require("tecs.types")
local type Closeable = coretypes.Closeable

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
    --- logs a warning for each. `proxy` accepts the textual spelling of an
    --- absolute [`URI`](tealdoc:tecs.io.URI), follows environment variables
    --- when nil, and forces a direct connection when empty. `noProxy` uses
    --- Reqwest's exclusion syntax, and `proxyCredentials` uses
    --- `user:password`.
    type ClientOptions = client.Options

    --- `Request` describes one request and requires only
    --- `url`.
    type Request = client.Request

    --- `Response` describes status, headers, and a progressive response body.
    type Response = client.Response

    --- A `Client` owns one connection pool and its active requests.
    ---
    --- Closing the client cancels every pending request, releases the pool,
    --- and remains safe to repeat. The Application drives active requests.
    interface Client is Closeable
        --- Sends one HTTP request and returns its response.
        ---
        --- A transport failure raises. An HTTP error status returns normally
        --- with that status in the response. Inside a system, the call
        --- suspends the world update only while the transfer is pending.
        --- @param self The open client that owns the request.
        --- @param request The caller supplies the URL and optional method,
        ---     headers, upload body, timeouts, and byte limit.
        --- @return Returns status, headers, and a one-shot streaming body.
        send: function(self: Client, request: Request): Response

        --- Returns the number of unsettled requests.
        ---
        --- @param self The client to inspect.
        --- @return Returns zero after every request settles or is canceled.
        pending: function(self: Client): integer
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
