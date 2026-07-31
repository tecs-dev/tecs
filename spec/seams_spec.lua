-- The platform seams stay seams.
--
-- `adapter` claims a licensed port supplies a platform without touching
-- anything above it. That claim is true of the code as it is written today and
-- there is nothing about writing a module that makes it stay true: reaching for
-- an SDL call is the shortest way to do almost anything, it works on every
-- machine a contributor owns, and the target where it does not work is one
-- nobody here can build for. So the claim needs a test, and the test cannot be
-- "does it run", because it runs.
--
-- What is checkable is where the FFI is named. This walks the compiled tree,
-- finds every module that reaches a generated binding, and holds the answer
-- against a declaration below. Two things follow from that:
--
--  * A module that starts calling SDL fails this until someone adds it to the
--    declaration, which means writing down which bucket it is in and why.
--  * A module that stops calling SDL fails it too, because a declaration
--    describing no current FFI use is invalid.
--
-- The compiled tree is read rather than the Teal source because `tl` strips
-- comments, and this module's own prose names half of SDL's file API. A string
-- literal survives, which is correct: `assets` runs its decoder on a worker as
-- a string, and that decoder does reach SDL.
--
-- `tecs/ffi/` is excluded from both scans. Those files are the generated
-- bindings; declaring a prototype is not a use of it.
--
-- What this cannot catch is in `it("...")` below, next to the check it is a
-- limit of.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local files = require("tecs.io.files")

-- The generated bindings. `tecs.ffi.loader` is deliberately not one: it finds
-- and types libraries rather than being one, and the engine's own native code
-- reached through it -- the worker channels, the log sink, the solver pool --
-- ships with the engine on every target and is not a portability question.
local BINDINGS = { "rust", "sdl3", "sdl3mixer", "sdl3ttf", "shaderc", "spvc" }

-- Every SDL entry point that reaches content, and the decoders that take a
-- path instead of a stream. This is the bug class: the storage seam covers
-- where content lives and how a file is reached, so a call from this list
-- outside the storage backend is a path that goes around it.
--
-- The `_IO` forms are absent on purpose. They take a stream rather than a
-- path, and the only way to get a stream from a file is `SDL_IOFromFile`,
-- which is here.
local STORAGE_SYMBOLS = {
    -- Reading and writing a file named by a path.
    "SDL_LoadFile",
    "SDL_LoadFileAsync",
    "SDL_SaveFile",
    "SDL_IOFromFile",
    -- Asking about a path, and changing one.
    "SDL_GetPathInfo",
    "SDL_GlobDirectory",
    "SDL_EnumerateDirectory",
    "SDL_CreateDirectory",
    "SDL_RemovePath",
    "SDL_RenamePath",
    "SDL_CopyFile",
    -- Where content and state live.
    "SDL_GetBasePath",
    "SDL_GetPrefPath",
    "SDL_GetCurrentDirectory",
    "SDL_GetUserFolder",
    -- SDL_Storage, which is what a backend for a target with no filesystem
    -- reaches for. Listed so that adopting it lands in the backend rather than
    -- anywhere else.
    "SDL_OpenTitleStorage",
    "SDL_OpenUserStorage",
    "SDL_OpenFileStorage",
    "SDL_OpenStorage",
    "SDL_CloseStorage",
    "SDL_StorageReady",
    "SDL_GetStorageFileSize",
    "SDL_ReadStorageFile",
    "SDL_WriteStorageFile",
    "SDL_CreateStorageDirectory",
    "SDL_EnumerateStorageDirectory",
    "SDL_RemoveStoragePath",
    "SDL_RenameStoragePath",
    "SDL_CopyStorageFile",
    "SDL_GetStoragePathInfo",
    "SDL_GetStorageSpaceRemaining",
    "SDL_GlobStorageDirectory",
    -- The audio decoder handed a path. Its `_IO` twin reads a stream.
    "MIX_LoadAudio",
}

