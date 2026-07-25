require("busted")

local luassert <const> = require("luassert")
local workers <const> = require("tecs2d.workers")

-- Mock love.audio before loading tecs2d.audio
local record MockSource
    _volume: number
    _pitch: number
    _looping: boolean
    _playing: boolean
    _paused: boolean
    _relative: boolean
    _x: number
    _y: number
    _z: number
    _refDistance: number
    _maxDistance: number
    _effects: {string: boolean}

    setVolume: function(self, v: number)
    getVolume: function(self): number
    setPitch: function(self, p: number)
    getPitch: function(self): number
    setLooping: function(self, l: boolean)
    isLooping: function(self): boolean
    play: function(self)
    stop: function(self)
    pause: function(self)
    isPlaying: function(self): boolean
    setRelative: function(self, r: boolean)
    setPosition: function(self, x: number, y: number, z: number)
    setAttenuationDistances: function(self, ref: number, max: number)
    setEffect: function(self, name: string, enabled: boolean): boolean
    clone: function(self): MockSource
end

local MockSource_mt: metatable<MockSource>
MockSource_mt = {
    __index = {
        setVolume = function(self: MockSource, v: number)
            self._volume = v
        end,
        getVolume = function(self: MockSource): number
            return self._volume
        end,
        setPitch = function(self: MockSource, p: number)
            self._pitch = p
        end,
        getPitch = function(self: MockSource): number
            return self._pitch
        end,
        setLooping = function(self: MockSource, l: boolean)
            self._looping = l
        end,
        isLooping = function(self: MockSource): boolean
            return self._looping
        end,
        play = function(self: MockSource)
            self._playing = true
            self._paused = false
        end,
        stop = function(self: MockSource)
            self._playing = false
            self._paused = false
        end,
        pause = function(self: MockSource)
            self._playing = false
            self._paused = true
        end,
        isPlaying = function(self: MockSource): boolean
            return self._playing
        end,
        setRelative = function(self: MockSource, r: boolean)
            self._relative = r
        end,
        setPosition = function(self: MockSource, x: number, y: number, z: number)
            self._x, self._y, self._z = x, y, z
        end,
        setAttenuationDistances = function(self: MockSource, ref: number, max: number)
            self._refDistance, self._maxDistance = ref, max
        end,
        setEffect = function(self: MockSource, name: string, enabled: boolean): boolean
            if not self._effects then
                self._effects = {}
            end
            self._effects[name] = enabled
            return true
        end,
        clone = function(self: MockSource): MockSource
            local cloned: MockSource = setmetatable({
                _volume = self._volume,
                _pitch = self._pitch,
                _looping = self._looping,
                _playing = false,
                _paused = false,
                _relative = self._relative,
                _x = self._x,
                _y = self._y,
                _z = self._z,
                _refDistance = self._refDistance,
                _maxDistance = self._maxDistance,
                _effects = {}
            }, MockSource_mt)
            return cloned
        end
    }
}

local function createMockSource(): MockSource
    return setmetatable({
        _volume = 1.0,
        _pitch = 1.0,
        _looping = false,
        _playing = false,
        _paused = false,
        _relative = false,
        _x = 0,
        _y = 0,
        _z = 0,
        _refDistance = 1,
        _maxDistance = 1000,
        _effects = {}
    }, MockSource_mt)
end

-- Mock the worker handle consumed by the audio manager.
local function createMockHandle(source: MockSource): workers.Handle<love.audio.Source>
    -- We need to cast through a table to satisfy Teal's strict interface checking
    local handle = {
        isComplete = true,
        value = source as love.audio.Source,
        err = nil,
        observe = function() end,
        map = function(): workers.Handle<love.audio.Source>
            return nil
        end,
        flatMap = function(): workers.Handle<love.audio.Source>
            return nil
        end,
        handle = function(): workers.Handle<love.audio.Source>
            return nil
        end
    }
    return handle as workers.Handle<love.audio.Source>
end

-- Set up love mock
local listenerX: number = 0
local listenerY: number = 0
local listenerZ: number = 0
local acceptEffects = true

local record AudioMock
    setPosition: function(x: number, y: number, z: number)
    setEffect: function(name: string, settings: {string:any} | boolean): boolean
end

local record LoveMock
    audio: AudioMock
end

