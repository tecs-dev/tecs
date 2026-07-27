-- Sound output: clips, voices, gain, and the component that attaches one to
-- an entity.
--
-- Playback is driven through a substituted backend rather than through a
-- sound card. No continuous-integration machine has one, and a machine that
-- does cannot assert what came out of it: there is no readback for audio the
-- way there is for a framebuffer. So what these tests assert is what was
-- asked of the platform. That a play queued exactly the bytes the clip holds,
-- that a gain reached the stream, that stopping unbound it, that a one-shot
-- whose queue drained gave its voice back, and that a looping one keeps being
-- topped up past the end of its clip.
--
-- Loading is the one half driven for real: the fixture is read and converted
-- by the asset worker, on a thread, which is what the "loading" status
-- immediately after the call proves.
--
-- What that leaves untested, rather than asserted: whether anything is
-- audible, whether SDL's mixer sums two bound streams the way its
-- documentation says, whether the logical device really follows the system
-- default when headphones are plugged in, and what the hardware does with a
-- gain above one. Those need a device and a pair of ears, and the tests here
-- prove the layer above them instead.

-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. package.path

local tecs = require("tecs")
local Audio = require("tecs.Audio")
local assets = require("tecs.assets")

-- A tenth of a second of 16-bit mono at 48000 Hz, which converts to exactly
-- 38400 bytes of 32-bit float stereo. Whole numbers, so a byte count that is
-- off by a resample is off by a lot rather than by rounding.
local FIXTURE = "spec/fixtures/blip.wav"
local CLIP_BYTES = 38400
-- The default lead, 0.25 seconds at 48000 Hz stereo float.
local LEAD_BYTES = 96000

