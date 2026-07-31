--[=[
What a platform has to supply, and nothing else.

SDL covers every platform this engine can be built for openly. It does not
cover the ones whose SDKs are licensed, and those cannot be added here even
by someone who holds a license: their headers may not be redistributed. So
the engine names its platform seams instead, and a licensed port supplies a
platform through this module without touching anything above it.

There are seven seams, and the reason each is a seam rather than a fork is
that everything else in the engine is already indifferent to the answer:

  lifecycle   SDL owns the loop and calls the application's `_init`,
              `_receive`, `_iterate`, and `_shutdown`. A console SDK owns
              its own loop and calls the same four. That is why the
              application is an object the host drives rather than a
              function that runs until done, and why nothing in it assumes
              control will ever come back.

  events      One typed stream, discriminated by `kind`. A platform that
              is not SDL produces those values directly instead of
              translating an `SDL_Event`, which is what `events.source`
              already exists for.

  input       The other direction. Rumble, an LED, a cursor mode and a text
              input session are commands a game issues, and no event
              vocabulary can express one. Device enumeration belongs here
              too, since a pad has to be opened before it reports anything.

  audio       Outbound in the same sense: opening a mixer, pointing a voice
              at a clip, setting a gain, stopping a voice. The one thing
              that comes back is whether a voice is still sounding, and
              nothing about sound arrives as an event.

  static FFI  A target that forbids `dlopen` cannot reach a library by
              name, so function pointers are taken at build time and
              installed as a table. Nothing calls `ffi.load` when one is
              present.

  storage     Where content is read from, persistent state and disposable
              caches are written to, and how it is reached once it is found.
              Never the working directory,
              which on a console does not exist in any useful sense. Both
              halves are the seam and neither is useful alone: a platform
              that says its content lives at a root it invented is not
              served by the engine then reading that root with the host's
              own file calls, which is why `storage` carries operations
              and not just paths.

  shaders     A pack of compiled shaders plus the reflection SDL_GPU wants,
              keyed by name. A platform with its own bytecode format
              declares that format; the pack layout does not change.

Only storage, the shader format and the device backends need to be *asked
for*, which is what this module does. The rest are already substitutable
where they live, and installing a platform wires them up.
]=]

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local events <const> = require("tecs.platform.events")
local inputbackend <const> = require("tecs.platform.inputbackend")
local audiobackend <const> = require("tecs.platform.audiobackend")
local storagebackend <const> = require("tecs.platform.storagebackend")

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
        prefPath: function(organization: string, application: string): string

        --- Directory this application may use for reconstructable data, ending
        --- in a separator. Created if absent. The operating system may empty
        --- it between any two runs.
        cachePath: function(organization: string, application: string): string

        --- Reaching a file once one of the three roots above has named it.
        --- Leave nil to keep SDL's, which is right for any target where the
        --- roots are directories. A target where they are not supplies this
        --- and `tecs.io.files` works unchanged above it.
        storage: storagebackend.Backend

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

    prefPath = function(organization: string, application: string): string
        local given = C.SDL_GetPrefPath(organization, application)
        if given == nil then
            error(("tecs: no writable directory: %s"):format(sdl.error()), 2)
        end
        local path = loader.toString(given)
        C.SDL_free(given)
        return path
    end,

    cachePath = function(organization: string, application: string): string
        local rust <const> = require("tecs.ffi.rust")
        local result <const> = rust.C.tecsSystemCachePath(organization, #organization, application, #application)
        if result == nil then
            error(("tecs: no system cache directory: %s"):format(loader.toString(rust.C.tecsRustError())), 2)
        end
        local path <const> = loader.toBytes(
            rust.C.tecsBytesData(result), tonumber(rust.C.tecsBytesLength(result)) as integer
        )
        rust.C.tecsBytesDestroy(result)
        return path
    end,

    storage = storagebackend.sdl,

    shaderFormat = function(): integer
        -- Metal takes MSL, every other public backend takes SPIR-V.
        local ffi = require("ffi") as {string: any}
        if ffi.os == "OSX" or ffi.os == "iOS" then
            return sdl.K.SDL_GPU_SHADERFORMAT_MSL
        end
        return sdl.K.SDL_GPU_SHADERFORMAT_SPIRV
    end,

    -- Nil: the Rust host drains SDL's queue and hands it over, so there is
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
    for _, required in ipairs({"basePath", "prefPath", "cachePath", "shaderFormat"}) do
        if (platform as {string: any})[required] == nil then
            error(("tecs: a platform must supply %s"):format(required), 2)
        end
    end
    -- A storage backend is optional, and a partial one is not. `tecs.io.files`
    -- calls these without checking, so a missing operation would surface as
    -- whichever file the game happened to open first rather than here. The two
    -- that are left out are `currentDirectory` and `userFolder`, which have no
    -- answer on a target that is not a desktop and are documented as absent.
    if platform.storage ~= nil then
        for _, operation in ipairs({
            "read",
            "write",
            "append",
            "info",
            "isSymlink",
            "glob",
            "createDirectory",
            "remove",
            "rename",
            "copy",
        }) do
            if (platform.storage as {string: any})[operation] == nil then
                error(("tecs: a storage backend must supply %s"):format(operation), 2)
            end
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

--- How the installed platform reaches a file.
---
--- Resolved per call rather than cached, because `tecs.io.files` is the only
--- caller and every one of its functions is already a syscall wrapped in a
--- table lookup. A platform that left this nil gets SDL's, which is the same
--- fallback `Input` and `Audio` make for their own backends.
function adapter.storage(): storagebackend.Backend
    return installed.storage or storagebackend.sdl
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
