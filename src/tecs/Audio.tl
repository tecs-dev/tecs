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
--- **A group's settings outlive the voices in it.** A gain, a mute and a pause
--- are recorded against the name and consulted when a voice starts, so a sound
--- that begins after "hold every effect for the menu" is held rather than
--- heard. The mixer cannot answer that on its own: `MIX_PauseTag` reaches what
--- is sounding at the moment it is called and nothing that starts afterwards.
---
--- **The mixer's own state is in the snapshot.** The master gain, the master
--- mute and every group's gain, mute and pause are a game's state as much as
--- an entity is, and none of them is in the world, so `install` adds a
--- snapshot handler that carries them.
---
--- **Position is passed through and nothing else.** See `Sound` for what a
--- caller still has to do by hand. `setStereo` is the other way to place a
--- voice, a plain left and right gain with no listener and no distance model
--- in it, which is usually what a game laid out on a plane wants. The two are
--- exclusive: the mixer holds one placement per track, so the later call
--- replaces the earlier one rather than layering over it.

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
-- Interned group names
-------------------------------------------------------------------------------

--- A group's name is its identity, for the same reason a clip's path is: the
--- integer a component carries is handed out in the order names are first
--- asked for, and that order is not something a snapshot can rely on
--- reproducing.
local groupIds: {string: integer} = {}
local groupNames: {integer: string} = {}
local groupCount = 0

--- Index of a group name, assigning one the first time it is seen.
---
--- Indices start at one, so zero is the index of no group at all and that is
--- what a `Sound` carries until something names one.
local function groupId(name: string): integer
    if name == nil or name == "" then
        error("tecs: a group name cannot be empty", 2)
    end
    local id = groupIds[name]
    if id ~= nil then return id end
    groupCount = groupCount + 1
    groupIds[name] = groupCount
    groupNames[groupCount] = name
    return groupCount
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
--- A group is named the way a clip is. An FFI component holds numbers, so what
--- `group` carries is an interned index from `Audio.groupId` rather than the
--- mixer's tag itself, and `Audio.groupName` reads it back. The index is this
--- run's and no other, which is why `serialize` writes the name: an integer in
--- a save file would name a different group the next time a build interned its
--- names in a different order.
---
--- `playing`, `gain`, `loop`, `pitch` and the position are followed for as
--- long as the voice sounds, so writing any of them is enough and nothing has
--- to be restarted to make one take. Each of those is a read and a compare per
--- sounding row per frame, which is the price of the component being live and
--- is why `clip` and `group` are not on the list: both take an untag, a
--- retag and a fresh input to change, neither is something a game writes
--- often, and following them would put that cost on every row that never
--- does. Moving a sound into another group is setting `group` and clearing
--- `voice`, which is the same thing changing its clip takes.
---
--- Disabling an entity silences its sound and re-enabling starts it again.
--- `Disabled` is excluded from every query that does not name it, so a
--- disabled row is not followed and its voice is taken back; the audio pass
--- clears the handle at the same moment, which is what lets the sound return
--- with the entity rather than reading as a one-shot that had finished.
local record Sound is Component
    --- Clip index, from `Audio.clipId`. Zero plays nothing.
    clip: number
    --- Nonzero sounds, zero does not. The instruction rather than a report:
    --- clearing it stops the voice and setting it again starts one, including
    --- on a one-shot that has already run out.
    playing: number
    --- 0 to 1, before the master gain.
    gain: number
    --- Nonzero repeats. Clearing it part way through lets the voice play out
    --- to its end rather than cutting it.
    loop: number
    --- Playback rate. 1 is unchanged, 2 is an octave up and half as long.
    pitch: number
    --- Nonzero reads `x`, `y` and `z`; zero mixes without a position.
    spatial: number
    x: number
    y: number
    z: number
    --- Group index, from `Audio.groupId`. Zero joins no group.
    group: number
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
        { "playing", "uint8_t" },
        { "gain", "float" },
        { "loop", "uint8_t" },
        { "pitch", "float" },
        { "spatial", "uint8_t" },
        { "x", "float" },
        { "y", "float" },
        { "z", "float" },
        { "group", "int32_t" },
        { "voice", "int32_t" },
    },
    defaults = { 0, 1, 1.0, 0, 1.0, 0, 0.0, 0.0, 0.0, 0, 0 },
    serialize = function(instance: Sound): {string: any}
        -- Both the clip and the group cross as the names they were interned
        -- from. An index is this run's numbering, and a file that carried one
        -- would name whatever the next run happened to intern in its place.
        return {
            clip = clipPaths[instance.clip as integer],
            playing = instance.playing ~= 0,
            gain = instance.gain,
            loop = instance.loop ~= 0,
            pitch = instance.pitch,
            spatial = instance.spatial ~= 0,
            x = instance.x,
            y = instance.y,
            z = instance.z,
            group = groupNames[instance.group as integer],
        }
    end,
    deserialize = function(_world: ecs.World, data: {string: any}): Sound
        local path = data.clip as string
        local clip = 0
        if path ~= nil and path ~= "" then clip = clipId(path) end
        local name = data.group as string
        local group = 0
        if name ~= nil and name ~= "" then group = groupId(name) end
        -- A file written before `playing` existed carries no answer, and the
        -- one that matches what it recorded is that the sound was on.
        local playing = 1
        if data.playing == false then playing = 0 end
        -- The voice is not restored. A snapshot records that an entity has a
        -- sound, not how far through it the mixer had got, so it starts.
        return Sound(clip, playing, data.gain as number,
            (data.loop as boolean) and 1 or 0,
            (data.pitch as number) or 1.0,
            (data.spatial as boolean) and 1 or 0,
            (data.x as number) or 0.0, (data.y as number) or 0.0,
            (data.z as number) or 0.0, group)
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
    --- Whether the voice is pinned to the front pair rather than placed, and
    --- the gains last pushed for it. The mixer holds one placement per track,
    --- so at most one of this and `spatial` is ever set.
    stereo: boolean
    left: number
    right: number
    --- Whether the voice repeats, as the mixer was last told.
    loop: boolean
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
        --- Pins the voice to the front pair of speakers at `left` and
        --- `right`, which is a pan rather than a position. Ignored when
        --- `spatial` is set, because the mixer holds one placement per track.
        --- Both gains default to 1.
        stereo: boolean
        left: number
        right: number
    end

    --- What a key allows.
    record Limit
        --- Voices this key may hold at once. Zero or absent is no ceiling.
        voices: integer
        --- Seconds after one starts before another may. Zero is none.
        cooldown: number
    end

    --- One sounding voice, as something looking in reads it.
    record VoiceInfo
        --- The handle a game holds, which `playing` and `stop` take.
        handle: integer
        --- Path of the clip it is reading, or nil once it has been released.
        clip: string
        --- What the voice asked for, before its group and the master.
        gain: number
        --- What reached the track, the group's gain and mute included.
        applied: number
        pitch: number
        group: string
        key: string
        paused: boolean
        --- Whether a fade-out is running it down.
        stopping: boolean
        --- Whether a `Sound` component started this rather than `play`.
        owned: boolean
        --- Whether it repeats when it reaches the end.
        loop: boolean
        spatial: boolean
        x: number
        y: number
        z: number
        --- Whether it is pinned to the front pair, and at what gains.
        stereo: boolean
        left: number
        right: number
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
    _muted: boolean
    _groupGains: {string: number}
    _groupMuted: {string: boolean}
    _groupPaused: {string: boolean}
    _limits: {string: Audio.Limit}
    _buckets: {string: Bucket}
    _clips: {integer: Clip}
    _loads: assets.Batch<Audio.Clip>
    --- Seconds `update` has been told about, which is what a cooldown is
    --- measured against.
    _now: number
