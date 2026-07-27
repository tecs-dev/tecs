-- The platform contract.
--
-- The point of a seam is that something else can sit in it. A contract nobody
-- has ever substituted is a guess about what a port would need, so this
-- installs a platform that is not SDL and drives real work through it: storage
-- resolves to its roots and every file is read and written through its own
-- backend, the device claims its shader format, and its events reach the
-- engine's input state having never been an SDL_Event.
--
-- Storage is the seam with two halves, and the second is why they are tested
-- together here. A platform that answers `/dev/content/` for its base and is
-- then read out of with `SDL_LoadFile` has been asked a question nobody acted
-- on. So the fake platform below answers roots that are not paths on this
-- machine, and the fake backend answers content that is not on this machine
-- either: if a call went back to SDL it finds nothing, and the assertion says
-- so rather than passing on a file that happened to be there.
--
-- This is not a console port and cannot be one: those SDKs are licensed and
-- their headers may not be redistributed. It is the evidence that a port has a
-- handful of things to supply and nothing above them to touch.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local sdl = require("tecs.ffi.sdl3")
local adapter = require("tecs.platform.adapter")
local paths = require("tecs.platform.paths")
local filesystem = require("tecs.platform.filesystem")
local events = require("tecs.platform.events")
local Input = require("tecs.platform.Input")
local capabilities = require("tecs.platform.capabilities")
local shadercompiler = require("tecs.gpu.shadercompiler")
local shaderpack = require("tecs.gpu.shaderpack")
local Audio = require("tecs.Audio")

local C = sdl.C

-- Sound output for a platform that has none of SDL's. Enough of the contract
-- to open something and be asked for a stream, which is as far as anything
-- gets without a clip.
local function fakeAudio()
    local backend = { name = "spec.console.audio", opens = 0 }
    backend.open = function(spec)
        backend.opens = backend.opens + 1
        backend.spec = spec
        return { id = 41 }
    end
    backend.close = function() end
    backend.setMixerGain = function() end
    backend.createTrack = function()
        return {}
    end
    backend.destroyTrack = function() end
    backend.setTrackClip = function()
        return true
    end
    backend.setTrackFile = function()
        return true
    end
    backend.clearTrack = function() end
    backend.play = function()
        return true
    end
    backend.stop = function() end
    backend.pause = function() end
    backend.resume = function() end
    backend.playing = function()
        return false
    end
    backend.setGain = function() end
    backend.setPitch = function() end
    backend.setPosition = function() end
    backend.clearPosition = function() end
    backend.tag = function() end
    backend.untag = function() end
    backend.pauseTag = function() end
    backend.resumeTag = function() end
    backend.stopTag = function() end
    return backend
end

