--[=[
SDL3 binding.

Exposes the raw C namespace plus the small helpers every caller needs.
Typed engine APIs live above this; this module stays thin so the
generated cdef remains the single source of truth.
]=]

local loader <const> = require("tecs.ffi.loader")

loader.declare("sdl3")

local namespace <const>, libraryPath <const> = loader.library("SDL3", "sdl3", "TECS_SDL3_PATH", "sdl3")

--- The SDL3 library, reached through the generated cdef.
---
--- Resolution runs at require time, so requiring this module raises when SDL3
--- cannot be found rather than answering a module whose calls fail later. No
--- version is checked: the cdef is generated from whatever headers the build
--- host had, and a runtime library older than those resolves the symbols it
--- does have and raises at the first access to one it does not.
local record sdl3
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

sdl3.C = namespace
sdl3.K = loader.constants("sdl3")
sdl3.path = libraryPath

--- Returns the current SDL error as a Lua string.
---
--- SDL does not clear the error on a successful call, so this is only
--- meaningful immediately after one that reported failure.
---
--- @return The pending message, or `"(no error)"` when SDL has none. Never nil
---     and never empty, so it is safe to interpolate straight into a message.
function sdl3.error(): string
    local message = sdl3.C.SDL_GetError()
    if message == nil then
        return "(no error)"
    end
    return loader.toString(message)
end

--- Raises with the pending SDL error, prefixed by `what`.
---
--- Never returns. Raised at stack level 3, which blames two frames above this
--- one: called directly from a wrapper, the position reported is that
--- wrapper's own caller, not the line holding the failed SDL call. Reached
--- through `check` there is one more frame in between, so the position lands
--- on the wrapper instead.
---
--- @param what The SDL entry point that failed, spelled as SDL spells it, e.g.
---     `"SDL_CreateGPUDevice"`. It is interpolated, not formatted, so a literal
---     `%` in it is safe.
function sdl3.fail(what: string)
    error(("tecs: %s failed: %s"):format(what, sdl3.error()), 3)
end

--- Asserts an SDL boolean result, raising with the pending error on failure.
---
--- The message is read at the moment of failure, so call this before any
--- further SDL call: the next one overwrites the pending error and the raise
--- then reports whatever that one left behind.
---
--- @param ok The failing call's own return, and nothing else. Any SDL call in
---     between makes the message belong to a different one.
--- @param what The SDL entry point that failed, as `fail` takes it.
function sdl3.check(ok: boolean, what: string)
    if not ok then
        sdl3.fail(what)
    end
end

return sdl3
