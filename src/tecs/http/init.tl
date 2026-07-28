--- HTTP, over libcurl's multi interface.
---
--- One module today, and the namespace exists so it stays that way when a
--- second lands beside it: an ECS plugin, or a server, would be
--- `tecs.http.plugin` and `tecs.http.server` rather than another top-level
--- name.
---
---     local client <const> = tecs.http.client({userAgent = "mygame/1.0"})
---
--- `tecs.http.client` is callable and is also where `Request`, `Response` and
--- `Options` live. See `tecs.http.client` for the whole surface.

local client <const> = require("tecs.http.client")

local record http
    client: client
end

http.client = client

return http