end

local AudioMT <const>: metatable<Audio> = { __index = Audio }

--- The audio each world had installed into it. Weak, so a world that has gone
--- takes its entry with it.
---
--- Declared here rather than beside `Audio.of`, because `destroy` clears the
--- entries naming it and reads this well before that point in the file.
local installed <const>: {ecs.World: Audio} =
    setmetatable({}, {__mode = "k"} as metatable<{ecs.World: Audio}>)

Audio.Sound = Sound

--- Index of a clip path, assigning one the first time it is seen.
function Audio.clipId(path: string): integer
    return clipId(path)
end

--- Path a clip index stands for, or nil when it names nothing.
function Audio.clipPath(id: integer): string
    return clipPaths[id]
end

--- Index of a group name, assigning one the first time it is seen.
---
--- What a `Sound` carries in `group`. The index means nothing outside the run
--- that handed it out, so it belongs in a component and never in a file.
function Audio.groupId(name: string): integer
    return groupId(name)
end

--- Name a group index stands for, or nil when it names nothing.
function Audio.groupName(id: integer): string
    return groupNames[id]
end

--- The decoders this build linked, in the mixer's own order.
---
--- What a build asked for and what it got are different questions: a decoder
--- whose dependency was not found is dropped silently. This answers the second.
function Audio.decoders(): {string}
    if not sdl3mixer.init() then return {} end
    return sdl3mixer.decoders()
end