-- A backend that records what it was asked to do and reports back whatever a
-- test tells it to. Nothing here reaches SDL, so it runs anywhere.
local function recorder(options)
    options = options or {}
    local backend = {
        name = "spec.audio",
        streams = {},
        opens = 0,
        closes = 0,
    }

    function backend.openDevice(spec)
        backend.opens = backend.opens + 1
        backend.spec = spec
        if options.silent then return 0 end
        return 7
    end

    function backend.closeDevice(device)
        backend.closes = backend.closes + 1
        backend.device = device
    end

    function backend.createStream()
        local stream = {
            index = #backend.streams + 1,
            bound = false,
            binds = 0,
            unbinds = 0,
            clears = 0,
            gains = {},
            queued = 0,
            pending = 0,
            puts = {},
            destroyed = false,
        }
        backend.streams[stream.index] = stream
        return stream
    end

    function backend.destroyStream(stream) stream.destroyed = true end

    function backend.bindStream(device, stream)
        backend.boundTo = device
        stream.bound = true
        stream.binds = stream.binds + 1
        return true
    end

    function backend.unbindStream(stream)
        stream.bound = false
        stream.unbinds = stream.unbinds + 1
    end

    function backend.putData(stream, _data, bytes)
        stream.puts[#stream.puts + 1] = bytes
        stream.queued = stream.queued + bytes
        -- Nothing consumes it until a test says so, which is what makes the
        -- device's progress something a test drives rather than waits for.
        stream.pending = stream.pending + bytes
        return true
    end

    function backend.pendingBytes(stream) return stream.pending end

    function backend.clearStream(stream)
        stream.clears = stream.clears + 1
        stream.pending = 0
    end

    function backend.setStreamGain(stream, gain)
        stream.gain = gain
        stream.gains[#stream.gains + 1] = gain
        return true
    end

    return backend
end

--- Whether `wanted` appears anywhere inside a nest of tables. A snapshot's
--- shape is the snapshot code's business; what matters here is which of two
--- values, a path or an index, ended up in it.
local function holds(value, wanted)
    if value == wanted then return true end
    if type(value) ~= "table" then return false end
    for _, item in pairs(value) do
        if holds(item, wanted) then return true end
    end
    return false
end

--- An audio object on a recording backend, with its fixture already loaded.
local function loaded(config)
    config = config or {}
    config.backend = config.backend or recorder()
    local audio = Audio.create(config)
    local clip = audio:load(FIXTURE)
    audio:waitForLoads()
    return audio, clip, config.backend
end

describe("audio", function()
    teardown(function()
        assets.shutdown()
    end)

    describe("clips", function()
        it("returns a clip immediately and resolves it later", function()
            local audio = Audio.create({ backend = recorder() })
            local clip = audio:load(FIXTURE)

            assert.are.equal("loading", clip.status,
                "loading must not block the caller")
            assert.are.equal(1, audio:loading())

            audio:waitForLoads()
            assert.are.equal("ready", clip.status)
            assert.are.equal(0, audio:loading())
            audio:destroy()
        end)

        it("converts to the output format while it is off the thread",
            function()
            -- The fixture is mono at 48000; the output is stereo. A duration
            -- of a tenth of a second means the conversion landed, since the
            -- byte count doubled and the frame count did not.
            local audio, clip = loaded()
            assert.is_true(math.abs(clip.duration - 0.1) < 1e-6,
                "a tenth of a second, whatever the file's channel count")
            audio:destroy()
        end)

        it("reports a missing file as failed rather than raising", function()
            local audio = Audio.create({ backend = recorder() })
            local clip = audio:load("spec/fixtures/does-not-exist.wav")
            audio:waitForLoads()

            assert.are.equal("failed", clip.status)
            assert.is_truthy(clip.error:find("cannot load"))
            assert.are.equal(0, audio:play(clip), "a failed clip plays nothing")
            audio:destroy()
        end)

        it("loads a path once", function()
            local audio = Audio.create({ backend = recorder() })
            local first = audio:load(FIXTURE)
            local second = audio:load(FIXTURE)
            assert.are.equal(first, second)
            assert.are.equal(1, audio:loading())
            audio:waitForLoads()
            audio:destroy()
        end)
    end)

    describe("playing", function()
        it("queues the clip's bytes on a bound stream", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip)

            assert.is_true(voice > 0)
            assert.are.equal(1, #backend.streams)
            local stream = backend.streams[1]
            assert.is_true(stream.bound)
            assert.are.equal(7, backend.boundTo, "bound to the opened device")
            assert.are.equal(CLIP_BYTES, stream.queued,
                "a one-shot shorter than the lead goes in whole")
            assert.are.equal(1, audio:sounding())
            audio:destroy()
        end)

        it("plays the same clip twice over, on a stream each", function()
            local audio, clip, backend = loaded()
            local first = audio:play(clip)
            local second = audio:play(clip)

            assert.are_not.equal(first, second)
            assert.are.equal(2, #backend.streams,
                "mixing is the platform's job, so two sounds are two streams")
            assert.are.equal(CLIP_BYTES, backend.streams[1].queued)
            assert.are.equal(CLIP_BYTES, backend.streams[2].queued)
            assert.are.equal(2, audio:sounding())
            audio:destroy()
        end)

        it("declines rather than stealing when every voice is busy", function()
            local audio, clip, backend = loaded({ maxVoices = 2 })
            assert.is_true(audio:play(clip) > 0)
            assert.is_true(audio:play(clip) > 0)

            assert.are.equal(0, audio:play(clip))
            assert.are.equal(2, #backend.streams)
            assert.are.equal(2, audio:sounding())
            audio:destroy()
        end)

        it("puts gain on the stream, before and during playback", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip, { gain = 0.25 })
            local stream = backend.streams[1]

            assert.are.equal(0.25, stream.gain)
            audio:setGain(voice, 0.5)
            assert.are.equal(0.5, stream.gain)

            audio:setMasterGain(0.5)
            assert.are.equal(0.25, stream.gain,
                "the master scales what is already sounding")
            audio:destroy()
        end)

        it("unbinds and empties the stream when a voice is stopped", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip)
            local stream = backend.streams[1]

            audio:stop(voice)
            assert.is_false(stream.bound)
            assert.are.equal(1, stream.unbinds)
            assert.are.equal(1, stream.clears,
                "an unbound stream keeps what it holds, so it is cleared too")
            assert.is_false(audio:playing(voice))
            assert.are.equal(0, audio:sounding())
            audio:destroy()
        end)

        it("gives a voice back once its queue has drained", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip)
            local stream = backend.streams[1]
            assert.is_true(audio:playing(voice))

            -- What a device consuming everything looks like from here.
            stream.pending = 0
            audio:update()

            assert.is_false(audio:playing(voice))
            assert.are.equal(0, audio:sounding())
            assert.is_false(stream.bound)
            audio:destroy()
        end)

        it("reuses a released stream for the next sound", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip)
            backend.streams[1].pending = 0
            audio:update()

            local again = audio:play(clip)
            assert.are.equal(1, #backend.streams, "the stream is pooled")
            assert.are.equal(2, backend.streams[1].binds)
            assert.are_not.equal(voice, again,
                "a reused slot answers to a new handle")
            audio:destroy()
        end)

        it("leaves a handle to a finished voice inert", function()
            local audio, clip, backend = loaded()
            local stale = audio:play(clip)
            backend.streams[1].pending = 0
            audio:update()

            local live = audio:play(clip, { gain = 0.75 })
            audio:setGain(stale, 0.1)
            assert.are.equal(0.75, backend.streams[1].gain,
                "the stale handle must not reach the sound that replaced it")
            audio:stop(stale)
            assert.is_true(audio:playing(live))
            audio:destroy()
        end)
    end)

    describe("feeding", function()
        it("queues no more than the lead", function()
            -- The clip is shorter than the lead, so a one-shot fits; a loop
            -- is what shows the ceiling.
            local audio, clip, backend = loaded()
            audio:play(clip, { loop = true })
            assert.are.equal(LEAD_BYTES, backend.streams[1].queued)
            audio:destroy()
        end)

        it("keeps topping a looping voice up past the end of its clip",
            function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip, { loop = true })
            local stream = backend.streams[1]

            stream.pending = 0
            audio:update()

            assert.are.equal(LEAD_BYTES * 2, stream.queued)
            assert.is_true(audio:playing(voice),
                "a loop does not end when the clip does")
            audio:destroy()
        end)

        it("tops a one-shot up only as far as it goes", function()
            -- A lead shorter than the clip, so the clip arrives in pieces.
            local audio, clip, backend = loaded({ lead = 0.05 })
            audio:play(clip)

            local stream = backend.streams[1]
            assert.are.equal(19200, stream.queued)

            stream.pending = 0
            audio:update()
            assert.are.equal(CLIP_BYTES, stream.queued,
                "the rest of the clip, and not a byte more")
            assert.are.equal(2, #stream.puts)
            audio:destroy()
        end)
    end)

    describe("the Sound component", function()
        local function scene(config)
            local audio, clip, backend = loaded(config)
            local world = tecs.newWorld()
            audio:install(world)
            return audio, clip, backend, world
        end

        it("starts a sound the frame its entity appears", function()
            local audio, clip, backend, world = scene()
            local entity = world:spawn(Audio.Sound(clip.id))

            world:update(1 / 60)

            assert.are.equal(1, audio:sounding())
            assert.are.equal(CLIP_BYTES, backend.streams[1].queued)
            assert.is_true(world:get(entity, Audio.Sound).voice > 0)
            audio:destroy()
        end)

        it("carries the component's gain to the stream", function()
            local audio, clip, backend, world = scene()
            world:spawn(Audio.Sound(clip.id, 0.5))
            world:update(1 / 60)
            assert.are.equal(0.5, backend.streams[1].gain)
            audio:destroy()
        end)

        it("stops the sound when its entity goes away", function()
            local audio, clip, backend, world = scene()
            local entity = world:spawn(Audio.Sound(clip.id, 1.0, 1))
            world:update(1 / 60)
            assert.are.equal(1, audio:sounding())

            world:despawn(entity)
            world:update(1 / 60)

            assert.are.equal(0, audio:sounding(),
                "a looping sound outlives its entity unless something ends it")
            assert.is_false(backend.streams[1].bound)
            audio:destroy()
        end)

        it("stops the sound when the component is removed", function()
            local audio, clip, backend, world = scene()
            local entity = world:spawn(Audio.Sound(clip.id, 1.0, 1))
            world:update(1 / 60)

            world:remove(entity, Audio.Sound)
            world:update(1 / 60)

            assert.are.equal(0, audio:sounding())
            assert.is_false(backend.streams[1].bound)
            audio:destroy()
        end)

        it("marks a finished one-shot rather than starting it again",
            function()
            local audio, clip, backend, world = scene()
            local entity = world:spawn(Audio.Sound(clip.id))
            world:update(1 / 60)

            backend.streams[1].pending = 0
            audio:update()
            world:update(1 / 60)

            assert.are.equal(-1, world:get(entity, Audio.Sound).voice)
            assert.are.equal(0, audio:sounding())

            world:update(1 / 60)
            assert.are.equal(0, audio:sounding(),
                "a one-shot that ended must not restart every frame")
            audio:destroy()
        end)

        it("plays again when a game clears the voice", function()
            local audio, clip, _, world = scene()
            local entity = world:spawn(Audio.Sound(clip.id))
            world:update(1 / 60)
            world:getMut(entity, Audio.Sound).voice = 0
            world:update(1 / 60)

            assert.is_true(world:get(entity, Audio.Sound).voice > 0)
            audio:destroy()
        end)

        it("leaves a voice a game started alone", function()
            -- The pass reaps voices no component refers to. One started by
            -- hand is not one of those, or `play` would be unusable next to
            -- the component.
            local audio, clip, _, world = scene()
            local voice = audio:play(clip, { loop = true })
            world:update(1 / 60)

            assert.is_true(audio:playing(voice))
            audio:destroy()
        end)

        it("survives a round trip through a snapshot", function()
            local audio, clip, _, world = scene()
            local entity = world:spawn(Audio.Sound(clip.id, 0.5, 1))
            world:update(1 / 60)
            assert.is_true(world:get(entity, Audio.Sound).voice > 0)

            local saved = world:saveSnapshot({ format = "table" }).snapshot
            assert.is_true(holds(saved.archetypes, FIXTURE),
                "a snapshot carries the path, not this run's index")

            world:loadSnapshot(saved)
            local restored = world:get(entity, Audio.Sound)
            assert.are.equal(clip.id, restored.clip)
            assert.are.equal(0.5, restored.gain)
            assert.are.equal(1, restored.loop)
            assert.are.equal(0, restored.voice,
                "a restored sound starts again rather than resuming")
            audio:destroy()
        end)
    end)

    describe("no output", function()
        it("keeps working when no device opens", function()
            local backend = recorder({ silent = true })
            local audio = Audio.create({ backend = backend })
            local clip = audio:load(FIXTURE)
            audio:waitForLoads()

            assert.is_false(audio.available)
            assert.are.equal("ready", clip.status,
                "loading does not need an output")
            assert.are.equal(0, audio:play(clip))
            assert.are.equal(0, audio:sounding())
            assert.are.equal(0, #backend.streams)
            audio:update()
            audio:stopAll()
            audio:destroy()
        end)
    end)

    describe("shutdown", function()
        it("closes the device and destroys every stream", function()
            local audio, clip, backend = loaded()
            audio:play(clip)
            audio:play(clip)
            audio:destroy()

            assert.are.equal(1, backend.closes)
            assert.are.equal(7, backend.device)
            for _, stream in ipairs(backend.streams) do
                assert.is_true(stream.destroyed)
                assert.is_false(stream.bound)
            end
            assert.are.equal(0, audio:sounding())
        end)
    end)
end)
