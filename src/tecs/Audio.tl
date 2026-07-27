--- Sound output, rooted at `app.audio`.
---
--- **The mixer decodes.** A clip is whatever SDL_mixer's decoders can read:
--- WAV, AIFF, VOC, AU, Ogg Vorbis, Opus, FLAC, MP3 and WavPack, depending on
--- what the build linked. `Audio.decoders` reports what this one has, which is
--- the only honest answer: a decoder whose dependency was missing at configure
--- time is dropped without complaint.
---
--- **A voice is a track.** The mixer sums every track on it into the buffer
--- the hardware reads, so playing the same clip three times over is three
--- tracks reading one clip, not three copies added together by this code.
---
--- **Resident or streamed.** A clip under `streamSeconds` is decoded once, up
--- front, and every voice reads the same PCM: that is what a sound effect
--- played forty times a second wants. A clip at or over it holds nothing, and
--- each voice opens the file and decodes as it plays: that is what a piece of
--- music wants, and it is also what a clip whose length the file cannot state
--- gets, because a file that will not say how long it is may be very long.
--- `load` takes `stream` to override the threshold either way.
---
--- **Loading is off the main thread.** A clip is read on the asset worker and
--- handed back as an address, the same route a decoded image takes. A load
--- never blocks a frame; the clip reports that it is still loading and `play`
--- declines until it is not.
---
--- **Nothing runs on an audio thread.** SDL_mixer can call back when a track
--- stops, and that callback fires on a thread the Lua VM did not create. A Lua
--- function invoked from such a thread is the unsafe case that keeps raw thread
--- creation unexposed (see `native/worker.c`), so no callback is installed and
--- `update` asks each sounding voice whether it is still playing instead. The
--- cost is that a voice is reaped on the frame after it ended rather than the
--- instant it did, which nothing here needs to be sooner.
---
--- **Limits are ours; groups are the mixer's.** A group is a tag, and the
--- mixer pauses, resumes and stops every voice carrying one. A key is a limit
--- bucket counted here, because the mixer has no notion of "at most three of
--- these at once, and not twice inside fifty milliseconds", which is what keeps
--- forty enemies dying together from playing forty identical sounds.
---
--- **Position is passed through and nothing else.** See `Sound` for what a
--- caller still has to do by hand.

local ecs <const> = require("tecs.ecs")
local assets <const> = require("tecs.assets")
local loader <const> = require("tecs.ffi.loader")
local sdl3mixer <const> = require("tecs.ffi.sdl3mixer")
local adapter <const> = require("tecs.platform.adapter")
local audiobackend <const> = require("tecs.platform.audiobackend")
local log <const> = require("tecs.log")

local type Backend = audiobackend.Backend
local type Component = ecs.Component

local LOGGER <const> = log.get("tecs.audio")

--- Frames per second the output runs at, unless configured otherwise.
local DEFAULT_FREQUENCY <const> = 48000
--- Output channels. Two, because that is what a stereo mix needs and mono
--- hardware is the platform's problem rather than this one's.
local DEFAULT_CHANNELS <const> = 2
--- Voices that may sound at once. Past this, `play` declines rather than
--- stealing: a sound that stops halfway through because something else
--- started is harder to explain than one that never started.
local DEFAULT_MAX_VOICES <const> = 32
--- Seconds past which a clip streams rather than being held in memory.
---
--- Ten is long enough that no sound effect reaches it and short enough that no
--- piece of music misses it.
local DEFAULT_STREAM_SECONDS <const> = 10.0

--- Slots a voice handle reserves for its index. The rest of the handle is a
--- generation, so a handle to a voice that has finished and been reused
--- refers to nothing rather than to whatever took its place.
local SLOT_SPAN <const> = 65536
--- Generations wrap here, which keeps a handle inside a signed 32-bit field
--- and so inside the `Sound` component.
local MAX_GENERATION <const> = 32767

--- A voice that has finished, as written back into `Sound.voice`.
---
--- Distinct from zero, which means "not started yet". Without the
--- distinction a one-shot would restart on the frame after it ended, forever.
local FINISHED <const> = -1

--- What `MIX_PlayTrack` is told to repeat forever.
local LOOP_FOREVER <const> = -1

-------------------------------------------------------------------------------
-- Interned clip names
-------------------------------------------------------------------------------

--- A clip's path is its identity, for the same reason an image's name is: the
--- integer a component carries is handed out in load order, and load order is
--- not something a snapshot can rely on reproducing.
local clipIds: {string: integer} = {}
local clipPaths: {integer: string} = {}
local clipCount = 0