-- Three buckets, and the whole audit is deciding which one a module is in.
--
--  seam     The module is a seam, or is the SDL implementation of one. A port
--           replaces it and nothing above it changes.
--  direct   SDL is the portability layer here and a port supplies SDL rather
--           than a replacement for this code.
--  bypass   A seam exists and this goes around it. Every entry is a defect
--           with a reason attached, not an exemption.
--
-- The stdio table below adds a fourth, `tool`, for code that runs on a build
-- machine and never on a target, where reaching stdio is the right answer and
-- routing it through a platform would be ceremony.
local REACH = {
    {
        bucket = "seam",
        reason = "Names the seams, and holds SDL's own answers for the two "
            .. "storage roots and the shader format. The worked example a "
            .. "port replaces wholesale.",
        modules = { "tecs/platform/adapter.lua" },
    },
    {
        bucket = "seam",
        reason = "The SDL implementation of one seam each, installed onto the "
            .. "platform record. A port supplies its own and the layer above "
            .. "-- filesystem, Input, Gamepad, Audio -- never sees the "
            .. "difference.",
        modules = {
            "tecs/platform/storagebackend.lua",
            "tecs/platform/inputbackend.lua",
            "tecs/platform/audiobackend.lua",
        },
    },
    {
        bucket = "seam",
        reason = "Translates an SDL_Event into the typed stream. A platform "
            .. "that has no SDL_Event produces those values directly through "
            .. "`events.source`, which is the hook `adapter.install` sets.",
        modules = { "tecs/platform/events.lua" },
    },
    {
        bucket = "direct",
        reason = "SDL_GPU is itself the abstraction, and SDL supports private "
            .. "backends. A licensed port builds one and this code is "
            .. "unchanged; the only thing it has to declare is its bytecode "
            .. "format, which is what `Platform.shaderFormat` is for.",
        modules = {
            "tecs/Backend.lua",
            "tecs/gfx/text.lua",
            "tecs/gfx/particles.lua",
            "tecs/gpu/Buffer.lua",
            "tecs/gpu/ComputePass.lua",
            "tecs/gpu/ComputePipeline.lua",
            "tecs/gpu/Deferred.lua",
            "tecs/gpu/Device.lua",
            "tecs/gpu/Frame.lua",
            "tecs/gpu/GraphicsPipeline.lua",
            "tecs/gpu/RenderPass.lua",
            "tecs/gpu/Sampler.lua",
            "tecs/gpu/Shader.lua",
            "tecs/gpu/Texture.lua",
            "tecs/gpu/TextureArray.lua",
            "tecs/gpu/shadercompiler.lua",
            "tecs/gpu/shaderpack.lua",
        },
    },
    {
        bucket = "direct",
        reason = "Asks SDL what it is running on, or what it can count on. "
            .. "There is nothing here for a platform to answer differently "
            .. "that SDL does not already answer differently.",
        modules = {
            "tecs/gpu/shaderbuild.lua",
            "tecs/platform/time.lua",
            "tecs/log.lua",
        },
    },
    {
        bucket = "direct",
        reason = "Optional operating-system facilities SDL already presents "
            .. "as one portable contract: what this build can do here, the "
            .. "clipboard, child processes, native dialogs, locales, power, "
            .. "standalone sensors and physical audio devices. None is part "
            .. "of the engine lifecycle or required for a game to run.",
        modules = {
            "tecs/platform/audio.lua",
            "tecs/platform/sensors.lua",
            "tecs/platform/os.lua",
        },
    },
    {
        bucket = "direct",
        reason = "The window and the application lifecycle. SDL owns the "
            .. "loop on every target it covers, and a port owns its own loop "
            .. "and calls the same four entry points, which is the lifecycle "
            .. "seam and needs no code here.",
        modules = {
            "tecs/Application.lua",
            "tecs/platform/window.lua",
        },
    },
    {
        bucket = "direct",
        reason = "Rapier, Rust regex, Rust standard networking, and rmcp are "
            .. "pinned Rust services built for every target this engine "
            .. "covers, so there is no platform seam to be on the far side of.",
        modules = {
            "tecs/physics/TaskPool.lua",
            "tecs/physics/World.lua",
            "tecs/io/mcp/transport.lua",
            "tecs/io.lua",
            "tecs/regex.lua",
        },
    },
    {
        bucket = "direct",
        reason = "Decoding, which is a library call over bytes rather than a "
            .. "platform question. Where those bytes come from is the storage "
            .. "seam's business and is declared separately below.",
        modules = {
            "tecs/audio.lua",
            "tecs/assets.lua",
            "tecs/gfx/screenshot.lua",
            "tecs/io/mcp/tools.lua",
        },
    },
    {
        bucket = "bypass",
        reason = "Enumerates the material and shader roots with "
            .. "SDL_GlobDirectory rather than files.glob, so content "
            .. "discovery goes around the storage seam even though the read "
            .. "beside it does not. Owned by the render tree.",
        modules = {
            "tecs/gpu/materials.lua",
            "tecs/gpu/shaders.lua",
        },
    },
}