-- Content for a platform whose content is not a filesystem. Nothing it answers
-- exists on this machine, so a call that fell back to SDL answers nil where
-- this answers bytes, and the difference is the assertion.
local function fakeStorage()
    local files = { ["/dev/content/levels/1.json"] = '{"room":"hold"}' }
    local backend = { name = "spec.console.storage", calls = {} }

    local function note(what, path)
        backend.calls[#backend.calls + 1] = what .. " " .. tostring(path)
    end

    backend.read = function(path)
        note("read", path)
        return files[path]
    end
    backend.write = function(path, bytes)
        note("write", path)
        files[path] = bytes
        return true
    end
    backend.info = function(path)
        note("info", path)
        if files[path] == nil then
            return nil, "no such title file"
        end
        return {
            kind = "file",
            size = #files[path],
            createdAt = 0,
            modifiedAt = 2e18,
            accessedAt = 2e18,
        }
    end
    backend.glob = function(path, pattern)
        note("glob " .. tostring(pattern), path)
        return { "levels", "levels/1.json" }
    end
    backend.createDirectory = function(path)
        note("createDirectory", path)
        return true
    end
    backend.remove = function(path)
        note("remove", path)
        files[path] = nil
        return true
    end
    backend.rename = function(from, to)
        note("rename", from .. " " .. to)
        files[to], files[from] = files[from], nil
        return true
    end
    backend.copy = function(from, to)
        note("copy", from .. " " .. to)
        files[to] = files[from]
        return true
    end
    -- currentDirectory and userFolder are left out on purpose: a title has
    -- neither, and the contract says a backend that omits them answers nil
    -- with a reason rather than being made to invent one.
    return backend
end

-- A platform with none of SDL's answers. Deliberately implausible values, so a
-- path that quietly went back to SDL is visible rather than plausible.
local function fakePlatform(queued)
    return {
        name = "spec.console",
        basePath = function()
            return "/dev/content/"
        end,
        prefPath = function(organisation, application)
            return "/dev/save/" .. organisation .. "/" .. application .. "/"
        end,
        -- A licensed backend's bytecode has no public format name, which is
        -- what the private format is for.
        shaderFormat = function()
            return sdl.K.SDL_GPU_SHADERFORMAT_PRIVATE
        end,
        events = queued and function(handler)
            for _, event in ipairs(queued) do
                handler(event)
            end
        end or nil,
        dynamicLibraries = false,
    }
end

describe("platform contract", function()
    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
    end)

    before_each(function()
        adapter.reset()
        paths.reset()
    end)

    teardown(function()
        adapter.reset()
        paths.reset()
        shadercompiler.usePack(nil)
        C.SDL_Quit()
    end)

    it("defaults to SDL, so nothing has to install anything", function()
        assert.are.equal("sdl", adapter.current().name)
        assert.is_not_nil(adapter.current().basePath())
    end)

    it("refuses a platform that is missing part of the contract", function()
        -- Half a platform is worse than none: the missing half silently falls
        -- back to SDL, which on a target without it is a crash somewhere else.
        assert.has_error(function()
            adapter.install(nil)
        end)
        assert.has_error(function()
            adapter.install({
                name = "half",
                basePath = function()
                    return "/"
                end,
            })
        end)
        assert.are.equal("sdl", adapter.current().name, "a rejected platform must not be half installed")
    end)

    it("refuses a storage backend that is missing an operation", function()
        -- A backend is optional and a partial one is not. `filesystem` calls
        -- these without checking, so a missing `copy` would surface as
        -- whichever file the game happened to reach first, on the target where
        -- nobody here can attach a debugger.
        local platform = fakePlatform()
        platform.storage = fakeStorage()
        platform.storage.copy = nil

        assert.has_error(function()
            adapter.install(platform)
        end, "tecs: a storage backend must supply copy")
        assert.are.equal("sdl", adapter.current().name)
    end)

    it("resolves content and state through the installed platform", function()
        adapter.install(fakePlatform())
        paths.reset()

        assert.are.equal("/dev/content/", paths.base())
        assert.are.equal("/dev/save/tecs/tecs/", paths.pref())
        assert.are.equal("/dev/save/tecs/tecs/save.json", paths.writable("save.json"))

        -- A development run has TECS_ASSETS set and it outranks everything,
        -- so content is checked against the platform only where nothing has
        -- overridden it.
        paths.setAssets(paths.base())
        assert.are.equal("/dev/content/art/hero.png", paths.asset("art/hero.png"))
    end)

    it("lets the environment still override the asset root", function()
        -- A development run reads out of a build tree whatever the platform is,
        -- because the platform's answer is where a shipped build put content.
        adapter.install(fakePlatform())
        paths.reset()
        paths.setAssets("/tmp/staging")
        assert.are.equal("/tmp/staging/", paths.assets())
        assert.are.equal(
            "/dev/save/tecs/tecs/",
            paths.pref(),
            "the writable root is the platform's and is not overridable"
        )
    end)

    it("reaches every file through the installed platform's storage", function()
        -- The half of the storage seam that resolving a root does not cover.
        -- Every one of these paths is under a root this platform invented and
        -- exists nowhere on this machine, so an operation that reached SDL
        -- fails and one that reached the backend does not.
        local platform = fakePlatform()
        platform.storage = fakeStorage()
        adapter.install(platform)
        paths.reset()
        -- A development run has TECS_ASSETS set and it outranks the platform,
        -- so content is pointed back at the platform's own base here.
        paths.setAssets(paths.base())

        local level = paths.asset("levels/1.json")
        assert.are.equal("/dev/content/levels/1.json", level)
        assert.are.equal('{"room":"hold"}', filesystem.read(level))

        local save = paths.writable("slot1.json")
        assert.is_true(filesystem.write(save, '{"score":41}'))
        assert.are.equal('{"score":41}', filesystem.read(save))

        assert.are.equal(15, filesystem.info(level).size)
        assert.is_true(filesystem.exists(level))
        assert.is_true(filesystem.isFile(level))
        assert.is_false(filesystem.isDirectory(level))
        assert.is_false(filesystem.exists("/dev/content/absent"))

        assert.are.same({ "levels", "levels/1.json" }, filesystem.list(paths.base()))
        assert.is_true(filesystem.createDirectory("/dev/save/tecs/tecs/shots"))
        assert.is_true(filesystem.copy(level, "/dev/content/levels/2.json"))
        assert.is_true(filesystem.rename("/dev/content/levels/2.json", "/dev/content/levels/3.json"))
        assert.is_true(filesystem.remove("/dev/content/levels/3.json"))

        -- Named, in order, so that an operation quietly answered by something
        -- other than this backend is a shorter list rather than a passing
        -- test. `list` is a glob with the pattern that stops it recursing.
        assert.are.same({
            "read /dev/content/levels/1.json",
            "write /dev/save/tecs/tecs/slot1.json",
            "read /dev/save/tecs/tecs/slot1.json",
            "info /dev/content/levels/1.json",
            "info /dev/content/levels/1.json",
            "info /dev/content/levels/1.json",
            "info /dev/content/levels/1.json",
            "info /dev/content/absent",
            "glob * /dev/content/",
            "createDirectory /dev/save/tecs/tecs/shots",
            "copy /dev/content/levels/1.json /dev/content/levels/2.json",
            "rename /dev/content/levels/2.json /dev/content/levels/3.json",
            "remove /dev/content/levels/3.json",
        }, platform.storage.calls)
    end)

    it("records what the platform opened, so a watcher sees it", function()
        -- The bookkeeping stays above the seam. A port supplies bytes; what
        -- was read and what it was read as is the engine's own record, and is
        -- what `watch` polls.
        local platform = fakePlatform()
        platform.storage = fakeStorage()
        adapter.install(platform)
        paths.reset()
        paths.setAssets(paths.base())

        filesystem.read(paths.asset("levels/1.json"), "level")
        assert.are.equal("level", filesystem.loaded()["/dev/content/levels/1.json"])
        assert.is_nil(filesystem.loaded()["/dev/content/absent"])
        assert.is_nil(filesystem.read("/dev/content/absent"))
        assert.is_nil(filesystem.loaded()["/dev/content/absent"], "a read that found nothing records nothing")
    end)

    it("answers nil for what a platform says it does not have", function()
        -- A title has no working directory and no pictures folder. Both are
        -- optional on a backend and both answer nil with a reason, which is
        -- already what SDL answers for a folder a desktop does not have, so a
        -- caller that handled SDL's nil handles this.
        local platform = fakePlatform()
        platform.storage = fakeStorage()
        adapter.install(platform)

        local cwd, why = filesystem.currentDirectory()
        assert.is_nil(cwd)
        assert.is_true(#why > 0)

        local folder, reason = filesystem.userFolder("pictures")
        assert.is_nil(folder)
        assert.is_true(#reason > 0)

        -- Still a name check and not a passthrough: a typo is the caller's
        -- defect on every platform.
        assert.has_error(function()
            filesystem.userFolder("picturez")
        end, "tecs: filesystem.userFolder does not know 'picturez'")
    end)

    it("keeps SDL's storage for a platform that only answers where", function()
        -- The graduated case, and the common one. A port whose content is a
        -- directory tree supplies two roots and no backend, and reading a file
        -- under those roots works because SDL's is still installed.
        local platform = fakePlatform()
        platform.prefPath = function()
            return os.getenv("TMPDIR") or "/tmp/"
        end
        adapter.install(platform)
        paths.reset()

        assert.are.equal("sdl", adapter.storage().name)
        local save = paths.writable("tecs-adapter-spec.txt")
        assert.is_true(filesystem.write(save, "on the host"))
        assert.are.equal("on the host", filesystem.read(save))
        assert.is_string(filesystem.currentDirectory())
        assert.is_true(filesystem.remove(save))
    end)

    it("takes the platform's shader format for the device to claim", function()
        adapter.install(fakePlatform())
        shadercompiler.usePack(nil)
        assert.are.equal(sdl.K.SDL_GPU_SHADERFORMAT_PRIVATE, shadercompiler.format())
        assert.are.equal("private", shaderpack.formatName(shadercompiler.format()))
    end)

    it("still prefers a loaded pack's format over the platform's", function()
        -- A pack holds one format and is the only thing a build without a
        -- compiler can supply, so it outranks what the platform would pick.
        adapter.install(fakePlatform())
        shadercompiler.usePack({
            version = shaderpack.VERSION,
            target = "spec.console",
            format = sdl.K.SDL_GPU_SHADERFORMAT_SPIRV,
            shaders = {},
        })
        assert.are.equal(sdl.K.SDL_GPU_SHADERFORMAT_SPIRV, shadercompiler.format())
        shadercompiler.usePack(nil)
    end)

    it("delivers the platform's own events into engine input state", function()
        -- The events never were SDL_Events. They go through the same typed
        -- stream and reach the same input tiers, which is what makes a platform
        -- that has no SDL_Event usable at all.
        adapter.install(fakePlatform({
            { kind = "keyDown", key = "space", scancode = 44, repeated = false },
            { kind = "mouseMotion", x = 120, y = 48, dx = 4, dy = 2 },
        }))

        local input = Input.create()
        local seen = {}
        input:beginFrame()
        events.drain(nil, 0, function(event)
            seen[#seen + 1] = event.kind
            input:handleEvent(event)
        end)

        assert.are.same({ "keyDown", "mouseMotion" }, seen)
        assert.is_true(input:keyDown(44), "a platform key press must reach the live tier")
        assert.is_true(input:keyPressed(44), "and the frame tier")
        assert.are.equal(120, input.mouseX)
        assert.are.equal(48, input.mouseY)
    end)

    it("reports the platform through capabilities", function()
        -- Capabilities are read rather than inferred, so a platform that
        -- cannot load a library by name and has its own bytecode format has to
        -- show up as itself and not as the host that happens to be running.
        adapter.install(fakePlatform())
        local caps = capabilities.get()

        assert.are.equal("spec.console", caps.target)
        assert.is_false(caps.dynamicLibraries)
        assert.are.same({ "private" }, caps.shaderFormats)

        adapter.reset()
        assert.are_not.equal("spec.console", capabilities.get().target, "removing the platform must be reflected too")
    end)

    it("plays sound through the platform's own output", function()
        -- Audio is outbound commands and nothing else, so the evidence that it
        -- is a seam is that an output which is not SDL's opens and is asked
        -- for what it is asked for.
        local platform = fakePlatform()
        platform.audio = fakeAudio()
        adapter.install(platform)

        local audio = Audio.create({ frequency = 22050, channels = 1 })
        assert.is_true(audio.available)
        assert.are.equal(1, platform.audio.opens)
        assert.are.equal(22050, platform.audio.spec.frequency)
        assert.are.equal(1, platform.audio.spec.channels)
        audio:destroy()
    end)

    it("returns to SDL when a platform is removed", function()
        adapter.install(fakePlatform({ { kind = "quit" } }))
        adapter.reset()
        paths.reset()

        assert.are.equal("sdl", adapter.current().name)
        assert.is_nil(events.source, "the event hook must be cleared with the platform")
        assert.are_not.equal("/dev/content/", paths.base())
    end)
end)