--- Takes one finished load into the clip it was read for.
---
--- Shared rather than closed over an instance: nothing here reads the mixer,
--- so every `Audio` hands its batch the same function.
local function settleClip(clip: Audio.Clip, handle: assets.Handle)
    if handle.status == "ready" then
        clip.resident = handle.resident
        clip.duration = handle.durationMs >= 0
            and handle.durationMs / 1000 or 0.0
        clip.status = "ready"
        return
    end
    clip.status = "failed"
    clip.error = handle.error
    LOGGER:error("cannot load '%s': %s", clip.path, handle.error or "unknown")
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
            referenced = false, loop = false,
            spatial = false, x = 0.0, y = 0.0, z = 0.0,
            stereo = false, left = 1.0, right = 1.0,
        }
        -- Taken from the end, so the first sound of a run uses slot one and a
        -- log or a snapshot reads in the order things happened.
        self._free[slot] = maxVoices + 1 - slot
    end

    self._sounding = 0
    self._masterGain = 1.0
    self._muted = false
    self._groupGains = {}
    self._groupMuted = {}
    self._groupPaused = {}
    self._limits = {}
    self._buckets = {}
    self._clips = {}
    self._loads = assets.batch(settleClip)
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
    self._loads:wait()

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
    -- A fresh batch rather than a drained one, so a load the wait above ran out
    -- of time on is dropped with the clips it was for rather than resolving
    -- into a mixer that has gone.
    self._loads = assets.batch(settleClip)

    if self._mixer ~= nil then
        self._backend.close(self._mixer)
        self._mixer = nil
    end
    self.available = false

    -- Every world this was installed into stops naming it. Nothing here can
    -- open an output again, so a world still answering with this mixer would
    -- hand the debug tools, and anything else reaching through `Audio.of`, a
    -- mixer that can only report that it is unavailable. Swept rather than
    -- indexed, because `install` takes a world and this holds no reference to
    -- any of them.
    for world, audio in pairs(installed) do
        if audio == self then installed[world] = nil end
    end
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
    self._loads:add(clip._handle, clip)
    return clip
end

--- The clip an index stands for, or nil when this instance has not loaded it.
function Audio:clip(id: integer): Audio.Clip
    return self._clips[id]
end

--- Blocks until every queued load has finished.
---
--- For startup and tests. A frame should let `update` resolve them instead.
function Audio:waitForLoads(timeoutMs?: number)
    self._loads:wait(timeoutMs)
end

--- Clips still being read.
function Audio:loading(): integer
    return self._loads:pending()
end

--- Re-reads a clip's file over the clip already loaded from it.
---
--- The counterpart to `Renderer:replaceImage`, and it keeps identity on the
--- same terms. A clip's index is its path's, so an edited file comes back under
--- the index every `Sound` row already carries and nothing in the world is
--- touched.
---
--- A streamed clip holds nothing to replace. Each voice opens the file for
--- itself, so the next one to start reads what is on disk now and this has only
--- to say so. Voices already sounding read the stream they opened, which is
--- what happens to a file edited under a running voice with or without a
--- reload.
---
--- A resident clip is decoded again and swapped, and it stays resident whatever
--- the new file's length would have chosen: rows already pointing at it were
--- started against held samples, and turning it into a stream under them would
--- change what a voice is, not what it sounds like. The clip it replaces is
--- destroyed here, which is safe with voices still on it: the mixer counts a
--- reference per track and frees at the last one, so a sound playing across the
--- swap finishes on the samples it started with.
---
--- Blocking, like every other reload: it is a debug operation, and answering
--- before the file has been read would report a success that had not happened
--- yet.
--- @param path The path the clip was loaded from.
--- @return Whether the clip was re-read, and a reason when it was not.
function Audio:reload(path: string): boolean, string
    local id = clipIds[path]
    local clip = id ~= nil and self._clips[id] or nil
    if clip == nil then
        return false, ("nothing has loaded '%s', so there is no clip to "
            .. "re-read"):format(path)
    end
    if clip.status == "loading" then
        return false, ("'%s' is still loading"):format(path)
    end
    if not clip.resident then return true end

    if not assets.installed() then assets.install() end
    local handle = assets.loadSound(path, "resident", self._streamMs)
    assets.waitAll()
    if handle.status ~= "ready" then
        local reason = handle.error or ("still " .. handle.status)
        handle:release()
        return false, ("'%s' did not load: %s"):format(path, reason)
    end

    -- Swapped before the old one is let go, so the clip is never pointing at a
    -- handle that has been released.
    local previous = clip._handle
    clip._handle = handle
    settleClip(clip, handle)
    if previous ~= nil then previous:release() end
    return true
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

--- The gain a voice should carry, its group's gain and mute included. The
--- master is the mixer's own number and is not multiplied in here.
local function composedGain(self: Audio, voice: Voice): number
    local group = voice.group
    if group == nil then return voice.gain end
    if self._groupMuted[group] then return 0.0 end
    local scale = self._groupGains[group]
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

