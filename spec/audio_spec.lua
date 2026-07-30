-- Sound output: clips, voices, groups, limits, and the component that
-- attaches one to an entity.
--
-- Playback is driven through a substituted backend rather than through a
-- sound card. No continuous-integration machine has one, and a machine that
-- does cannot assert what came out of it: there is no readback for audio the
-- way there is for a framebuffer. So what these tests assert is what was
-- asked of the mixer. That a play pointed a track at the right input and
-- started it with the right options, that a gain reached the track and the
-- master reached the mixer, that stopping ended it, that a voice the mixer
-- reports as finished gives its slot back, and that a group's operations go
-- out as tag operations.
--
-- The mixer pulls rather than being fed, so the one thing a test drives is
-- whether a track is still playing. Setting `track.playing = false` is what a
-- mixer finishing a voice looks like from here, and every reaping test turns
-- on it.
--
-- Loading is the one half driven for real: both fixtures are read and decoded
-- by SDL_mixer on the asset worker, on a thread, which is what the "pending"
-- status immediately after the call proves. `blip.ogg` is there so the Vorbis
-- decoder is exercised rather than assumed; it was produced from `blip.wav`
-- with `oggenc -q 4 -o spec/fixtures/blip.ogg spec/fixtures/blip.wav`.
--
-- The debug tool is driven the same way, through `mcp.dispatch`, because what
-- an agent gets is the encoded payload and not the Lua tables behind it.
--
-- What that leaves untested, rather than asserted: whether anything is
-- audible, whether SDL_mixer sums two tracks the way its documentation says,
-- whether a fade is actually a ramp rather than a cut, what a frequency ratio
-- does to a decoder's output, whether 3D positioning puts a sound where it
-- claims, whether the mixer really follows the system default when headphones
-- are plugged in, and what the hardware does with a gain above one. Those
-- need a device and a pair of ears, and the tests here prove the layer above
-- them instead.

-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local cjson = require("cjson")
local tecs = require("tecs")
local Audio = require("tecs.audio").Audio
local newAudio = require("tecs.audio").newAudio
local assets = require("tecs.assets")
local mcp = require("tecs.mcp")
local mcpTools = require("tecs.mcp.tools")

-- A tenth of a second of 16-bit mono at 48000 Hz, and the same tenth of a
-- second encoded as Ogg Vorbis. Whole numbers, so a duration that is off by a
-- resample is off by a lot rather than by rounding.
local FIXTURE = "spec/fixtures/blip.wav"
local VORBIS = "spec/fixtures/blip.ogg"
local CLIP_SECONDS = 0.1

