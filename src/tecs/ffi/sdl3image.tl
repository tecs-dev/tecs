--- SDL3_image binding: file bytes to pixels.
---
--- Decoding happens on a worker, so this is loaded in the worker's state as
--- well as the main one. `ffi.load` resolves to the same already-mapped
--- library in both, so there is one copy of the decoder in the process.

local loader <const> = require("tecs.ffi.loader")

loader.declare("sdl3image")

local namespace <const>, libraryPath <const> = loader.library(
    "SDL3_image", "sdl3_image", "TECS_SDL3IMAGE_PATH", "sdl3image"
)

--- The SDL3_image library, reached through the generated cdef.
---
--- Resolution runs at require time, so requiring this module raises when
--- SDL3_image cannot be found rather than answering a module whose calls fail
--- later. That applies in a worker state too, where the require is what pulls
--- the decoder in. No version is checked; a library older than the headers the
--- cdef came from raises at the first access to a symbol it lacks.
---
--- Which formats decode is a property of the build, not of this module: a
--- decoder whose dependency was missing at configure time is absent from the
--- library, and the load of that format fails at runtime.
local record sdl3image
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

sdl3image.C = namespace
sdl3image.K = loader.constants("sdl3image")
sdl3image.path = libraryPath

return sdl3image
