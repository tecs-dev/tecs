--- What a platform has to supply, and nothing else.
---
--- SDL covers every platform this engine can be built for openly. It does not
--- cover the ones whose SDKs are licensed, and those cannot be added here even
--- by someone who holds a licence: their headers may not be redistributed. So
--- the engine names its platform seams instead, and a licensed port supplies a
--- platform through this module without touching anything above it.
---
--- There are seven seams, and the reason each is a seam rather than a fork is
--- that everything else in the engine is already indifferent to the answer:
---
---   lifecycle   SDL owns the loop and calls the application's `_init`,
---               `_receive`, `_iterate`, and `_shutdown`. A console SDK owns
---               its own loop and calls the same four. That is why the
---               application is an object the host drives rather than a
---               function that runs until done, and why nothing in it assumes
---               control will ever come back.
---
---   events      One typed stream, discriminated by `kind`. A platform that
---               is not SDL produces those values directly instead of
---               translating an `SDL_Event`, which is what `events.source`
---               already exists for.
---
---   input       The other direction. Rumble, an LED, a cursor mode and a text
---               input session are commands a game issues, and no event
---               vocabulary can express one. Device enumeration belongs here
---               too, since a pad has to be opened before it reports anything.
---
---   audio       Outbound in the same sense: opening an output, queueing PCM,
---               setting a gain, stopping a voice. Nothing about sound comes
---               back as an event, so it has no other face.
---
---   static FFI  A target that forbids `dlopen` cannot reach a library by
---               name, so function pointers are taken at build time and
---               installed as a table. Nothing calls `ffi.load` when one is
---               present.
---
---   storage     Where content is read from and state is written to. Never the
---               working directory, which on a console does not exist in any
---               useful sense.
---
---   shaders     A pack of compiled shaders plus the reflection SDL_GPU wants,
---               keyed by name. A platform with its own bytecode format
---               declares that format; the pack layout does not change.
---
--- Only storage, the shader format and the device backends need to be *asked
--- for*, which is what this module does. The rest are already substitutable
--- where they live, and installing a platform wires them up.

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local events <const> = require("tecs.platform.events")
local inputbackend <const> = require("tecs.platform.inputbackend")
local audiobackend <const> = require("tecs.platform.audiobackend")

local C <const> = sdl.C

local record adapter
    record Platform
        --- Name this platform reports as. Shown by capabilities and used in
        --- diagnostics; it is not matched against.
        name: string

        --- Directory content is read from, ending in a separator. Empty if the
        --- platform declines to say, in which case callers fall back.
        basePath: function(): string

        --- Directory this application may write to, ending in a separator.
        --- Created if absent. Raising here is correct if there is none: a build
        --- that cannot save should fail where that is discovered.
        prefPath: function(organisation: string, application: string): string

        --- SDL shader format the platform's own bytecode is declared as. A
        --- private format is what a licensed backend uses, since its shader
        --- format has no public name.
        shaderFormat: function(): integer

        --- Delivers one iteration's input as typed events, in arrival order.
        --- Leave nil to keep SDL's queue, which the host already drains.
        events: function(handler: function(events.Event))

        --- Devices and outbound input commands. Leave nil to keep SDL's.
        input: inputbackend.Backend

        --- Sound output. Leave nil to keep SDL's.
        audio: audiobackend.Backend

        --- Whether a library can be loaded by name at run time.
        dynamicLibraries: boolean
    end
end

--- The SDL platform. Every field is what SDL supplies, so this doubles as the
--- worked example of the contract: a port replaces these and nothing else.
local sdlPlatform <const>: adapter.Platform = {
    name = "sdl",

    basePath = function(): string
        local given = C.SDL_GetBasePath()
        return given == nil and "" or loader.toString(given)
    end,

    prefPath = function(organisation: string, application: string): string
        local given = C.SDL_GetPrefPath(organisation, application)
        if given == nil then
            error(("tecs: no writable directory: %s"):format(sdl.error()), 2)
        end
        local path = loader.toString(given)
        C.SDL_free(given)
        return path
    end,

    shaderFormat = function(): integer
        -- Metal takes MSL, every other public backend takes SPIR-V.
        local ffi = require("ffi") as {string: any}
        if ffi.os == "OSX" or ffi.os == "iOS" then
            return sdl.K.SDL_GPU_SHADERFORMAT_MSL
        end
        return sdl.K.SDL_GPU_SHADERFORMAT_SPIRV
    end,

    -- Nil: the C host drains SDL's queue and hands it over, so there is
    -- nothing for a platform hook to do.
    events = nil,

    input = inputbackend.sdl,

    audio = audiobackend.sdl,

    dynamicLibraries = not loader.isStatic("sdl3"),
}

local installed: adapter.Platform = sdlPlatform

--- Bumped whenever the platform changes.
---
--- Modules that cache a platform answer compare this rather than being told,
--- because telling them means this module reaching back into them and a cycle
--- of requires that cannot be typed.
local generation = 0

--- Installs `platform`, replacing whatever was there.
---
--- Call before creating an application: storage roots and the shader format are
--- read during startup and then cached, so a platform installed afterwards
--- would be half in effect.
function adapter.install(platform: adapter.Platform)
    if platform == nil then
        error("tecs: a platform is required", 2)
    end
    for _, required in ipairs({ "basePath", "prefPath", "shaderFormat" }) do
        if (platform as {string: any})[required] == nil then
            error(("tecs: a platform must supply %s"):format(required), 2)
        end
    end
    installed = platform
    generation = generation + 1
    -- The event stream already has one hook for a source that is not SDL's
    -- queue, so a platform uses that rather than introducing a second.
    events.source = platform.events
end

--- The platform in use. The SDL one unless something replaced it.
function adapter.current(): adapter.Platform
    return installed
end

--- Restores the SDL platform. For a test that installed another.
function adapter.reset()
    installed = sdlPlatform
    events.source = nil
    generation = generation + 1
end

--- Which platform installation this is. Changes when the platform does.
function adapter.generation(): integer
    return generation
end

return adapter
