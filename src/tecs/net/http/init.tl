--- Asynchronous HTTP over Reqwest and rustls.
---
---     tecs.net.http.newClient({userAgent = "mygame/1.0"})
---         :send({url = "https://example.com/manifest.json"})
---         :map(function(response: tecs.net.http.Response): string
---             return response.body:text()
---         end)
---         :onSettle(function(manifest: tecs.Future<string>) print(manifest.value) end)
---
--- Nothing goes in a frame. An application turns every open client once an
--- iteration, so a request is started and answered without a game asking
--- anything to happen in between.
---
--- One protocol namespace under `tecs.net`, which is the transport below it.
--- `Client`, `ClientOptions`, `Request` and `Response` are the vocabulary of a
--- transfer, `DataStream` is what a body is in either direction, and `plugin`
--- is the same client with a request spawned as an entity instead.

local client <const> = require("tecs.net.http.client")
local clients <const> = require("tecs.net.http.clients")
local plugin <const> = require("tecs.net.http.plugin")
local DataStream <const> = require("tecs.net.http.DataStream")

local type Options = client.Options

local record http
    --- A Reqwest connection pool and the `Future.Source` behind every future
    --- it hands out. Rust drives sockets on Tokio; the SDL loop drains results.
    type Client = client.Client

    --- How a client behaves for every request it sends. Named for the client
    --- rather than left as `Options`, because a namespace carrying requests,
    --- responses and a plugin has more than one thing that could be optioned.
    type ClientOptions = client.Options

    --- One request. Only `url` is required.
    type Request = client.Request

    --- What a completed transfer settles to, whatever the status code. A 404
    --- is one of these rather than a failed future.
    type Response = client.Response

    --- Bytes, wherever they are: a string, a borrowed buffer, a path, or a
    --- handle the caller opened. A request takes one and a response carries
    --- one, so neither side has to know which kind it is.
    DataStream: DataStream

    --- A request as an entity, for a world that would rather spawn one than
    --- hold a future.
    ---
    --- The one name here that is a namespace of its own, and it stays one
    --- because its `Request` and `Response` are components rather than the
    --- records above. Two pairs of that name cannot share a level, and the
    --- components are registered under strings that do not move.
    plugin: plugin

    --- Builds a client.
    ---
    --- @param options Read here rather than kept, so a field changed on the
    ---     table afterwards is not seen. Omitted takes every default. Each
    ---     entry of `insecureHosts` logs a warning as the client is built.
    --- @return An open client, already on the list an application turns once
    ---     an iteration. It stays there until `close`, which is what ends a
    ---     client: dropping the last reference to one does not.
    newClient: function(options?: Options): client.Client

    --- Turns every open client once.
    ---
    --- What an application calls each iteration. A game calls nothing; this is
    --- for a headless tool that has no application, and for a test driving a
    --- transfer a turn at a time.
    ---
    --- @return How many transfers settled during this turn, across every open
    ---     client, so a caller that wants to know whether anything happened
    ---     does not have to ask each future. 0 when none is open.
    pumpClients: function(): integer

    --- How many clients are open.
    ---
    --- @return Clients built and not yet closed, counted process-wide rather
    ---     than per world. One nobody closed is still counted, which is what
    ---     makes this the way to see a client that leaked.
    openClients: function(): integer
end

http.DataStream = DataStream
http.plugin = plugin
http.newClient = client.newClient
http.pumpClients = clients.pump
http.openClients = clients.count

return http
