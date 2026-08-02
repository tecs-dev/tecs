--[=[
Asynchronous HTTP and HTTPS.

```teal no-format
local client <const> = tecs.io.http.newClient({userAgent = "mygame/1.0"})
local response <const> = client:send({
    url = tecs.io.URI.new("https://example.com/manifest.json"),
})
local body <const> = response.body
if body is tecs.io.ReadableStream then
    print(body:readAll())
end
```

The process runtime turns every open client once per iteration, so requests
advance without game code pumping them.

An HTTP error status still returns a response. DNS, connection, TLS, timeout,
or streaming failures raise at the suspended call.

Call `Client:close` when you no longer need its connection pool. Losing the
last Lua reference does not cancel its requests. A headless tool calls
[`tecs.runtime.poll`](/modules/runtime/#tecs.runtime.poll);
[`Application`](tealdoc:tecs.Application) calls it once per frame.
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

    --- `Response` describes what a completed transfer
    --- settles to regardless of status code.
    type Response = client.Response

    --- A `Client` owns one connection pool and its active requests.
    ---
    --- Closing the client cancels every pending request, releases the pool,
    --- and remains safe to repeat. An application or `tecs.runtime.poll`
    --- drives active requests rather than game code calling `poll` directly.
    interface Client is Closeable
        --- Sends one HTTP request and returns its response.
        ---
        --- A transport failure raises. An HTTP error status returns normally
        --- with that status in the response. Inside a system, the call
        --- suspends the world update only while the transfer is pending.
        --- @param self The open client that owns the request.
        --- @param request The caller supplies the URL and optional method,
        ---     headers, body, destination, timeouts, and byte limit.
        --- @return Returns the completed response.
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