-- Modules that name one of the storage symbols, and what each is doing with
-- it. Everything here that is outside a seam is a bypass: the seam exists, is
-- reachable, and this went around it.
local STORAGE = {
    ["tecs/platform/storagebackend.lua"] = {
        bucket = "seam",
        symbols = {
            "SDL_LoadFile",
            "SDL_SaveFile",
            "SDL_IOFromFile",
            "SDL_GetPathInfo",
            "SDL_GlobDirectory",
            "SDL_CreateDirectory",
            "SDL_RemovePath",
            "SDL_RenamePath",
            "SDL_CopyFile",
            "SDL_GetCurrentDirectory",
            "SDL_GetUserFolder",
        },
        reason = "The seam's SDL implementation, and the one place these "
            .. "belong. Ten path calls, one each, plus the open a streaming "
            .. "read or write is built on.",
    },
    ["tecs/platform/adapter.lua"] = {
        bucket = "seam",
        symbols = { "SDL_GetBasePath", "SDL_GetPrefPath" },
        reason = "The SDL platform's answer for the two storage roots. A port "
            .. "replaces the platform record these sit in.",
    },
    ["tecs/platform/audiobackend.lua"] = {
        bucket = "seam",
        symbols = { "SDL_IOFromFile" },
        reason = "Opens a file for the mixer to stream a track out of. Inside "
            .. "the audio seam, so a port that has neither this mixer nor "
            .. "this file API replaces the whole backend and takes this call "
            .. "with it.",
    },
    ["tecs/gpu/materials.lua"] = {
        bucket = "bypass",
        symbols = { "SDL_GlobDirectory" },
        reason = "Finds every *.glsl under the material roots. Reads each one "
            .. "through files.read, so only the enumeration is outside "
            .. "the seam. Owned by the render tree.",
    },
    ["tecs/gpu/shaders.lua"] = {
        bucket = "bypass",
        symbols = { "SDL_GlobDirectory" },
        reason = "The same enumeration for shader sources. Owned by the " .. "render tree.",
    },
    ["tecs/assets.lua"] = {
        bucket = "bypass",
        symbols = { "MIX_LoadAudio" },
        reason = "The worker sound decoder is handed a path and opens it "
            .. "itself, so clips are read outside the storage seam.",
    },
}

-- The other way around the seam, and the one that has nothing to do with SDL.
-- `io.open` reaches a file through the C runtime, which on a target whose
-- content is not a filesystem reaches nothing at all, and on Android reaches
-- everything except the package the content is inside.
local STDIO = {
    ["tecs/gpu/shaderpack.lua"] = {
        bucket = "tool",
        reason = "Writes the pack a target without a compiler consumes. Runs "
            .. "from `cargo xtask shaders` on a build machine; the loading half of "
            .. "the same module reads through files.",
    },
    ["tecs/gpu/shaderbuild.lua"] = {
        bucket = "tool",
        reason = "Writes the manifest beside that pack, on the same build " .. "machine and in the same breath.",
    },
    ["tecs/utils/profile.lua"] = {
        bucket = "tool",
        reason = "Dumps a profile where whoever was profiling asked for it. "
            .. "Nothing calls it on a target and a release does not profile.",
    },
    ["tecs/io/mcp/tools.lua"] = {
        bucket = "bypass",
        reason = "The debug server pages the engine's own log file, seeking to "
            .. "the offset the agent left off at and asking how long the file "
            .. "is now. A `Reader` reads forward and closes, so neither "
            .. "question can be put to the seam. Development only.",
    },
    ["tecs/internal/snapshot.lua"] = {
        bucket = "bypass",
        reason = "Writes a world snapshot to a path, which is a save a game "
            .. "may take, so this is the one entry here a shipped build "
            .. "reaches. It cannot simply call filesystem: this is the ECS "
            .. "half, which a tool loads without the engine and therefore "
            .. "without SDL, and requiring the platform would put a graphics "
            .. 'stack behind `require("tecs.ecs")`. Closing it means '
            .. "handing the writer in rather than naming a path.",
    },
}