--- Index of a clip path, assigning one the first time it is seen.
---
--- Indices start at one, so zero is the index of no clip at all and that is
--- what a `Sound` carries until something names one.
local function clipId(path: string): integer
    if path == nil or path == "" then
        error("tecs: a clip path cannot be empty", 2)
    end
    local id = clipIds[path]
    if id ~= nil then return id end
    clipCount = clipCount + 1
    clipIds[path] = clipCount
    clipPaths[clipCount] = path
    return clipCount
end

-------------------------------------------------------------------------------
-- The component
-------------------------------------------------------------------------------

--- A sound attached to an entity.
---
--- Presence is the instruction: an entity carrying this with a loaded clip
--- starts sounding on the next audio pass, and stops when the component or
--- the entity goes away. That is what makes sound an entity rather than a
--- handle a game has to remember to release, and it is why despawning
--- something mid-sound does the obvious thing.
---
--- Position is passed to the mixer and nothing more. `spatial` switches it on,
--- and `x`, `y` and `z` are read as the mixer reads them: a right-handed
--- system whose listener sits at the origin and cannot be moved, with x
--- positive to the right, y positive up and z positive behind. So a caller with
--- a camera and a world has three jobs this component does not do for it, and
--- doing any of them here would fix answers that belong to a game:
---
--- 1. Subtract the listener. There is no listener component and no rule that
---    the camera is one, so whatever a game decides is listening is what it
---    subtracts before writing these fields.
--- 2. Choose a scale. The mixer attenuates with distance on its own, and how
---    loud a sound a hundred world units away should be is a question about a
---    game's units, not about audio.
--- 3. Decide what a screen-space sound means. A sound on a layer that does not
---    move with the camera has no world position to convert, and the answer is
---    to leave `spatial` at zero.
---
--- No group is named here. A group is a string, an FFI component holds
--- numbers, and interning group names into a second integer space would make
--- the mixer's tags something a snapshot had to reproduce. A game that wants an
--- entity's sound in a group starts it with `play` and holds the handle.
local record Sound is Component
    --- Clip index, from `Audio.clipId`. Zero plays nothing.
    clip: number
    --- 0 to 1, before the master gain.
    gain: number
    --- Nonzero repeats until the component goes away.
    loop: number
    --- Playback rate. 1 is unchanged, 2 is an octave up and half as long.
    pitch: number
    --- Nonzero reads `x`, `y` and `z`; zero mixes without a position.
    spatial: number
    x: number
    y: number
    z: number
    --- Voice the audio pass assigned: zero before it starts, negative once a
    --- one-shot has finished. Written by the engine; setting it back to zero
    --- is how a game asks for the sound again.
    voice: number
end

ecs.newFFIComponent({
    name = "Sound",
    container = Sound,
    fields = {
        { "clip", "int32_t" },
        { "gain", "float" },
        { "loop", "uint8_t" },
        { "pitch", "float" },
        { "spatial", "uint8_t" },
        { "x", "float" },
        { "y", "float" },
        { "z", "float" },
        { "voice", "int32_t" },
    },
    defaults = { 0, 1.0, 0, 1.0, 0, 0.0, 0.0, 0.0, 0 },
    serialize = function(instance: Sound): {string: any}
        return {
            clip = clipPaths[instance.clip as integer],
            gain = instance.gain,
            loop = instance.loop ~= 0,
            pitch = instance.pitch,
            spatial = instance.spatial ~= 0,
            x = instance.x,
            y = instance.y,
            z = instance.z,
        }
    end,
    deserialize = function(_world: ecs.World, data: {string: any}): Sound
        local path = data.clip as string
        local clip = 0
        if path ~= nil and path ~= "" then clip = clipId(path) end
        -- The voice is not restored. A snapshot records that an entity has a
        -- sound, not how far through it the mixer had got, so it starts.
        return Sound(clip, data.gain as number,
            (data.loop as boolean) and 1 or 0,
            (data.pitch as number) or 1.0,
            (data.spatial as boolean) and 1 or 0,
            (data.x as number) or 0.0, (data.y as number) or 0.0,
            (data.z as number) or 0.0)
    end,
})

-------------------------------------------------------------------------------
-- Types
-------------------------------------------------------------------------------