--- Pushes a voice's rate, skipping the call when nothing changed.
local function applyPitch(self: Audio, voice: Voice, ratio: number)
    if voice.pitch == ratio then return end
    voice.pitch = ratio
    self._backend.setPitch(voice.track, ratio)
end

--- Pushes whether a voice repeats, skipping the call when nothing changed.
local function applyLoop(self: Audio, voice: Voice, loop: boolean)
    if voice.loop == loop then return end
    voice.loop = loop
    self._backend.setLoops(voice.track, loop and LOOP_FOREVER or 0)
end

--- Places a voice, skipping the call when it has not moved.
local function applyPosition(self: Audio, voice: Voice,
                             x: number, y: number, z: number)
    if voice.spatial and voice.x == x and voice.y == y and voice.z == z then
        return
    end
    -- The mixer keeps one placement per track, so this leaves the other.
    voice.spatial = true
    voice.stereo = false
    voice.x = x
    voice.y = y
    voice.z = z
    self._backend.setPosition(voice.track, x, y, z)
end

--- Pans a voice, skipping the call when nothing changed.
local function applyStereo(self: Audio, voice: Voice,
                           left: number, right: number)
    if voice.stereo and voice.left == left and voice.right == right then
        return
    end
    voice.stereo = true
    voice.spatial = false
    voice.left = left
    voice.right = right
    self._backend.setStereo(voice.track, left, right)
end