--- Every compiled module under `tecs/`, as paths relative to `root`.
---
--- Through `files.glob`, which is the seam this file is about: a
--- recursive glob answers every descendant, and the spec that checks nothing
--- goes around the storage backend gets there through it.
local function modules()
    local found = {}
    for _, entry in ipairs(assert(files.glob(root .. "/tecs"))) do
        if entry:sub(-4) == ".lua" and entry:sub(1, 4) ~= "ffi/" then
            found[#found + 1] = "tecs/" .. entry
        end
    end
    table.sort(found)
    return found
end

--- Whether `text` names `symbol` as a whole word.
---
--- Frontier patterns on both sides, so `MIX_LoadAudio` does not match
--- `MIX_LoadAudio_IO` and `SDL_LoadFile` does not match `SDL_LoadFile_IO`.
--- Those take a stream rather than a path and are not what is being looked
--- for.
local function names(text, symbol)
    return text:find("%f[%w_]" .. symbol .. "%f[^%w_]") ~= nil
end

--- Flattens the grouped declaration into module -> { bucket, reason }.
local function declaredReach()
    local flat = {}
    for _, group in ipairs(REACH) do
        for _, name in ipairs(group.modules) do
            assert(flat[name] == nil, name .. " is declared twice")
            flat[name] = { bucket = group.bucket, reason = group.reason }
        end
    end
    return flat
end

describe("the platform seams", function()
    local sources = {}

    setup(function()
        for _, name in ipairs(modules()) do
            sources[name] = assert(files.read(root .. "/" .. name), "cannot read " .. name)
        end
    end)

    it("declares every module that reaches a generated binding", function()
        -- The audit, as a property. A module added to the tree that calls SDL
        -- fails here until someone says which bucket it is in and why, and
        -- writing that sentence is most of the value: two of the three buckets
        -- are fine and the third is a defect, and nobody decides which without
        -- being asked.
        local found = {}
        for name, text in pairs(sources) do
            for _, binding in ipairs(BINDINGS) do
                if text:find('require("tecs.ffi.' .. binding .. '")', 1, true) then
                    found[name] = true
                    break
                end
            end
        end

        local declared = declaredReach()
        local missing, stale = {}, {}
        for name in pairs(found) do
            if declared[name] == nil then
                missing[#missing + 1] = name
            end
        end
        for name in pairs(declared) do
            if not found[name] then
                stale[#stale + 1] = name
            end
        end
        table.sort(missing)
        table.sort(stale)

        assert.are.same({}, missing, "these reach a binding and are not declared in REACH")
        assert.are.same({}, stale, "these are declared in REACH and reach nothing")
    end)

    it("keeps reading and writing a file inside the storage backend", function()
        -- The bug class, checked by name rather than by module. The storage
        -- seam covers where content lives and how a file there is reached, so
        -- one of these symbols outside `storagebackend` is a path around it,
        -- whatever the module is called and whoever added it.
        local found = {}
        for name, text in pairs(sources) do
            local hits = {}
            for _, symbol in ipairs(STORAGE_SYMBOLS) do
                if names(text, symbol) then
                    hits[#hits + 1] = symbol
                end
            end
            if #hits > 0 then
                table.sort(hits)
                found[name] = table.concat(hits, " ")
            end
        end

        local declared = {}
        for name, entry in pairs(STORAGE) do
            local sorted = { table.unpack(entry.symbols) }
            table.sort(sorted)
            declared[name] = table.concat(sorted, " ")
        end

        assert.are.same(declared, found, "the storage symbols named outside the backend have moved")
    end)

    it("holds filesystem itself to the seam it is the front of", function()
        -- The property closing this bypass bought, stated on its own so that
        -- putting an SDL call back into the module fails with the reason
        -- rather than as one line of a table diff.
        local text = sources["tecs/io/files/init.lua"]
        assert.is_string(text, "the module is under tecs.io")
        for _, binding in ipairs(BINDINGS) do
            assert.is_nil(
                text:find('require("tecs.ffi.' .. binding .. '")', 1, true),
                "filesystem must reach the platform only through adapter.storage"
            )
        end
        for _, symbol in ipairs(STORAGE_SYMBOLS) do
            assert.is_false(names(text, symbol), "filesystem must not name " .. symbol)
        end
    end)

    it("declares every module that reaches a file through stdio", function()
        -- Watched separately from the SDL symbols because it is a different
        -- reflex with the same effect: someone needs to write a file, writes
        -- `io.open`, and it works everywhere they can test it. A seam that
        -- only guarded the SDL side would be one `io.open` away from being
        -- decorative.
        local found = {}
        for name, text in pairs(sources) do
            if names(text, "io%.open") then
                found[name] = true
            end
        end

        local missing, stale = {}, {}
        for name in pairs(found) do
            if STDIO[name] == nil then
                missing[#missing + 1] = name
            end
        end
        for name in pairs(STDIO) do
            if not found[name] then
                stale[#stale + 1] = name
            end
        end
        table.sort(missing)
        table.sort(stale)

        assert.are.same({}, missing, "these open a file through stdio and are not declared in STDIO")
        assert.are.same({}, stale, "these are declared in STDIO and open nothing")
    end)

    it("makes every declaration carry a bucket and a reason", function()
        -- The declaration is only worth having if it says something. A bucket
        -- nobody chose and an empty reason would turn this file into the list
        -- of modules it is meant not to be.
        local buckets = { seam = true, direct = true, bypass = true, tool = true }
        for _, group in ipairs(REACH) do
            assert.is_true(buckets[group.bucket] == true, "unknown bucket " .. tostring(group.bucket))
            assert.is_true(#group.reason > 40, "a reason has to be one: " .. group.reason)
            assert.is_true(#group.modules > 0, "a group with no modules in it")
        end
        for name, entry in pairs(STORAGE) do
            assert.is_true(buckets[entry.bucket] == true, name .. " has an unknown bucket")
            assert.is_true(#entry.reason > 40, name .. " needs a reason")
            assert.is_true(#entry.symbols > 0, name .. " declares no symbols")
        end
        for name, entry in pairs(STDIO) do
            assert.is_true(buckets[entry.bucket] == true, name .. " has an unknown bucket")
            assert.is_true(#entry.reason > 40, name .. " needs a reason")
        end
    end)

    it("cannot see through a name it does not know", function()
        -- Said out loud, because a guard whose limits are not written down is
        -- read as covering more than it does.
        --
        -- This checks names in compiled Lua. It does not catch a call reached
        -- by a name built at run time -- `C["SDL_" .. verb]` -- it does not
        -- catch `os.execute`, and it does not catch a C library some future
        -- module cdefs for itself, none of which are SDL and all of which
        -- would go around the seam just as thoroughly. It says nothing about
        -- whether a module that is behind the seam uses it correctly; that is
        -- what `adapter_spec` drives a fake platform through it for. And a
        -- declared bypass keeps passing forever, which is the price of a tree
        -- that has some.
        --
        -- What it does catch is the way this actually happens: someone needs
        -- to read a file, writes the call that reads a file, and it works on
        -- every machine anyone here owns.
        -- Two modules do build a name, and both read an enum value rather
        -- than call a function: a button or an axis whose number this SDL may
        -- not have, answered as nil instead of as the wrong button. Held to
        -- exactly those two, so a third has to argue for itself.
        local computed = {}
        for name, text in pairs(sources) do
            if text:find("C%[") ~= nil then
                computed[#computed + 1] = name
            end
        end
        table.sort(computed)
        assert.are.same({
            "tecs/platform/events.lua",
            "tecs/platform/inputbackend.lua",
        }, computed, "an SDL name built at run time is invisible to the checks above")
    end)
end)
