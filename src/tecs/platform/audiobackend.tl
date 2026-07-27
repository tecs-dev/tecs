--- The output half of the platform seam, for sound.
---
--- Audio only ever goes one way. A game opens a mixer, points a voice at a
--- clip, starts it, adjusts it and stops it; nothing comes back except whether
--- a voice is still sounding. So unlike input, which has an event stream in
--- front of it, this seam is commands and one measurement, and that is the
--- whole contract a port has to answer.
---
--- The unit of playback is a track, because the mixer is what mixes. Every
--- track on one mixer is summed into the buffer the hardware reads, so playing
--- two sounds at once means two tracks and not summing samples here.
---
--- The one measurement is `playing`. A mixer pulls rather than being fed, so
--- there is nothing to top up and no queue depth to read: a voice is over when
--- the mixer says it has stopped, and `Audio:update` asks once a frame. That is
--- also why no callback appears in this contract, in either direction.
--- SDL_mixer offers one for a track that stopped, and it runs on the audio
--- thread. A Lua function invoked from a thread the VM did not create is the
--- unsafe case that keeps raw thread creation unexposed (see `native/worker.c`),
--- so the answer is polled instead.
---
--- Exactly one thing writes each gain. The master is the mixer's own number
--- and goes straight to it, so setting it costs one call however many voices
--- are sounding. A voice's gain and its group's are multiplied out above this
--- seam and arrive as one product, because SDL_mixer's per-tag gain is not a
--- separate multiplier: it writes each tagged track's own gain, so using it for
--- a group would overwrite whatever the voice asked for.
---
--- Clips are not loaded through here. A clip is decoded on the asset worker and
--- arrives as a pointer, the same route a decoded image takes, so what this
--- seam takes is a loaded clip or a path to stream from.
---
--- `Audio` holds a backend and never reaches the FFI itself. The SDL
--- implementation below is the worked example, and the only thing in the audio
--- layer that names a `MIX_` symbol.

local sdl <const> = require("tecs.ffi.sdl3")
local sdl3mixer <const> = require("tecs.ffi.sdl3mixer")
local loader <const> = require("tecs.ffi.loader")

local C <const> = sdl.C
local K <const> = sdl.K
local MIX <const> = sdl3mixer.C

--- The layout the mixer renders in.
---
--- Samples are always 32-bit float. Clips are converted by the mixer as it
--- reads them, so this describes the output and nothing else.
local record Spec
    --- Frames per second.
    frequency: integer
    --- Interleaved channels per frame.
    channels: integer
end

--- What a voice is started with. Everything is in milliseconds or in loops.
local record PlayParams
    --- Times to repeat after the first pass. Negative repeats forever.
    loops: integer
    --- Where a repeat returns to, from the start of the clip.
    loopStartMs: integer
    --- Silence to full over this long. Zero starts at full.
    fadeInMs: integer
    --- Where the first pass begins, from the start of the clip.
    startMs: integer
end