local mockAudio: AudioMock = {
    setPosition = function(x: number, y: number, z: number)
        listenerX, listenerY, listenerZ = x, y, z
    end,
    setEffect = function(_name: string, _settings: {string:any} | boolean): boolean
        return acceptEffects
    end,
}

local globalEnv = _G as {string: LoveMock}
globalEnv["love"] = {
    audio = mockAudio
}

-- Now load the manager
local manager <const> = require("tecs2d.audio.internal.manager")

describe("tecs2d.audio", function()

    describe("AudioManager", function()

        describe("Sound Groups", function()

            it("should have default groups", function()
                local audio = manager.new()
                luassert.equals(1.0, audio:getGroupVolume("master"))
                luassert.equals(0.8, audio:getGroupVolume("music"))
                luassert.equals(1.0, audio:getGroupVolume("sfx"))
                luassert.equals(1.0, audio:getGroupVolume("ui"))
            end)

            it("should set group volume", function()
                local audio = manager.new()
                audio:setGroupVolume("sfx", 0.5)
                luassert.equals(0.5, audio:getGroupVolume("sfx"))
            end)

            it("should clamp group volume between 0 and 1", function()
                local audio = manager.new()
                audio:setGroupVolume("sfx", 1.5)
                luassert.equals(1.0, audio:getGroupVolume("sfx"))

                audio:setGroupVolume("sfx", -0.5)
                luassert.equals(0.0, audio:getGroupVolume("sfx"))
            end)

            it("should create new groups on demand", function()
                local audio = manager.new()
                audio:setGroupVolume("custom", 0.6)
                luassert.equals(0.6, audio:getGroupVolume("custom"))
            end)

            it("should mute and unmute groups", function()
                local audio = manager.new()
                luassert.is_false(audio:isGroupMuted("sfx"))

                audio:muteGroup("sfx", true)
                luassert.is_true(audio:isGroupMuted("sfx"))

                audio:muteGroup("sfx", false)
                luassert.is_false(audio:isGroupMuted("sfx"))
            end)

            it("should mute all sounds when master is muted", function()
                local audio = manager.new()
                audio:muteGroup("master", true)

                local source = createMockSource()
                local handle = createMockHandle(source)

                local played = audio:play(handle, { group = "sfx", volume = 1.0 })
                luassert.is_not_nil(played)
                luassert.equals(0, (played as MockSource):getVolume())
            end)

        end)

        describe("Voice Limiting", function()

            it("should limit concurrent voices", function()
                local audio = manager.new()
                audio:setVoiceLimit("explosion", 2)

                local source = createMockSource()
                local handle = createMockHandle(source)

                -- First two should play
                local s1 = audio:play(handle, { key = "explosion" })
                local s2 = audio:play(handle, { key = "explosion" })
                luassert.is_not_nil(s1)
                luassert.is_not_nil(s2)

                -- Third should be blocked
                local s3 = audio:play(handle, { key = "explosion" })
                luassert.is_nil(s3)
            end)

            it("should allow more voices after cleanup", function()
                local audio = manager.new()
                audio:setVoiceLimit("punch", 1)

                local source = createMockSource()
                local handle = createMockHandle(source)

                local s1 = audio:play(handle, { key = "punch" })
                luassert.is_not_nil(s1)

                -- Second blocked
                local s2 = audio:play(handle, { key = "punch" })
                luassert.is_nil(s2)

                -- Stop the first source
                (s1 as MockSource):stop()

                -- Update to cleanup
                audio:update(0.1)

                -- Now another should be allowed
                local s3 = audio:play(handle, { key = "punch" })
                luassert.is_not_nil(s3)
            end)

        end)

        describe("Cooldowns", function()

            it("should block sounds during cooldown", function()
                local audio = manager.new()
                audio:setCooldown("footstep", 0.1)

                local source = createMockSource()
                local handle = createMockHandle(source) 

                -- First should play
                local s1 = audio:play(handle, { key = "footstep" })
                luassert.is_not_nil(s1)
                luassert.is_true(audio:isOnCooldown("footstep"))

                -- Second blocked by cooldown
                local s2 = audio:play(handle, { key = "footstep" })
                luassert.is_nil(s2)
            end)

            it("should allow sounds after cooldown expires", function()
                local audio = manager.new()
                audio:setCooldown("step", 0.05)

                local source = createMockSource()
                local handle = createMockHandle(source) 

                local s1 = audio:play(handle, { key = "step" })
                luassert.is_not_nil(s1)

                -- Update past cooldown
                audio:update(0.06)

                luassert.is_false(audio:isOnCooldown("step"))

                local s2 = audio:play(handle, { key = "step" })
                luassert.is_not_nil(s2)
            end)

        end)

        describe("Play API", function()

            it("should play 2D sounds", function()
                local audio = manager.new()
                local source = createMockSource()
                local handle = createMockHandle(source) 

                local played = audio:play(handle, { group = "ui", volume = 0.8 })
                luassert.is_not_nil(played)
                luassert.is_true((played as MockSource)._relative)
                luassert.is_true((played as MockSource):isPlaying())
            end)

            it("should play 3D positional sounds", function()
                local audio = manager.new()
                local source = createMockSource()
                local handle = createMockHandle(source) 

                local played = audio:playAt(handle, 100, 200, 50, { group = "sfx" })
                luassert.is_not_nil(played)
                luassert.is_false((played as MockSource)._relative)
                luassert.equals(100, (played as MockSource)._x)
                luassert.equals(200, (played as MockSource)._y)
                luassert.equals(50, (played as MockSource)._z)
            end)

            it("should apply group volume", function()
                local audio = manager.new()
                audio:setGroupVolume("sfx", 0.5)

                local source = createMockSource()
                local handle = createMockHandle(source) 

                local played = audio:play(handle, { group = "sfx", volume = 1.0 })
                -- Volume should be 1.0 * 0.5 (group) * 1.0 (master) = 0.5
                luassert.equals(0.5, (played as MockSource):getVolume())
            end)

            it("should apply master volume", function()
                local audio = manager.new()
                audio:setGroupVolume("master", 0.5)

                local source = createMockSource()
                local handle = createMockHandle(source) 

                local played = audio:play(handle, { group = "sfx", volume = 1.0 })
                -- Volume should be 1.0 * 1.0 (sfx) * 0.5 (master) = 0.5
                luassert.equals(0.5, (played as MockSource):getVolume())
            end)

            it("should return nil for muted group", function()
                local audio = manager.new()
                audio:muteGroup("sfx", true)

                local source = createMockSource()
                local handle = createMockHandle(source) 

                local played = audio:play(handle, { group = "sfx" })
                -- Still plays but with 0 volume
                luassert.is_not_nil(played)
                luassert.equals(0, (played as MockSource):getVolume())
            end)

            it("should apply pitch", function()
                local audio = manager.new()
                local source = createMockSource()
                local handle = createMockHandle(source) 

                local played = audio:play(handle, { pitch = 1.5 })
                luassert.equals(1.5, (played as MockSource):getPitch())
            end)

        end)

        describe("Effects", function()

            it("does not retain an effect definition rejected by Love", function()
                local audio = manager.new()
                acceptEffects = false
                audio:setGroupEffect("sfx", "reverb", {})

                local source = createMockSource()
                local played = audio:play(createMockHandle(source), { group = "sfx" })
                acceptEffects = true

                luassert.is_nil((played as MockSource)._effects["sfx_reverb"])
            end)

        end)

        describe("Stop API", function()

            it("should stop all sounds in a group", function()
                local audio = manager.new()
                local source = createMockSource()
                local handle = createMockHandle(source) 

                local s1 = audio:play(handle, { group = "sfx" })
                local s2 = audio:play(handle, { group = "sfx" })
                local s3 = audio:play(handle, { group = "music" })

                luassert.is_true((s1 as MockSource):isPlaying())
                luassert.is_true((s2 as MockSource):isPlaying())
                luassert.is_true((s3 as MockSource):isPlaying())

                audio:stopGroup("sfx")

                luassert.is_false((s1 as MockSource):isPlaying())
                luassert.is_false((s2 as MockSource):isPlaying())
                luassert.is_true((s3 as MockSource):isPlaying())  -- music still playing
            end)

            it("should stop all sounds", function()
                local audio = manager.new()
                local source = createMockSource()
                local handle = createMockHandle(source) 

                local s1 = audio:play(handle, { group = "sfx" })
                local s2 = audio:play(handle, { group = "music" })

                audio:stopAll()

                luassert.is_false((s1 as MockSource):isPlaying())
                luassert.is_false((s2 as MockSource):isPlaying())
            end)

        end)

        describe("Listener", function()

            it("should set listener position", function()
                local audio = manager.new()
                audio:setListenerPosition(10, 20, 30)

                -- Check the mock was called
                luassert.equals(10, listenerX)
                luassert.equals(20, listenerY)
                luassert.equals(30, listenerZ)
            end)

        end)

        describe("Snapshot", function()

            it("round-trips group volumes, mutes, pauses, and listener", function()
                local src = manager.new()
                src:setGroupVolume("music", 0.25)
                src:setGroupVolume("custom", 0.6)
                src:muteGroup("sfx", true)
                src:pauseGroup("ui")
                src:setListenerPosition(5, 6, 7)

                local data = src:serializeMixer()

                local dst = manager.new()
                dst:restoreMixer(data)

                luassert.equals(0.25, dst:getGroupVolume("music"))
                luassert.equals(0.6, dst:getGroupVolume("custom"))
                luassert.is_true(dst:isGroupMuted("sfx"))
                luassert.is_true(dst:isGroupPaused("ui"))
                luassert.equals(5, listenerX)
                luassert.equals(6, listenerY)
                luassert.equals(7, listenerZ)
            end)

            it("re-applies restored group volume to already-registered sources", function()
                -- Emulate the load ordering: an AudioSource-backed source is
                -- registered against default group volumes BEFORE the mixer
                -- state is restored. restoreMixer must re-level it.
                local dst = manager.new()
                local source = createMockSource()
                dst:registerComponentSource(
                    source as love.audio.Source, "sfx", 1.0)
                luassert.equals(1.0, (source as MockSource):getVolume())

                local src = manager.new()
                src:setGroupVolume("sfx", 0.5)
                dst:restoreMixer(src:serializeMixer())

                luassert.equals(0.5, (source as MockSource):getVolume())
            end)

            it("tolerates nil data", function()
                local audio = manager.new()
                audio:restoreMixer(nil)
                luassert.equals(1.0, audio:getGroupVolume("master"))
            end)

        end)

        describe("Pause/Resume", function()

            it("should pause and resume a group", function()
                local audio = manager.new()
                local source = createMockSource()
                local handle = createMockHandle(source)

                local played = audio:play(handle, { group = "sfx" })
                luassert.is_true((played as MockSource):isPlaying())

                audio:pauseGroup("sfx")
                luassert.is_true(audio:isGroupPaused("sfx"))
                luassert.is_false((played as MockSource):isPlaying())
                luassert.is_true((played as MockSource)._paused)

                audio:resumeGroup("sfx")
                luassert.is_false(audio:isGroupPaused("sfx"))
                luassert.is_true((played as MockSource):isPlaying())
            end)

            it("should pause and resume individual source", function()
                local audio = manager.new()
                local source = createMockSource()
                local handle = createMockHandle(source)

                local played = audio:play(handle, { group = "sfx" })
                luassert.is_true((played as MockSource):isPlaying())

                audio:pause(played)
                luassert.is_false((played as MockSource):isPlaying())

                audio:resume(played)
                luassert.is_true((played as MockSource):isPlaying())
            end)

        end)

        describe("Component Sources", function()

            it("should register and apply volume to component sources", function()
                local audio = manager.new()
                audio:setGroupVolume("sfx", 0.5)

                local source = createMockSource()
                audio:registerComponentSource(source as love.audio.Source, "sfx", 1.0)

                -- Volume should be 1.0 * 0.5 (group) * 1.0 (master) = 0.5
                luassert.equals(0.5, source:getVolume())
            end)

            it("should track component source fading state", function()
                local audio = manager.new()
                local source = createMockSource()

                audio:registerComponentSource(source as love.audio.Source, "sfx", 1.0)
                luassert.is_false(audio:isComponentSourceFading(source as love.audio.Source))
            end)

            it("should check if component source should play", function()
                local audio = manager.new()
                local source = createMockSource()

                audio:registerComponentSource(source as love.audio.Source, "sfx", 1.0)
                luassert.is_true(audio:shouldComponentSourcePlay(source as love.audio.Source))

                audio:pauseGroup("sfx")
                luassert.is_false(audio:shouldComponentSourcePlay(source as love.audio.Source))
            end)

        end)

    end)

end)
