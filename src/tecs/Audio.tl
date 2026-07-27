--- Sound output, rooted at `app.audio`.
---
--- **WAV only.** Clips are read with `SDL_LoadWAV`, and there is no
--- SDL_mixer and no decoder in this engine. So Ogg Vorbis, Opus, MP3, FLAC
--- and tracker modules do not load, and neither does anything else that is
--- compressed: a file is PCM, or it fails with "cannot load". Adding a
--- decoder means adding a dependency and a licence to the build, which is a
--- decision this module does not get to make on its own.
---
--- **Nothing is mixed here.** A voice is one platform stream, and every
--- stream bound to the output is summed by the platform. Playing the same
--- clip three times over is three streams reading the same bytes, not three
--- copies added together by this code. `SDL_MixAudio` is therefore unused:
--- the only thing it could do that binding cannot is sum into a buffer this
--- engine owns, and nothing needs one.
---
--- **Nothing runs on an audio thread.** SDL can pull audio from a callback,
--- and that callback fires on a thread the Lua VM did not create. A Lua
--- function invoked from such a thread is the unsafe case that keeps raw
--- thread creation unexposed (see `native/worker.c`), so the device is fed by
--- queueing instead, from `update`, on the thread everything else runs on. A
--- callback mixer would need a native bridge, and there is none.
---
--- **Every voice is fed in pieces.** A sound is not queued whole and then
--- forgotten; each update tops its stream up to a fixed lead in seconds and
--- no further. That is what a long piece of music needs, and running short
--- sounds through the same path means there is one playback shape rather than
--- two. Looping falls out of it: the cursor wraps and the next top-up crosses
--- the join with no gap. What it does not do is stream from disk. `SDL_LoadWAV`
--- has no partial-read form, so the file is resident even though the stream's
--- queue is bounded, and reading a WAV incrementally means parsing the
--- container here, which is the decoder this module does not have.
---
--- **Loading is off the main thread.** A clip is read and converted on the
--- asset worker and handed back as an address, the same route a decoded image
--- takes. A load never blocks a frame; the clip reports that it is still
--- loading and `play` declines until it is not.
---
--- Positional panning is deliberately absent. See `Sound` for why.

local ecs <const> = require("tecs.ecs")
local assets <const> = require("tecs.assets")
local loader <const> = require("tecs.ffi.loader")
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
--- Seconds of audio kept queued ahead of the device on each voice.
---
--- Long enough that a frame that runs late does not run the queue dry, short
--- enough that stopping a voice is not audibly deferred by what is already
--- committed.
local DEFAULT_LEAD <const> = 0.25
--- Bytes per sample. Clips arrive as 32-bit float, always.
local SAMPLE_BYTES <const> = 4

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
--- There is no listener and no panning. SDL gives a stream one gain and a
--- channel map, and a channel map reorders channels rather than attenuating
--- them, so constant-power panning would mean either summing samples here or
--- splitting every mono clip across two streams. Both are real designs with
--- real costs, and neither is worth committing to before the questions under
--- it are answered: which units distance is in, what the falloff curve is,
--- whether the listener follows the camera or an entity, and what happens to
--- a sound on a screen-space layer. Attenuating by distance without panning
--- would be the cheap half of that, and shipping the cheap half is what fixes
--- the answers to the other questions by accident. `gain` is the seam it will
--- arrive through when it does.
local record Sound is Component
    --- Clip index, from `Audio.clipId`. Zero plays nothing.
    clip: number
    --- 0 to 1, before the master gain.
    gain: number
    --- Nonzero repeats until the component goes away.
    loop: number
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
        { "voice", "int32_t" },
    },
    defaults = { 0, 1.0, 0, 0 },
    serialize = function(instance: Sound): {string: any}
        return {
            clip = clipPaths[instance.clip as integer],
            gain = instance.gain,
            loop = instance.loop ~= 0,
        }
    end,
    deserialize = function(_world: ecs.World, data: {string: any}): Sound
        local path = data.clip as string
        local clip = 0
        if path ~= nil and path ~= "" then clip = clipId(path) end
        -- The voice is not restored. A snapshot records that an entity has a
        -- sound, not how far through it the device had got, so it starts.
        return Sound(clip, data.gain as number,
            (data.loop as boolean) and 1 or 0)
    end,
})