local record Backend
    --- Name this backend reports as. For diagnostics; it is not matched
    --- against.
    name: string

    --- Opens the platform's default playback output and returns a mixer for
    --- it. Nil when there is no output, which is the answer a machine with no
    --- sound hardware gives and is not an error.
    ---
    --- The default specifically, not a device chosen by name. A platform that
    --- can follow its own default is expected to, so that plugging in
    --- headphones moves the sound without anything above here being told.
    open: function(spec: Spec): loader.CPtr
    close: function(mixer: loader.CPtr)
    --- Scales the whole mix. A separate number from any voice's gain, which
    --- is what lets the master be set once rather than multiplied into every
    --- voice that happens to be sounding.
    setMixerGain: function(mixer: loader.CPtr, gain: number)

    --- Creates a voice on `mixer`. Nil when one cannot be made.
    createTrack: function(mixer: loader.CPtr): loader.CPtr
    destroyTrack: function(track: loader.CPtr)

    --- Points a voice at a loaded clip. Several voices may share one clip.
    setTrackClip: function(track: loader.CPtr, clip: loader.CPtr): boolean
    --- Points a voice at a file it decodes as it plays, holding nothing
    --- resident. One file is opened per voice, because a decoder reads a
    --- position and two voices cannot share one.
    setTrackFile: function(track: loader.CPtr, path: string): boolean
    --- Removes a voice's input, releasing whatever it was reading.
    clearTrack: function(track: loader.CPtr)

    play: function(track: loader.CPtr, params: PlayParams): boolean
    --- Stops a voice, over `fadeMs` if that is positive. A faded stop keeps
    --- the voice sounding until the fade finishes, so `playing` stays true
    --- until it does.
    stop: function(track: loader.CPtr, fadeMs: integer)
    pause: function(track: loader.CPtr)
    resume: function(track: loader.CPtr)
    --- Whether the mixer is still taking samples from this voice. False for a
    --- voice that is paused, which is why pausing is tracked above this seam
    --- rather than inferred from here.
    playing: function(track: loader.CPtr): boolean

    --- Scales a voice, 0 to 1 for silence to unchanged. Above 1 is louder and
    --- may clip, which is the platform's business rather than this layer's.
    setGain: function(track: loader.CPtr, gain: number)
    --- Playback rate, 1 for unchanged. Doubling it raises the pitch an octave
    --- and halves the duration.
    setPitch: function(track: loader.CPtr, ratio: number)
    --- Places a voice in space, relative to a listener fixed at the origin.
    setPosition: function(track: loader.CPtr, x: number, y: number, z: number)
    --- Returns a voice to unpositioned mixing.
    clearPosition: function(track: loader.CPtr)

    --- Tags are names several voices answer to at once, and are how a group
    --- reaches its members without this layer holding a list.
    tag: function(track: loader.CPtr, tag: string)
    untag: function(track: loader.CPtr, tag: string)
    pauseTag: function(mixer: loader.CPtr, tag: string)
    resumeTag: function(mixer: loader.CPtr, tag: string)
    stopTag: function(mixer: loader.CPtr, tag: string, fadeMs: integer)
end

local record audiobackend
    Spec: Spec
    PlayParams: PlayParams
    Backend: Backend
    --- The SDL backend, and the default everywhere.
    sdl: Backend
end

-------------------------------------------------------------------------------
-- The SDL backend
-------------------------------------------------------------------------------

--- Property names `MIX_PlayTrack` reads its options from.
---
--- Written out rather than taken from the generated constants, because these
--- expand to string literals and the constant recovery evaluates each macro as
--- an integer: a string one comes back as the address its literal happened to
--- have. Names are part of SDL's published interface and change no more often
--- than the functions that read them.
local PROP_LOOPS <const> = "SDL_mixer.play.loops"
local PROP_LOOP_START_MS <const> = "SDL_mixer.play.loop_start_millisecond"
local PROP_FADE_IN_MS <const> = "SDL_mixer.play.fade_in_milliseconds"
local PROP_START_MS <const> = "SDL_mixer.play.start_millisecond"

--- Reusable spec and position, filled per call. Opening is startup-shaped
--- work, but positioning happens per voice per frame and must not allocate.
local audioSpec <const> = loader.newStruct("SDL_AudioSpec")
local point <const> = loader.newStruct("MIX_Point3D")

--- Options handed to every play. Made once and overwritten, because every
--- field is set on every call: each option's default is the value that means
--- "not asked for", so nothing has to be cleared between voices.
local playProps: integer = 0

