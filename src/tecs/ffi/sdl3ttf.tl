--[=[
SDL3_ttf binding.

The generated declarations include both the font API and the public text
engine operation records. Tecs creates text with no SDL renderer and reads
those operations directly, so SDL_ttf shapes and lays out text without ever
calling back into Lua or expanding glyphs into a vertex buffer.
]=]

local loader <const> = require("tecs.ffi.loader")

-- SDL_ttf's declarations refer to SDL surfaces, rectangles, streams, colors,
-- and properties.
loader.declare("sdl3")
loader.declare("sdl3ttf")

local namespace <const>, libraryPath <const> = loader.library(
    "SDL3_ttf", "sdl3_ttf", "TECS_SDL3TTF_PATH", "sdl3ttf"
)

--- The SDL3_ttf library, reached through the generated cdef.
local record sdl3ttf
    --- Functions and enum constants, resolved through the loaded library.
    C: loader.CNamespace
    --- Integer `#define` constants stripped before the cdef is installed.
    K: {string: integer}
    --- What satisfied the load, for diagnostics.
    path: string
end

sdl3ttf.C = namespace
sdl3ttf.K = loader.constants("sdl3ttf")
sdl3ttf.path = libraryPath

local started = false

--- Initializes SDL_ttf once in this Lua state.
--- @return Returns true when SDL_ttf is ready.
function sdl3ttf.init(): boolean
    if started then
        return true
    end
    if not namespace.TTF_Init() then
        return false
    end
    started = true
    return true
end

--- Reports whether this state initialized SDL_ttf.
--- @return Returns this state's initialization flag.
function sdl3ttf.started(): boolean
    return started
end

--- Releases this state's SDL_ttf initialization reference.
function sdl3ttf.quit()
    if not started then
        return
    end
    namespace.TTF_Quit()
    started = false
end

return sdl3ttf
