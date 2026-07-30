--[=[
Asynchronous HTTP and HTTPS.

```teal no-format
tecs.io.http.newClient({userAgent = "mygame/1.0"})
    :send({url = "https://example.com/manifest.json"})
    :map(function(response: tecs.io.http.Response): string
        local body <const> = response.body:text()
        return body
    end)
    :onSettle(function(manifest: tecs.Future<string>)
        print(manifest.value)
    end)
```

An application turns every open client once per iteration, so requests
advance without game code pumping them.

An HTTP error status still produces a ready response. A failed future means
that DNS, connection, TLS, timeout, or streaming produced no response.

Call `Client:close` when you no longer need its connection pool. Losing the
last Lua reference does not cancel its requests. A headless tool calls
`pumpClients`; [`Application`](tealdoc:tecs.Application) does this once per
frame.
]=]

-- Implementation details:
-- Reqwest owns connection pools and drives sockets on Tokio. Rustls provides
-- TLS, and the application loop drains completed transfers into Lua futures.

local client <const> = require("tecs.io.http.client")
local clients <const> = require("tecs.io.http.clients")
local plugin <const> = require("tecs.io.http.plugin")
local DataStream <const> = require("tecs.io.http.DataStream")

local type Options = client.Options

local record http
    --- `Client` names a connection pool and its request
    --- futures.
    type Client = client.Client

    --- `ClientOptions` configures every request sent
    --- through a client.
    type ClientOptions = client.Options

    --- `Request` describes one request and requires only
    --- `url`.
    type Request = client.Request

    --- `Response` describes what a completed transfer
    --- settles to regardless of status code.
    type Response = client.Response

    --- Read-only. `DataStream` names bytes stored in a string, borrowed
    --- buffer, path, or caller-opened handle.
    DataStream: DataStream

    --- Read-only. `plugin` exposes requests and responses as ECS components.
    plugin: plugin

    --- Builds a client.
    ---
    --- @param options The caller supplies client defaults or omits this record
    ---     to use every default. Each `insecureHosts` entry logs a warning.
    --- @return Returns an open client that remains active until `close`.
    newClient: function(options?: Options): client.Client

    --- Turns every open client once.
    ---
    --- An application calls this each iteration. Headless tools and tests call
    --- it directly.
    ---
    --- @return Returns how many transfers settled across every open client
    ---     during this turn, or zero without an open client.
    pumpClients: function(): integer

    --- Returns the open-client count.
    ---
    --- @return Returns the process-wide count of clients not yet closed.
    openClients: function(): integer
end

http.DataStream = DataStream
http.plugin = plugin
http.newClient = client.newClient
http.pumpClients = clients.pump
http.openClients = clients.count

return http