--- One playback in progress. Internal: a game holds the integer handle.
local record Voice
    track: loader.CPtr
    clip: Audio.Clip
    --- What the game asked for, before the group and the master.
    gain: number
    --- The value last pushed to the track, so an unchanged gain costs nothing
    --- per frame.
    applied: number
    --- The rate last pushed to the track, for the same reason and because a
    --- reused track keeps whatever the last voice set.
    pitch: number
    --- Group tag, or nil.
    group: string
    --- Limit bucket, or nil.
    key: string
    --- Rises each time the slot is taken, so a stale handle is inert.
    generation: integer
    sounding: boolean
    --- Set while a stop is fading out. Such a voice keeps its slot until the
    --- mixer says it has finished, and takes no further instruction.
    stopping: boolean
    --- Tracked here because a paused track reports that it is not playing, and
    --- reaping on that alone would collect everything a group paused.
    paused: boolean
    --- True when a `Sound` component started this, and so when the audio pass
    --- is the thing that decides it should stop.
    owned: boolean
    --- Set by the pass that walks `Sound` rows, cleared before each walk.
    referenced: boolean
    --- Last position pushed, so an unmoved sound costs nothing per frame.
    spatial: boolean
    x: number
    y: number
    z: number
end

--- How many of one key are sounding, and when one last started.
local record Bucket
    count: integer
    last: number
end

local record Audio
    record Config
        --- Frames per second. Defaults to 48000.
        frequency: integer
        --- Output channels. Defaults to 2.
        channels: integer
        --- Voices that may sound at once. Defaults to 32.
        maxVoices: integer
        --- Seconds at which a clip streams instead of being held resident.
        --- Defaults to 10.
        streamSeconds: number
        --- Output backend. Defaults to the installed platform's.
        backend: Backend
    end

    --- A loaded sound.
    record Clip
        path: string
        --- Index of `path`, which is what a `Sound` component carries.
        id: integer
        --- "loading", "ready", "failed", or "released" once the audio object
        --- it was loaded into has been destroyed.
        status: string
        --- Set when loading failed.
        error: string
        --- Seconds of audio, or zero when the file cannot say.
        duration: number
        --- Whether the decoded audio is held in memory. False for a clip each
        --- voice reads from the file for itself.
        resident: boolean
        _handle: assets.Handle
    end

    record LoadOptions
        --- Forces streaming when true and residency when false. Left unset,
        --- the clip's duration decides against `streamSeconds`.
        stream: boolean
    end

    record PlayOptions
        --- 0 to 1, before the group and the master gains. Defaults to 1.
        gain: number
        --- Repeats until stopped. Defaults to false.
        loop: boolean
        --- Seconds from the start of the clip a repeat returns to, so an
        --- intro can play once and the rest of it loop. Defaults to 0.
        loopStart: number
        --- Seconds into the clip the first pass begins. Defaults to 0.
        start: number
        --- Seconds of silence-to-full at the start. Defaults to 0.
        fadeIn: number
        --- Playback rate. 1 is unchanged. Defaults to 1.
        pitch: number
        --- Fraction of `pitch` to vary by, chosen anew for each voice. 0.1
        --- spreads voices over plus or minus a tenth. Defaults to 0.
        pitchVariance: number
        --- Group this voice joins. Defaults to none.
        group: string
        --- Limit bucket this voice counts against. Defaults to none.
        key: string
        --- Position, when `spatial`. See `Sound` for what the numbers mean.
        spatial: boolean
        x: number
        y: number
        z: number
    end

    --- What a key allows.
    record Limit
        --- Voices this key may hold at once. Zero or absent is no ceiling.
        voices: integer
        --- Seconds after one starts before another may. Zero is none.
        cooldown: number
    end

    Sound: Sound

    --- Whether an output opened. False on a machine with no sound, where
    --- every call here still works and nothing is heard.
    available: boolean

    _backend: Backend
    _mixer: loader.CPtr
    _spec: audiobackend.Spec
    _params: audiobackend.PlayParams
    _voices: {Voice}
    _free: {integer}
    _sounding: integer
    _streamMs: integer
    _masterGain: number
    _groupGains: {string: number}
    _limits: {string: Audio.Limit}
    _buckets: {string: Bucket}
    _clips: {integer: Clip}
    _loading: {Clip}
    --- Seconds `update` has been told about, which is what a cooldown is
    --- measured against.
    _now: number
end

local AudioMT <const>: metatable<Audio> = { __index = Audio }

--- Takes finished loads. Declared here and defined below, because shutting
--- down has to drain what is in flight and shutting down is described first.
local resolveLoads: function(self: Audio): integer

Audio.Sound = Sound

--- Index of a clip path, assigning one the first time it is seen.
function Audio.clipId(path: string): integer
    return clipId(path)
end

--- Path a clip index stands for, or nil when it names nothing.
function Audio.clipPath(id: integer): string
    return clipPaths[id]
end

