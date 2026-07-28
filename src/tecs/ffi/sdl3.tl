--- SDL3 binding.
---
--- Exposes the raw C namespace plus the small helpers every caller needs.
--- Typed engine APIs live above this; this module stays thin so the
--- generated cdef remains the single source of truth.

local loader <const> = require("tecs.ffi.loader")

loader.declare("sdl3")

local namespace <const>, libraryPath <const> = loader.library("SDL3", "sdl3", "TECS_SDL3_PATH", "sdl3")

local record sdl3
    --- Functions and enum constants, resolved through the loaded library.
    C: loader.CNamespace
    --- Integer `#define` constants, which the preprocessor strips before the
    --- cdef sees them and so cannot be reached through `C`.
    K: {string: integer}
    --- Absolute path of the library that satisfied the load.
    path: string
end

sdl3.C = namespace
sdl3.K = loader.constants("sdl3")
sdl3.path = libraryPath

--- Returns the current SDL error as a Lua string.
function sdl3.error(): string
    local message = sdl3.C.SDL_GetError()
    if message == nil then
        return "(no error)"
    end
    return loader.toString(message)
end

--- Raises with the pending SDL error, prefixed by `what`.
function sdl3.fail(what: string)
    error(("tecs: %s failed: %s"):format(what, sdl3.error()), 3)
end

--- Asserts an SDL boolean result, raising with the pending error on failure.
function sdl3.check(ok: boolean, what: string)
    if not ok then
        sdl3.fail(what)
    end
end

return sdl3