local sdlBackend <const>: Backend = {
    name = "sdl",

    open = function(spec: Spec): loader.CPtr
        -- The subsystem is started here rather than alongside video, because a
        -- machine with no sound is a machine that still runs. Failing the
        -- process's whole init over an output nobody may use is not the
        -- trade this makes.
        if tonumber(C.SDL_WasInit(K.SDL_INIT_AUDIO)) == 0 then
            if not C.SDL_InitSubSystem(K.SDL_INIT_AUDIO) then return nil end
        end
        if not sdl3mixer.init() then return nil end

        local fields = audioSpec as loader.CStruct
        fields.format = C.SDL_AUDIO_F32
        fields.channels = spec.channels
        fields.freq = spec.frequency

        -- The default id, so SDL keeps the logical device pointed at whatever
        -- the system default becomes. Tracks on it follow the move.
        local mixer = MIX.MIX_CreateMixerDevice(
            K.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, audioSpec)
        if mixer == nil then return nil end
        if playProps == 0 then
            playProps = tonumber(C.SDL_CreateProperties()) as integer
        end
        return mixer
    end,

    close = function(mixer: loader.CPtr)
        MIX.MIX_DestroyMixer(mixer)
        if playProps ~= 0 then
            C.SDL_DestroyProperties(playProps)
            playProps = 0
        end
        -- Everything the library made is gone with this, including clips a
        -- worker loaded, so callers destroy their own first.
        sdl3mixer.quit()
    end,

    setMixerGain = function(mixer: loader.CPtr, gain: number)
        MIX.MIX_SetMixerGain(mixer, gain)
    end,

    createTrack = function(mixer: loader.CPtr): loader.CPtr
        local track = MIX.MIX_CreateTrack(mixer)
        if track == nil then return nil end
        return track
    end,

    destroyTrack = function(track: loader.CPtr)
        MIX.MIX_DestroyTrack(track)
    end,

    setTrackClip = function(track: loader.CPtr, clip: loader.CPtr): boolean
        return MIX.MIX_SetTrackAudio(track, clip) as boolean
    end,

    setTrackFile = function(track: loader.CPtr, path: string): boolean
        local file = C.SDL_IOFromFile(path, "rb")
        if file == nil then return false end
        -- Closed by the mixer when the track stops reading it, which is what
        -- keeps a streamed voice from leaking a descriptor per play.
        return MIX.MIX_SetTrackIOStream(track, file, true) as boolean
    end,

    clearTrack = function(track: loader.CPtr)
        MIX.MIX_SetTrackAudio(track, nil)
    end,

    play = function(track: loader.CPtr, params: PlayParams): boolean
        C.SDL_SetNumberProperty(playProps, PROP_LOOPS, params.loops)
        C.SDL_SetNumberProperty(playProps, PROP_LOOP_START_MS,
            params.loopStartMs)
        C.SDL_SetNumberProperty(playProps, PROP_FADE_IN_MS, params.fadeInMs)
        C.SDL_SetNumberProperty(playProps, PROP_START_MS, params.startMs)
        return MIX.MIX_PlayTrack(track, playProps) as boolean
    end,

    stop = function(track: loader.CPtr, fadeMs: integer)
        -- Frames here, milliseconds on the tag form. Converted through the
        -- track, so the answer follows the mixer's own rate.
        if fadeMs <= 0 then
            MIX.MIX_StopTrack(track, 0)
            return
        end
        MIX.MIX_StopTrack(track, MIX.MIX_TrackMSToFrames(track, fadeMs))
    end,

    pause = function(track: loader.CPtr)
        MIX.MIX_PauseTrack(track)
    end,

    resume = function(track: loader.CPtr)
        MIX.MIX_ResumeTrack(track)
    end,

    playing = function(track: loader.CPtr): boolean
        return MIX.MIX_TrackPlaying(track) as boolean
    end,

    setGain = function(track: loader.CPtr, gain: number)
        MIX.MIX_SetTrackGain(track, gain)
    end,

    setPitch = function(track: loader.CPtr, ratio: number)
        MIX.MIX_SetTrackFrequencyRatio(track, ratio)
    end,

    setPosition = function(track: loader.CPtr, x: number, y: number,
                           z: number)
        local fields = point as loader.CStruct
        fields.x = x
        fields.y = y
        fields.z = z
        MIX.MIX_SetTrack3DPosition(track, point)
    end,

    clearPosition = function(track: loader.CPtr)
        MIX.MIX_SetTrack3DPosition(track, nil)
    end,

    tag = function(track: loader.CPtr, tag: string)
        MIX.MIX_TagTrack(track, tag)
    end,

    untag = function(track: loader.CPtr, tag: string)
        MIX.MIX_UntagTrack(track, tag)
    end,

    pauseTag = function(mixer: loader.CPtr, tag: string)
        MIX.MIX_PauseTag(mixer, tag)
    end,

    resumeTag = function(mixer: loader.CPtr, tag: string)
        MIX.MIX_ResumeTag(mixer, tag)
    end,

    stopTag = function(mixer: loader.CPtr, tag: string, fadeMs: integer)
        MIX.MIX_StopTag(mixer, tag, fadeMs)
    end,
}

audiobackend.sdl = sdlBackend

return audiobackend
