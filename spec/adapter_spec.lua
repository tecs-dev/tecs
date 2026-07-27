-- The platform contract.
--
-- The point of a seam is that something else can sit in it. A contract nobody
-- has ever substituted is a guess about what a port would need, so this
-- installs a platform that is not SDL and drives real work through it: storage
-- resolves to its roots, the device claims its shader format, and its events
-- reach the engine's input state having never been an SDL_Event.
--
-- This is not a console port and cannot be one: those SDKs are licensed and
-- their headers may not be redistributed. It is the evidence that a port has
-- five things to supply and nothing above them to touch.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. package.path

local sdl = require("tecs.ffi.sdl3")
local adapter = require("tecs.platform.adapter")
local paths = require("tecs.platform.paths")
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
    backend.createTrack = function() return {} end
    backend.destroyTrack = function() end
    backend.setTrackClip = function() return true end
    backend.setTrackFile = function() return true end
    backend.clearTrack = function() end
    backend.play = function() return true end
    backend.stop = function() end
    backend.pause = function() end
    backend.resume = function() end
    backend.playing = function() return false end
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

-- A platform with none of SDL's answers. Deliberately implausible values, so a
-- path that quietly went back to SDL is visible rather than plausible.
local function fakePlatform(queued)
    return {
        name = "spec.console",
        basePath = function() return "/dev/content/" end,
        prefPath = function(organisation, application)
            return "/dev/save/" .. organisation .. "/" .. application .. "/"
        end,
        -- A licensed backend's bytecode has no public format name, which is
        -- what the private format is for.
        shaderFormat = function()
            return sdl.K.SDL_GPU_SHADERFORMAT_PRIVATE
        end,
        events = queued and function(handler)
            for _, event in ipairs(queued) do handler(event) end
        end or nil,
        dynamicLibraries = false,
    }
end

describe("platform contract", function()
    setup(function() assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO)) end)

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
        assert.has_error(function() adapter.install(nil) end)
        assert.has_error(function()
            adapter.install({ name = "half", basePath = function() return "/" end })
        end)
        assert.are.equal("sdl", adapter.current().name,
            "a rejected platform must not be half installed")
    end)

    it("resolves content and state through the installed platform", function()
        adapter.install(fakePlatform())
        paths.reset()

        assert.are.equal("/dev/content/", paths.base())
        assert.are.equal("/dev/save/tecs/tecs/", paths.pref())
        assert.are.equal("/dev/save/tecs/tecs/save.json",
            paths.writable("save.json"))

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
        assert.are.equal("/dev/save/tecs/tecs/", paths.pref(),
            "the writable root is the platform's and is not overridable")
    end)

    it("takes the platform's shader format for the device to claim", function()
        adapter.install(fakePlatform())
        shadercompiler.usePack(nil)
        assert.are.equal(sdl.K.SDL_GPU_SHADERFORMAT_PRIVATE,
            shadercompiler.format())
        assert.are.equal("private",
            shaderpack.formatName(shadercompiler.format()))
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
        assert.are.equal(sdl.K.SDL_GPU_SHADERFORMAT_SPIRV,
            shadercompiler.format())
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
        assert.is_true(input:keyDown(44),
            "a platform key press must reach the live tier")
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
        assert.are_not.equal("spec.console", capabilities.get().target,
            "removing the platform must be reflected too")
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
        assert.is_nil(events.source,
            "the event hook must be cleared with the platform")
        assert.are_not.equal("/dev/content/", paths.base())
    end)
end)