-- A backend that records what it was asked to do and reports back whatever a
-- test tells it to. Nothing here reaches SDL, so it runs anywhere.
local function recorder(options)
    options = options or {}
    local backend = {
        name = "spec.audio",
        tracks = {},
        opens = 0,
        closes = 0,
        mixerGain = 1.0,
        tagOps = {},
    }

    --- Every track carrying `tag`, which is how the mixer reaches a group.
    local function tagged(tag)
        local found = {}
        for _, track in ipairs(backend.tracks) do
            if track.tags[tag] then
                found[#found + 1] = track
            end
        end
        return found
    end

    function backend.open(spec)
        backend.opens = backend.opens + 1
        backend.spec = spec
        if options.silent then
            return nil
        end
        backend.mixer = { id = 7 }
        return backend.mixer
    end

    function backend.close(mixer)
        backend.closes = backend.closes + 1
        backend.closed = mixer
    end

    function backend.setMixerGain(_mixer, gain)
        backend.mixerGain = gain
    end

    function backend.createTrack(mixer)
        local track = {
            index = #backend.tracks + 1,
            mixer = mixer,
            playing = false,
            paused = false,
            plays = 0,
            stops = 0,
            destroyed = false,
            gain = 1.0,
            gains = {},
            pitch = 1.0,
            tags = {},
            input = nil,
            position = nil,
            stereo = nil,
            params = nil,
            fadeOutMs = nil,
            -- The loop count last pushed part way through, and where the
            -- mixer says the track is reading. A decoder that cannot seek is
            -- what the `unseekable` option stands in for.
            loops = nil,
            positionMs = 0,
        }
        backend.tracks[track.index] = track
        return track
    end

    function backend.destroyTrack(track)
        track.destroyed = true
    end

    function backend.setTrackClip(track, clip)
        if options.refuseInput then
            return false
        end
        track.input = { kind = "clip", clip = clip }
        return true
    end

    function backend.setTrackFile(track, path)
        if options.refuseInput then
            return false
        end
        track.input = { kind = "file", path = path }
        return true
    end

    function backend.clearTrack(track)
        track.input = nil
    end

    function backend.play(track, params)
        track.plays = track.plays + 1
        -- Copied, because one options record is reused for every play.
        track.params = {
            loops = params.loops,
            loopStartMs = params.loopStartMs,
            fadeInMs = params.fadeInMs,
            startMs = params.startMs,
        }
        track.playing = true
        track.paused = false
        return true
    end

    function backend.stop(track, fadeMs)
        track.stops = track.stops + 1
        track.fadeOutMs = fadeMs
        -- A fade keeps the mixer taking samples until it finishes, so only an
        -- immediate stop ends the track here.
        if fadeMs <= 0 then
            track.playing = false
        end
    end

    function backend.pause(track)
        track.paused = true
        track.playing = false
    end

    function backend.resume(track)
        track.paused = false
        track.playing = true
    end

    function backend.playing(track)
        return track.playing
    end

    function backend.setGain(track, gain)
        track.gain = gain
        track.gains[#track.gains + 1] = gain
    end

    function backend.setPitch(track, ratio)
        track.pitch = ratio
    end

    function backend.setLoops(track, loops)
        track.loops = loops
    end

    function backend.seek(track, ms)
        if options.unseekable then
            return false
        end
        track.positionMs = ms
        return true
    end

    function backend.tell(track)
        return track.positionMs
    end

    function backend.setPosition(track, x, y, z)
        track.position = { x = x, y = y, z = z }
        -- The mixer holds one placement per track, so recording both would
        -- let a test pass that the real thing fails.
        track.stereo = nil
    end

    function backend.setStereo(track, left, right)
        track.stereo = { left = left, right = right }
        track.position = nil
    end

    function backend.clearSpatial(track)
        track.position = nil
        track.stereo = nil
    end

    function backend.tag(track, tag)
        track.tags[tag] = true
    end
    function backend.untag(track, tag)
        track.tags[tag] = nil
    end

    function backend.pauseTag(_mixer, tag)
        backend.tagOps[#backend.tagOps + 1] = { op = "pause", tag = tag }
        for _, track in ipairs(tagged(tag)) do
            backend.pause(track)
        end
    end

    function backend.resumeTag(_mixer, tag)
        backend.tagOps[#backend.tagOps + 1] = { op = "resume", tag = tag }
        for _, track in ipairs(tagged(tag)) do
            backend.resume(track)
        end
    end

    function backend.stopTag(_mixer, tag, fadeMs)
        backend.tagOps[#backend.tagOps + 1] = { op = "stop", tag = tag, fadeMs = fadeMs }
        for _, track in ipairs(tagged(tag)) do
            backend.stop(track, fadeMs)
        end
    end

    return backend
end

--- Whether `wanted` appears anywhere inside a nest of tables. A snapshot's
--- shape is the snapshot code's business; what matters here is which of two
--- values, a path or an index, ended up in it.
local function holds(value, wanted)
    if value == wanted then
        return true
    end
    if type(value) ~= "table" then
        return false
    end
    for _, item in pairs(value) do
        if holds(item, wanted) then
            return true
        end
    end
    return false
end

--- Replaces every occurrence of the string `from` inside a nest of tables.
---
--- Stands in for a save file written by a run that interned its names in a
--- different order, which is exactly the case an index in a file gets wrong.
local function rewrite(value, from, to)
    if type(value) ~= "table" then
        return
    end
    for key, item in pairs(value) do
        if item == from then
            value[key] = to
        else
            rewrite(item, from, to)
        end
    end
end

--- An audio object on a recording backend, with its fixture already loaded.
local function loaded(config, path)
    config = config or {}
    config.backend = config.backend or recorder()
    local audio = newAudio(config)
    local clip = audio:load(path or FIXTURE):wait().value
    return audio, clip, config.backend
end

--- The same, plus a world the audio is installed into.
local function scene(config)
    local audio, clip, backend = loaded(config)
    local world = tecs.ecs.newWorld()
    audio:install(world)
    return audio, clip, backend, world
end

--- Calls a debug tool the way an agent does, and returns its payload.
local function callTool(name, args)
    local response = cjson.decode(mcp.dispatch(cjson.encode({
        jsonrpc = "2.0",
        id = 1,
        method = "tools/call",
        params = { name = name, arguments = args or {} },
    })))
    return response.result
end

describe("audio", function()
    teardown(function()
        assets.shutdown()
    end)

    describe("the build", function()
        it("carries a decoder for every fixture it is asked to read", function()
            local names = {}
            for _, decoder in ipairs(Audio.decoders()) do
                names[decoder] = true
            end
            assert.is_true(names.WAV, "the built-in WAV reader is not optional")
            assert.is_true(names.VORBIS or names.STBVORBIS, "an Ogg Vorbis decoder, under either backend's name")
        end)
    end)

    describe("clips", function()
        it("returns a future immediately and resolves it with the clip", function()
            local audio = newAudio({ backend = recorder() })
            local loading = audio:load(FIXTURE)
            local clip = audio:clip(Audio.clipId(FIXTURE))

            assert.are.equal("pending", loading.status, "loading must not block the caller")
            assert.are.equal("pending", clip.status, "the cached clip exposes the same work to inspection")
            assert.are.equal(1, audio:loading())

            audio:waitForLoads()
            assert.are.equal("ready", loading.status)
            assert.are.equal(clip, loading.value)
            assert.are.equal("ready", clip.status)
            assert.are.equal(0, audio:loading())
            audio:destroy()
        end)

        it("reads a compressed file, not only PCM", function()
            local audio, clip = loaded(nil, VORBIS)
            assert.are.equal("ready", clip.status, "the mixer's decoders are what make this more than WAV")
            assert.is_true(
                math.abs(clip.duration - CLIP_SECONDS) < 1e-3,
                "a tenth of a second, whatever container it arrived in"
            )
            audio:destroy()
        end)

        it("reports the length the file states", function()
            local audio, clip = loaded()
            assert.is_true(math.abs(clip.duration - CLIP_SECONDS) < 1e-6)
            audio:destroy()
        end)

        it("reports a missing file as failed rather than raising", function()
            local audio = newAudio({ backend = recorder() })
            local path = "spec/fixtures/does-not-exist.wav"
            local loading = audio:load(path)
            audio:waitForLoads()

            local clip = audio:clip(Audio.clipId(path))
            assert.are.equal("failed", loading.status)
            assert.are.equal(clip.error, loading.error)
            assert.are.equal("failed", clip.status)
            assert.is_truthy(clip.error:find("cannot load"))
            assert.are.equal(0, audio:play(clip), "a failed clip plays nothing")
            audio:destroy()
        end)

        it("loads a path once", function()
            local audio = newAudio({ backend = recorder() })
            local first = audio:load(FIXTURE)
            local second = audio:load(FIXTURE)
            assert.are_not.equal(first, second, "each caller needs an independently cancelable future")
            assert.are.equal(1, audio:loading())
            audio:waitForLoads()
            assert.are.equal("ready", first.status)
            assert.are.equal("ready", second.status)
            assert.are.equal(first.value, second.value, "one path still names one clip")
            audio:destroy()
        end)

        it("lets one caller cancel without giving up the cached load", function()
            local audio = newAudio({ backend = recorder() })
            local canceled = audio:load(FIXTURE)
            local kept = audio:load(FIXTURE)

            canceled:cancel()
            assert.are.equal("canceled", canceled.status)
            assert.are.equal("pending", kept.status)
            assert.are.equal(1, audio:loading())

            audio:waitForLoads()
            assert.are.equal("ready", kept.status)
            assert.are.equal("ready", kept.value.status)
            assert.are.equal(kept.value, audio:clip(Audio.clipId(FIXTURE)))
            audio:destroy()
        end)

        it("keeps its cached load after every caller cancels", function()
            local audio = newAudio({ backend = recorder() })
            local canceled = audio:load(FIXTURE)

            canceled:cancel()
            audio:waitForLoads()

            assert.are.equal("canceled", canceled.status)
            assert.are.equal("ready", audio:clip(Audio.clipId(FIXTURE)).status)
            assert.are.equal(0, audio:loading())
            audio:destroy()
        end)

        it("returns settled futures after the cached load has answered", function()
            local audio = newAudio({ backend = recorder() })
            local first = audio:load(FIXTURE):wait()
            local ready = audio:load(FIXTURE)

            assert.are.equal("ready", ready.status)
            assert.are.equal(first.value, ready.value)

            local missingPath = "spec/fixtures/does-not-exist.wav"
            local failed = audio:load(missingPath):wait()
            local failedAgain = audio:load(missingPath)
            assert.are.equal("failed", failed.status)
            assert.are.equal("failed", failedAgain.status)
            assert.are.equal(failed.error, failedAgain.error)
            audio:destroy()
        end)

        -- A join over these two would have stopped at the missing file, since
        -- `Future.all` fails on its first failed input and a path with no file
        -- fails as fast as the worker can look, and it would have answered with
        -- the good load still in flight. What the wait is asking is "is anything
        -- of mine outstanding", which a failure answers as well as a success.
        it("waits for every load, whatever each of them settled as", function()
            local audio = newAudio({ backend = recorder() })
            local missing = audio:load("spec/fixtures/does-not-exist.wav")
            local present = audio:load(FIXTURE)
            assert.are.equal(2, audio:loading())

            audio:waitForLoads()

            assert.are.equal(0, audio:loading(), "a failed load left the rest unwaited for")
            assert.are.equal("failed", missing.status)
            assert.are.equal("ready", present.status)
            audio:destroy()
        end)

        -- The mixer frees everything SDL_mixer made for it, so a clip arriving
        -- afterwards would hold a pointer into it. Destroying with a decode in
        -- flight has to settle that decode before it closes.
        --
        -- `assets.pending` is what says it did. A destroy that gave the load up
        -- instead of waiting for it would leave the entry queued until the worker
        -- answered, and every other observable here would read the same: destroy
        -- writes `"released"` over each clip and zeroes its own count whether it
        -- drained or canceled.
        it("settles a load in flight before it frees the mixer", function()
            local audio = newAudio({ backend = recorder() })
            local loading = audio:load(FIXTURE)
            local clip = audio:clip(Audio.clipId(FIXTURE))
            assert.are.equal(1, audio:loading())
            assert.is_true(assets.pending() >= 1, "the loader has nothing queued to destroy under")

            audio:destroy()

            assert.are.equal(0, assets.pending(), "the mixer went while a decode was outstanding")
            assert.are.equal(0, audio:loading())
            assert.are.equal("ready", loading.status)
            assert.are.equal("released", clip.status)
            assert.is_nil(clip._sound, "a released clip still points at samples")

            assets.waitAll()
            assert.are.equal("released", clip.status, "something arrived after the mixer had gone")
        end)

        -- The drain that waiting means is the loader's, and the loader's scope is
        -- every load in the process. So an instance with nothing outstanding has
        -- to decide not to enter it: a mixer that loaded nothing must not spend
        -- a `waitForLoads` on a texture somebody else asked for.
        it("drains nobody when it has nothing in flight", function()
            assets.install()
            local audio = newAudio({ backend = recorder() })
            local elsewhere = assets.loadImage("spec/fixtures/split.png")

            audio:waitForLoads()
            assert.are.equal("pending", elsewhere.status, "an unrelated decode was drained")

            audio:destroy()
            assert.are.equal("pending", elsewhere.status, "destroy drained it instead")

            assets.waitAll()
            elsewhere.value:release()
        end)
    end)

    describe("resident and streamed", function()
        it("holds a clip shorter than the threshold in memory", function()
            local audio, clip = loaded({ streamSeconds = 10 })
            assert.is_true(clip.resident, "a sound effect is decoded once and read by every voice")
            audio:destroy()
        end)

        it("streams one at or over the threshold", function()
            local audio, clip = loaded({ streamSeconds = 0.05 }, VORBIS)
            assert.is_false(clip.resident, "a long clip is not worth a decoded copy")
            assert.is_nil(clip._sound.audio, "and nothing was loaded to hold one")
            audio:destroy()
        end)

        it("takes an explicit answer over the threshold", function()
            local audio = newAudio({
                backend = recorder(),
                streamSeconds = 10,
            })
            local streamed = audio:load(VORBIS, { stream = true }):wait().value
            assert.is_false(streamed.resident)

            local other = newAudio({
                backend = recorder(),
                streamSeconds = 0.05,
            })
            local kept = other:load(FIXTURE, { stream = false }):wait().value
            assert.is_true(kept.resident)

            audio:destroy()
            other:destroy()
        end)

        it("points a streamed voice at the file and a resident one at the clip", function()
            local streaming, music, backend = loaded({ streamSeconds = 0.05 }, VORBIS)
            streaming:play(music)
            assert.are.equal("file", backend.tracks[1].input.kind)
            assert.are.equal(VORBIS, backend.tracks[1].input.path)
            streaming:destroy()

            local audio, clip, other = loaded()
            audio:play(clip)
            assert.are.equal("clip", other.tracks[1].input.kind)
            audio:destroy()
        end)
    end)

    -- Re-reading a file over the clip already loaded from it. Identity is the
    -- point, exactly as it is for an image: a clip's index is its path's, so a
    -- `Sound` row keeps naming the right sound and nothing in the world is
    -- touched. The fixture is copied to a temporary path first, because what is
    -- being edited is the file behind a clip that is already loaded.
    describe("reloading a clip", function()
        local temp

        local function copyInto(target, source)
            local input = assert(io.open(source, "rb"))
            local bytes = input:read("*a")
            input:close()
            local output = assert(io.open(target, "wb"))
            output:write(bytes)
            output:close()
        end

        before_each(function()
            temp = os.tmpname() .. ".wav"
            copyInto(temp, FIXTURE)
        end)

        after_each(function()
            os.remove(temp)
        end)

        it("decodes the file again under the index the clip already had", function()
            local audio, clip = loaded(nil, temp)
            assert.is_true(clip.resident)
            local id, previous = clip.id, clip._sound

            -- A different file entirely, under the same name. A reload that
            -- answered from a cache would report success and change nothing.
            copyInto(temp, VORBIS)
            assert.is_true(audio:reload(temp))

            assert.are.equal(id, clip.id, "a re-read must not move what a Sound carries")
            assert.are.equal(clip, audio:clip(id), "the clip is the same object, so every row still names it")
            assert.are_not.equal(previous, clip._sound, "the file was not read again")
            assert.is_nil(previous.audio, "the clip it replaced was not let go")
            assert.are.equal("ready", clip.status)
            assert.is_true(clip.resident)
            audio:destroy()
        end)

        it("starts the next voice on what was just read", function()
            local audio, clip, backend = loaded(nil, temp)
            copyInto(temp, VORBIS)
            audio:reload(temp)

            audio:play(clip)
            assert.are.equal(clip._sound.audio, backend.tracks[1].input.clip)
            audio:destroy()
        end)

        it("leaves a voice already sounding on the samples it started with", function()
            local audio, clip, backend = loaded(nil, temp)
            local voice = audio:play(clip)
            local started = backend.tracks[1].input.clip

            copyInto(temp, VORBIS)
            assert.is_true(audio:reload(temp))

            assert.is_true(audio:playing(voice), "a reload must not cut a sound off")
            assert.are.equal(
                started,
                backend.tracks[1].input.clip,
                "the mixer counts a reference per track, so a sounding voice plays out on what it had"
            )
            audio:destroy()
        end)

        it("has nothing to replace for a streamed clip", function()
            local audio = newAudio({ backend = recorder() })
            local clip = audio:load(temp, { stream = true }):wait().value
            assert.is_false(clip.resident)
            local handle = clip._sound

            copyInto(temp, VORBIS)
            assert.is_true(audio:reload(temp), "every voice opens the file itself, so there is nothing held")
            assert.are.equal(handle, clip._sound, "a streamed clip holds nothing that needed re-reading")
            audio:destroy()
        end)

        it("refuses a path nothing has loaded", function()
            local audio = newAudio({ backend = recorder() })
            local ok, reason = audio:reload("spec/fixtures/never-loaded.wav")
            assert.is_false(ok)
            assert.is_truthy(reason:find("never-loaded.wav", 1, true), "unexpected refusal: " .. tostring(reason))
            audio:destroy()
        end)

        it("keeps the clip it had when the new file will not decode", function()
            local audio, clip, backend = loaded(nil, temp)
            local handle = clip._sound

            local broken = assert(io.open(temp, "wb"))
            broken:write("not a sound file")
            broken:close()

            local ok, reason = audio:reload(temp)
            assert.is_false(ok)
            assert.is_truthy(reason:find("did not load", 1, true), "unexpected refusal: " .. tostring(reason))

            -- Refused means nothing moved, which for a clip means it is still
            -- playable off what it already held.
            assert.are.equal("ready", clip.status)
            assert.are.equal(handle, clip._sound)
            audio:play(clip)
            assert.are.equal(handle.audio, backend.tracks[1].input.clip)
            audio:destroy()
        end)

        it("is driven by the debug tool the way an agent drives it", function()
            local audio, clip, _, world = scene()
            local reloadable = audio:load(temp):wait().value
            mcpTools.bind(nil, world)
            assert.are.equal("ready", clip.status)

            copyInto(temp, VORBIS)
            local result = callTool("reload_sound", { path = temp })
            assert.is_falsy(result.isError, tostring(result.content and result.content[1] and result.content[1].text))
            assert.are.equal(temp, result.structuredContent.path)
            assert.is_true(result.structuredContent.resident)
            assert.are.equal("ready", reloadable.status)

            local refused = callTool("reload_sound", { path = "spec/fixtures/never-loaded.wav" })
            assert.is_true(refused.isError)
            assert.is_truthy(refused.content[1].text:find("nothing has loaded", 1, true))
            audio:destroy()
        end)
    end)

    describe("playing", function()
        it("starts one track per voice", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip)

            assert.is_true(voice > 0)
            assert.are.equal(1, #backend.tracks)
            local track = backend.tracks[1]
            assert.is_true(track.playing)
            assert.are.equal(1, track.plays)
            assert.are.equal(backend.mixer, track.mixer, "made on the mixer that was opened")
            assert.are.equal(1, audio:sounding())
            audio:destroy()
        end)

        it("plays the same clip twice over, on a track each", function()
            local audio, clip, backend = loaded()
            local first = audio:play(clip)
            local second = audio:play(clip)

            assert.are_not.equal(first, second)
            assert.are.equal(2, #backend.tracks, "mixing is the mixer's job, so two sounds are two tracks")
            assert.are.equal(2, audio:sounding())
            audio:destroy()
        end)

        it("declines rather than stealing when every voice is busy", function()
            local audio, clip, backend = loaded({ maxVoices = 2 })
            assert.is_true(audio:play(clip) > 0)
            assert.is_true(audio:play(clip) > 0)

            assert.are.equal(0, audio:play(clip))
            assert.are.equal(2, #backend.tracks)
            assert.are.equal(2, audio:sounding())
            audio:destroy()
        end)

        it("puts gain on the track and the master on the mixer", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip, { gain = 0.25 })
            local track = backend.tracks[1]

            assert.are.equal(0.25, track.gain)
            audio:setGain(voice, 0.5)
            assert.are.equal(0.5, track.gain)

            audio:setMasterGain(0.5)
            assert.are.equal(0.5, backend.mixerGain, "the master is the mixer's own number, not every voice's")
            assert.are.equal(0.5, track.gain, "so a voice's gain is left exactly as it was asked for")
            assert.are.equal(0.5, audio:masterGain())
            audio:destroy()
        end)

        it("ends and detaches a track when a voice is stopped", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip)
            local track = backend.tracks[1]

            audio:stop(voice)
            assert.is_false(track.playing)
            assert.are.equal(1, track.stops)
            assert.is_nil(track.input, "the input is dropped, so a streamed voice closes its file")
            assert.is_false(audio:playing(voice))
            assert.are.equal(0, audio:sounding())
            audio:destroy()
        end)

        it("gives a voice back once the mixer says it has finished", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip)
            local track = backend.tracks[1]
            assert.is_true(audio:playing(voice))

            audio:update(1 / 60)
            assert.is_true(audio:playing(voice), "a voice the mixer is still taking samples from stays")

            -- What a mixer running a voice to its end looks like from here.
            track.playing = false
            audio:update(1 / 60)

            assert.is_false(audio:playing(voice))
            assert.are.equal(0, audio:sounding())
            audio:destroy()
        end)

        it("reuses a released track for the next sound", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip)
            backend.tracks[1].playing = false
            audio:update(1 / 60)

            local again = audio:play(clip)
            assert.are.equal(1, #backend.tracks, "the track is pooled")
            assert.are.equal(2, backend.tracks[1].plays)
            assert.are_not.equal(voice, again, "a reused slot answers to a new handle")
            audio:destroy()
        end)

        it("leaves a handle to a finished voice inert", function()
            local audio, clip, backend = loaded()
            local stale = audio:play(clip)
            backend.tracks[1].playing = false
            audio:update(1 / 60)

            local live = audio:play(clip, { gain = 0.75 })
            audio:setGain(stale, 0.1)
            assert.are.equal(0.75, backend.tracks[1].gain, "the stale handle must not reach the sound that replaced it")
            audio:stop(stale)
            assert.is_true(audio:playing(live))
            audio:destroy()
        end)

        it("holds one voice without reaping it", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip)

            audio:pause(voice)
            assert.is_true(backend.tracks[1].paused)
            assert.is_true(audio:paused(voice))

            audio:update(1 / 60)
            assert.is_true(
                audio:playing(voice),
                "a paused track reports that it is not playing, and reaping " .. "on that alone would collect it"
            )

            audio:resume(voice)
            assert.is_false(audio:paused(voice))
            assert.is_true(backend.tracks[1].playing)
            audio:destroy()
        end)

        it("declines when the mixer will not take the input", function()
            local audio, clip, backend = loaded({ backend = recorder({ refuseInput = true }) })
            assert.are.equal(0, audio:play(clip))
            assert.are.equal(0, audio:sounding())
            assert.are.equal(0, backend.tracks[1].plays, "a track with no input is never started")
            assert.is_nil(
                backend.tracks[1].input,
                "and a resident clip that was refused does not fall back to " .. "reading the file"
            )
            audio:destroy()
        end)
    end)

    describe("looping and start points", function()
        it("asks for an endless loop rather than a count", function()
            local audio, clip, backend = loaded()
            audio:play(clip, { loop = true })
            assert.are.equal(-1, backend.tracks[1].params.loops)
            audio:destroy()
        end)

        it("plays once by default", function()
            local audio, clip, backend = loaded()
            audio:play(clip)
            assert.are.equal(0, backend.tracks[1].params.loops)
            audio:destroy()
        end)

        it("carries a loop point and a start offset in milliseconds", function()
            local audio, clip, backend = loaded()
            audio:play(clip, { loop = true, loopStart = 0.02, start = 0.05 })
            local params = backend.tracks[1].params
            assert.are.equal(20, params.loopStartMs, "so an intro plays once and the rest of it repeats")
            assert.are.equal(50, params.startMs)
            audio:destroy()
        end)

        it("changes whether a voice repeats part way through", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip, { loop = true })
            assert.is_true(audio:looping(voice))
            assert.is_nil(backend.tracks[1].loops, "the play already carried the count, so nothing is pushed twice")

            audio:setLoop(voice, false)
            assert.are.equal(
                0,
                backend.tracks[1].loops,
                "a piece of music told to stop looping plays out to its end rather than being cut"
            )
            assert.is_false(audio:looping(voice))

            audio:setLoop(voice, true)
            assert.are.equal(-1, backend.tracks[1].loops)
            audio:destroy()
        end)

        it("pushes a loop change once", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip)
            audio:setLoop(voice, false)
            assert.is_nil(backend.tracks[1].loops, "a one-shot already plays once")

            audio:setLoop(voice, true)
            audio:setLoop(voice, true)
            assert.are.equal(-1, backend.tracks[1].loops)

            backend.tracks[1].loops = nil
            audio:setLoop(voice, true)
            assert.is_nil(backend.tracks[1].loops, "an unchanged loop costs no call")
            audio:destroy()
        end)

        it("leaves a loop change to a finished voice inert", function()
            local audio, clip, backend = loaded()
            local stale = audio:play(clip, { loop = true })
            backend.tracks[1].playing = false
            audio:update(1 / 60)

            audio:setLoop(stale, false)
            assert.is_nil(backend.tracks[1].loops)
            assert.is_false(audio:looping(stale))
            audio:destroy()
        end)

        it("returns a reused track's loop to what the next voice asked for", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip, { loop = true })
            audio:setLoop(voice, false)
            backend.tracks[1].playing = false
            audio:update(1 / 60)

            local again = audio:play(clip, { loop = true })
            assert.is_true(audio:looping(again), "the next sound on this slot must not inherit a loop")
            audio:destroy()
        end)
    end)

    describe("seek and tell", function()
        it("moves a voice's read position and reads it back", function()
            local audio, clip = loaded()
            local voice = audio:play(clip)

            assert.are.equal(0, audio:tell(voice))
            assert.is_true(audio:seek(voice, 0.04))
            assert.is_true(math.abs(audio:tell(voice) - 0.04) < 1e-9, "seconds in and seconds out")
            audio:destroy()
        end)

        it("reports an input that cannot seek rather than raising", function()
            local audio, clip = loaded({ backend = recorder({ unseekable = true }) })
            local voice = audio:play(clip)
            assert.is_false(audio:seek(voice, 0.04), "a decoder is allowed not to be able to seek")
            audio:destroy()
        end)

        it("answers nothing for a handle that names no voice", function()
            local audio, clip, backend = loaded()
            local stale = audio:play(clip)
            backend.tracks[1].playing = false
            audio:update(1 / 60)

            assert.is_false(audio:seek(stale, 0.01))
            assert.is_nil(audio:tell(stale))
            audio:destroy()
        end)

        it("says nothing rather than a negative when the mixer cannot answer", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip)
            -- What a decoder that will not report a position looks like here.
            backend.tracks[1].positionMs = -1
            assert.is_nil(audio:tell(voice))
            audio:destroy()
        end)
    end)

    describe("fades", function()
        it("hands a fade-in to the mixer rather than ramping gain here", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip, { gain = 0.8, fadeIn = 0.25 })
            local track = backend.tracks[1]

            assert.are.equal(250, track.params.fadeInMs)
            assert.are.equal(0.8, track.gain, "the gain is where it will end up; the ramp is the mixer's")
            assert.is_true(audio:playing(voice))
            audio:destroy()
        end)

        it("keeps a faded-out voice until the mixer has finished it", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip)
            local track = backend.tracks[1]

            audio:stop(voice, 0.5)
            assert.are.equal(500, track.fadeOutMs)
            assert.is_true(track.playing)
            assert.is_true(audio:playing(voice), "a fading voice has not finished, so it keeps its slot")

            audio:update(1 / 60)
            assert.are.equal(1, audio:sounding())

            track.playing = false
            audio:update(1 / 60)
            assert.is_false(audio:playing(voice))
            assert.are.equal(0, audio:sounding())
            audio:destroy()
        end)

        it("takes everything down over one fade", function()
            local audio, clip, backend = loaded()
            local first = audio:play(clip)
            local second = audio:play(clip)

            audio:stopAll(0.75)
            assert.are.equal(750, backend.tracks[1].fadeOutMs)
            assert.are.equal(750, backend.tracks[2].fadeOutMs)
            assert.is_true(audio:playing(first), "a fading voice has not finished, so it keeps its slot")
            assert.is_true(audio:playing(second))
            assert.are.equal(2, audio:sounding())

            backend.tracks[1].playing = false
            backend.tracks[2].playing = false
            audio:update(1 / 60)
            assert.are.equal(0, audio:sounding())
            audio:destroy()
        end)

        it("lets a paused voice run its fade out", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip)
            audio:pause(voice)

            audio:stopAll(0.5)
            assert.is_false(audio:paused(voice), "a paused voice does not advance, so a fade on one would never finish")
            assert.are.equal(500, backend.tracks[1].fadeOutMs)
            audio:destroy()
        end)

        it("ends everything at once when no fade is given", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip)
            audio:play(clip)

            audio:stopAll()
            assert.are.equal(0, backend.tracks[1].fadeOutMs)
            assert.is_false(backend.tracks[1].playing)
            assert.is_false(audio:playing(voice))
            assert.are.equal(0, audio:sounding())
            audio:destroy()
        end)

        it("ignores a second stop while one is fading", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip)
            audio:stop(voice, 0.5)
            audio:stop(voice)
            assert.are.equal(1, backend.tracks[1].stops)
            assert.is_true(audio:playing(voice))
            audio:destroy()
        end)
    end)

    describe("pitch", function()
        it("sets a rate only when one was asked for", function()
            local audio, clip, backend = loaded()
            audio:play(clip)
            assert.are.equal(1.0, backend.tracks[1].pitch)

            local voice = audio:play(clip, { pitch = 1.5 })
            assert.are.equal(1.5, backend.tracks[2].pitch)
            audio:setPitch(voice, 0.5)
            assert.are.equal(0.5, backend.tracks[2].pitch)
            audio:destroy()
        end)

        it("returns a reused track to the rate the next voice asked for", function()
            local audio, clip, backend = loaded()
            audio:play(clip, { pitch = 1.5 })
            backend.tracks[1].playing = false
            audio:update(1 / 60)

            audio:play(clip)
            assert.are.equal(1.0, backend.tracks[1].pitch, "the next sound on this slot must not inherit a rate")
            audio:destroy()
        end)

        it("spreads variance around the rate that was asked for", function()
            local audio, clip, backend = loaded({ maxVoices = 16 })
            local spread = {}
            for _ = 1, 16 do
                audio:play(clip, { pitch = 2.0, pitchVariance = 0.1 })
            end
            for index = 1, 16 do
                local pitch = backend.tracks[index].pitch
                assert.is_true(pitch >= 1.8 and pitch <= 2.2, "a tenth either side of the rate, and no further")
                spread[pitch] = true
            end
            local distinct = 0
            for _ in pairs(spread) do
                distinct = distinct + 1
            end
            assert.is_true(distinct > 1, "forty of one sound must not all come out at one pitch")
            audio:destroy()
        end)

        -- Variance is drawn from the world's `tecs.audio` stream rather than
        -- from a process-wide generator, so a run that seeded the world fires
        -- the same rates in the same order every time it is played back.
        local function variedRates(seed, count)
            local audio, clip, backend, world = scene({ maxVoices = 32 })
            tecs.ecs.random.seed(world, seed)
            local rates = {}
            for index = 1, count do
                audio:play(clip, { pitch = 2.0, pitchVariance = 0.25 })
                rates[index] = backend.tracks[index].pitch
            end
            audio:destroy()
            return rates
        end

        it("repeats the same variance for the same world seed", function()
            assert.are.same(variedRates(4242, 12), variedRates(4242, 12))
        end)

        it("gives a different world seed different variance", function()
            local a, b = variedRates(4242, 12), variedRates(4243, 12)
            local shared = 0
            for index = 1, 12 do
                if a[index] == b[index] then
                    shared = shared + 1
                end
            end
            assert.is_true(shared < 3, shared .. " of 12 rates matched across seeds")
        end)

        it("carries the variance stream through a snapshot", function()
            local audio, clip, backend, world = scene({ maxVoices = 32 })
            tecs.ecs.random.seed(world, 4242)
            audio:play(clip, { pitch = 2.0, pitchVariance = 0.25 })

            local saved = world:saveSnapshot().buffer
            audio:play(clip, { pitch = 2.0, pitchVariance = 0.25 })
            local afterSave = backend.tracks[2].pitch

            -- Left a long way from where it was saved, so a load that did not
            -- restore the stream would not land back on the same rate.
            for _ = 3, 24 do
                audio:play(clip, { pitch = 2.0, pitchVariance = 0.25 })
            end

            world:loadSnapshot(saved)
            audio:play(clip, { pitch = 2.0, pitchVariance = 0.25 })
            assert.are.equal(afterSave, backend.tracks[25].pitch)
            audio:destroy()
        end)
    end)

    describe("groups", function()
        it("tags a voice with its group", function()
            local audio, clip, backend = loaded()
            audio:play(clip, { group = "music" })
            assert.is_true(backend.tracks[1].tags.music)
            audio:destroy()
        end)

        it("scales the voices in a group, and later joiners too", function()
            local audio, clip, backend = loaded()
            audio:play(clip, { gain = 0.5, group = "sfx" })
            audio:play(clip, { gain = 1.0, group = "music" })

            audio:setGroupGain("sfx", 0.5)
            assert.are.equal(0.25, backend.tracks[1].gain, "the group multiplies what the voice asked for")
            assert.are.equal(1.0, backend.tracks[2].gain, "and reaches nothing outside it")
            assert.are.equal(0.5, audio:groupGain("sfx"))

            audio:play(clip, { gain = 0.4, group = "sfx" })
            assert.are.equal(0.2, backend.tracks[3].gain)
            audio:destroy()
        end)

        it("pauses and resumes a group through the mixer's tags", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip, { group = "sfx" })
            local other = audio:play(clip)

            audio:pauseGroup("sfx")
            assert.are.same({ op = "pause", tag = "sfx" }, backend.tagOps[1])
            assert.is_true(backend.tracks[1].paused)
            assert.is_false(backend.tracks[2].paused, "and only that group")
            assert.is_true(audio:paused(voice))
            assert.is_false(audio:paused(other))

            audio:update(1 / 60)
            assert.is_true(audio:playing(voice), "a paused voice is held, not finished")
            assert.are.equal(2, audio:sounding())

            audio:resumeGroup("sfx")
            assert.are.equal("resume", backend.tagOps[2].op)
            assert.is_false(backend.tracks[1].paused)
            assert.is_false(audio:paused(voice))
            audio:destroy()
        end)

        it("stops a group at once", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip, { group = "sfx" })
            local other = audio:play(clip, { group = "music" })

            audio:stopGroup("sfx")
            assert.are.equal("stop", backend.tagOps[1].op)
            assert.are.equal(0, backend.tagOps[1].fadeMs)
            assert.is_false(audio:playing(voice))
            assert.is_true(audio:playing(other))
            assert.are.equal(1, audio:sounding())
            audio:destroy()
        end)

        it("stops a group over a fade", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip, { group = "music" })

            audio:stopGroup("music", 1.5)
            assert.are.equal(1500, backend.tagOps[1].fadeMs)
            assert.is_true(audio:playing(voice), "a group fading out is still sounding")

            backend.tracks[1].playing = false
            audio:update(1 / 60)
            assert.is_false(audio:playing(voice))
            audio:destroy()
        end)

        it("untags a track when its voice ends, so the next one is clean", function()
            local audio, clip, backend = loaded()
            audio:play(clip, { group = "sfx" })
            backend.tracks[1].playing = false
            audio:update(1 / 60)
            assert.is_nil(backend.tracks[1].tags.sfx)

            audio:play(clip, { group = "music" })
            assert.is_nil(backend.tracks[1].tags.sfx)
            assert.is_true(backend.tracks[1].tags.music)
            audio:destroy()
        end)
    end)

    describe("interned group names", function()
        it("hands out one index per name and reads it back", function()
            local first = Audio.groupId("music")
            assert.are.equal(first, Audio.groupId("music"))
            assert.are_not.equal(first, Audio.groupId("dialogue"))
            assert.are.equal("music", Audio.groupName(first))
            assert.is_nil(Audio.groupName(0), "zero is no group at all")
        end)

        it("refuses a name with nothing in it", function()
            assert.has_error(function()
                Audio.groupId("")
            end)
        end)
    end)

    describe("a paused group", function()
        it("holds a sound that starts after the pause", function()
            local audio, clip, backend = loaded()
            audio:pauseGroup("sfx")
            assert.is_true(audio:groupPaused("sfx"))

            local voice = audio:play(clip, { group = "sfx" })
            assert.is_true(voice > 0, "the pause holds a sound, it does not " .. "refuse one")
            assert.is_true(
                backend.tracks[1].paused,
                "the mixer's tag pause reaches what is sounding when it is "
                    .. "called and ignores everything that starts afterwards"
            )
            assert.is_true(audio:paused(voice))

            audio:update(1 / 60)
            assert.are.equal(1, audio:sounding(), "and a held voice is not reaped")

            audio:resumeGroup("sfx")
            assert.is_false(audio:groupPaused("sfx"))
            assert.is_false(audio:paused(voice))
            assert.is_true(backend.tracks[1].playing)
            audio:destroy()
        end)

        it("holds an entity's sound that starts after the pause", function()
            local audio, clip, backend, world = scene()
            audio:pauseGroup("sfx")
            world:spawn(Audio.Sound(clip.id, 1, 1.0, 1, 1.0, 0, 0, 0, 0, Audio.groupId("sfx")))
            world:update(1 / 60)

            assert.is_true(
                backend.tracks[1].paused,
                "an entity spawned during the menu is the case a sticky " .. "pause exists for"
            )
            audio:destroy()
        end)

        it("leaves a sound outside the group alone", function()
            local audio, clip, backend = loaded()
            audio:pauseGroup("sfx")
            audio:play(clip, { group = "music" })
            audio:play(clip)

            assert.is_false(backend.tracks[1].paused)
            assert.is_false(backend.tracks[2].paused)
            audio:destroy()
        end)

        it("reports a group nothing has paused as running", function()
            local audio = newAudio({ backend = recorder() })
            assert.is_false(audio:groupPaused("sfx"))
            audio:destroy()
        end)
    end)

    describe("mute", function()
        it("silences a group without discarding its gain", function()
            local audio, clip, backend = loaded()
            audio:setGroupGain("sfx", 0.5)
            audio:play(clip, { gain = 1.0, group = "sfx" })
            assert.are.equal(0.5, backend.tracks[1].gain)

            audio:setGroupMuted("sfx", true)
            assert.is_true(audio:groupMuted("sfx"))
            assert.are.equal(0, backend.tracks[1].gain)
            assert.are.equal(
                0.5,
                audio:groupGain("sfx"),
                "setting the gain to zero would lose the level to come back "
                    .. "to, which is what a mute exists instead of"
            )

            audio:setGroupMuted("sfx", false)
            assert.are.equal(0.5, backend.tracks[1].gain)
            audio:destroy()
        end)

        it("silences a voice that joins a muted group later", function()
            local audio, clip, backend = loaded()
            audio:setGroupMuted("sfx", true)
            audio:play(clip, { gain = 1.0, group = "sfx" })
            audio:play(clip, { gain = 1.0, group = "music" })

            assert.are.equal(0, backend.tracks[1].gain)
            assert.are.equal(1.0, backend.tracks[2].gain, "and reaches nothing outside it")
            audio:destroy()
        end)

        it("puts the master on the mixer and does not fan out to the groups", function()
            local audio, clip, backend = loaded()
            audio:setMasterGain(0.8)
            audio:setGroupGain("sfx", 0.5)
            audio:play(clip, { gain = 1.0, group = "sfx" })

            audio:setMuted(true)
            assert.is_true(audio:muted())
            assert.are.equal(0, backend.mixerGain)
            assert.are.equal(0.8, audio:masterGain(), "the level a later unmute returns to")
            assert.is_false(
                audio:groupMuted("sfx"),
                "a master mute that wrote every group's bit would leave " .. "nothing to put back"
            )
            assert.are.equal(
                0.5,
                backend.tracks[1].gain,
                "and one number on the mixer costs the same however many " .. "voices are sounding"
            )

            audio:setMasterGain(0.4)
            assert.are.equal(
                0,
                backend.mixerGain,
                "a slider moved while muted changes what an unmute returns " .. "to and nothing that is audible now"
            )

            audio:setMuted(false)
            assert.are.equal(0.4, backend.mixerGain)
            audio:destroy()
        end)
    end)

    describe("keyed limits", function()
        it("caps how many voices one key holds", function()
            local audio, clip = loaded()
            audio:setLimit("hit", { voices = 3 })

            for _ = 1, 3 do
                assert.is_true(audio:play(clip, { key = "hit" }) > 0)
            end
            assert.are.equal(
                0,
                audio:play(clip, { key = "hit" }),
                "forty enemies dying together do not play forty sounds"
            )
            assert.are.equal(3, audio:keyCount("hit"))
            assert.is_true(audio:play(clip) > 0, "and other sounds still start")
            audio:destroy()
        end)

        it("frees a key's room when a voice ends", function()
            local audio, clip, backend = loaded()
            audio:setLimit("hit", { voices = 1 })
            local voice = audio:play(clip, { key = "hit" })
            assert.are.equal(0, audio:play(clip, { key = "hit" }))

            backend.tracks[1].playing = false
            audio:update(1 / 60)
            assert.are.equal(0, audio:keyCount("hit"))
            assert.is_false(audio:playing(voice))
            assert.is_true(audio:play(clip, { key = "hit" }) > 0)
            audio:destroy()
        end)

        it("refuses a second start inside the cooldown", function()
            local audio, clip = loaded()
            audio:setLimit("hit", { cooldown = 0.05 })

            assert.is_true(audio:play(clip, { key = "hit" }) > 0)
            assert.are.equal(0, audio:play(clip, { key = "hit" }))

            audio:update(0.02)
            assert.are.equal(
                0,
                audio:play(clip, { key = "hit" }),
                "the cooldown is measured against the frames that have run"
            )

            audio:update(0.04)
            assert.is_true(audio:play(clip, { key = "hit" }) > 0)
            audio:destroy()
        end)

        it("composes a limit with a group without either knowing the other", function()
            local audio, clip, backend = loaded()
            audio:setLimit("hit", { voices = 2 })
            audio:setGroupGain("sfx", 0.5)

            local first = audio:play(clip, { gain = 1.0, key = "hit", group = "sfx" })
            audio:play(clip, { gain = 1.0, key = "hit", group = "sfx" })
            assert.are.equal(0, audio:play(clip, { key = "hit", group = "sfx" }), "the key caps the count")
            assert.are.equal(0.5, backend.tracks[1].gain, "and the group sets the gain")
            assert.is_true(backend.tracks[1].tags.sfx)

            -- Stopping through the group also releases the key's count, since
            -- both are torn down when the slot goes back.
            audio:stopGroup("sfx")
            assert.are.equal(0, audio:keyCount("hit"))
            assert.is_false(audio:playing(first))
            audio:destroy()
        end)

        it("counts nothing for a key with no limit", function()
            local audio, clip = loaded()
            for _ = 1, 5 do
                audio:play(clip, { key = "step" })
            end
            assert.are.equal(5, audio:keyCount("step"))
            assert.is_nil(audio:limit("step"))
            audio:destroy()
        end)
    end)

    describe("spatial position", function()
        it("passes a position through and nothing else", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip, { spatial = true, x = 3, y = -1, z = 2 })
            assert.are.same({ x = 3, y = -1, z = 2 }, backend.tracks[1].position)

            audio:setPosition(voice, 4, 0, 0)
            assert.are.same({ x = 4, y = 0, z = 0 }, backend.tracks[1].position)

            audio:clearSpatial(voice)
            assert.is_nil(backend.tracks[1].position)
            audio:destroy()
        end)

        it("leaves an unpositioned voice unpositioned", function()
            local audio, clip, backend = loaded()
            audio:play(clip)
            assert.is_nil(backend.tracks[1].position)
            audio:destroy()
        end)

        it("clears a reused track's position", function()
            local audio, clip, backend = loaded()
            audio:play(clip, { spatial = true, x = 9, y = 9, z = 9 })
            backend.tracks[1].playing = false
            audio:update(1 / 60)
            assert.is_nil(backend.tracks[1].position)

            audio:play(clip)
            assert.is_nil(backend.tracks[1].position, "the next sound on this slot must not inherit a position")
            audio:destroy()
        end)
    end)

    describe("stereo panning", function()
        it("puts a plain left and right gain on the track", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip, { stereo = true, left = 0.8, right = 0.2 })
            assert.are.same(
                { left = 0.8, right = 0.2 },
                backend.tracks[1].stereo,
                "a game on a plane wants a pan, not a listener to subtract from"
            )

            audio:setStereo(voice, 0.1, 0.9)
            assert.are.same({ left = 0.1, right = 0.9 }, backend.tracks[1].stereo)
            audio:destroy()
        end)

        it("defaults both gains to one", function()
            local audio, clip, backend = loaded()
            audio:play(clip, { stereo = true })
            assert.are.same({ left = 1.0, right = 1.0 }, backend.tracks[1].stereo)
            audio:destroy()
        end)

        it("replaces a position rather than layering over it", function()
            -- The mixer keeps one spatialization mode per track: setting a
            -- pan resets the 3D position and setting a position recomputes
            -- the same speaker gains a pan wrote.
            local audio, clip, backend = loaded()
            local voice = audio:play(clip, { spatial = true, x = 3, y = 0, z = 0 })
            assert.are.same({ x = 3, y = 0, z = 0 }, backend.tracks[1].position)

            audio:setStereo(voice, 0.25, 0.75)
            assert.is_nil(backend.tracks[1].position, "the later call is the one that is heard")
            assert.are.same({ left = 0.25, right = 0.75 }, backend.tracks[1].stereo)

            audio:setPosition(voice, 0, 0, -1)
            assert.is_nil(backend.tracks[1].stereo, "and it goes the other way too")
            assert.are.same({ x = 0, y = 0, z = -1 }, backend.tracks[1].position)
            audio:destroy()
        end)

        it("takes the position when a play asks for both", function()
            local audio, clip, backend = loaded()
            audio:play(clip, { spatial = true, x = 1, y = 2, z = 3, stereo = true, left = 0.5, right = 0.5 })
            assert.are.same(
                { x = 1, y = 2, z = 3 },
                backend.tracks[1].position,
                "one of the two has to win, and it must not be whichever the code happens to write last"
            )
            assert.is_nil(backend.tracks[1].stereo)
            audio:destroy()
        end)

        it("leaves both behind on one call", function()
            local audio, clip, backend = loaded()
            local voice = audio:play(clip, { stereo = true, left = 0.3, right = 0.7 })

            audio:clearSpatial(voice)
            assert.is_nil(backend.tracks[1].stereo, "a null to either mode leaves both, so one call answers for them")
            assert.is_nil(backend.tracks[1].position)
            audio:destroy()
        end)

        it("clears a reused track's pan", function()
            local audio, clip, backend = loaded()
            audio:play(clip, { stereo = true, left = 0.0, right = 1.0 })
            backend.tracks[1].playing = false
            audio:update(1 / 60)
            assert.is_nil(backend.tracks[1].stereo)

            audio:play(clip)
            assert.is_nil(backend.tracks[1].stereo, "the next sound on this slot must not inherit a pan")
            audio:destroy()
        end)

        it("reports the placement a voice is in", function()
            local audio, clip = loaded()
            local voice = audio:play(clip, { stereo = true, left = 0.4, right = 0.6 })

            local sounding = audio:voices()
            assert.are.equal(voice, sounding[1].handle)
            assert.is_true(sounding[1].stereo)
            assert.is_false(sounding[1].spatial, "the two are exclusive, so what looks in must not show both")
            assert.are.equal(0.4, sounding[1].left)
            assert.are.equal(0.6, sounding[1].right)
            audio:destroy()
        end)
    end)

    describe("the Sound component", function()
        it("starts a sound the frame its entity appears", function()
            local audio, clip, backend, world = scene()
            local entity = world:spawn(Audio.Sound(clip.id))

            world:update(1 / 60)

            assert.are.equal(1, audio:sounding())
            assert.is_true(backend.tracks[1].playing)
            assert.is_true(world:get(entity, Audio.Sound).voice > 0)
            audio:destroy()
        end)

        it("carries the component's gain to the track", function()
            local audio, clip, backend, world = scene()
            world:spawn(Audio.Sound(clip.id, 1, 0.5))
            world:update(1 / 60)
            assert.are.equal(0.5, backend.tracks[1].gain)
            audio:destroy()
        end)

        it("carries pitch and position", function()
            local audio, clip, backend, world = scene()
            world:spawn(Audio.Sound(clip.id, 1, 1.0, 0, 1.25, 1, 2, 3, 4))
            world:update(1 / 60)

            assert.are.equal(1.25, backend.tracks[1].pitch)
            assert.are.same({ x = 2, y = 3, z = 4 }, backend.tracks[1].position)
            audio:destroy()
        end)

        it("follows a moving sound", function()
            local audio, clip, backend, world = scene()
            local entity = world:spawn(Audio.Sound(clip.id, 1, 1.0, 1, 1.0, 1, 0, 0, 0))
            world:update(1 / 60)

            world:getMut(entity, Audio.Sound).x = 5
            world:update(1 / 60)
            assert.are.equal(5, backend.tracks[1].position.x)

            world:getMut(entity, Audio.Sound).spatial = 0
            world:update(1 / 60)
            assert.is_nil(backend.tracks[1].position)
            audio:destroy()
        end)

        it("stops the sound when its entity goes away", function()
            local audio, clip, backend, world = scene()
            local entity = world:spawn(Audio.Sound(clip.id, 1, 1.0, 1))
            world:update(1 / 60)
            assert.are.equal(1, audio:sounding())

            world:despawn(entity)
            world:update(1 / 60)

            assert.are.equal(0, audio:sounding(), "a looping sound outlives its entity unless something ends it")
            assert.is_false(backend.tracks[1].playing)
            audio:destroy()
        end)

        it("stops the sound when the component is removed", function()
            local audio, clip, backend, world = scene()
            local entity = world:spawn(Audio.Sound(clip.id, 1, 1.0, 1))
            world:update(1 / 60)

            world:remove(entity, Audio.Sound)
            world:update(1 / 60)

            assert.are.equal(0, audio:sounding())
            assert.is_false(backend.tracks[1].playing)
            audio:destroy()
        end)

        it("marks a finished one-shot rather than starting it again", function()
            local audio, clip, backend, world = scene()
            local entity = world:spawn(Audio.Sound(clip.id))
            world:update(1 / 60)

            backend.tracks[1].playing = false
            audio:update(1 / 60)
            world:update(1 / 60)

            assert.are.equal(-1, world:get(entity, Audio.Sound).voice)
            assert.are.equal(0, audio:sounding())

            world:update(1 / 60)
            assert.are.equal(0, audio:sounding(), "a one-shot that ended must not restart every frame")
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

        it("follows a gain, a rate and a loop without a restart", function()
            local audio, clip, backend, world = scene()
            local entity = world:spawn(Audio.Sound(clip.id, 1, 1.0, 1, 1.0))
            world:update(1 / 60)
            local track = backend.tracks[1]
            local voice = world:get(entity, Audio.Sound).voice

            local sound = world:getMut(entity, Audio.Sound)
            sound.gain = 0.25
            sound.pitch = 1.5
            sound.loop = 0
            world:update(1 / 60)

            assert.are.equal(0.25, track.gain)
            assert.are.equal(1.5, track.pitch)
            assert.are.equal(0, track.loops, "a loop cleared part way through lets the voice play out")
            assert.are.equal(1, track.plays, "and none of it starts the sound over")
            assert.are.equal(voice, world:get(entity, Audio.Sound).voice)
            audio:destroy()
        end)

        it("costs no call while nothing on the row moves", function()
            local audio, clip, backend, world = scene()
            world:spawn(Audio.Sound(clip.id, 1, 0.5, 1, 1.25))
            world:update(1 / 60)

            local track = backend.tracks[1]
            local calls = #track.gains
            track.pitch = nil
            track.loops = nil
            for _ = 1, 5 do
                world:update(1 / 60)
            end

            assert.are.equal(calls, #track.gains, "a followed field is a compare, not a call")
            assert.is_nil(track.pitch)
            assert.is_nil(track.loops)
            audio:destroy()
        end)

        it("stops and starts a sound from the playing flag", function()
            local audio, clip, backend, world = scene()
            local entity = world:spawn(Audio.Sound(clip.id, 1, 1.0, 1))
            world:update(1 / 60)
            assert.are.equal(1, audio:sounding())

            world:getMut(entity, Audio.Sound).playing = 0
            world:update(1 / 60)
            assert.are.equal(0, audio:sounding(), "the flag is the instruction, not a report")
            assert.is_false(backend.tracks[1].playing)
            assert.are.equal(0, world:get(entity, Audio.Sound).voice, "and the row is left ready to start again")

            world:getMut(entity, Audio.Sound).playing = 1
            world:update(1 / 60)
            assert.are.equal(1, audio:sounding())
            assert.are.equal(2, backend.tracks[1].plays)
            audio:destroy()
        end)

        it("starts nothing while the flag is clear", function()
            local audio, clip, backend, world = scene()
            local entity = world:spawn(Audio.Sound(clip.id, 0))
            world:update(1 / 60)

            assert.are.equal(0, audio:sounding(), "a sound spawned switched off is not heard once first")
            assert.are.equal(0, #backend.tracks)
            assert.are.equal(0, world:get(entity, Audio.Sound).voice)
            audio:destroy()
        end)

        it("plays a spent one-shot again when the flag is cycled", function()
            local audio, clip, backend, world = scene()
            local entity = world:spawn(Audio.Sound(clip.id))
            world:update(1 / 60)
            backend.tracks[1].playing = false
            audio:update(1 / 60)
            world:update(1 / 60)
            assert.are.equal(-1, world:get(entity, Audio.Sound).voice)

            world:getMut(entity, Audio.Sound).playing = 0
            world:update(1 / 60)
            assert.are.equal(
                0,
                world:get(entity, Audio.Sound).voice,
                "switching off rearms, so the flag says whether the sound is on rather than whether it has run"
            )

            world:getMut(entity, Audio.Sound).playing = 1
            world:update(1 / 60)
            assert.are.equal(1, audio:sounding())
            audio:destroy()
        end)

        it("brings a re-enabled loop back", function()
            local audio, clip, backend, world = scene()
            local entity = world:spawn(Audio.Sound(clip.id, 1, 1.0, 1))
            world:update(1 / 60)
            assert.are.equal(1, audio:sounding())

            world:set(entity, tecs.ecs.Disabled)
            world:update(1 / 60)
            assert.are.equal(0, audio:sounding(), "a disabled entity is not heard")
            assert.is_false(backend.tracks[1].playing)
            assert.are.equal(
                0,
                world:get(entity, Audio.Sound).voice,
                "and the handle goes with it, or re-enabling reads a voice that has gone as one that finished"
            )

            world:remove(entity, tecs.ecs.Disabled)
            world:update(1 / 60)
            assert.are.equal(1, audio:sounding())
            assert.are.equal(2, backend.tracks[1].plays)
            audio:destroy()
        end)

        it("leaves a disabled one-shot that had already finished spent", function()
            local audio, clip, backend, world = scene()
            local entity = world:spawn(Audio.Sound(clip.id))
            world:update(1 / 60)
            backend.tracks[1].playing = false
            audio:update(1 / 60)
            world:update(1 / 60)
            assert.are.equal(-1, world:get(entity, Audio.Sound).voice)

            world:set(entity, tecs.ecs.Disabled)
            world:update(1 / 60)
            world:remove(entity, tecs.ecs.Disabled)
            world:update(1 / 60)

            assert.are.equal(0, audio:sounding(), "a sound that ran out does not come back for being switched off")
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

        it("joins the group its component names", function()
            local audio, clip, backend, world = scene()
            audio:setGroupGain("sfx", 0.5)
            world:spawn(Audio.Sound(clip.id, 1, 0.5, 0, 1.0, 0, 0, 0, 0, Audio.groupId("sfx")))
            world:update(1 / 60)

            assert.is_true(
                backend.tracks[1].tags.sfx,
                "an effects slider that only reached sounds a game started " .. "by hand would reach almost nothing"
            )
            assert.are.equal(
                0.25,
                backend.tracks[1].gain,
                "and the group's gain multiplies what the component asked for"
            )
            audio:destroy()
        end)

        it("reaches an entity's sound through its group", function()
            local audio, clip, backend, world = scene()
            world:spawn(Audio.Sound(clip.id, 1, 1.0, 1, 1.0, 0, 0, 0, 0, Audio.groupId("sfx")))
            world:update(1 / 60)

            audio:pauseGroup("sfx")
            assert.is_true(backend.tracks[1].paused)
            audio:resumeGroup("sfx")

            audio:stopGroup("sfx")
            assert.are.equal(0, audio:sounding())
            audio:destroy()
        end)

        it("leaves a sound naming no group untagged", function()
            local audio, clip, backend, world = scene()
            world:spawn(Audio.Sound(clip.id))
            world:update(1 / 60)
            assert.is_nil(next(backend.tracks[1].tags))
            audio:destroy()
        end)

        it("carries a group's name through a snapshot, not this run's index", function()
            local audio, clip, _, world = scene()
            local entity = world:spawn(Audio.Sound(clip.id, 1, 1.0, 0, 1.0, 0, 0, 0, 0, Audio.groupId("sfx")))
            world:update(1 / 60)

            local saved = world:saveSnapshot({ format = "table" }).snapshot
            assert.is_true(
                holds(saved.archetypes, "sfx"),
                "an index in a file names whatever the next run happens to " .. "intern in its place"
            )

            world:loadSnapshot(saved)
            assert.are.equal(Audio.groupId("sfx"), world:get(entity, Audio.Sound).group)
            audio:destroy()
        end)

        it("resolves a saved group this run has never interned", function()
            local audio, clip, _, world = scene()
            world:spawn(Audio.Sound(clip.id, 1, 1.0, 1, 1.0, 0, 0, 0, 0, Audio.groupId("sfx")))
            world:update(1 / 60)

            -- The name is the only thing the file carries, so rewriting it
            -- moves the sound. A file holding an index could not do this: it
            -- would land on whichever group this run numbered the same.
            local saved = world:saveSnapshot({ format = "table" }).snapshot
            rewrite(saved, "sfx", "cutscene")

            world:loadSnapshot(saved)
            world:update(1 / 60)

            local sounding = audio:voices()
            assert.are.equal(1, #sounding)
            assert.are.equal("cutscene", sounding[1].group)
            audio:destroy()
        end)

        it("survives a round trip through a snapshot", function()
            local audio, clip, _, world = scene()
            local entity = world:spawn(Audio.Sound(clip.id, 1, 0.5, 1, 1.5, 1, 7, 8, 9))
            local hushed = world:spawn(Audio.Sound(clip.id, 0))
            world:update(1 / 60)
            assert.is_true(world:get(entity, Audio.Sound).voice > 0)

            local saved = world:saveSnapshot({ format = "table" }).snapshot
            assert.is_true(holds(saved.archetypes, FIXTURE), "a snapshot carries the path, not this run's index")

            world:loadSnapshot(saved)
            local restored = world:get(entity, Audio.Sound)
            assert.are.equal(clip.id, restored.clip)
            assert.are.equal(1, restored.playing)
            assert.are.equal(
                0,
                world:get(hushed, Audio.Sound).playing,
                "a sound switched off comes back switched off rather than starting on the next pass"
            )
            assert.are.equal(0.5, restored.gain)
            assert.are.equal(1, restored.loop)
            assert.are.equal(1.5, restored.pitch)
            assert.are.equal(1, restored.spatial)
            assert.are.equal(7, restored.x)
            assert.are.equal(9, restored.z)
            assert.are.equal(0, restored.voice, "a restored sound starts again rather than resuming")
            audio:destroy()
        end)
    end)

    describe("the mixer in a snapshot", function()
        it("carries the master and every group's settings", function()
            local audio, _, backend, world = scene()
            audio:setMasterGain(0.3)
            audio:setMuted(true)
            audio:setGroupGain("music", 0.25)
            audio:setGroupMuted("sfx", true)
            audio:pauseGroup("ambience")

            local saved = world:saveSnapshot({ format = "table" }).snapshot

            audio:setMasterGain(1.0)
            audio:setMuted(false)
            audio:setGroupGain("music", 1.0)
            audio:setGroupMuted("sfx", false)
            audio:resumeGroup("ambience")

            world:loadSnapshot(saved)

            assert.are.equal(0.3, audio:masterGain(), "none of this is in the world, so nothing else would carry it")
            assert.is_true(audio:muted())
            assert.are.equal(0, backend.mixerGain)
            assert.are.equal(0.25, audio:groupGain("music"))
            assert.is_true(audio:groupMuted("sfx"))
            assert.is_true(audio:groupPaused("ambience"))
            audio:destroy()
        end)

        it("puts a group the snapshot does not name back to its defaults", function()
            local audio, _, _, world = scene()
            local saved = world:saveSnapshot({ format = "table" }).snapshot

            audio:setGroupGain("menu", 0.1)
            audio:setGroupMuted("menu", true)
            audio:pauseGroup("menu")
            world:loadSnapshot(saved)

            assert.are.equal(
                1.0,
                audio:groupGain("menu"),
                "a load is the saved state, not the saved state merged over " .. "whatever this run had set"
            )
            assert.is_false(audio:groupMuted("menu"))
            assert.is_false(audio:groupPaused("menu"))
            audio:destroy()
        end)

        it("reaches the voices already sounding", function()
            local audio, clip, backend, world = scene()
            audio:setGroupGain("sfx", 0.25)
            local saved = world:saveSnapshot({ format = "table" }).snapshot

            audio:setGroupGain("sfx", 1.0)
            audio:play(clip, { gain = 1.0, group = "sfx" })
            assert.are.equal(1.0, backend.tracks[1].gain)

            world:loadSnapshot(saved)
            assert.are.equal(
                0.25,
                backend.tracks[1].gain,
                "a restored level that only reached later sounds would leave " .. "what is playing at the wrong volume"
            )
            audio:destroy()
        end)

        it("leaves keyed limits to the build rather than to the file", function()
            local audio, _, _, world = scene()
            audio:setLimit("hit", { voices = 3 })
            local saved = world:saveSnapshot({ format = "table" }).snapshot

            -- A limit is a rule the build states at startup beside the clip
            -- it governs. Restoring one would let an old save override a rule
            -- the build has since changed.
            audio:setLimit("hit", { voices = 1 })
            world:loadSnapshot(saved)
            assert.are.equal(1, audio:limit("hit").voices)
            audio:destroy()
        end)
    end)

    describe("the debug surface", function()
        it("reports the mixer, the clips and the voices sounding", function()
            local audio, clip, _, world = scene()
            mcpTools.bind(nil, world)

            audio:setMasterGain(0.5)
            audio:setGroupGain("sfx", 0.25)
            audio:setGroupMuted("music", true)
            audio:pauseGroup("ambience")
            audio:setLimit("hit", { voices = 3, cooldown = 0.05 })
            local voice = audio:play(clip, { group = "sfx", key = "hit" })

            local result = callTool("audio")
            assert.is_falsy(result.isError, tostring(result.content and result.content[1] and result.content[1].text))
            local reported = result.structuredContent

            assert.is_true(reported.available)
            assert.are.equal(0.5, reported.masterGain)
            assert.is_false(reported.muted)
            assert.are.equal(1, reported.sounding)
            assert.are.equal(0, reported.loading)

            local groups = {}
            for _, group in ipairs(reported.groups) do
                groups[group.name] = group
            end
            assert.are.equal(0.25, groups.sfx.gain)
            assert.are.equal(1, groups.sfx.voices)
            assert.is_true(groups.music.muted)
            assert.is_true(groups.ambience.paused, "a group holding nothing yet still holds what starts")

            assert.are.equal(1, #reported.voices)
            assert.are.equal(
                voice,
                reported.voices[1].handle,
                "the handle stop and playing take, so what this shows can be " .. "acted on"
            )
            assert.are.equal(FIXTURE, reported.voices[1].clip)
            assert.are.equal("sfx", reported.voices[1].group)

            local keys = {}
            for _, key in ipairs(reported.keys) do
                keys[key.key] = key
            end
            assert.are.equal(3, keys.hit.voices)
            assert.are.equal(1, keys.hit.count)

            assert.are.equal(FIXTURE, reported.clips[1].path)
            assert.are.equal("ready", reported.clips[1].status)
            audio:destroy()
        end)

        it("says why rather than failing when no audio is installed", function()
            mcpTools.bind(nil, tecs.ecs.newWorld())
            local result = callTool("audio")
            assert.is_true(result.isError)
            assert.is_truthy(result.content[1].text:find("no audio", 1, true))
        end)

        it("stops answering for a world once the mixer is destroyed", function()
            -- Nothing can open an output again, so a world still naming a
            -- destroyed mixer would answer every reader with one that can
            -- only report itself unavailable. Two worlds because `install`
            -- takes a world and the mixer holds no reference to any of them.
            local audio, _, _, world = scene()
            local second = tecs.ecs.newWorld()
            audio:install(second)
            assert.are.equal(audio, Audio.of(world))
            assert.are.equal(audio, Audio.of(second))

            audio:destroy()

            assert.is_nil(Audio.of(world))
            assert.is_nil(Audio.of(second), "every world it was installed into, not just the last")

            mcpTools.bind(nil, world)
            local result = callTool("audio")
            assert.is_true(
                result.isError,
                "so the debug tool says none is installed rather than " .. "reporting on a mixer that has gone"
            )
        end)
    end)

    describe("no output", function()
        it("keeps working when no mixer opens", function()
            local backend = recorder({ silent = true })
            local audio = newAudio({ backend = backend })
            local clip = audio:load(FIXTURE):wait().value

            assert.is_false(audio.available)
            assert.are.equal("ready", clip.status, "loading does not need an output")
            assert.are.equal(0, audio:play(clip))
            assert.are.equal(0, audio:sounding())
            assert.are.equal(0, #backend.tracks)
            audio:update(1 / 60)
            audio:setMasterGain(0.5)
            audio:setMuted(true)
            audio:setGroupGain("sfx", 0.5)
            audio:setGroupMuted("sfx", true)
            audio:pauseGroup("sfx")
            assert.is_true(
                audio:groupPaused("sfx"),
                "the settings are recorded whether or not there is an output "
                    .. "to send them to, so a snapshot carries them either way"
            )
            audio:resumeGroup("sfx")
            audio:stopGroup("sfx")
            audio:stopAll()
            audio:destroy()
        end)
    end)

    describe("shutdown", function()
        it("closes the mixer and destroys every track", function()
            local audio, clip, backend = loaded()
            audio:play(clip)
            audio:play(clip)
            audio:destroy()

            assert.are.equal(1, backend.closes)
            assert.are.equal(backend.mixer, backend.closed)
            for _, track in ipairs(backend.tracks) do
                assert.is_true(track.destroyed)
                assert.is_false(track.playing)
            end
            assert.are.equal(0, audio:sounding())
        end)
    end)
end)