-------------------------------------------------------------------------------
-- Types
-------------------------------------------------------------------------------

--- One playback in progress. Internal: a game holds the integer handle.
local record Voice
    stream: loader.CPtr
    clip: Audio.Clip
    --- Bytes of the clip handed to the stream so far.
    cursor: integer
    loop: boolean
    --- What the game asked for, before the master gain.
    gain: number
    --- The value last pushed to the stream, so an unchanged gain costs
    --- nothing per frame.
    applied: number
    --- Rises each time the slot is taken, so a stale handle is inert.
    generation: integer
    sounding: boolean
    --- True when a `Sound` component started this, and so when the audio pass
    --- is the thing that decides it should stop.
    owned: boolean
    --- Set by the pass that walks `Sound` rows, cleared before each walk.
    referenced: boolean
end

local record Audio
    record Config
        --- Frames per second. Defaults to 48000.
        frequency: integer
        --- Output channels. Defaults to 2.
        channels: integer
        --- Voices that may sound at once. Defaults to 32.
        maxVoices: integer
        --- Seconds kept queued ahead of the device. Defaults to 0.25.
        lead: number
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
        --- Seconds of audio, once ready.
        duration: number
        _handle: assets.Handle
        _samples: loader.BytePointer
        _length: integer
    end

    record PlayOptions
        --- 0 to 1, before the master gain. Defaults to 1.
        gain: number
        --- Repeats until stopped. Defaults to false.
        loop: boolean
    end

    Sound: Sound

    --- Whether an output opened. False on a machine with no sound, where
    --- every call here still works and nothing is heard.
    available: boolean

    _backend: Backend
    _device: integer
    _spec: audiobackend.Spec
    _voices: {Voice}
    _free: {integer}
    _sounding: integer
    _leadBytes: integer
    _masterGain: number
    _clips: {integer: Clip}
    _loading: {Clip}
end

local AudioMT <const>: metatable<Audio> = { __index = Audio }

Audio.Sound = Sound

--- Index of a clip path, assigning one the first time it is seen.
function Audio.clipId(path: string): integer
    return clipId(path)
end

--- Path a clip index stands for, or nil when it names nothing.
function Audio.clipPath(id: integer): string
    return clipPaths[id]
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

    local lead = given.lead or DEFAULT_LEAD
    self._leadBytes = math.floor(
        lead * self._spec.frequency * self._spec.channels * SAMPLE_BYTES)

    local maxVoices = given.maxVoices or DEFAULT_MAX_VOICES
    if maxVoices < 1 or maxVoices >= SLOT_SPAN then
        error(("tecs: maxVoices must be between 1 and %d"):format(
            SLOT_SPAN - 1), 2)
    end
    self._voices = {}
    self._free = {}
    for slot = 1, maxVoices do
        self._voices[slot] = {
            cursor = 0, gain = 1.0, applied = -1.0, generation = 0,
            sounding = false, owned = false, referenced = false, loop = false,
        }
        -- Taken from the end, so the first sound of a run uses slot one and a
        -- log or a snapshot reads in the order things happened.
        self._free[slot] = maxVoices + 1 - slot
    end

    self._sounding = 0
    self._masterGain = 1.0
    self._clips = {}
    self._loading = {}

    self._device = self._backend.openDevice(self._spec)
    self.available = self._device ~= 0
    if not self.available then
        LOGGER:info("no audio output; sound is silent for this run")
    end
    return self
end

