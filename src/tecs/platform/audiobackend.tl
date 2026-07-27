--- The output half of the platform seam, for sound.
---
--- Audio only ever goes one way. A game opens an output, hands over PCM, sets
--- a gain and stops a voice; nothing comes back except how much of what was
--- handed over is still waiting. So unlike input, which has an event stream in
--- front of it, this seam is commands and one measurement, and that is the
--- whole contract a port has to answer.
---
--- The unit of playback is a stream, because the platform is what mixes. Every
--- stream bound to one device is summed by the backend into the buffer the
--- hardware reads, so playing two sounds at once means binding two streams and
--- not summing samples here.
---
--- No callbacks appear in this contract, in either direction. A platform that
--- drives audio from a callback runs it on a thread the Lua VM did not create,
--- and a Lua function invoked from such a thread is the unsafe case that keeps
--- raw thread creation unexposed (see `native/worker.c`). Feeding the device
--- by queueing is what makes that avoidable.
---
--- `Audio` holds a backend and never reaches the FFI itself. The SDL
--- implementation below is the worked example, and the only thing in the audio
--- layer that names an SDL symbol.

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")

local C <const> = sdl.C
local K <const> = sdl.K

--- The layout PCM is carried in.
---
--- Samples are always 32-bit float, so the format is two numbers rather than
--- three. Every clip is converted to this on the worker that loads it, which
--- is what lets one stream format serve every sound.
local record Spec
    --- Frames per second.
    frequency: integer
    --- Interleaved channels per frame.
    channels: integer
end

local record Backend
    --- Name this backend reports as. For diagnostics; it is not matched
    --- against.
    name: string

    --- Opens the platform's default playback output at `spec` and returns an
    --- id for it. Zero when there is no output, which is the answer a machine
    --- with no sound hardware gives and is not an error.
    ---
    --- The default specifically, not a device chosen by name. A platform that
    --- can follow its own default is expected to, so that plugging in
    --- headphones moves the sound without anything above here being told.
    openDevice: function(spec: Spec): integer
    closeDevice: function(device: integer)

    --- Creates a voice carrying `spec`. Nil when one cannot be made.
    createStream: function(spec: Spec): loader.CPtr
    destroyStream: function(stream: loader.CPtr)

    --- Starts mixing `stream` into `device`.
    bindStream: function(device: integer, stream: loader.CPtr): boolean
    --- Stops mixing it. What the stream still holds stays in it, so a voice
    --- that is going to be reused is cleared as well as unbound.
    unbindStream: function(stream: loader.CPtr)

    --- Queues `bytes` bytes of PCM at `data`. The platform takes a copy, so
    --- the caller may overwrite or free `data` as soon as this returns.
    ---
    --- A byte pointer rather than an opaque one, because what is handed over
    --- is an offset into a clip: a long sound is fed a piece at a time from
    --- the middle of its buffer.
    putData: function(stream: loader.CPtr, data: loader.BytePointer,
                      bytes: integer): boolean
    --- Bytes the stream still has to hand the device. Zero means everything
    --- queued has been consumed, which is the closest thing to a voice having
    --- finished that a queue-fed API can report.
    pendingBytes: function(stream: loader.CPtr): integer
    --- Drops everything the stream is holding.
    clearStream: function(stream: loader.CPtr)

    --- Scales a voice, 0 to 1 for silence to unchanged. Above 1 is louder and
    --- may clip, which is the platform's business rather than this layer's.
    setStreamGain: function(stream: loader.CPtr, gain: number): boolean
end

local record audiobackend
    Spec: Spec
    Backend: Backend
    --- The SDL backend, and the default everywhere.
    sdl: Backend
end

-------------------------------------------------------------------------------
-- The SDL backend
-------------------------------------------------------------------------------

--- Reusable spec, filled per call. Opening and creating are startup-shaped
--- work, but there is no reason to allocate for them either.
local audioSpec <const> = loader.newStruct("SDL_AudioSpec")

local function fill(spec: Spec)
    local fields = audioSpec as loader.CStruct
    fields.format = C.SDL_AUDIO_F32
    fields.channels = spec.channels
    fields.freq = spec.frequency
end

local sdlBackend <const>: Backend = {
    name = "sdl",

    openDevice = function(spec: Spec): integer
        -- The subsystem is started here rather than alongside video, because a
        -- machine with no sound is a machine that still runs. Failing the
        -- process's whole init over an output nobody may use is not the
        -- trade this makes.
        if tonumber(C.SDL_WasInit(K.SDL_INIT_AUDIO)) == 0 then
            if not C.SDL_InitSubSystem(K.SDL_INIT_AUDIO) then return 0 end
        end

        fill(spec)
        -- The default id, so SDL keeps the logical device pointed at whatever
        -- the system default becomes. Streams bound to it follow the move.
        --
        -- Not SDL_OpenAudioDeviceStream, which opens a device and one stream
        -- together and then refuses every further binding on it: a second
        -- voice on that device fails with "cannot change stream bindings on
        -- device opened with SDL_OpenAudioDeviceStream". This form starts
        -- unpaused as well, so nothing has to be resumed before it sounds.
        return tonumber(C.SDL_OpenAudioDevice(
            K.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, audioSpec)) as integer
    end,

    closeDevice = function(device: integer)
        C.SDL_CloseAudioDevice(device)
    end,

    createStream = function(spec: Spec): loader.CPtr
        fill(spec)
        -- Both ends the same: clips arrive already converted, so the stream
        -- resamples nothing and exists only to be a mixable queue.
        local stream = C.SDL_CreateAudioStream(audioSpec, audioSpec)
        if stream == nil then return nil end
        return stream
    end,

    destroyStream = function(stream: loader.CPtr)
        C.SDL_DestroyAudioStream(stream)
    end,

    bindStream = function(device: integer, stream: loader.CPtr): boolean
        return C.SDL_BindAudioStream(device, stream) as boolean
    end,

    unbindStream = function(stream: loader.CPtr)
        C.SDL_UnbindAudioStream(stream)
    end,

    putData = function(stream: loader.CPtr, data: loader.BytePointer,
                       bytes: integer): boolean
        return C.SDL_PutAudioStreamData(stream, data, bytes) as boolean
    end,

    pendingBytes = function(stream: loader.CPtr): integer
        local available = tonumber(C.SDL_GetAudioStreamAvailable(stream)) as integer
        if available < 0 then return 0 end
        return available
    end,

    clearStream = function(stream: loader.CPtr)
        C.SDL_ClearAudioStream(stream)
    end,

    setStreamGain = function(stream: loader.CPtr, gain: number): boolean
        return C.SDL_SetAudioStreamGain(stream, gain) as boolean
    end,
}

audiobackend.sdl = sdlBackend

return audiobackend
