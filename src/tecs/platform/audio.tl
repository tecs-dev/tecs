--[=[
Audio device discovery and pull-based microphone capture.

Published under `tecs.audio` beside the mixer, which is `tecs.audio.Audio`.
This half names physical devices for an `Audio.Config.device` and exposes
recording, which is a stream of bytes coming into the game rather than a
mixer sending sound out. Kept a file of its own because it reaches SDL and
nothing else, so listing devices never opens a mixer.
]=]

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")

local C <const> = sdl.C
local K <const> = sdl.K

local BYTES_PER_SAMPLE <const> = 4
local DEFAULT_FREQUENCY <const> = 48000
local DEFAULT_CHANNELS <const> = 1

local record Device
    id: number
    name: string
    frequency: integer
    channels: integer
end

--- An open recording device, pulled rather than pushed.
---
--- Capture is running by the time one of these exists, and SDL's own thread is
--- filling the stream behind it. Nothing arrives until `read` asks, so a game
--- that stops asking leaves samples to pile up in SDL's buffer rather than
--- losing them.
local record Microphone
    --- Samples per second, after SDL's conversion from whatever the device
    --- actually runs at. The value asked for, not the device's own.
    frequency: integer
    --- Interleaved channels per frame, again after conversion.
    channels: integer
    _stream: loader.CPtr
    _destroyed: boolean

    --- Complete sample frames ready to read without blocking.
    ---
    --- @return Whole frames only, so a partly arrived frame is not counted and
    ---     reads as zero until the rest of it lands. Zero once destroyed,
    ---     rather than an error.
    availableFrames: function(self: Microphone): integer

    --- Pulls up to `maxFrames` complete sample frames.
    ---
    --- @param maxFrames Omit to take everything ready now. Zero is allowed and
    ---     takes nothing. A limit above what is ready takes what is ready
    ---     rather than waiting for the rest.
    --- @return Interleaved native-endian float32 samples, as bytes in a string,
    ---     `channels * 4` per frame. An empty string means nothing was ready
    ---     and is not a failure. Nil on one, with the reason beside it: a
    ---     destroyed microphone, a `maxFrames` that is not a non-negative
    ---     integer, or SDL's own error.
    --- @return The reason, when the first return is nil.
    read: function(self: Microphone, maxFrames?: integer): string, string

    --- Stops the device filling the stream, keeping whatever is already in it.
    ---
    --- @return False with a reason on failure, including for a microphone
    ---     already destroyed. Pausing one already paused succeeds.
    --- @return The reason, when the first return is false.
    pause: function(self: Microphone): boolean, string

    --- Starts the device filling the stream again after `pause`.
    ---
    --- @return False with a reason on failure, including for a microphone
    ---     already destroyed.
    --- @return The reason, when the first return is false.
    resume: function(self: Microphone): boolean, string

    --- Stops capture and closes the recording device. Safe more than once.
    ---
    --- Whatever was captured and not yet read is discarded with the stream, so
    --- a last `read` belongs before this rather than after.
    destroy: function(self: Microphone)
end

local record MicrophoneConfig
    --- Physical device id from `recordingDevices`. Omitted uses the current
    --- system default.
    device: number
    --- Samples per second after SDL converts the device input. Defaults to
    --- 48000.
    frequency: integer
    --- Interleaved channels. Defaults to one.
    channels: integer
end

local record audio
    Device: Device
    Microphone: Microphone
    MicrophoneConfig: MicrophoneConfig
end

local MicrophoneMT <const>: metatable<Microphone> = {__index = Microphone}
local countOut <const> = loader.newArray("int[1]")
local framesOut <const> = loader.newArray("int[1]")
local deviceSpec <const> = loader.newStruct("SDL_AudioSpec")
local captureSpec <const> = loader.newStruct("SDL_AudioSpec")

local function ensureSubsystem(): boolean, string
    if tonumber(C.SDL_WasInit(K.SDL_INIT_AUDIO)) ~= 0 then
        return true, nil
    end
    if not C.SDL_InitSubSystem(K.SDL_INIT_AUDIO) then
        return false, sdl.error()
    end
    return true, nil
end

local function devices(recording: boolean): {Device}, string
    local ok, err = ensureSubsystem()
    if not ok then
        return {}, err
    end
    local ids: loader.CValue
    if recording then
        ids = C.SDL_GetAudioRecordingDevices(countOut)
    else
        ids = C.SDL_GetAudioPlaybackDevices(countOut)
    end
    local out: {Device} = {}
    if ids == nil then
        return out, sdl.error()
    end
    local list = ids as loader.CArray
    for index = 0, (countOut[0] as integer) - 1 do
        local id = tonumber(list[index]) as number
        local frequency, channels = 0, 0
        if C.SDL_GetAudioDeviceFormat(id, deviceSpec, framesOut) then
            local fields = deviceSpec as loader.CStruct
            frequency = tonumber(fields.freq) as integer
            channels = tonumber(fields.channels) as integer
        end
        out[#out + 1] = {
            id = id,
            name = loader.toString(C.SDL_GetAudioDeviceName(id)),
            frequency = frequency,
            channels = channels,
        }
    end
    C.SDL_free(ids)
    return out, nil