--- The decoders this build linked, in the mixer's own order.
---
--- What a build asked for and what it got are different questions: a decoder
--- whose dependency was not found is dropped silently. This answers the second.
function Audio.decoders(): {string}
    if not sdl3mixer.init() then return {} end
    return sdl3mixer.decoders()
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

--- Opens the platform's default output.
---
--- Never raises for want of hardware. A machine with no sound card gets an
--- object whose calls all succeed and produce nothing, because a game that
--- cannot be played without an audio device is rarer than a test machine
--- without one.
function Audio.create(config?: Audio.Config): Audio
    local given = config or {} as Audio.Config
    local self = setmetatable({} as Audio, AudioMT)

    self._backend = given.backend or adapter.current().audio or audiobackend.sdl
    self._spec = {
        frequency = given.frequency or DEFAULT_FREQUENCY,
        channels = given.channels or DEFAULT_CHANNELS,
    }
    self._streamMs = math.floor(
        (given.streamSeconds or DEFAULT_STREAM_SECONDS) * 1000)

    local maxVoices = given.maxVoices or DEFAULT_MAX_VOICES
    if maxVoices < 1 or maxVoices >= SLOT_SPAN then
        error(("tecs: maxVoices must be between 1 and %d"):format(
            SLOT_SPAN - 1), 2)
    end
    self._voices = {}
    self._free = {}
    for slot = 1, maxVoices do
        self._voices[slot] = {
            gain = 1.0, applied = -1.0, pitch = 1.0, generation = 0,
            sounding = false, stopping = false, paused = false, owned = false,
            referenced = false, spatial = false, x = 0.0, y = 0.0, z = 0.0,
        }
        -- Taken from the end, so the first sound of a run uses slot one and a
        -- log or a snapshot reads in the order things happened.
        self._free[slot] = maxVoices + 1 - slot
    end

    self._sounding = 0
    self._masterGain = 1.0
    self._groupGains = {}
    self._limits = {}
    self._buckets = {}
    self._clips = {}
    self._loading = {}
    self._now = 0.0
    -- One options record, overwritten per play. Every field is set each time,
    -- so nothing carries over from the previous voice.
    self._params = { loops = 0, loopStartMs = 0, fadeInMs = 0, startMs = 0 }

    self._mixer = self._backend.open(self._spec)
    self.available = self._mixer ~= nil
    if not self.available then
        LOGGER:info("no audio output; sound is silent for this run")
    end
    return self
end

--- Stops everything and closes the output.
function Audio:destroy()
    -- Drained first. A clip that arrived after the mixer had gone would hold a
    -- pointer into a library that has released everything it made.
    if #self._loading > 0 then
        assets.waitAll()
        resolveLoads(self)
    end

    for slot = 1, #self._voices do
        local voice = self._voices[slot]
        if voice.track ~= nil then
            if voice.sounding then self._backend.stop(voice.track, 0) end
            self._backend.destroyTrack(voice.track)
            voice.track = nil
        end
        voice.sounding = false
        voice.stopping = false
        voice.paused = false
    end
    self._sounding = 0
    self._buckets = {}

    for _, clip in pairs(self._clips) do
        if clip._handle ~= nil then
            clip._handle:release()
            clip._handle = nil
        end
        clip.resident = false
        clip.status = "released"
    end
    self._clips = {}
    self._loading = {}

    if self._mixer ~= nil then
        self._backend.close(self._mixer)
        self._mixer = nil
    end
    self.available = false
end

-------------------------------------------------------------------------------
-- Clips
-------------------------------------------------------------------------------