--- Stops everything and closes the output.
function Audio:destroy()
    for slot = 1, #self._voices do
        local voice = self._voices[slot]
        if voice.stream ~= nil then
            if voice.sounding then self._backend.unbindStream(voice.stream) end
            self._backend.destroyStream(voice.stream)
            voice.stream = nil
        end
        voice.sounding = false
    end
    self._sounding = 0

    for _, clip in pairs(self._clips) do
        if clip._handle ~= nil then
            clip._handle:release()
            clip._handle = nil
        end
        clip._samples = nil
        clip._length = 0
        clip.status = "released"
    end
    self._clips = {}
    self._loading = {}

    if self._device ~= 0 then
        self._backend.closeDevice(self._device)
        self._device = 0
    end
    self.available = false
end

-------------------------------------------------------------------------------
-- Clips
-------------------------------------------------------------------------------

--- Queues a WAV for loading and returns its clip immediately.
---
--- Loading the same path twice returns the same clip; a clip is the file, and
--- playing it twice over is two voices reading one buffer.
function Audio:load(path: string): Audio.Clip
    local id = clipId(path)
    local existing = self._clips[id]
    if existing ~= nil then return existing end

    -- The worker is what reads the file, and a game that only ever plays
    -- sound has no other reason to have started it.
    if not assets.installed() then assets.install() end

    local clip: Audio.Clip = {
        path = path,
        id = id,
        status = "loading",
        duration = 0.0,
        _length = 0,
        _handle = assets.loadSound(path, self._spec.frequency,
            self._spec.channels),
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
local function resolveLoads(self: Audio): integer
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
            clip._samples = loader.bytePointer(handle.samples)
            clip._length = handle.bytes
            clip.duration = handle.bytes
                / (self._spec.frequency * self._spec.channels * SAMPLE_BYTES)
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

--- Hands the stream as much as the lead calls for, wrapping when looping.
local function feed(self: Audio, voice: Voice)
    local clip = voice.clip
    local length = clip._length
    if length <= 0 then return end

    local want = self._leadBytes - self._backend.pendingBytes(voice.stream)
    while want > 0 do
        local remaining = length - voice.cursor
        if remaining <= 0 then
            if not voice.loop then return end
            voice.cursor = 0
            remaining = length
        end
        local chunk = remaining < want and remaining or want
        self._backend.putData(voice.stream, clip._samples + voice.cursor, chunk)
        voice.cursor = voice.cursor + chunk
        want = want - chunk
    end
end

--- Unbinds a voice, empties it, and returns the slot.
local function release(self: Audio, slot: integer)
    local voice = self._voices[slot]
    if not voice.sounding then return end
    self._backend.unbindStream(voice.stream)
    -- Unbinding stops it feeding the output but leaves whatever it still
    -- holds inside it, so the next sound on this slot would start with the
    -- tail of the last one.
    self._backend.clearStream(voice.stream)
    voice.sounding = false
    voice.owned = false
    voice.clip = nil
    voice.cursor = 0
    self._sounding = self._sounding - 1
    self._free[#self._free + 1] = slot
end

--- Starts `clip` on a free voice and returns its handle, or zero.
local function start(self: Audio, clip: Audio.Clip, gain: number,
                     loop: boolean, owned: boolean): integer
    if not self.available then return 0 end
    if clip == nil or clip.status ~= "ready" or clip._length <= 0 then
        return 0
    end

    local count = #self._free
    if count == 0 then return 0 end
    local slot = self._free[count]
    self._free[count] = nil

    local voice = self._voices[slot]
    if voice.stream == nil then
        -- Made on first use rather than at startup, so a game that never
        -- plays anything holds no streams.
        voice.stream = self._backend.createStream(self._spec)
        if voice.stream == nil then
            self._free[#self._free + 1] = slot
            return 0
        end
    end

    voice.generation = voice.generation + 1
    if voice.generation > MAX_GENERATION then voice.generation = 1 end
    voice.clip = clip
    voice.cursor = 0
    voice.loop = loop
    voice.gain = gain
    voice.applied = gain * self._masterGain
    voice.sounding = true
    voice.owned = owned
    voice.referenced = false

    self._backend.setStreamGain(voice.stream, voice.applied)
    if not self._backend.bindStream(self._device, voice.stream) then
        voice.sounding = false
        self._free[#self._free + 1] = slot
        return 0
    end

    self._sounding = self._sounding + 1
    -- The first piece goes in before this returns, so a sound is audible
    -- without waiting for the next update to notice it.
    feed(self, voice)
    return voice.generation * SLOT_SPAN + slot
end

--- Plays `clip`, returning a handle, or zero when it did not start.
---
--- Zero means the clip is not loaded, loading failed, every voice is busy, or
--- the machine has no output. None of those is worth raising over: a sound
--- that does not play is not a reason for a frame to stop.
function Audio:play(clip: Audio.Clip, options?: Audio.PlayOptions): integer
    local given = options or {} as Audio.PlayOptions
    return start(self, clip, given.gain or 1.0, given.loop == true, false)
end

--- Stops a voice. A handle to one that already ended does nothing.
function Audio:stop(handle: integer)
    local voice = voiceOf(self, handle)
    if voice == nil then return end
    release(self, handle % SLOT_SPAN)
end

--- Stops everything.
function Audio:stopAll()
    for slot = 1, #self._voices do
        release(self, slot)
    end
end

--- Whether a handle still names a sounding voice.
function Audio:playing(handle: integer): boolean
    return voiceOf(self, handle) ~= nil
end

--- Sets a voice's gain, before the master gain.
function Audio:setGain(handle: integer, gain: number)
    local voice = voiceOf(self, handle)
    if voice == nil then return end
    voice.gain = gain
    local applied = gain * self._masterGain
    if applied == voice.applied then return end
    voice.applied = applied
    self._backend.setStreamGain(voice.stream, applied)
end

--- Scales everything. Applied to what is already sounding, not only to what
--- starts next.
function Audio:setMasterGain(gain: number)
    self._masterGain = gain
    for slot = 1, #self._voices do
        local voice = self._voices[slot]
        if voice.sounding then
            local applied = voice.gain * gain
            if applied ~= voice.applied then
                voice.applied = applied
                self._backend.setStreamGain(voice.stream, applied)
            end
        end
    end
end

--- The master gain.
function Audio:masterGain(): number
    return self._masterGain
end

--- Voices sounding right now.
function Audio:sounding(): integer
    return self._sounding
end

--- Takes finished loads, tops up every voice, and releases the ones that
--- have finished. Call once per frame.
---
--- "Finished" is the platform having taken every byte, which is a little
--- earlier than the last sample reaching the speaker: whatever the device has
--- already pulled into its own buffer plays out regardless. A queue-fed API
--- reports what it has been asked for, not what has been heard, and the
--- difference is one device buffer.
function Audio:update(): integer
    resolveLoads(self)

    for slot = 1, #self._voices do
        local voice = self._voices[slot]
        if voice.sounding then
            local drained = self._backend.pendingBytes(voice.stream) <= 0
            if drained and not voice.loop
                and voice.cursor >= voice.clip._length then
                release(self, slot)
            else
                feed(self, voice)
            end
        end
    end
    return self._sounding
end

-------------------------------------------------------------------------------
-- The entity interface
-------------------------------------------------------------------------------

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
                local started = start(self, self._clips[entry.clip as integer],
                    entry.gain as number, (entry.loop as integer) ~= 0, true)
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
                end
            end
        end
    end

    for slot = 1, #voices do
        local voice = voices[slot]
        if voice.sounding and voice.owned and not voice.referenced then
            release(self, slot)
        end
    end
end

--- Adds the system that plays `Sound` components.
---
--- `update` is not added here. Feeding the device is not world work: it has
--- to keep happening while the world is paused, and an application drives it
--- from the iteration instead.
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
