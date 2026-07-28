--- SDL3_net binding.
---
--- Sockets, and nothing above them. The public transport and MCP debug server
--- are both built on this binding; protocol framing stays above it.
---
--- Chosen over luasocket because it is the same ecosystem as everything else
--- here, so it reaches the same generated-binding and static-registry path,
--- and because it is non-blocking by default: the accept, read and status
--- calls all return immediately, which is what lets a server be polled from a
--- phase rather than owning a thread.

local loader <const> = require("tecs.ffi.loader")

loader.declare("sdl3net")

local namespace <const>, libraryPath <const> = loader.library("SDL3_net", "sdl3_net", "TECS_SDL3NET_PATH", "sdl3net")

--- The SDL3_net library, reached through the generated cdef.
---
--- Resolution runs at require time, so requiring this module raises when
--- SDL3_net cannot be found rather than answering a module whose calls fail
--- later. No version is checked; a library older than the headers the cdef
--- came from raises at the first access to a symbol it lacks.
---
--- `NET_Init` is not called here. A caller initialises the library itself,
--- and the socket calls reached through `C` are non-blocking: they report a
--- pending operation rather than waiting for it.
local record sdl3net
    --- Functions and enum constants, resolved through the loaded library.
    C: loader.CNamespace
    --- Integer `#define` constants, which the preprocessor strips before the
    --- cdef sees them and so cannot be reached through `C`.
    K: {string: integer}
    --- What satisfied the load: an absolute path, or the bare soname when the
    --- dynamic linker resolved it itself, or `"(registry)"` when the host
    --- linked the symbols in. Diagnostic, and not always openable.
    path: string
end

sdl3net.C = namespace
sdl3net.K = loader.constants("sdl3net")
sdl3net.path = libraryPath

return sdl3net
