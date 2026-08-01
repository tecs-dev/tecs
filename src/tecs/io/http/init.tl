--[=[
Asynchronous HTTP and HTTPS.

```teal no-format
local endpoint <const> = tecs.io.newURI(
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

    --- `Client` names a connection pool and its request
    --- futures.
    type Client = client.Client

    --- `Request` describes one request and requires only
    --- `url`.
    type Request = client.Request

    --- `Response` describes what a completed transfer
    --- settles to regardless of status code.
    type Response = client.Response

    --- Read-only. `plugin` exposes requests and responses as ECS components.
    plugin: plugin

    --- Builds a client.
    ---
    --- @param options The caller supplies client defaults or omits this record
    ---     to use every default. Each `insecureHosts` entry logs a warning.
    --- @return Returns an open client that remains active until `close`.
    newClient: function(options?: ClientOptions): client.Client

    --- Returns the open-client count.
    ---
    --- @return Returns the process-wide count of clients not yet closed.
    getOpenClientCount: function(): integer
end

http.plugin = plugin
http.newClient = client.newClient
http.getOpenClientCount = clients.count

return http
