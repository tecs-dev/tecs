--- SDL3_net binding.
---
--- Sockets, and nothing above them. The MCP transport is built on this; the
--- engine itself does not use the network.
---
--- Chosen over luasocket because it is the same ecosystem as everything else
--- here, so it reaches the same generated-binding and static-registry path,
--- and because it is non-blocking by default: the accept, read and status
--- calls all return immediately, which is what lets a server be polled from a
--- phase rather than owning a thread.

local loader <const> = require("tecs2d.ffi.loader")

loader.declare("sdl3net")

local namespace <const>, libraryPath <const> =
    loader.library("SDL3_net", "sdl3_net", "TECS2D_SDL3NET_PATH", "sdl3net")

local record sdl3net
    C: loader.CNamespace
    K: {string: integer}
    path: string
end

sdl3net.C = namespace
sdl3net.K = loader.constants("sdl3net")
sdl3net.path = libraryPath

return sdl3net
