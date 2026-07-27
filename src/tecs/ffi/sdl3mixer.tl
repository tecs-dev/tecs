--- SDL3_mixer binding: file bytes to a mix.
---
--- The SDL3 library is `MIX_*` and shares nothing but a name with the SDL2
--- `Mix_*` one. A mixer owns tracks, a track is one voice, and a tag is a name
--- several tracks answer to at once.
---
--- Loading happens on a worker, so this is loaded in the worker's state as well
--- as the main one. `ffi.load` resolves to the same already-mapped library in
--- both, so there is one copy of the decoders in the process, and the library's
--- own initialisation is process-wide rather than per-state.
---
--- `MIX_Init` is documented as not thread safe, so `init` is called from the
--- main thread only, before anything is sent to a worker that will decode.
--- The refcount it keeps is the library's; the flag here only stops this state
--- asking twice.

local loader <const> = require("tecs.ffi.loader")

loader.declare("sdl3mixer")

local namespace <const>, libraryPath <const> =
    loader.library("SDL3_mixer", "sdl3_mixer", "TECS_SDL3MIXER_PATH", "sdl3mixer")

local record sdl3mixer
    C: loader.CNamespace
    K: {string: integer}
    path: string
end

sdl3mixer.C = namespace
sdl3mixer.K = loader.constants("sdl3mixer")
sdl3mixer.path = libraryPath

local started = false

--- Initialises the library, once per state. Returns whether it is usable.
---
--- Call from the main thread. Everything else in this library may be called
--- from any thread once this has returned.
function sdl3mixer.init(): boolean
    if started then return true end
    if not namespace.MIX_Init() then return false end
    started = true
    return true
end

--- Whether `init` has succeeded in this state.
function sdl3mixer.started(): boolean
    return started
end

--- Releases the library, destroying every mixer, track and audio it made.
---
--- Nothing loaded through this library may be touched afterwards, including
--- anything a worker loaded, so callers destroy their own objects first.
function sdl3mixer.quit()
    if not started then return end
    namespace.MIX_Quit()
    started = false
end

--- The decoders this build carries, in the order the library reports them.
---
--- What was asked for at configure time and what got linked are different
--- questions: a decoder whose dependency was not found is dropped silently.
--- This is the answer to the second question.
function sdl3mixer.decoders(): {string}
    local names: {string} = {}
    local count = tonumber(namespace.MIX_GetNumAudioDecoders()) as integer
    for index = 0, count - 1 do
        names[index + 1] = loader.toString(namespace.MIX_GetAudioDecoder(index))
    end
    return names
end

return sdl3mixer