end

--- Physical playback devices attached now.
---
--- A snapshot, not a subscription: devices come and go while a game runs, so
--- an id held across a hotplug may name nothing.
---
--- @return The devices, listed afresh each call and the caller's to keep.
---     Empty rather than nil when the audio subsystem cannot start, so a caller
---     that only iterates needs no nil check.
--- @return SDL's reason, when something went wrong. Nil on success, including
---     for a machine that genuinely has no playback device.
function audio.playbackDevices(): {Device}, string
    return devices(false)
end

--- Physical recording devices attached now.
---
--- @return The devices, read as `playbackDevices` reads its own.
--- @return SDL's reason, when something went wrong.
function audio.recordingDevices(): {Device}, string
    return devices(true)
end

--- Opens a microphone as interleaved native-endian 32-bit float samples.
---
--- No callback is installed. SDL's audio thread fills its own stream and the
--- game pulls completed bytes from the main thread with `read`.
---
--- @param config May be nil, which opens the system's current default
---     recording device at 48000 Hz in mono. `frequency` has to be a positive
---     integer and `channels` an integer from 1 to 32; either outside that
---     range is reported rather than raised. SDL converts the device's real
---     format to what is asked for, so these are what `read` returns and not
---     what the hardware runs at.
--- @return An open microphone, already recording: the stream is resumed before
---     this returns, so samples accumulate from here whether or not anything
---     reads them. Nil on failure, with the reason beside it, and nothing is
---     left open in that case.
--- @return The reason, when the first return is nil.
function audio.openMicrophone(config?: MicrophoneConfig): Microphone, string
    local ok, err = ensureSubsystem()
    if not ok then
        return nil, err
    end
    local given = config or {} as MicrophoneConfig
    local frequency = given.frequency or DEFAULT_FREQUENCY
    local channels = given.channels or DEFAULT_CHANNELS
    if frequency < 1 or frequency ~= math.floor(frequency) then
        return nil, "microphone frequency must be a positive integer"
    end
    if channels < 1 or channels > 32 or channels ~= math.floor(channels) then
        return nil, "microphone channels must be an integer from 1 to 32"
    end

    local fields = captureSpec as loader.CStruct
    fields.format = C.SDL_AUDIO_F32
    fields.channels = channels
    fields.freq = frequency
    local stream = C.SDL_OpenAudioDeviceStream(
        given.device or K.SDL_AUDIO_DEVICE_DEFAULT_RECORDING, captureSpec, nil, nil
    )
    if stream == nil then
        return nil, sdl.error()
    end
    if not C.SDL_ResumeAudioStreamDevice(stream) then
        local message = sdl.error()
        C.SDL_DestroyAudioStream(stream)
        return nil, message
    end
    return setmetatable(
        {
            frequency = frequency,
            channels = channels,
            _stream = stream,
            _destroyed = false,
        } as Microphone,
        MicrophoneMT
    ), nil
end

function Microphone:availableFrames(): integer
    if self._destroyed then
        return 0
    end
    local bytes = tonumber(C.SDL_GetAudioStreamAvailable(self._stream)) as integer
    if bytes <= 0 then
        return 0
    end
    return math.floor(bytes / (self.channels * BYTES_PER_SAMPLE))
end

function Microphone:read(maxFrames?: integer): string, string
    if self._destroyed then
        return nil, "microphone is destroyed"
    end
    if maxFrames ~= nil and (maxFrames < 0 or maxFrames ~= math.floor(maxFrames)) then
        return nil, "maxFrames must be a non-negative integer"
    end
    local frames = self:availableFrames()
    if maxFrames ~= nil and maxFrames < frames then
        frames = maxFrames
    end
    if frames == 0 then
        return "", nil
    end
    local bytes = frames * self.channels * BYTES_PER_SAMPLE
    local buffer = loader.newArray("uint8_t[?]", bytes)
    local received = tonumber(C.SDL_GetAudioStreamData(self._stream, buffer, bytes)) as integer
    if received < 0 then
        return nil, sdl.error()
    end
    return loader.toBytes(buffer as loader.CValue, received), nil
end

function Microphone:pause(): boolean, string
    if self._destroyed then
        return false, "microphone is destroyed"
    end
    if not C.SDL_PauseAudioStreamDevice(self._stream) then
        return false, sdl.error()
    end
    return true, nil
end

function Microphone:resume(): boolean, string
    if self._destroyed then
        return false, "microphone is destroyed"
    end
    if not C.SDL_ResumeAudioStreamDevice(self._stream) then
        return false, sdl.error()
    end
    return true, nil
end

function Microphone:destroy()
    if self._destroyed then
        return
    end
    C.SDL_DestroyAudioStream(self._stream)
    self._stream = nil
    self._destroyed = true
end

return audio
