--- HTTP, over libcurl's multi interface.
---
---     tecs.http.client({userAgent = "mygame/1.0"})
---         :send({url = "https://example.com/manifest.json"})
---         :map(function(response: tecs.http.client.Response): string
---             return response.body:text()
---         end)
---         :onSettle(function(manifest: tecs.Future<string>) print(manifest.value) end)
---
--- Nothing goes in a frame. An application turns every open client once an
--- iteration, so a request is started and answered without a game asking
--- anything to happen in between.
---
--- `tecs.http.client` is callable and is also where `Request`, `Response` and
--- `Options` live. `tecs.http.DataStream` is what a body is, in either
--- direction. See `tecs.http.client` for the whole surface.

local client <const> = require("tecs.http.client")
local clients <const> = require("tecs.http.clients")
local DataStream <const> = require("tecs.http.DataStream")

local record http
    client: client
    clients: clients
    DataStream: DataStream
end

http.client = client
http.clients = clients
http.DataStream = DataStream

return http
