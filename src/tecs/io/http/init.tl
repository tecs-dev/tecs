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
local datastream <const> = require("tecs.io.http.DataStream")
local loader <const> = require("tecs.ffi.loader")

local type Options = client.Options
local type DataStream = datastream.DataStream

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

    --- Creates a stream over a string already in memory.
    ---
    --- @param text The stream retains this immutable string. A non-string
    ---     value raises.
    --- @param contentType Nil sends no `Content-Type` rather than guessing
    ---     one.
    --- @return A source-only stream whose `length` is the string's byte count.
    newStringStream: function(text: string, contentType?: string): DataStream

    --- Creates a stream over a borrowed FFI buffer.
    ---
    --- @param pointer The caller retains and keeps this buffer alive until the
    ---     transfer finishes. Nil raises.
    --- @param length The readable byte count. Nil or negative raises, and the
    ---     function does not check it against the allocation.
    --- @param contentType Nil sends no `Content-Type` rather than guessing
    ---     one.
    --- @return A source-only stream.
    newBytesStream: function(pointer: loader.CValue, length: integer, contentType?: string): DataStream

    --- Creates a stream over a path read and written through `tecs.io.files`.
    ---
    --- The function does not open the file. A source opens when a transfer
    --- starts and a destination opens when its first byte arrives.
    ---
    --- @param path An empty or non-string path raises. A missing path is
    ---     allowed because it may name a destination.
    --- @param contentType Nil sends no `Content-Type` rather than guessing
    ---     one.
    --- @return A source and destination stream. `length` is set only when the
    ---     path already names a file.
    newFileStream: function(path: string, contentType?: string): DataStream

    --- Creates a stream over a handle the caller opened and still owns.
    ---
    --- The stream never closes the handle. A request containing this stream
    --- cannot be snapshotted because its ownership and position cannot be
    --- reconstructed.
    ---
    --- @param handle Reading starts at this open handle's current position.
    ---     Nil raises.
    --- @param length Optional metadata that does not control HTTP framing.
    --- @param contentType Nil sends no `Content-Type` rather than guessing
    ---     one.
    --- @return A source and destination stream.
    newHandleStream: function(handle: FILE, length?: integer, contentType?: string): DataStream

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

http.DataStream = datastream.DataStream
http.plugin = plugin
http.newStringStream = datastream.newStringStream
http.newBytesStream = datastream.newBytesStream
http.newFileStream = datastream.newFileStream
http.newHandleStream = datastream.newHandleStream
http.newClient = client.newClient
http.pumpClients = clients.pump
http.openClients = clients.count

return http
