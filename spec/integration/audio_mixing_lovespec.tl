--- Love2D integration suite: audio mixer semantics. Drives the audio
--- manager and AudioSource components in a real app via run_lua and
--- asserts on live source state (volume, pitch, play state). Sources
--- come from generated silent SoundData wrapped in fake asset handles,
--- so no audio files are involved.
---
--- Run via `make test-love FILE_MATCH='audio_mixing'`.

require("busted")
local luassert <const> = require("luassert")
local socket <const> = require("socket")
local fixture <const> = require("spec.integration.harness.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/compliance"

local sleep <const> = socket.sleep as function(number)

local function run(app: fixture.App, code: string): {string}
    return fixture.runLua(app, code)
end

describe("audio mixing: groups, fades, and component sources", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        run(app, [[
            local audio = require("tecs2d.audio")
            _G.mgr = world.resources[audio]
            _G.audioMod = audio
            math.randomseed(42)

            -- Fake asset handles around generated silent sources.
            local function fakeHandle(seconds)
                local samples = math.floor(22050 * seconds)
                local data = love.sound.newSoundData(samples, 22050, 16, 1)
                local source = love.audio.newSource(data, "static")
                return {isComplete = true, err = nil, value = source}
            end
            _G.longHandle = fakeHandle(2.0)
            _G.shortHandle = fakeHandle(0.1)
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("muteGroup('master') silences sources in other groups", function()
        local values = run(app, [[
            local src = _G.mgr:play(_G.longHandle, {group = "sfx", loop = true})
            _G.mgr:muteGroup("master", true)
            local volume = src:getVolume()
            _G.mgr:stop(src)
            _G.mgr:muteGroup("master", false)
            return volume
        ]])
        luassert.are.equal(0, tonumber(values[1]),
            "sfx source still audible while master is muted")
    end)

    it("muting a group silences a source mid fade-in and keeps it silent", function()
        run(app, [[
            _G.fadeSrc = _G.mgr:play(_G.longHandle, {group = "sfx", loop = true, fadeIn = 2.0})
            _G.mgr:muteGroup("sfx", true)
            return true
        ]])
        sleep(0.4)  -- let several update() ticks lerp the fade
        local values = run(app, [[
            local volume = _G.fadeSrc:getVolume()
            _G.mgr:stop(_G.fadeSrc)
            _G.mgr:muteGroup("sfx", false)
            return volume
        ]])
        luassert.are.equal(0, tonumber(values[1]),
            "fade kept raising the volume of a muted source")
    end)

    it("setGroupVolume during a fading pause still pauses the group", function()
        run(app, [[
            _G.pauseSrc = _G.mgr:play(_G.longHandle, {group = "music", loop = true})
            _G.mgr:pauseGroup("music", 0.3)
            _G.mgr:setGroupVolume("music", 0.8)
            return true
        ]])
        sleep(0.8)
        local values = run(app, [[
            local playing = _G.pauseSrc:isPlaying()
            _G.mgr:resumeGroup("music")
            _G.mgr:stop(_G.pauseSrc)
            _G.mgr:setGroupVolume("music", 1.0)
            return playing
        ]])
        luassert.are.equal("false", values[1],
            "group volume change retargeted the pause fade; source never paused")
    end)

    it("playing into a paused group starts paused until resume", function()
        run(app, "_G.mgr:pauseGroup('ambience') return true")
        local values = run(app, [[
            _G.pausedPlay = _G.mgr:play(_G.longHandle, {group = "ambience", loop = true})
            return _G.pausedPlay:isPlaying()
        ]])
        luassert.are.equal("false", values[1], "source played into a paused group")

        local resumed = run(app, [[
            _G.mgr:resumeGroup("ambience")
            local playing = _G.pausedPlay:isPlaying()
            _G.mgr:stop(_G.pausedPlay)
            return playing
        ]])
        luassert.are.equal("true", resumed[1], "source did not resume with its group")
    end)

    it("keeps pitch variance for the whole playback", function()
        run(app, [[
            local audio = _G.audioMod
            _G.pitchEntity = world:spawn(audio.AudioSource.new({
                handle = _G.longHandle,
                relative = true,
                looping = true,
                playing = true,
                pitch = 1.0,
                pitchVariance = 0.4,
            }))
            return true
        ]])
        sleep(0.4)  -- several frames past playback start
        local values = run(app, [[
            local audio = _G.audioMod
            local comp = world:get(_G.pitchEntity, audio.AudioSource)
            return comp._source and comp._source:getPitch() or -1
        ]])
        local pitch = tonumber(values[1])
        luassert.is_true(pitch > 0, "component source never initialized")
        luassert.is_true(math.abs(pitch - 1.0) > 0.01,
            "pitch variance was reset to base pitch after playback started (pitch = "
            .. tostring(pitch) .. ")")
        run(app, "world:despawn(_G.pitchEntity) return true")
    end)

    it("does not retrigger finished one-shot component sources", function()
        run(app, [[
            local audio = _G.audioMod
            _G.oneShot = world:spawn(audio.AudioSource.new({
                handle = _G.shortHandle,
                relative = true,
                looping = false,
                playing = true,
            }))
            return true
        ]])
        -- The clip is 0.1s; after this it must have ended for good.
        sleep(0.6)
        local values = run(app, [[
            local audio = _G.audioMod
            local comp = world:get(_G.oneShot, audio.AudioSource)
            return tostring(comp.playing), tostring(comp._source and comp._source:isPlaying())
        ]])
        luassert.are.equal("false", values[1],
            "one-shot AudioSource.playing never cleared after the clip ended")
        luassert.are.equal("false", values[2],
            "one-shot source retriggered after finishing")
        run(app, "world:despawn(_G.oneShot) return true")
    end)
end)