--- Returns a voice to unpositioned mixing, out of either placement.
local function applyUnplaced(self: Audio, voice: Voice)
    if not voice.spatial and not voice.stereo then return end
    voice.spatial = false
    voice.stereo = false
    self._backend.clearSpatial(voice.track)
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
    applyUnplaced(self, voice)
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
    applyPitch(self, voice, pitch)

    -- The two placements are exclusive, and a position wins when a caller
    -- asks for both rather than one silently undoing the other.
    if options.spatial == true then
        applyPosition(self, voice, options.x or 0.0, options.y or 0.0,
            options.z or 0.0)
    elseif options.stereo == true then
        applyStereo(self, voice, options.left or 1.0, options.right or 1.0)
    end

    -- The play carries the loop count, so nothing is pushed here; what is
    -- recorded is what a later `setLoop` compares against.
    voice.loop = options.loop == true

    local params = self._params
    params.loops = voice.loop and LOOP_FOREVER or 0
    params.loopStartMs = math.floor((options.loopStart or 0.0) * 1000)
    params.startMs = math.floor((options.start or 0.0) * 1000)
    params.fadeInMs = math.floor((options.fadeIn or 0.0) * 1000)

    if not self._backend.play(voice.track, params) then
        if voice.group ~= nil then
            self._backend.untag(voice.track, voice.group)
            voice.group = nil
        end
        -- Dropped here as well as in `release`, because a slot that never
        -- started is not released and a streamed input would stay open. The
        -- placement goes with it, for the same reason.
        self._backend.clearTrack(voice.track)
        applyUnplaced(self, voice)
        voice.sounding = false
        voice.key = nil
        self._free[#self._free + 1] = slot
        return 0
    end

    -- A group's pause is a standing instruction rather than something the
    -- mixer keeps: `MIX_PauseTag` reaches the tracks sounding when it is
    -- called and explicitly ignores the rest, so a voice starting into a
    -- paused group is held here or it would be the one sound the menu missed.
    -- After the play, because a track that has not started cannot be paused.
    if voice.group ~= nil and self._groupPaused[voice.group] then
        voice.paused = true
        self._backend.pause(voice.track)
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

--- Stops everything, over `fadeOut` seconds if that is given.
---
--- A faded stop leaves each voice sounding until the mixer finishes it, so
--- they are reaped by `update` rather than here. The ramp is the mixer's, on
--- the same terms as `stop` and `stopGroup`.
function Audio:stopAll(fadeOut?: number)
    local seconds = fadeOut or 0.0
    local fadeMs = math.floor(seconds * 1000)
    for slot = 1, #self._voices do
        local voice = self._voices[slot]
        if voice.sounding then
            self._backend.stop(voice.track, fadeMs)
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
---
--- Neither this nor `resume` takes a fade, and that is a decision rather than
--- an omission. The mixer ramps on a play and on a stop and nowhere else, so a
--- faded pause has to be a ramp run from here: a list of voices in flight, a
--- `setGain` per voice per frame, and the pause itself issued only once the
--- ramp reaches zero, which makes this a command that takes effect later and
--- needs its own answer for what a stop, a group gain or a second pause
--- during the ramp means. Each step also lands on a frame boundary, so a
--- quarter-second fade at 60 frames a second is fifteen steps on a stream
--- running at 48000, and its length follows the frame rate rather than the
--- clock. Drift and cost of exactly that kind are what handing fades to the
--- mixer avoids, and one voice held for a menu is not worth giving it up.
---
--- The mixer does offer the pieces to fade out and take a sound back where it
--- left off: `tell` reads the position, `stop` fades out, and `play` returns
--- with `start` and `fadeIn`. That re-reads the input rather than holding it,
--- so it is a different thing from a pause, and which of the two a moment
--- wants is a game's answer rather than this layer's.
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
    if voice == nil then return end
    applyPitch(self, voice, ratio)
end

--- Changes whether a voice repeats, part way through.
---
--- The mixer replaces the count it was started with, so clearing this on a
--- looping piece of music lets it play out to its end rather than cutting it,
--- and setting it on a one-shot keeps it going. It reaches a sounding voice
--- only: a stopped one takes its count from the next play.
function Audio:setLoop(handle: integer, loop: boolean)
    local voice = voiceOf(self, handle)
    if voice == nil then return end
    applyLoop(self, voice, loop == true)
end

--- Whether a voice repeats when it reaches the end.
function Audio:looping(handle: integer): boolean
    local voice = voiceOf(self, handle)
    return voice ~= nil and voice.loop
end

--- Moves a voice's read position, in seconds from the start of its clip.
---
--- False when the handle names nothing, or when the input cannot seek: a
--- decoder is allowed not to be able to, and some can only reach a time
--- rather than an exact sample.
function Audio:seek(handle: integer, seconds: number): boolean
    local voice = voiceOf(self, handle)
    if voice == nil then return false end
    return self._backend.seek(voice.track, math.floor(seconds * 1000))
end

--- Seconds into its clip a voice is reading, or nil.
---
--- Nil when the handle names nothing or the mixer cannot say. A paused voice
--- reports where it stopped, which with `seek` and `fadeIn` is what taking a
--- sound back where it left off is built from.
function Audio:tell(handle: integer): number
    local voice = voiceOf(self, handle)
    if voice == nil then return nil end
    local ms = self._backend.tell(voice.track)
    if ms < 0 then return nil end
    return ms / 1000
end

--- Places a voice in space. See `Sound` for what the numbers mean.
---
--- Replaces a pan set by `setStereo` rather than combining with it.
function Audio:setPosition(handle: integer, x: number, y: number, z: number)
    local voice = voiceOf(self, handle)
    if voice == nil then return end
    applyPosition(self, voice, x, y, z)
end

--- Pins a voice to the front pair of speakers at explicit gains.
---
--- A pan rather than a position, and usually what a game laid out on a plane
--- wants: there is no listener to subtract and no distance model to argue
--- with, only "how much of this comes out of each side". `left` at 0.8 and
--- `right` at 0.2 is a sound over to the left, whatever the speakers are.
--- Negative reads as silence and above 1 is louder, on the same terms as a
--- gain.
---
--- Replaces a position set by `setPosition` rather than combining with it:
--- the mixer holds one placement per track, and each call writes it.
function Audio:setStereo(handle: integer, left: number, right: number)
    local voice = voiceOf(self, handle)
    if voice == nil then return end
    applyStereo(self, voice, left, right)
end

--- Returns a voice to unpositioned mixing, out of either placement.
function Audio:clearSpatial(handle: integer)
    local voice = voiceOf(self, handle)
    if voice == nil then return end
    applyUnplaced(self, voice)
end

--- Scales everything. One number on the mixer, so this costs the same whether
--- one voice is sounding or every voice is.
---
--- Setting this while muted changes the level a later unmute returns to and
--- nothing that is audible now, which is what a volume slider moved with the
--- sound off should do.
function Audio:setMasterGain(gain: number)
    self._masterGain = gain
    if self._mixer ~= nil and not self._muted then
        self._backend.setMixerGain(self._mixer, gain)
    end
end

--- The master gain, whether or not a mute is holding it down.
function Audio:masterGain(): number
    return self._masterGain
end

--- Silences everything without discarding the master gain.
---
--- The mixer's own number again, so it costs one call however many voices are
--- sounding. It does not fan out to the groups: `groupMuted` answers "is this
--- group silenced", and writing every group's bit here would overwrite the
--- answers an unmute has to put back. That is the same loss as setting a gain
--- to zero, which is what a mute exists instead of.
function Audio:setMuted(muted: boolean)
    local wanted = muted == true
    if self._muted == wanted then return end
    self._muted = wanted
    if self._mixer ~= nil then
        self._backend.setMixerGain(self._mixer,
            wanted and 0.0 or self._masterGain)
    end
end

--- Whether a master mute is holding the output down.
function Audio:muted(): boolean
    return self._muted
end

--- Voices sounding right now, including paused and fading ones.
function Audio:sounding(): integer
    return self._sounding
end

--- Voices that may sound at once, as `maxVoices` configured it.
function Audio:maxVoices(): integer
    return #self._voices
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
---
--- The level, not what is audible: a muted group still answers with the gain
--- an unmute would put back.
function Audio:groupGain(name: string): number
    return self._groupGains[name] or 1.0
end

--- Silences a group without discarding the level it was set to.
---
--- Bookkeeping over the gains that already exist rather than anything the
--- mixer is told about: every voice in the group is composed at zero while
--- this holds, and an unmute puts each one back at its own gain times
--- `groupGain(name)`.
function Audio:setGroupMuted(name: string, muted: boolean)
    local wanted = muted == true
    if (self._groupMuted[name] == true) == wanted then return end
    self._groupMuted[name] = wanted or nil
    for slot = 1, #self._voices do
        local voice = self._voices[slot]
        if voice.sounding and voice.group == name then
            applyGain(self, voice)
        end
    end
end

--- Whether a group is muted.
function Audio:groupMuted(name: string): boolean
    return self._groupMuted[name] == true
end

--- Holds every voice in a group where it is, and every voice that joins it
--- later.
---
--- Recorded as well as sent, because the mixer's tag pause reaches what is
--- sounding when it is called: without the record, a sound started into a
--- paused group would be the one thing still heard.
function Audio:pauseGroup(name: string)
    self._groupPaused[name] = true
    if self._mixer == nil then return end
    self._backend.pauseTag(self._mixer, name)
    for slot = 1, #self._voices do
        local voice = self._voices[slot]
        if voice.sounding and voice.group == name then voice.paused = true end
    end
end

--- Lets a paused group carry on, and lets later joiners start sounding.
function Audio:resumeGroup(name: string)
    self._groupPaused[name] = nil
    if self._mixer == nil then return end
    self._backend.resumeTag(self._mixer, name)
    for slot = 1, #self._voices do
        local voice = self._voices[slot]
        if voice.sounding and voice.group == name then voice.paused = false end
    end
end

--- Whether a group is holding its voices, including the ones not started yet.
function Audio:groupPaused(name: string): boolean
    return self._groupPaused[name] == true
end

--- Appends a name to `names` unless `seen` already holds it.
local function note(names: {string}, seen: {string: boolean}, name: string)
    if seen[name] then return end
    seen[name] = true
    names[#names + 1] = name
end

--- Every group with a gain, a mute or a pause recorded against it.
local function settledGroups(self: Audio, names: {string},
                             seen: {string: boolean})
    for name in pairs(self._groupGains) do note(names, seen, name) end
    for name in pairs(self._groupMuted) do note(names, seen, name) end
    for name in pairs(self._groupPaused) do note(names, seen, name) end
end

--- Every group this instance knows of: one whose gain, mute or pause has been
--- set, and one a sounding voice is in. Sorted, so a caller reading it twice
--- reads it the same way.
function Audio:groups(): {string}
    local names: {string} = {}
    local seen: {string: boolean} = {}
    settledGroups(self, names, seen)
    for slot = 1, #self._voices do
        local voice = self._voices[slot]
        if voice.sounding and voice.group ~= nil then
            note(names, seen, voice.group)
        end
    end
    table.sort(names)
    return names
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

--- Every key with a limit set or a voice counted against it, sorted.
function Audio:keys(): {string}
    local names: {string} = {}
    local seen: {string: boolean} = {}
    for name in pairs(self._limits) do
        seen[name] = true
        names[#names + 1] = name
    end
    for name in pairs(self._buckets) do
        if not seen[name] then names[#names + 1] = name end
    end
    table.sort(names)
    return names
end

-------------------------------------------------------------------------------
-- Looking in
-------------------------------------------------------------------------------

--- Every clip this instance has loaded, in the order they were asked for.
---
--- For introspection: it builds a list per call, so nothing on a frame's path
--- should read it.
function Audio:clips(): {Audio.Clip}
    local ids: {integer} = {}
    for id in pairs(self._clips) do ids[#ids + 1] = id end
    table.sort(ids)
    local list: {Audio.Clip} = {}
    for index = 1, #ids do list[index] = self._clips[ids[index]] end
    return list
end

--- Every sounding voice, paused and fading ones included.
---
--- For introspection, on the same terms as `clips`. The handles it reports are
--- the ones `playing` and `stop` take, so what this shows can be acted on.
function Audio:voices(): {Audio.VoiceInfo}
    local list: {Audio.VoiceInfo} = {}
    for slot = 1, #self._voices do
        local voice = self._voices[slot]
        if voice.sounding then
            list[#list + 1] = {
                handle = voice.generation * SLOT_SPAN + slot,
                clip = voice.clip ~= nil and voice.clip.path or nil,
                gain = voice.gain,
                applied = voice.applied,
                pitch = voice.pitch,
                group = voice.group,
                key = voice.key,
                paused = voice.paused,
                stopping = voice.stopping,
                owned = voice.owned,
                loop = voice.loop,
                spatial = voice.spatial,
                x = voice.x,
                y = voice.y,
                z = voice.z,
                stereo = voice.stereo,
                left = voice.left,
                right = voice.right,
            }
        end
    end
    return list
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
    self._loads:resolve()

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

--- Puts the rows of entities something has disabled back to rest.
---
--- `Disabled` is excluded from every query that does not name it, so a
--- disabled row is not walked below and the voice it holds is taken by the
--- sweep for looking abandoned. The row is left naming a voice that has gone,
--- which reads on re-enabling as a one-shot that finished, and the sound never
--- comes back. Clearing the handle here is what makes it.
---
--- Archetype-shaped rather than per-row: a disabled entity is in an archetype
--- of its own, so a world with nothing disabled matches nothing and this walks
--- nothing. Only the frame something is disabled on writes.
local function hush(hushed: ecs.Query)
    for archetype, length in hushed:iter() do
        local rows = archetype:get(Sound) as {Sound}
        local mutable: {Sound} = nil
        for row = 1, length do
            if (rows[row].voice as integer) > 0 then
                if mutable == nil then
                    mutable = archetype:getMut(Sound) as {Sound}
                end
                -- Zero rather than finished: a voice the sweep is about to
                -- take back is not one that ran to its end.
                mutable[row].voice = 0
            end
        end
    end
end

--- Starts, stops, follows and reaps the voices `Sound` components ask for.
---
--- One walk answers all of it. A row asking to sound with no voice starts one;
--- a sounding row has its gain, rate, loop and position followed; a row that
--- has stopped asking, or whose voice has ended, is put back to rest; and a
--- voice nothing referred to during the walk belonged to an entity that has
--- gone or been disabled, so it is stopped. That last case is what makes
--- despawning something mid-sound work without an observer on every archetype
--- that might hold one.
---
--- Following is a read and a compare per field per sounding row. Every field
--- on the list is one a game changes without wanting the sound to restart,
--- and every field left off it takes a stop and a fresh start to change
--- anyway, so nothing here is paid for on behalf of a case that cannot use it.
local function reconcile(self: Audio, sounds: ecs.Query, hushed: ecs.Query)
    local voices = self._voices
    for slot = 1, #voices do
        voices[slot].referenced = false
    end

    hush(hushed)

    for archetype, length in sounds:iter() do
        local rows = archetype:get(Sound) as {Sound}
        -- Taken mutable on the first row that actually changes, and not at
        -- all otherwise. Taking it up front would mark the column dirty every
        -- frame for every archetype holding a sound.
        local mutable: {Sound} = nil

        for row = 1, length do
            local entry = rows[row]
            local handle = entry.voice as integer

            if (entry.playing as integer) == 0 then
                -- Asked for silence. Whatever is sounding ends now, and the
                -- row goes back to zero rather than to finished, so that
                -- setting the flag again starts it: a one-shot that has run
                -- out plays a second time instead of staying spent.
                if handle ~= 0 then
                    local voice = voiceOf(self, handle)
                    if voice ~= nil then
                        self._backend.stop(voice.track, 0)
                        release(self, handle % SLOT_SPAN)
                    end
                    if mutable == nil then
                        mutable = archetype:getMut(Sound) as {Sound}
                    end
                    mutable[row].voice = 0
                end
            elseif handle == 0 then
                rowOptions.gain = entry.gain as number
                rowOptions.loop = (entry.loop as integer) ~= 0
                rowOptions.pitch = entry.pitch as number
                rowOptions.spatial = (entry.spatial as integer) ~= 0
                rowOptions.x = entry.x as number
                rowOptions.y = entry.y as number
                rowOptions.z = entry.z as number
                -- nil for index zero, which is what "no group" reads as. Only
                -- rows that are starting pay for the lookup: a group is read
                -- once, like the clip, and a sounding voice keeps the one it
                -- joined.
                rowOptions.group = groupNames[entry.group as integer]
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
                    -- Each of these is a load and a compare, and the call
                    -- past it runs only on the frame the value moved. The
                    -- guard is written out rather than left to the helper so
                    -- that an unchanged row makes no call at all.
                    if voice.gain ~= entry.gain then
                        voice.gain = entry.gain as number
                        applyGain(self, voice)
                    end
                    local pitch = entry.pitch as number
                    if voice.pitch ~= pitch then
                        applyPitch(self, voice, pitch)
                    end
                    local loop = (entry.loop as integer) ~= 0
                    if voice.loop ~= loop then
                        applyLoop(self, voice, loop)
                    end
                    if (entry.spatial as integer) ~= 0 then
                        applyPosition(self, voice, entry.x as number,
                            entry.y as number, entry.z as number)
                    elseif voice.spatial then
                        applyUnplaced(self, voice)
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

-------------------------------------------------------------------------------
-- The mixer in a snapshot
-------------------------------------------------------------------------------

--- The mixer state a snapshot carries.
---
--- The master gain and mute, and every group's gain, mute and pause. A player
--- who turned the music down and held the effects for a menu expects to find
--- it that way after a load, and none of it is in the world, so nothing else
--- would carry it.
---
--- Keyed limits are not here, and neither is what a bucket holds. A limit is a
--- rule the build states at startup beside the clip it governs, so restoring
--- one from a file would let an old save override a rule the build has since
--- changed. A bucket is derived from voices, and a snapshot restores no voices:
--- a `Sound` comes back with its voice cleared and starts again.
local function saveMixer(self: Audio): {string: any}
    local groups: {string: any} = {}
    for _, name in ipairs(self:groups()) do
        local gain = self._groupGains[name]
        local muted = self._groupMuted[name] == true
        local paused = self._groupPaused[name] == true
        -- A group that only has voices in it has nothing set, and writing its
        -- defaults out would make a save grow with what a run happened to play.
        if gain ~= nil or muted or paused then
            groups[name] = {
                gain = gain or 1.0, muted = muted, paused = paused,
            }
        end
    end
    return {
        masterGain = self._masterGain,
        muted = self._muted,
        groups = groups,
    }
end

--- Puts saved mixer state back, through the ordinary setters.
---
--- Every group this instance knows about is visited, not only the ones the
--- snapshot names, so loading a save made before a group was ever touched puts
--- that group back to its defaults rather than leaving this run's settings on
--- it. Going through the setters is what makes the voices already sounding
--- follow, since each one recomposes its gain and the tags are told about a
--- pause.
local function loadMixer(self: Audio, value: {string: any})
    local saved = (value ~= nil and value.groups or nil) as {string: any}

    -- The groups this run has settings on, and the ones the file names. A
    -- group that only ever had voices in it carries no settings, so there is
    -- nothing on it to put back.
    local names: {string} = {}
    local seen: {string: boolean} = {}
    settledGroups(self, names, seen)
    if saved ~= nil then
        for name in pairs(saved) do note(names, seen, name) end
    end

    for _, name in ipairs(names) do
        local entry = (saved ~= nil and saved[name] or nil) as {string: any}
        self:setGroupGain(name,
            entry ~= nil and (entry.gain as number) or 1.0)
        self:setGroupMuted(name, entry ~= nil and entry.muted == true)
        if entry ~= nil and entry.paused == true then
            self:pauseGroup(name)
        else
            self:resumeGroup(name)
        end
    end

    self:setMasterGain(
        value ~= nil and (value.masterGain as number) or 1.0)
    self:setMuted(value ~= nil and value.muted == true)
end

-------------------------------------------------------------------------------
-- The plugin
-------------------------------------------------------------------------------

--- The audio installed into a world, or nil when none has been.
---
--- What lets something holding only the world reach the mixer, which is what
--- the debug tools have and what a game writing its own systems often has too.
function Audio.of(world: ecs.World): Audio
    return installed[world]
end

--- Adds the system that plays `Sound` components, and the snapshot handler
--- that carries the mixer.
---
--- `update` is not added here. Reaping voices is not world work: it has to
--- keep happening while the world is paused, and an application drives it from
--- the iteration instead.
function Audio:install(world: ecs.World)
    installed[world] = self

    local sounds = world:query({
        name = "tecs.Sounds",
        include = { Sound },
    })

    -- Naming `Disabled` opts out of the exclusion every other query gets, so
    -- this is the disabled rows and only those. They are in archetypes of
    -- their own, so it matches nothing until something is disabled.
    local hushed = world:query({
        name = "tecs.DisabledSounds",
        include = { Sound, ecs.builtins.Disabled },
    })

    world:addSystem({
        name = "tecs.PlaySounds",
        -- After gameplay has decided what exists and before anything renders,
        -- so a sound spawned this frame starts this frame.
        phase = ecs.phases.PostUpdate,
        run = function() reconcile(self, sounds, hushed) end,
    })

    world:addSnapshotHandler({
        name = "tecs.audio",
        save = function(_world: ecs.World): any
            return saveMixer(self)
        end,
        load = function(_world: ecs.World, value: any)
            loadMixer(self, value as {string: any})
        end,
    })
end

return Audio