--- Queues a sound for loading and returns its clip immediately.
---
--- Loading the same path twice returns the same clip; a clip is the file, and
--- playing it twice over is two voices reading one clip. `options.stream`
--- overrides the duration threshold that otherwise decides whether the clip is
--- held in memory.
function Audio:load(path: string, options?: Audio.LoadOptions): Audio.Clip
    local id = clipId(path)
    local existing = self._clips[id]
    if existing ~= nil then return existing end

    -- The worker is what reads the file, and a game that only ever plays
    -- sound has no other reason to have started it.
    if not assets.installed() then assets.install() end

    local given = options or {} as Audio.LoadOptions
    local mode = "auto"
    if given.stream == true then
        mode = "stream"
    elseif given.stream == false then
        mode = "resident"
    end

    local clip: Audio.Clip = {
        path = path,
        id = id,
        status = "loading",
        duration = 0.0,
        resident = false,
        _handle = assets.loadSound(path, mode, self._streamMs),
    }
    self._clips[id] = clip
    self._loading[#self._loading + 1] = clip
    return clip
end

--- The clip an index stands for, or nil when this instance has not loaded it.
function Audio:clip(id: integer): Audio.Clip
    return self._clips[id]
end

--- Takes finished loads. Called by `update`.
resolveLoads = function(self: Audio): integer
    local waiting = #self._loading
    if waiting == 0 then return 0 end
    assets.update()

    local resolved = 0
    local kept: {Audio.Clip} = {}
    for index = 1, waiting do
        local clip = self._loading[index]
        local handle = clip._handle
        if handle.status == "loading" then
            kept[#kept + 1] = clip
        elseif handle.status == "ready" then
            clip.resident = handle.resident
            clip.duration = handle.durationMs >= 0
                and handle.durationMs / 1000 or 0.0
            clip.status = "ready"
            resolved = resolved + 1
        else
            clip.status = "failed"
            clip.error = handle.error
            LOGGER:error("cannot load '%s': %s", clip.path,
                handle.error or "unknown")
            resolved = resolved + 1
        end
    end
    self._loading = kept
    return resolved
end

--- Blocks until every queued load has finished.
---
--- For startup and tests. A frame should let `update` resolve them instead.
function Audio:waitForLoads(timeoutMs?: number)
    if #self._loading == 0 then return end
    assets.waitAll(timeoutMs)
    resolveLoads(self)
end

--- Clips still being read.
function Audio:loading(): integer
    return #self._loading
end

-------------------------------------------------------------------------------
-- Voices
-------------------------------------------------------------------------------

--- The voice a handle refers to, or nil when it refers to one that has ended.
local function voiceOf(self: Audio, handle: integer): Voice
    if handle == nil or handle <= 0 then return nil end
    local slot = handle % SLOT_SPAN
    local voice = self._voices[slot]
    if voice == nil or not voice.sounding then return nil end
    if voice.generation ~= (handle - slot) / SLOT_SPAN then return nil end
    return voice
end

--- The gain a voice should carry, group included. The master is the mixer's
--- own number and is not multiplied in here.
local function composedGain(self: Audio, voice: Voice): number
    if voice.group == nil then return voice.gain end
    local scale = self._groupGains[voice.group]
    if scale == nil then return voice.gain end
    return voice.gain * scale
end

--- Pushes a voice's gain, skipping the call when nothing changed.
local function applyGain(self: Audio, voice: Voice)
    local applied = composedGain(self, voice)
    if applied == voice.applied then return end
    voice.applied = applied
    self._backend.setGain(voice.track, applied)
end

--- Gives a slot back, untagging and un-counting whatever it held.
local function release(self: Audio, slot: integer)
    local voice = self._voices[slot]
    if not voice.sounding then return end

    if voice.group ~= nil then
        self._backend.untag(voice.track, voice.group)
        voice.group = nil
    end
    if voice.key ~= nil then
        local bucket = self._buckets[voice.key]
        if bucket ~= nil then bucket.count = bucket.count - 1 end
        voice.key = nil
    end
    -- Dropped rather than left attached, so a streamed voice closes its file
    -- and a resident clip stops being referenced by a track nothing plays.
    self._backend.clearTrack(voice.track)

    voice.sounding = false
    voice.stopping = false
    voice.paused = false
    voice.owned = false
    voice.clip = nil
    voice.applied = -1.0
    if voice.spatial then
        self._backend.clearPosition(voice.track)
        voice.spatial = false
    end
    self._sounding = self._sounding - 1
    self._free[#self._free + 1] = slot
end

--- Whether `key` has room for another voice right now.
local function admits(self: Audio, key: string): boolean
    local limit = self._limits[key]
    if limit == nil then return true end
    local bucket = self._buckets[key]
    if bucket == nil then return true end
    if limit.cooldown ~= nil and limit.cooldown > 0
        and self._now - bucket.last < limit.cooldown then
        return false
    end
    if limit.voices ~= nil and limit.voices > 0
        and bucket.count >= limit.voices then
        return false
    end
    return true
end

--- Starts `clip` on a free voice and returns its handle, or zero.
local function start(self: Audio, clip: Audio.Clip, options: Audio.PlayOptions,
                     owned: boolean): integer
    if not self.available then return 0 end
    if clip == nil or clip.status ~= "ready" then return 0 end

    local key = options.key
    if key ~= nil and not admits(self, key) then return 0 end

    local count = #self._free
    if count == 0 then return 0 end
    local slot = self._free[count]
    self._free[count] = nil

    local voice = self._voices[slot]
    if voice.track == nil then
        -- Made on first use rather than at startup, so a game that never
        -- plays anything holds no tracks.
        voice.track = self._backend.createTrack(self._mixer)
        if voice.track == nil then
            self._free[#self._free + 1] = slot
            return 0
        end
    end

    local pointed: boolean
    if clip.resident then
        pointed = self._backend.setTrackClip(voice.track, clip._handle.audio)
    else
        pointed = self._backend.setTrackFile(voice.track, clip.path)
    end
    if not pointed then
        self._free[#self._free + 1] = slot
        return 0
    end

    voice.generation = voice.generation + 1
    if voice.generation > MAX_GENERATION then voice.generation = 1 end
    voice.clip = clip
    voice.gain = options.gain or 1.0
    voice.applied = -1.0
    voice.group = options.group
    voice.key = key
    voice.sounding = true
    voice.stopping = false
    voice.paused = false
    voice.owned = owned
    voice.referenced = false

    if voice.group ~= nil then self._backend.tag(voice.track, voice.group) end
    applyGain(self, voice)

    local pitch = options.pitch or 1.0
    local variance = options.pitchVariance or 0.0
    if variance ~= 0.0 then
        pitch = pitch * (1.0 + (math.random() * 2.0 - 1.0) * variance)
    end
    -- Compared against what this track already carries, not against one,
    -- because a reused slot would otherwise keep the last voice's rate.
    if pitch ~= voice.pitch then
        self._backend.setPitch(voice.track, pitch)
        voice.pitch = pitch
    end

    voice.spatial = options.spatial == true
    if voice.spatial then
        voice.x = options.x or 0.0
        voice.y = options.y or 0.0
        voice.z = options.z or 0.0
        self._backend.setPosition(voice.track, voice.x, voice.y, voice.z)
    end

    local params = self._params
    params.loops = options.loop == true and LOOP_FOREVER or 0
    params.loopStartMs = math.floor((options.loopStart or 0.0) * 1000)
    params.startMs = math.floor((options.start or 0.0) * 1000)
    params.fadeInMs = math.floor((options.fadeIn or 0.0) * 1000)

    if not self._backend.play(voice.track, params) then
        if voice.group ~= nil then
            self._backend.untag(voice.track, voice.group)
            voice.group = nil
        end
        -- Dropped here as well as in `release`, because a slot that never
        -- started is not released and a streamed input would stay open.
        self._backend.clearTrack(voice.track)
        voice.sounding = false
        voice.key = nil
        self._free[#self._free + 1] = slot
        return 0
    end

    if key ~= nil then
        local bucket = self._buckets[key]
        if bucket == nil then
            bucket = { count = 0, last = 0.0 }
            self._buckets[key] = bucket
        end
        bucket.count = bucket.count + 1
        bucket.last = self._now
    end

    self._sounding = self._sounding + 1
    return voice.generation * SLOT_SPAN + slot
end

--- Plays `clip`, returning a handle, or zero when it did not start.
---
--- Zero means the clip is not loaded, loading failed, a key's limit or
--- cooldown declined it, every voice is busy, or the machine has no output.
--- None of those is worth raising over: a sound that does not play is not a
--- reason for a frame to stop.
function Audio:play(clip: Audio.Clip, options?: Audio.PlayOptions): integer
    return start(self, clip, options or {} as Audio.PlayOptions, false)
end

--- Stops a voice. A handle to one that already ended does nothing.
---
--- `fadeOut` seconds keeps the voice sounding while it fades, so `playing`
--- stays true until `update` sees the mixer finish it.
function Audio:stop(handle: integer, fadeOut?: number)
    local voice = voiceOf(self, handle)
    if voice == nil or voice.stopping then return end
    local seconds = fadeOut or 0.0
    if seconds <= 0.0 then
        self._backend.stop(voice.track, 0)
        release(self, handle % SLOT_SPAN)
        return
    end
    self._backend.stop(voice.track, math.floor(seconds * 1000))
    voice.stopping = true
end

--- Stops everything, at once.
function Audio:stopAll()
    for slot = 1, #self._voices do
        local voice = self._voices[slot]
        if voice.sounding then
            self._backend.stop(voice.track, 0)
            release(self, slot)
        end
    end
end

--- Whether a handle still names a sounding voice. A paused or fading voice
--- still counts: it has not finished.
function Audio:playing(handle: integer): boolean
    return voiceOf(self, handle) ~= nil
end

--- Whether a handle names a voice a pause is holding.
function Audio:paused(handle: integer): boolean
    local voice = voiceOf(self, handle)
    return voice ~= nil and voice.paused
end

--- Holds a voice where it is. It keeps its slot until something resumes or
--- stops it, because a paused voice has not finished.
function Audio:pause(handle: integer)
    local voice = voiceOf(self, handle)
    if voice == nil or voice.paused or voice.stopping then return end
    voice.paused = true
    self._backend.pause(voice.track)
end

--- Lets a paused voice carry on.
function Audio:resume(handle: integer)
    local voice = voiceOf(self, handle)
    if voice == nil or not voice.paused then return end
    voice.paused = false
    self._backend.resume(voice.track)
end

--- Sets a voice's gain, before its group and the master.
function Audio:setGain(handle: integer, gain: number)
    local voice = voiceOf(self, handle)
    if voice == nil then return end
    voice.gain = gain
    applyGain(self, voice)
end

--- Sets a voice's playback rate. 1 is unchanged.
function Audio:setPitch(handle: integer, ratio: number)
    local voice = voiceOf(self, handle)
    if voice == nil or voice.pitch == ratio then return end
    voice.pitch = ratio
    self._backend.setPitch(voice.track, ratio)
end

--- Places a voice in space. See `Sound` for what the numbers mean.
function Audio:setPosition(handle: integer, x: number, y: number, z: number)
    local voice = voiceOf(self, handle)
    if voice == nil then return end
    if voice.spatial and voice.x == x and voice.y == y and voice.z == z then
        return
    end
    voice.spatial = true
    voice.x = x
    voice.y = y
    voice.z = z
    self._backend.setPosition(voice.track, x, y, z)
end

--- Returns a voice to unpositioned mixing.
function Audio:clearPosition(handle: integer)
    local voice = voiceOf(self, handle)
    if voice == nil or not voice.spatial then return end
    voice.spatial = false
    self._backend.clearPosition(voice.track)
end

--- Scales everything. One number on the mixer, so this costs the same whether
--- one voice is sounding or every voice is.
function Audio:setMasterGain(gain: number)
    self._masterGain = gain
    if self._mixer ~= nil then self._backend.setMixerGain(self._mixer, gain) end
end

--- The master gain.
function Audio:masterGain(): number
    return self._masterGain
end

--- Voices sounding right now, including paused and fading ones.
function Audio:sounding(): integer
    return self._sounding
end

-------------------------------------------------------------------------------
-- Groups
-------------------------------------------------------------------------------

--- Scales every voice in a group, and every voice that joins it later.
---
--- Composed here rather than through the mixer's per-tag gain, which writes
--- each tagged track's own gain and would overwrite what the voice asked for.
function Audio:setGroupGain(name: string, gain: number)
    self._groupGains[name] = gain
    for slot = 1, #self._voices do
        local voice = self._voices[slot]
        if voice.sounding and voice.group == name then
            applyGain(self, voice)
        end
    end
end

--- A group's gain. 1 for one nothing has set.
function Audio:groupGain(name: string): number
    return self._groupGains[name] or 1.0
end

--- Holds every voice in a group where it is.
function Audio:pauseGroup(name: string)
    if self._mixer == nil then return end
    self._backend.pauseTag(self._mixer, name)
    for slot = 1, #self._voices do
        local voice = self._voices[slot]
        if voice.sounding and voice.group == name then voice.paused = true end
    end
end

--- Lets a paused group carry on.
function Audio:resumeGroup(name: string)
    if self._mixer == nil then return end
    self._backend.resumeTag(self._mixer, name)
    for slot = 1, #self._voices do
        local voice = self._voices[slot]
        if voice.sounding and voice.group == name then voice.paused = false end
    end
end

--- Ends every voice in a group, over `fadeOut` seconds if that is given.
---
--- A faded stop leaves the voices sounding until they finish, so they are
--- reaped by `update` rather than here.
function Audio:stopGroup(name: string, fadeOut?: number)
    if self._mixer == nil then return end
    local seconds = fadeOut or 0.0
    self._backend.stopTag(self._mixer, name, math.floor(seconds * 1000))
    for slot = 1, #self._voices do
        local voice = self._voices[slot]
        if voice.sounding and voice.group == name then
            if seconds > 0.0 then
                voice.stopping = true
                -- A paused voice does not advance, so a fade on one would
                -- never finish and the slot would never come back.
                voice.paused = false
            else
                release(self, slot)
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Keyed limits
-------------------------------------------------------------------------------

--- Caps how many voices a key may hold and how often it may start one.
---
--- A key is not a group. A group says where a sound's gain comes from and what
--- a pause reaches; a key says how many of one sound the mix will carry. The
--- two are set independently on `play`, so "at most three footsteps at once,
--- all of them in the effects group" is the ordinary case and neither name has
--- to know about the other.
---
--- Passing nil removes the limit. Voices already sounding are left alone.
function Audio:setLimit(key: string, limit: Audio.Limit)
    self._limits[key] = limit
end

--- The limit a key carries, or nil.
function Audio:limit(key: string): Audio.Limit
    return self._limits[key]
end

--- Voices a key is holding right now.
function Audio:keyCount(key: string): integer
    local bucket = self._buckets[key]
    return bucket ~= nil and bucket.count or 0
end

-------------------------------------------------------------------------------
-- The frame
-------------------------------------------------------------------------------

--- Takes finished loads and reaps the voices the mixer has finished with.
--- Call once per frame, with the frame's step.
---
--- The step is what a cooldown is measured against. Nothing else here needs
--- time: a fade is the mixer's to run, and a voice is over when the mixer says
--- so rather than when a clock here says it should be.
function Audio:update(dt?: number): integer
    self._now = self._now + (dt or 0.0)
    resolveLoads(self)

    for slot = 1, #self._voices do
        local voice = self._voices[slot]
        if voice.sounding and not voice.paused
            and not self._backend.playing(voice.track) then
            release(self, slot)
        end
    end
    return self._sounding
end

-------------------------------------------------------------------------------
-- The entity interface
-------------------------------------------------------------------------------

--- Options `reconcile` fills per row, so a walk over a million sounds
--- allocates nothing.
local rowOptions <const>: Audio.PlayOptions = {}

--- Starts, stops and reaps the voices `Sound` components ask for.
---
--- One walk answers all three. A row with no voice starts one; a row whose
--- voice has ended is marked so it does not start again; and a voice nothing
--- referred to during the walk belonged to an entity that has gone, so it is
--- stopped. That last case is what makes despawning something mid-sound work
--- without an observer on every archetype that might hold one.
local function reconcile(self: Audio, sounds: ecs.Query)
    local voices = self._voices
    for slot = 1, #voices do
        voices[slot].referenced = false
    end

    for archetype, length in sounds:iter() do
        local rows = archetype:get(Sound) as {Sound}
        -- Taken mutable on the first row that actually changes, and not at
        -- all otherwise. Taking it up front would mark the column dirty every
        -- frame for every archetype holding a sound.
        local mutable: {Sound} = nil

        for row = 1, length do
            local entry = rows[row]
            local handle = entry.voice as integer

            if handle == 0 then
                rowOptions.gain = entry.gain as number
                rowOptions.loop = (entry.loop as integer) ~= 0
                rowOptions.pitch = entry.pitch as number
                rowOptions.spatial = (entry.spatial as integer) ~= 0
                rowOptions.x = entry.x as number
                rowOptions.y = entry.y as number
                rowOptions.z = entry.z as number
                local started = start(self,
                    self._clips[entry.clip as integer], rowOptions, true)
                if started ~= 0 then
                    if mutable == nil then
                        mutable = archetype:getMut(Sound) as {Sound}
                    end
                    mutable[row].voice = started
                    voices[started % SLOT_SPAN].referenced = true
                end
            elseif handle > 0 then
                local voice = voiceOf(self, handle)
                if voice == nil then
                    if mutable == nil then
                        mutable = archetype:getMut(Sound) as {Sound}
                    end
                    mutable[row].voice = FINISHED
                else
                    voice.referenced = true
                    if voice.gain ~= entry.gain then
                        self:setGain(handle, entry.gain as number)
                    end
                    if (entry.spatial as integer) ~= 0 then
                        self:setPosition(handle, entry.x as number,
                            entry.y as number, entry.z as number)
                    elseif voice.spatial then
                        self:clearPosition(handle)
                    end
                end
            end
        end
    end

    for slot = 1, #voices do
        local voice = voices[slot]
        if voice.sounding and voice.owned and not voice.referenced then
            self._backend.stop(voice.track, 0)
            release(self, slot)
        end
    end
end

--- Adds the system that plays `Sound` components.
---
--- `update` is not added here. Reaping voices is not world work: it has to
--- keep happening while the world is paused, and an application drives it from
--- the iteration instead.
function Audio:install(world: ecs.World)
    local sounds = world:query({
        name = "tecs.Sounds",
        include = { Sound },
    })

    world:addSystem({
        name = "tecs.PlaySounds",
        -- After gameplay has decided what exists and before anything renders,
        -- so a sound spawned this frame starts this frame.
        phase = ecs.phases.PostUpdate,
        run = function() reconcile(self, sounds) end,
    })
end

return Audio
