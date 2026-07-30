--[=[
Clips, voices, groups, limits, and entity-owned sound.

[`Application`](tealdoc:tecs.Application) exposes one
[`Audio`](tealdoc:tecs.audio.Audio) as `app.audio`. A platform without an output
device still provides the object, but `available` reports false and playback
returns handle zero.

## Playback

`load` returns a [`Future`](tealdoc:tecs.Future) for one shared clip per path.
Starting the load never blocks the frame. Reading a pending future's `value`
does, so that dereference is for startup, tools, and tests rather than a frame.

```teal
local step <const> = app.audio:load("assets/sfx/step.ogg").value
app.audio:setLimit("footstep", {
    voices = 3,
    cooldown = 0.05,
})

local voice <const> = app.audio:play(step, {
    gain = 0.7,
    group = "sfx",
    key = "footstep",
    pitchVariance = 0.1,
})

if voice ~= 0 then
    app.audio:stop(voice, 0.2)
end
```

Clips shorter than `streamSeconds` stay resident and share decoded samples.
Longer clips stream separately for each voice. `LoadOptions.stream` overrides
that choice. Use `Audio.decoders()` when a game needs to report the formats
available in the current build.

A stale voice handle never controls a later voice that reuses its slot.
Commands ignore stale handles and queries return false or nil.

## Groups and limits

A group controls gain, mute, pause, resume, and stop. Its settings also apply
to voices that join later. A key controls admission through a concurrent voice
limit and cooldown. One voice may use both.

Snapshots retain master and group settings. Pitch variance uses the world's
snapshotted `tecs.audio` random stream.

## Placement

`setPosition` uses right-handed coordinates with a listener fixed at the
origin. The game chooses the listener, subtracts its position, and converts
world units to an audio scale. `setStereo` assigns explicit left and right
gains. The latest placement call replaces the earlier mode.

## Entity-owned sound

An entity can carry [`Sound`](tealdoc:tecs.audio.Sound) instead of keeping a voice handle. The audio system
starts it, follows writable playback fields, and stops it when the component or
entity disappears. Write through `world:getMut`. A direct FFI write needs
`world:markComponentDirty`, and `batchSpawn` must initialize every field.
]=]
-- Implementation details:
-- SDL_mixer supplies the decoders and represents each voice as a track.
-- Resident loads cross the asset worker as owned addresses; streamed voices
-- open their own decoder.
-- Voice handles pack a slot with its generation, so recycling a slot
-- invalidates every older handle to it.
--
-- SDL_mixer can report track completion from an audio thread LuaJIT did not
-- create. Audio installs no Lua callback there. `update` polls sounding tracks
-- and reaps a completed voice on the following frame.
--
-- Mixer tags implement group operations on voices that already sound. Tecs
-- records group state separately so later voices inherit gain, mute, and pause.
-- Tecs also owns key counts and cooldowns because the mixer has no admission
-- model.

local ecs <const> = require("tecs.ecs")
local type types = require("tecs.types")
local assets <const> = require("tecs.assets")
local random <const> = require("tecs.random")
local loader <const> = require("tecs.ffi.loader")
local sdl3mixer <const> = require("tecs.ffi.sdl3mixer")
local adapter <const> = require("tecs.platform.adapter")
local audiobackend <const> = require("tecs.platform.audiobackend")
local platformaudio <const> = require("tecs.platform.audio")
local log <const> = require("tecs.log")

local Future <const> = require("tecs.Future")

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
--- generation, so a handle whose slot the mixer has finished and reused
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
--- code assigns the integer a component carries in load order, and load order is
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
    if id ~= nil then
        return id
    end
    clipCount = clipCount + 1
    clipIds[path] = clipCount
    clipPaths[clipCount] = path
    return clipCount
end

-------------------------------------------------------------------------------
-- Interned group names
-------------------------------------------------------------------------------

--- A group's name is its identity, for the same reason a clip's path is: the
--- code assigns the integer a component carries in first-use order, which a
--- snapshot cannot rely on reproducing.
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
    if id ~= nil then
        return id
    end
    groupCount = groupCount + 1
    groupIds[name] = groupCount
    groupNames[groupCount] = name
    return groupCount
end

-------------------------------------------------------------------------------
-- The component
-------------------------------------------------------------------------------

--- Represents a sound attached to an entity.
---
--- Presence is the instruction: an entity carrying this with a loaded clip
--- starts sounding on the next audio pass, and stops when the component or
--- the entity goes away. That is what makes sound an entity rather than a
--- handle a game has to remember to release, and it is why despawning
--- something mid-sound does the obvious thing.
---
--- The audio pass sends position to the mixer and does nothing else with it.
--- `spatial` switches it on, and the mixer reads `x`, `y` and `z` in a right-handed
--- system. The mixer fixes its listener at the origin, with x
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
--- A name identifies a group, just as a path identifies a clip. An FFI component holds numbers, so what
--- `group` carries is an interned index from `Audio.groupId` rather than the
--- mixer's tag itself, and `Audio.groupName` reads it back. The index is this
--- run's and no other, which is why `serialize` writes the name: an integer in
--- a save file would name a different group the next time a build interned its
--- names in a different order.
---
--- The audio pass follows `playing`, `gain`, `loop`, `pitch` and the position for as
--- long as the voice sounds, so writing any of them is enough and nothing has
--- to restart the voice to apply a change. Each of those costs one read and compare per
--- sounding row per frame, which is the price of the component being live and
--- is why `clip` and `group` are not on the list: both take an untag, a
--- retag and a fresh input to change, neither is something a game writes
--- often, and following them would put that cost on every row that never
--- does. Moving a sound into another group is setting `group` and clearing
--- `voice`, which is the same thing changing its clip takes.
---
--- Disabling an entity silences its sound and re-enabling starts it again.
--- Queries exclude [`Disabled`](/modules/ecs/#tecs.ecs.Disabled) unless they name it, so a
--- disabled row is not followed and its voice is taken back; the audio pass
--- clears the handle at the same moment, which is what lets the sound return
--- with the entity rather than reading as a one-shot that had finished.
local record Sound is Component
    --- Caller-writable. Selects a clip by its `Audio.clipId` index. Zero plays
    --- nothing.
    clip: number
    --- Caller-writable. Uses nonzero to request playback and zero to stop. This
    --- field gives an instruction rather than a report:
    --- clearing it stops the voice and setting it again starts one, including
    --- on a one-shot that has already run out.
    playing: number
    --- Caller-writable. Sets linear gain from zero to one before group and
    --- master gain.
    gain: number
    --- Caller-writable. Uses nonzero to repeat. Clearing it part way through lets the voice play out
    --- to its end rather than cutting it.
    loop: number
    --- Caller-writable. Sets playback rate. One leaves it unchanged, while two
    --- plays an octave higher in half the time.
    pitch: number
    --- Caller-writable. Uses nonzero to read `x`, `y`, and `z`; zero mixes
    --- without a position.
    spatial: number
    --- Caller-writable. Sets the position right of the listener.
    x: number
    --- Caller-writable. Sets the position above the listener.
    y: number
    --- Caller-writable. Sets the position behind the listener.
    z: number
    --- Caller-writable. Selects a group by its `Audio.groupId` index. Zero
    --- joins no group.
    group: number
    --- Engine-owned. Reports the voice assigned by the audio pass: zero before
    --- it starts and negative once a
    --- one-shot has finished. Written by the engine; setting it back to zero
    --- is how a game asks for the sound again.
    voice: number
end

ecs.newFFIComponent({
    name = "Sound",
    container = Sound,
    fields = {
        {"clip", "int32_t"},
        {"playing", "uint8_t"},
        {"gain", "float"},
        {"loop", "uint8_t"},
        {"pitch", "float"},
        {"spatial", "uint8_t"},
        {"x", "float"},
        {"y", "float"},
        {"z", "float"},
        {"group", "int32_t"},
        {"voice", "int32_t"},
    },
    defaults = {0, 1, 1.0, 0, 1.0, 0, 0.0, 0.0, 0.0, 0, 0},
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
    deserialize = function(_world: types.World, data: {string: any}): Sound
        local path = data.clip as string
        local clip = 0
        if path ~= nil and path ~= "" then
            clip = clipId(path)
        end
        local name = data.group as string
        local group = 0
        if name ~= nil and name ~= "" then
            group = groupId(name)
        end
        -- A file written before `playing` existed carries no answer, and the
        -- one that matches what it recorded is that the sound was on.
        local playing = 1
        if data.playing == false then
            playing = 0
        end
        -- The voice is not restored. A snapshot records that an entity has a
        -- sound, not how far through it the mixer had got, so it starts.
        return Sound(
            clip,
            playing,
            data.gain as number,
            (data.loop as boolean) and 1 or 0,
            (data.pitch as number) or 1.0,
            (data.spatial as boolean) and 1 or 0,
            (data.x as number) or 0.0,
            (data.y as number) or 0.0,
            (data.z as number) or 0.0,
            group
        )
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
    --- Tracks whether the voice uses the front pair rather than a position, and
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

-- Implementation details: The mixer and its devices share one public module.
-- The device implementation remains in the platform layer.
local record audio
    --- Represents one audio output and the voices sounding on it.
    ---
    --- Units, in one place, because none of them is in a signature:
    ---
    ---   * **Time is seconds** everywhere on this surface: a fade, a seek, a loop
    ---     point, a cooldown, a clip's duration. Milliseconds appear only below the
    ---     platform seam. Every fade is a duration to run for, never a moment to
    ---     finish at, so calling one twice restarts it rather than moving a
    ---     deadline.
    ---   * **Gain is linear amplitude, not decibels.** 0 is silence and 1 is the
    ---     sound as recorded. Above 1 is louder and may clip. The level a voice
    ---     reaches the hardware at is its own gain times its group's gain times the
    ---     master gain, and a mute at either level composes as a zero without
    ---     discarding the gain underneath it.
    ---   * **Pitch is a playback rate, not an interval.** 1 preserves the
    ---     original rate, 2 is an
    ---     octave up and half as long, 0.5 an octave down and twice as long. It
    ---     resamples, so it changes duration; there is no time-stretch here.
    ---   * **Position is the mixer's frame, not the world's.** The mixer fixes
    ---     the listener at the origin. x is positive to the right, y
    ---     is positive **up**, and z is positive behind. World Y runs down, so a
    ---     caller feeding world coordinates in has to flip Y as well as subtract
    ---     whatever it decided is listening. See [`Sound`](tealdoc:tecs.audio.Sound).
    ---
    --- A voice handle is a generation and a slot packed into one integer. It stays
    --- meaningful for exactly as long as the voice sounds. When a voice ends
    --- naturally or either `stop` or `update` ends it, every call taking the handle becomes a
    --- no-op, and it never starts naming the next voice to take that slot. Nothing
    --- requires release, and holding a stale handle is not an error.
    ---
    --- Nothing here is thread safe, and nothing here calls back. Everything runs on
    --- the thread that calls it.
    record Audio
        --- Configures `newAudio` through optional fields.
        record Config
            --- Caller-writable. Sets the sample frequency in frames per second
            --- and defaults to 48000.
            frequency: integer
            --- Caller-writable. Sets the number of output channels and defaults
            --- to two.
            channels: integer
            --- Caller-writable. Sets how many voices may sound at once and
            --- defaults to 32.
            maxVoices: integer
            --- Caller-writable. Sets the duration in seconds at which a clip
            --- streams instead of remaining resident.
            --- Defaults to 10.
            streamSeconds: number
            --- Caller-writable. Selects the output backend and defaults to the
            --- installed platform backend.
            backend: Backend
            --- Caller-writable. Selects a physical output device by an id from
            --- `tecs.audio.playbackDevices`.
            --- Omitted follows the operating-system default as it changes.
            device: number
        end

        --- Represents one shared playable sound after its load.
        ---
        --- `load` settles a future with this only after reading succeeds.
        --- `clip` also exposes the cached instance while its load is pending or
        --- after it fails, which is why the status and error remain visible.
        --- Every load for the same path shares one instance.
        record Clip
            --- Read-only. Reports the path used to load the clip,
            --- exactly as given. This is a clip's
            --- identity, so two spellings of one file are two clips.
            path: string
            --- Read-only. Reports the `path` index carried by a
            --- [`Sound`](tealdoc:tecs.audio.Sound) component.
            id: integer
            --- Read-only. Reports `"pending"` while the loader reads the file,
            --- then `"ready"` or `"failed"`, and `"released"` once the owning
            --- [`Audio`](tealdoc:tecs.audio.Audio) is destroyed.
            ---
            --- These four words reach an agent over JSON-RPC, through the
            --- `audio` debug tool's clip list, so they are a compatibility
            --- surface rather than identifiers this tree renames in one commit.
            ---
            --- The first three are [`Future`](tealdoc:tecs.Future)'s, because a
            --- clip's first three states are its load's. `"released"` has no
            --- counterpart there: a released clip is a load that succeeded and
            --- then had its samples given back, and a future has no word for
            --- that because a future ends at the answer. `"canceled"` never
            --- appears here, because the only thing that gives up a clip's load
            --- is `destroy`, which has written `"released"` by then.
            status: string
            --- Read-only. Reports the error when loading fails.
            error: string
            --- Read-only. Reports the audio duration in seconds, or zero when
            --- the file cannot provide one.
            duration: number
            --- Read-only. Reports whether decoded audio remains in memory.
            --- False identifies a clip each
            --- voice reads from the file for itself.
            resident: boolean

            --- Engine-owned. Stores the settled asset so reload and destroy can
            --- manage it. Ordinary game code should ignore this field. The value
            --- swap it and `destroy` can release it. Nil until the load lands,
            --- and nil again once released.
            _sound: assets.Sound
        end

        --- Configures `load` through one optional field.
        record LoadOptions
            --- Caller-writable. Forces streaming when true and residency when
            --- false. Left unset,
            --- the clip's duration decides against `streamSeconds`.
            stream: boolean
        end

        --- Configures `play` through optional fields. The whole table may be
        --- omitted.
        ---
        --- Read once, when the voice starts. Changing the table afterwards reaches
        --- nothing: use `setGain`, `setPitch`, `setLoop`, `setPosition` and
        --- `setStereo` on the handle instead. The table is not retained, so one
        --- a caller may fill and reuse one table for every play.
        record PlayOptions
            --- Caller-writable. Sets linear gain from zero to one before group
            --- and master gains. Defaults to one.
            gain: number
            --- Caller-writable. Repeats playback until stopped and defaults to
            --- false.
            loop: boolean
            --- Caller-writable. Sets the position in seconds to which a repeat
            --- returns, so an
            --- intro can play once and the rest of it loop. Defaults to 0.
            loopStart: number
            --- Caller-writable. Sets where the first pass begins in seconds and
            --- defaults to zero.
            start: number
            --- Caller-writable. Sets the fade-in duration in seconds and
            --- defaults to zero.
            fadeIn: number
            --- Caller-writable. Sets playback rate and defaults to one.
            pitch: number
            --- Caller-writable. Sets the fraction of `pitch` varied for each
            --- new voice. A value of 0.1
            --- spreads voices over plus or minus a tenth. Defaults to 0.
            pitchVariance: number
            --- Caller-writable. Selects the group this voice joins and defaults
            --- to none.
            group: string
            --- Caller-writable. Selects the limit bucket counted by this voice
            --- and defaults to none.
            key: string
            --- Caller-writable. Enables spatial positioning. See
            --- [`Sound`](tealdoc:tecs.audio.Sound) for
            --- the coordinate system.
            spatial: boolean
            --- Caller-writable. Sets the position right of the listener and
            --- defaults to zero.
            x: number
            --- Caller-writable. Sets the position above the listener, which
            --- uses the opposite sign from
            --- world Y. Defaults to 0.
            y: number
            --- Caller-writable. Sets the position behind the listener and
            --- defaults to zero.
            z: number
            --- Caller-writable. Pins the voice to the front pair of speakers at `left` and
            --- `right`, which is a pan rather than a position. Ignored when
            --- `spatial` is set, because the mixer holds one placement per track.
            --- Both gains default to 1.
            stereo: boolean
            --- Caller-writable. Sets left-speaker gain on the same linear scale as `gain`.
            --- Negative reads as silence and above 1 is louder. Defaults to 1.
            left: number
            --- Caller-writable. Sets right-speaker gain on the same terms as
            --- `left`.
            right: number
        end

        --- Defines what a key allows.
        record Limit
            --- Caller-writable. Sets how many voices this key may hold at once.
            --- Zero or absent removes the ceiling.
            voices: integer
            --- Caller-writable. Sets the cooldown in seconds after a voice
            --- starts. Zero disables the cooldown.
            cooldown: number
        end

        --- Describes one sounding voice for inspection.
        record VoiceInfo
            --- Read-only. Reports the handle accepted by `playing` and `stop`.
            handle: integer
            --- Read-only. Reports the clip path, or nil after release.
            clip: string
            --- Read-only. Reports the gain requested by the voice before group
            --- and master gain.
            gain: number
            --- Read-only. Reports the gain applied to the track, including
            --- group gain and mute. The
            --- master gain is not in it: that is the mixer's own number and is not
            --- multiplied per voice.
            applied: number
            --- Read-only. Reports the playback rate carried by the track, so the pitch variance a
            --- value already includes any variance that `play` drew rather
            --- than only the requested rate.
            pitch: number
            --- Read-only. Reports the group tag, or nil for no group.
            group: string
            --- Read-only. Reports the limit bucket, or nil for no bucket.
            key: string
            --- Read-only. Reports whether its own pause or its group holds it.
            paused: boolean
            --- Read-only. Reports whether a fade-out is stopping the voice.
            stopping: boolean
            --- Read-only. Reports whether a
            --- [`Sound`](tealdoc:tecs.audio.Sound) component started the
            --- voice instead of `play`.
            owned: boolean
            --- Read-only. Reports whether playback repeats at the end.
            loop: boolean
            --- Read-only. Reports whether the voice has a spatial position.
            --- This remains false when
            --- `stereo`: the mixer holds one placement per track.
            spatial: boolean
            --- Read-only. Reports the last horizontal position pushed in the
            --- mixer's coordinate system, positive right.
            --- Meaningless unless `spatial`.
            x: number
            --- Read-only. Reports the last vertical position pushed, positive
            --- up. It has no meaning unless `spatial`.
            y: number
            --- Read-only. Reports the last depth position pushed, positive
            --- behind. It has no meaning unless
            --- `spatial`.
            z: number
            --- Read-only. Reports whether the voice remains pinned to the front
            --- speaker pair.
            stereo: boolean
            --- Read-only. Reports the last left-speaker gain pushed. It has no
            --- meaning unless `stereo`.
            left: number
            --- Read-only. Reports the last right-speaker gain pushed. It has no
            --- meaning unless `stereo`.
            right: number
        end

        --- Read-only. Exposes the [`Sound`](tealdoc:tecs.audio.Sound)
        --- component for queries and writes. See
        --- the record's own documentation for what its fields mean.
        Sound: Sound

        --- Read-only. Reports whether an output opened. False identifies a
        --- machine with no sound, where
        --- every call here still works and nothing is heard.
        available: boolean

        --- Engine-owned. Stores the platform audio backend. Ordinary game code
        --- should ignore this field.
        _backend: Backend

        --- Engine-owned. Stores the open output. Ordinary game code should
        --- ignore this field. It remains nil on a machine that has none and again
        --- after `destroy`, which is what `available` reports.
        _mixer: loader.CPtr

        --- Engine-owned. Stores the opened output layout. Ordinary game code
        --- should ignore this field.
        _spec: audiobackend.Spec

        --- Engine-owned. Stores a reusable play-options record. Ordinary game
        --- code should ignore this field. Every field is
        --- written each time, so nothing carries over between voices.
        _params: audiobackend.PlayParams

        --- Engine-owned. Stores every voice slot. Ordinary game code should
        --- ignore this field. Its
        --- length is `maxVoices` and never changes after `newAudio`.
        _voices: {Voice}

        --- Engine-owned. Stores unused voice slots. Ordinary game code should
        --- ignore this field. The stack is taken from the end, so the first
        --- sound of a run gets slot one.
        _free: {integer}

        --- Engine-owned. Stores how many slots remain in use. Ordinary game
        --- code should use `sounding`.
        _sounding: integer

        --- Engine-owned. Stores the streaming threshold in milliseconds.
        --- Ordinary game code should ignore this field. This is where
        --- `streamSeconds` ends up.
        _streamMs: integer

        --- Engine-owned. Stores master gain while mute holds output down.
        --- Ordinary game code should use the master-gain methods rather than
        --- this field.
        --- discarding.
        _masterGain: number

        --- Engine-owned. Stores whether master mute holds output at zero.
        --- Ordinary game code should use the mute methods.
        _muted: boolean

        --- Engine-owned. Stores gain by group name. Ordinary game code should
        --- use the group-gain methods. An absent entry means one.
        --- on the mixer's tags, whose per-tag gain would overwrite each voice's
        --- own.
        _groupGains: {string: number}

        --- Engine-owned. Stores mute state by group name. Ordinary game code
        --- should use the group-mute methods.
        _groupMuted: {string: boolean}

        --- Engine-owned. Stores pause state by group name. Ordinary game code
        --- should use the group-pause methods. It provides a standing
        --- instruction, so a voice starting into a paused group is held too.
        _groupPaused: {string: boolean}

        --- Engine-owned. Stores limits by key. Ordinary game code should use
        --- `setLimit` and `limit`.
        _limits: {string: Audio.Limit}

        --- Engine-owned. Stores the live count and last start time by key.
        --- Ordinary game code should ignore this field. Entries appear on the first
        --- voice counted against it.
        _buckets: {string: Bucket}

        --- Engine-owned. Stores loaded clips by interned index. Ordinary game
        --- code should use the clip methods.
        _clips: {integer: Clip}

        --- Engine-owned. Stores loads in flight by clip index. Ordinary game
        --- code should ignore this field, which lets `destroy` give up
        --- what the drain ran out of time on.
        _inFlight: {integer: Future<assets.Sound>}

        --- Engine-owned. Stores the caller futures still watching cached loads.
        --- Ordinary game code should ignore this field. Each caller gets one,
        --- so canceling it does not cancel another caller or the cache's own
        --- interest. `destroy` cancels them before giving up the owned load.
        _loadCallers: {Future<Audio.Clip>: boolean}

        --- Engine-owned. Counts the loads in `_inFlight`. Ordinary game code
        --- should use `loading`.
        ---
        --- A count rather than a walk of the table above, because it is read on
        --- a frame and because it is what `waitForLoads` and `destroy` test
        --- before entering the loader's drain: this instance having nothing
        --- outstanding is the one case where the drain's process-wide scope
        --- would make it wait on somebody else's work for nothing.
        _loading: integer
        --- Engine-owned. Stores the random stream used for pitch variance.
        --- Ordinary game code should ignore this field. It remains private until `install`
        --- points it at the world's `tecs.audio` stream, so a save carries the
        --- rate the next shot fires at rather than restarting the variance.
        _random: random.Random
        --- Engine-owned. Stores the seconds passed to `update`, which a cooldown
        --- uses.
        --- measured against.
        _now: number
    end

    --- Read-only. Exposes the [`Sound`](tealdoc:tecs.audio.Sound) component
    --- that plays a clip from an entity.
    Sound: Sound

    --- Configures `newAudio`.
    type Config = Audio.Config
    --- A loaded clip, or one still loading.
    type Clip = Audio.Clip
    --- Configures `Audio:load`.
    type LoadOptions = Audio.LoadOptions
    --- Configures `Audio:play`.
    type PlayOptions = Audio.PlayOptions
    --- Defines how many voices a key allows and how soon it may repeat.
    type Limit = Audio.Limit
    --- Describes one voice returned by `Audio:voices`.
    type VoiceInfo = Audio.VoiceInfo

    --- Describes a physical device before the game opens it.
    type Device = platformaudio.Device
    --- An open recording device, read by polling.
    type Microphone = platformaudio.Microphone
    --- Configures `openMicrophone`.
    type MicrophoneConfig = platformaudio.MicrophoneConfig

    --- Builds the mixer a game plays sound through, opening the platform's
    --- default output.
    ---
    --- Never raises for want of hardware. A machine with no sound card gets an
    --- object whose calls all succeed and produce nothing, because few games
    --- require an audio device while many test machines lack one.
    ---
    --- @param config Omitted takes the defaults. `maxVoices` outside 1 to
    ---     65535 raises, which is the one field here that does; every other
    ---     one out of range is the platform's to refuse.
    --- @return The mixer, which the caller has to `destroy`. Check `available`
    ---     for whether an output actually opened; it is false on a machine
    ---     with no sound, and every call still succeeds and is silent.
    newAudio: function(config?: Audio.Config): Audio

    --- Returns the physical playback devices attached now.
    ---
    --- @return The devices, listed afresh each call and the caller's to keep.
    ---     Empty rather than nil when the subsystem cannot start.
    --- @return SDL's reason, when something went wrong.
    playbackDevices: function(): {platformaudio.Device}, string

    --- Returns the physical recording devices attached now.
    ---
    --- @return The devices, listed afresh each call and the caller's to keep.
    ---     Empty rather than nil when the subsystem cannot start.
    --- @return SDL's reason, when something went wrong.
    recordingDevices: function(): {platformaudio.Device}, string

    --- Opens a microphone as interleaved native-endian 32-bit float samples.
    ---
    --- The API installs no callback. The audio thread fills its own stream and
    --- the game pulls completed bytes from the main thread with `read`.
    ---
    --- @param config Omitted opens the default recording device at its own
    ---     frequency and channel count.
    --- @return The open microphone, whose closing is the caller's through
    ---     `destroy`. Nil on failure, and nothing is left open in that case.
    --- @return The reason, when the first return is nil.
    openMicrophone: function(config?: platformaudio.MicrophoneConfig): platformaudio.Microphone, string
end

local type Audio = audio.Audio

local AudioMT <const>: metatable<Audio> = {__index = Audio}

--- The audio each world had installed into it. Weak, so a world that has gone
--- takes its entry with it.
---
--- Declared here rather than beside `Audio.of`, because `destroy` clears the
--- entries naming it and reads this well before that point in the file.
local installed <const>: {types.World: Audio} = setmetatable({}, {__mode = "k"} as metatable<{types.World: Audio}>)

Audio.Sound = Sound

audio.Sound = Sound

-- The device half, under this module's public names. `platform/audio.tl` is
-- the seam and reaches only SDL; `tecs.audio` is the surface, the way
-- `tecs.io.files` publishes what `platform/content.tl` holds.
audio.playbackDevices = platformaudio.playbackDevices
audio.recordingDevices = platformaudio.recordingDevices
audio.openMicrophone = platformaudio.openMicrophone

--- Returns the index of a clip path and assigns one on first use.
---
--- @param path Must be non-empty; an empty one raises. Not checked against the
---     filesystem, so this hands out an index for a path that does not exist.
--- @return An index from 1 up, shared by every
---     [`Audio`](tealdoc:tecs.audio.Audio) in the process. It belongs only to
---     this run and means nothing in a file, which is why
---     [`Sound`](tealdoc:tecs.audio.Sound)
---     serializes the path instead.
function Audio.clipId(path: string): integer
    return clipId(path)
end

--- Returns the path represented by a clip index, or nil.
---
--- @param id Zero is the index of no clip and answers nil, as does any index
---     never handed out.
function Audio.clipPath(id: integer): string
    return clipPaths[id]
end

--- Returns the index of a group name and assigns one on first use.
---
--- What a [`Sound`](tealdoc:tecs.audio.Sound) carries in `group`. The index
--- means nothing outside the run that handed it out, so it belongs in a
--- component and never in a file.
---
--- @param name Must be non-empty; an empty one raises. A group needs no
---     declaring: naming one here is all it takes to exist.
--- @return An index from 1 up, shared by every
---     [`Audio`](tealdoc:tecs.audio.Audio) in the process.
function Audio.groupId(name: string): integer
    return groupId(name)
end

--- Returns the name represented by a group index, or nil.
---
--- @param id Zero is the index of no group and answers nil, which is what a
---     [`Sound`](tealdoc:tecs.audio.Sound) in no group carries.
function Audio.groupName(id: integer): string
    return groupNames[id]
end

--- Returns the decoders linked into this build in mixer order.
---
--- What a build asked for and what it got are different questions: a decoder
--- The mixer silently omits a decoder whose dependency the build could not find.
--- This function answers the second question.
---
--- @return Decoder names such as `"WAV"` and `"OGG"`, in the mixer's own order
---     rather than sorted, and empty when the mixer will not start at all. A
---     fresh table each call.
function Audio.decoders(): {string}
    if not sdl3mixer.init() then
        return {}
    end
    return sdl3mixer.decoders()
end

--- Takes one finished load into the clip it was read for.
---
--- Shared rather than closed over an instance: nothing here reads the mixer,
--- so every `Audio` settles its loads through the same function.
local function settleClip(clip: Audio.Clip, settled: Future<assets.Sound>)
    if settled.status == "ready" then
        local sound <const> = settled.value
        clip._sound = sound
        clip.resident = sound.resident
        clip.duration = sound.durationMs >= 0 and sound.durationMs / 1000 or 0.0
        clip.status = "ready"
        return
    end
    clip.status = "failed"
    clip.error = settled.error
    LOGGER:error("cannot load '%s': %s", clip.path, settled.error or "unknown")
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function audio.newAudio(config?: Audio.Config): Audio
    local given = config or {} as Audio.Config
    local self = setmetatable({} as Audio, AudioMT)

    self._backend = given.backend or adapter.current().audio or audiobackend.sdl
    self._spec = {
        frequency = given.frequency or DEFAULT_FREQUENCY,
        channels = given.channels or DEFAULT_CHANNELS,
    }
    self._streamMs = math.floor((given.streamSeconds or DEFAULT_STREAM_SECONDS) * 1000)

    local maxVoices = given.maxVoices or DEFAULT_MAX_VOICES
    if maxVoices < 1 or maxVoices >= SLOT_SPAN then
        error(("tecs: maxVoices must be between 1 and %d"):format(SLOT_SPAN - 1), 2)
    end
    self._voices = {}
    self._free = {}
    for slot = 1, maxVoices do
        self._voices[slot] = {
            gain = 1.0,
            applied = -1.0,
            pitch = 1.0,
            generation = 0,
            sounding = false,
            stopping = false,
            paused = false,
            owned = false,
            referenced = false,
            loop = false,
            spatial = false,
            x = 0.0,
            y = 0.0,
            z = 0.0,
            stereo = false,
            left = 1.0,
            right = 1.0,
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
    self._inFlight = {}
    self._loadCallers = {}
    self._loading = 0
    self._random = random.new()
    self._now = 0.0
    -- One options record, overwritten per play. Every field is set each time,
    -- so nothing carries over from the previous voice.
    self._params = {loops = 0, loopStartMs = 0, fadeInMs = 0, startMs = 0}

    self._mixer = self._backend.open(self._spec, given.device)
    self.available = self._mixer ~= nil
    if not self.available then
        LOGGER:info("no audio output; sound is silent for this run")
    end
    return self
end

--- Stops everything and closes the output.
---
--- Blocks until this instance's loads have settled, since a clip arriving
--- afterwards would hold a pointer into a library that has released everything
--- it made. A load the wait ran out of time on is given up instead.
--- This method stops every voice without a fade, moves every clip to
--- `"released"`, and removes this mixer from every world that installed it.
--- There is no reopening: make a new instance instead.
function Audio:destroy()
    -- Drained first. A clip that arrived after the mixer had gone would hold a
    -- pointer into a library that has released everything it made. The drain is
    -- the loader's, so it covers every load in the process and not only this
    -- instance's, which can lengthen this wait and cannot shorten it: the
    -- guarantee this needs survives the wider scope, and the count is what keeps
    -- an instance with nothing outstanding from paying for it.
    if self._loading > 0 then
        assets.waitAll()
    end

    for slot = 1, #self._voices do
        local voice = self._voices[slot]
        if voice.track ~= nil then
            if voice.sounding then
                self._backend.stop(voice.track, 0)
            end
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
        if clip._sound ~= nil then
            clip._sound:release()
            clip._sound = nil
        end
        clip.resident = false
        clip.status = "released"
    end
    self._clips = {}
    -- Cancel every caller link first. Each one gives its watcher on the owned
    -- asset future back, so canceling the root below can reach zero even when a
    -- caller kept the future after this Audio was destroyed.
    local callers <const> = self._loadCallers
    self._loadCallers = {}
    for caller in pairs(callers) do
        caller:cancel()
    end
    -- Whatever the wait above ran out of time on is given up rather than left
    -- to settle into a mixer that has gone. A canceled decode still has its
    -- address destroyed when the worker answers, so nothing is leaked by it.
    --
    -- Taken off the instance before the walk: canceling a load settles it, and
    -- its settlement runs the listener that clears its own entry, so walking the
    -- live table would be a `pairs` over something a listener is changing.
    local outstanding <const> = self._inFlight
    self._inFlight = {}
    for _, loading in pairs(outstanding) do
        loading:cancel()
    end
    self._loading = 0

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
    for world, mixer in pairs(installed) do
        if mixer == self then
            installed[world] = nil
        end
    end
end

-------------------------------------------------------------------------------
-- Clips
-------------------------------------------------------------------------------

--- Returns one future for this caller over the shared cached load.
local function callerLoad(self: Audio, clip: Audio.Clip, loading: Future<assets.Sound>): Future<Audio.Clip>
    local caller <const> = loading:map(function(): Audio.Clip return clip end)
    self._loadCallers[caller] = true
    caller:onSettle(function(settled: Future<Audio.Clip>) self._loadCallers[settled] = nil end)
    return caller
end

--- Queues a sound for loading and returns a future for its clip.
---
--- Loading the same path twice returns distinct futures over one load and one
--- eventual clip; a clip is the file, and playing it twice over is two voices
--- reading one clip. Canceling one caller's future does not cancel another or
--- the cached load. `options.stream` overrides the duration threshold that
--- otherwise decides whether the clip is held in memory.
---
--- @param path Must be non-empty. Not checked here: a path that does not exist
---     returns a failed future a frame or two later, so this never raises for
---     a missing file.
--- @return A caller-owned [`Future`](tealdoc:tecs.Future) that settles with the
---     cached clip after the load succeeds. Concurrent calls return distinct
---     futures whose ready values are the same table. A later call returns an
---     already-settled future. Only the first call reads `options`.
function Audio:load(path: string, options?: Audio.LoadOptions): Future<Audio.Clip>
    local id = clipId(path)
    local existing = self._clips[id]
    if existing ~= nil then
        if existing.status == "ready" then
            return Future.settled(existing)
        end
        if existing.status == "failed" then
            return Future.failed(existing.error or ("cannot load " .. path))
        end
        local inFlight <const> = self._inFlight[id]
        if inFlight ~= nil then
            return callerLoad(self, existing, inFlight)
        end
        return Future.failed("cannot load " .. path)
    end

    -- The worker is what reads the file, and a game that only ever plays
    -- sound has no other reason to have started it.
    if not assets.installed() then
        assets.install()
    end

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
        status = "pending",
        duration = 0.0,
        resident = false,
    }
    self._clips[id] = clip

    -- The listener is attached where the work starts rather than added to a
    -- list something else drains, so nothing walks the outstanding loads on a
    -- frame where none of them finished.
    local loading <const> = assets.loadSound(path, mode, self._streamMs)
    self._inFlight[id] = loading
    self._loading = self._loading + 1
    loading:onSettle(function(settled: Future<assets.Sound>)
        self._inFlight[id] = nil
        self._loading = self._loading - 1
        if settled.status == "canceled" then
            -- Given up at destroy. There is no mixer left to point a clip at,
            -- and reporting it as a load that failed would be a line in the log
            -- about something nobody asked for any more.
            return
        end
        settleClip(clip, settled)
    end)
    return callerLoad(self, clip, loading)
end

--- Returns the clip represented by an index, or nil when this instance has not
--- loaded it.
---
--- @param id From `Audio.clipId`, or from a `Sound.clip` field. Clip indices are
---     every instance shares clip indices but not clips, so an index another
---     instance loaded answers nil here.
function Audio:clip(id: integer): Audio.Clip
    return self._clips[id]
end

--- Blocks until every load this instance has queued has settled.
---
--- For startup and tests. A frame should let `update` resolve them instead.
--- Every load settles, whatever it settled as, so one missing file does not
--- leave the rest unwaited for.
---
--- Waiting drains the loader, so loads another subsystem queued settle here as
--- well and a slow one elsewhere lengthens this wait. It cannot shorten it, and
--- an instance with nothing in flight drains nothing.
---
--- @param timeoutMs **Milliseconds**, unlike the seconds everything else on
---     this surface takes, because it is a wait on the asset worker rather
---     than an audio duration. Omitting it does not wait forever: it takes a
---     5000 ms default. Running out is not reported, so read `loading`
---     afterwards to tell a finished wait from a timed-out one.
function Audio:waitForLoads(timeoutMs?: number)
    if self._loading == 0 then
        return
    end
    -- A drain over the loader's live count rather than a join over the futures
    -- in `_inFlight`, for three reasons and only one of them is failure.
    -- `Future.all` reads its inputs once, so a load that a listener starts while
    -- this is waiting is not among them and the wait answers with a decode
    -- outstanding, which is what `destroy` must never do. Joining also takes a
    -- hold on each input that only canceling the join gives back, so `destroy`'s
    -- cancel would decrement to one rather than to zero and abandon nothing. And
    -- a join fails on its first failed input, which a missing file reaches as
    -- fast as the worker can look.
    --
    -- The loader settles its barrier after a result has run that result's
    -- listeners, so a load chained onto one holds it pending rather than
    -- slipping past it. No join has that property.
    assets.waitAll(timeoutMs)
end

--- Returns the number of loads this instance is still waiting on.
---
--- @return Loads not yet settled, which counts loads rather than clips. A
---     failed load counts as settled, so zero means every `load` has an answer
---     and not that every answer was a success. Zero after `waitForLoads` is
---     what tells a finished wait from a timed-out one.
function Audio:loading(): integer
    return self._loading
end

--- Re-reads a clip's file over the clip already loaded from it.
---
--- The counterpart to `Renderer:replaceImage`, and it keeps identity on the
--- same terms. A clip's index is its path's, so an edited file comes back under
--- the index every [`Sound`](tealdoc:tecs.audio.Sound) row already carries and nothing in the world is
--- touched.
---
--- A streamed clip holds nothing to replace. Each voice opens the file for
--- itself, so the next one to start reads what is on disk now and this has only
--- to say so. Voices already sounding read the stream they opened, which is
--- what happens to a file edited under a running voice with or without a
--- reload.
---
--- The loader decodes a resident clip again and swaps it in. It stays resident whatever
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
--- @param path The path originally used to load the clip.
--- @return Whether the clip was re-read, and a reason when it was not.
function Audio:reload(path: string): boolean, string
    local id = clipIds[path]
    local clip = id ~= nil and self._clips[id] or nil
    if clip == nil then
        return false, ("nothing has loaded '%s', so there is no clip to " .. "re-read"):format(path)
    end
    if clip.status == "pending" then
        return false, ("'%s' is still loading"):format(path)
    end
    if not clip.resident then
        return true
    end

    if not assets.installed() then
        assets.install()
    end
    -- This one load rather than the loader's whole drain: a future has a source,
    -- so waiting on it is precise, and a reload has no reason to spend its
    -- budget on decodes somebody else started.
    local loading = assets.loadSound(path, "resident", self._streamMs)
    loading:wait()
    if loading.status ~= "ready" then
        local reason = loading.error or ("still " .. loading.status)
        loading:cancel()
        return false, ("'%s' did not load: %s"):format(path, reason)
    end

    -- Swapped before the old one is let go, so the clip is never pointing at a
    -- clip that has been released.
    local previous = clip._sound
    settleClip(clip, loading)
    if previous ~= nil then
        previous:release()
    end
    return true
end

-------------------------------------------------------------------------------
-- Voices
-------------------------------------------------------------------------------

--- The voice a handle refers to, or nil when it refers to one that has ended.
local function voiceOf(self: Audio, handle: integer): Voice
    if handle == nil or handle <= 0 then
        return nil
    end
    local slot = handle % SLOT_SPAN
    local voice = self._voices[slot]
    if voice == nil or not voice.sounding then
        return nil
    end
    if voice.generation ~= (handle - slot) / SLOT_SPAN then
        return nil
    end
    return voice
end

--- The gain a voice should carry, its group's gain and mute included. The
--- master is the mixer's own number and is not multiplied in here.
local function composedGain(self: Audio, voice: Voice): number
    local group = voice.group
    if group == nil then
        return voice.gain
    end
    if self._groupMuted[group] then
        return 0.0
    end
    local scale = self._groupGains[group]
    if scale == nil then
        return voice.gain
    end
    return voice.gain * scale
end

--- Pushes a voice's gain, skipping the call when nothing changed.
local function applyGain(self: Audio, voice: Voice)
    local applied = composedGain(self, voice)
    if applied == voice.applied then
        return
    end
    voice.applied = applied
    self._backend.setGain(voice.track, applied)
end

--- Pushes a voice's rate, skipping the call when nothing changed.
local function applyPitch(self: Audio, voice: Voice, ratio: number)
    if voice.pitch == ratio then
        return
    end
    voice.pitch = ratio
    self._backend.setPitch(voice.track, ratio)
end

--- Pushes whether a voice repeats, skipping the call when nothing changed.
local function applyLoop(self: Audio, voice: Voice, loop: boolean)
    if voice.loop == loop then
        return
    end
    voice.loop = loop
    self._backend.setLoops(voice.track, loop and LOOP_FOREVER or 0)
end

--- Places a voice, skipping the call when it has not moved.
local function applyPosition(self: Audio, voice: Voice, x: number, y: number, z: number)
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
local function applyStereo(self: Audio, voice: Voice, left: number, right: number)
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
    if not voice.spatial and not voice.stereo then
        return
    end
    voice.spatial = false
    voice.stereo = false
    self._backend.clearSpatial(voice.track)
end

--- Gives a slot back, untagging and un-counting whatever it held.
local function release(self: Audio, slot: integer)
    local voice = self._voices[slot]
    if not voice.sounding then
        return
    end

    if voice.group ~= nil then
        self._backend.untag(voice.track, voice.group)
        voice.group = nil
    end
    if voice.key ~= nil then
        local bucket = self._buckets[voice.key]
        if bucket ~= nil then
            bucket.count = bucket.count - 1
        end
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
    if limit == nil then
        return true
    end
    local bucket = self._buckets[key]
    if bucket == nil then
        return true
    end
    if limit.cooldown ~= nil and limit.cooldown > 0 and self._now - bucket.last < limit.cooldown then
        return false
    end
    if limit.voices ~= nil and limit.voices > 0 and bucket.count >= limit.voices then
        return false
    end
    return true
end

--- Starts `clip` on a free voice and returns its handle, or zero.
local function start(self: Audio, clip: Audio.Clip, options: Audio.PlayOptions, owned: boolean): integer
    if not self.available then
        return 0
    end
    if clip == nil or clip.status ~= "ready" then
        return 0
    end

    local key = options.key
    if key ~= nil and not admits(self, key) then
        return 0
    end

    local count = #self._free
    if count == 0 then
        return 0
    end
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
        pointed = self._backend.setTrackClip(voice.track, clip._sound.audio)
    else
        pointed = self._backend.setTrackFile(voice.track, clip.path)
    end
    if not pointed then
        self._free[#self._free + 1] = slot
        return 0
    end

    voice.generation = voice.generation + 1
    if voice.generation > MAX_GENERATION then
        voice.generation = 1
    end
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

    if voice.group ~= nil then
        self._backend.tag(voice.track, voice.group)
    end
    applyGain(self, voice)

    local pitch = options.pitch or 1.0
    local variance = options.pitchVariance or 0.0
    if variance ~= 0.0 then
        pitch = pitch * (1.0 + self._random:range(-1.0, 1.0) * variance)
    end
    -- Compared against what this track already carries, not against one,
    -- because a reused slot would otherwise keep the last voice's rate.
    applyPitch(self, voice, pitch)

    -- The two placements are exclusive, and a position wins when a caller
    -- asks for both rather than one silently undoing the other.
    if options.spatial == true then
        applyPosition(self, voice, options.x or 0.0, options.y or 0.0, options.z or 0.0)
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
            bucket = {count = 0, last = 0.0}
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
---
--- A key's limit **drops the new voice**; it never steals an older one. A
--- sound that stops halfway through because something else started is harder
--- to explain than one that never started, and the same reasoning is why a
--- full voice pool declines rather than stealing.
---
--- @param clip Accepts nil and returns zero, so callers may pass a `load`
---     result directly without a guard.
--- @param options The method reads this once and follows no later changes.
--- @return A handle for `stop`, `playing`, `setGain` and the rest, or zero
---     when nothing started. It stays valid while the voice sounds and goes
---     inert for good once it does not; it is never reissued for a later
---     voice, and requires no release.
function Audio:play(clip: Audio.Clip, options?: Audio.PlayOptions): integer
    return start(self, clip, options or {} as Audio.PlayOptions, false)
end

--- Stops a voice. A handle to one that already ended does nothing.
---
--- `fadeOut` seconds keeps the voice sounding while it fades, so `playing`
--- stays true until `update` sees the mixer finish it.
---
--- @param handle A stale one is a no-op, as is one already fading out: a
---     second stop does not shorten a fade in progress.
--- @param fadeOut Seconds to ramp down over, a duration and not a moment to
---     finish at. Omitted or zero stops at once and frees the slot within this
---     call. The ramp is the mixer's, so it follows the audio clock rather
---     than the frame rate.
function Audio:stop(handle: integer, fadeOut?: number)
    local voice = voiceOf(self, handle)
    if voice == nil or voice.stopping then
        return
    end
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
--- `update` reaps them instead of this call. The mixer owns the ramp, on
--- the same terms as `stop` and `stopGroup`.
---
--- Reaches every voice, whichever group it is in and whether a
--- [`Sound`](tealdoc:tecs.audio.Sound)
--- component started it or `play` did. A row still asking to sound starts a
--- fresh voice on the next audio pass, so this silences a world rather than
--- keeping it silent.
---
--- @param fadeOut Seconds, a duration. Omitted or zero frees every slot within
---     this call. A positive one unpauses the voices it fades, because a
---     paused voice does not advance and its fade would never finish.
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

--- Returns whether a handle still names a sounding voice. A paused or fading voice
--- still counts: it has not finished.
---
--- @return false for a handle whose voice has ended, for zero, and for one
---     from another [`Audio`](tealdoc:tecs.audio.Audio). A voice that ended on its own reads true until
---     the next `update` reaps it, since nothing here is told the instant it
---     finished.
function Audio:playing(handle: integer): boolean
    return voiceOf(self, handle) ~= nil
end

--- Returns whether a handle names a paused voice.
---
--- @return true whether the hold came from `pause` on this handle or from
---     `pauseGroup` on its group; the two are not told apart. false for a
---     handle that names nothing.
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
---
--- @param handle A no-op for a handle that names nothing, one already paused,
---     and one fading out, since a paused fade would never finish. Not holder
---     counted: one `resume` undoes any number of `pause` calls.
function Audio:pause(handle: integer)
    local voice = voiceOf(self, handle)
    if voice == nil or voice.paused or voice.stopping then
        return
    end
    voice.paused = true
    self._backend.pause(voice.track)
end

--- Lets a paused voice carry on.
---
--- @param handle A no-op for a handle that names nothing and for one that is
---     not paused. Resumes a voice its group paused, and the group's hold does
---     not put it back; a voice starting into that group afterwards is still
---     held.
function Audio:resume(handle: integer)
    local voice = voiceOf(self, handle)
    if voice == nil or not voice.paused then
        return
    end
    voice.paused = false
    self._backend.resume(voice.track)
end

--- Sets a voice's gain, before its group and the master.
---
--- @param handle A no-op for one that names nothing.
--- @param gain Linear amplitude, not decibels: 0 is silence, 1 is the clip as
---     recorded, above 1 is louder and may clip. Takes effect on the next
---     buffer the mixer fills rather than ramping, so a large jump on a
---     sounding voice can be audible as a step.
function Audio:setGain(handle: integer, gain: number)
    local voice = voiceOf(self, handle)
    if voice == nil then
        return
    end
    voice.gain = gain
    applyGain(self, voice)
end

--- Sets a voice's playback rate. A value of 1 preserves the original rate.
---
--- @param ratio A resampling rate, not an interval: 2 is an octave up and half
---     as long, 0.5 an octave down and twice as long. It changes how long the
---     clip takes, so a looped voice's period moves with it.
function Audio:setPitch(handle: integer, ratio: number)
    local voice = voiceOf(self, handle)
    if voice == nil then
        return
    end
    applyPitch(self, voice, ratio)
end

--- Changes whether a voice repeats, part way through.
---
--- The mixer replaces its starting repeat count, so clearing this on a
--- looping piece of music lets it play out to its end rather than cutting it,
--- and setting it on a one-shot keeps it going. It reaches a sounding voice
--- only: a stopped one takes its count from the next play.
---
--- @param loop true repeats forever; there is no finite repeat count here.
---     Setting it does not move the loop point. The voice keeps the
---     `loopStart` from `play`.
function Audio:setLoop(handle: integer, loop: boolean)
    local voice = voiceOf(self, handle)
    if voice == nil then
        return
    end
    applyLoop(self, voice, loop == true)
end

--- Returns whether a voice repeats at the end.
---
--- @return What this layer last told the mixer, not a reading from it. false
---     for a handle that names nothing.
function Audio:looping(handle: integer): boolean
    local voice = voiceOf(self, handle)
    return voice ~= nil and voice.loop
end

--- Moves a voice's read position, in seconds from the start of its clip.
---
--- False when the handle names nothing, or when the input cannot seek: a
--- the decoder does not support seeking, or can only reach a time
--- rather than an exact sample.
---
--- @param seconds From the start of the clip, not from where the voice is now,
---     and not from the loop point. Converted through the track's own rate, so
---     it lands on a sample frame rather than on a mixer tick.
--- @return false when the handle names nothing or the input refused the seek.
---     A true does not promise the exact sample: some decoders reach only the
---     nearest point they can.
function Audio:seek(handle: integer, seconds: number): boolean
    local voice = voiceOf(self, handle)
    if voice == nil then
        return false
    end
    return self._backend.seek(voice.track, math.floor(seconds * 1000))
end

--- Returns the voice position in seconds, or nil.
---
--- Nil when the handle names nothing or the mixer cannot say. A paused voice
--- reports where it stopped, which with `seek` and `fadeIn` is what taking a
--- sound back where it left off is built from.
---
--- @return Seconds from the start of the clip, so a looped voice's reading
---     falls back at each repeat rather than accumulating. nil when the handle
---     names nothing and nil when the mixer will not say, which are not told
---     apart here.
function Audio:tell(handle: integer): number
    local voice = voiceOf(self, handle)
    if voice == nil then
        return nil
    end
    local ms = self._backend.tell(voice.track)
    if ms < 0 then
        return nil
    end
    return ms / 1000
end

--- Places a voice in space. See [`Sound`](tealdoc:tecs.audio.Sound) for what the numbers mean.
---
--- Replaces a pan set by `setStereo` rather than combining with it.
---
--- Puts the voice in the mixer's 3D mode, which folds its input down to mono
--- before placing it, so a stereo clip loses its stereo image when positioned.
---
--- @param x Positive to the right of the listener. The mixer fixes the
---     listener at the origin.
--- @param y Positive **above** the listener. World Y runs down, so world
---     coordinates need their Y negated on the way in.
--- @param z Positive behind the listener.
function Audio:setPosition(handle: integer, x: number, y: number, z: number)
    local voice = voiceOf(self, handle)
    if voice == nil then
        return
    end
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
---
--- @param left Gain out of the left speaker, on the same linear scale as
---     `setGain`. It multiplies with the voice, group and master gains rather
---     than replacing any of them, so a pan of 1 and 1 is not silence.
--- @param right Gain out of the right speaker. There is no normalization
---     between the two: 1 and 1 is the sound at full out of both sides, not
---     half out of each.
function Audio:setStereo(handle: integer, left: number, right: number)
    local voice = voiceOf(self, handle)
    if voice == nil then
        return
    end
    applyStereo(self, voice, left, right)
end

--- Returns a voice to unpositioned mixing, out of either placement.
---
--- One call answers for both, because clearing either mode in the mixer clears
--- the other. A no-op for a handle that names nothing and for a voice that was
--- never placed.
function Audio:clearSpatial(handle: integer)
    local voice = voiceOf(self, handle)
    if voice == nil then
        return
    end
    applyUnplaced(self, voice)
end

--- Scales everything. One number on the mixer, so this costs the same whether
--- one voice is sounding or every voice is.
---
--- Setting this while muted changes the level a later unmute returns to and
--- nothing that is audible now, which is what a volume slider moved with the
--- sound off should do.
---
--- @param gain Linear amplitude, not decibels, on the same scale as a voice's:
---     0 silences, 1 leaves the mix as mixed, above 1 is louder and may clip.
function Audio:setMasterGain(gain: number)
    self._masterGain = gain
    if self._mixer ~= nil and not self._muted then
        self._backend.setMixerGain(self._mixer, gain)
    end
end

--- Returns master gain, whether or not mute holds it down.
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
    if self._muted == wanted then
        return
    end
    self._muted = wanted
    if self._mixer ~= nil then
        self._backend.setMixerGain(self._mixer, wanted and 0.0 or self._masterGain)
    end
end

--- Returns whether master mute holds the output down.
function Audio:muted(): boolean
    return self._muted
end

--- Returns the number of voices sounding now, including paused and fading
--- voices.
---
--- @return Slots in use, so it drops only when `update` reaps a voice, not the
---     instant one ends. `play` declines once it reaches `maxVoices`.
function Audio:sounding(): integer
    return self._sounding
end

--- Returns the configured maximum number of simultaneous voices.
---
--- @return The ceiling `play` refuses at, fixed for the instance's life. Not
---     a hardware limit: it is what `newAudio` was given, defaulting to 32.
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
---
--- @param name Needs no declaring, and setting a gain on a name nothing is in
---     is how a game configures a group before anything joins it. Recorded
---     against the name, so it outlives every voice that was in it.
--- @param gain Linear amplitude, multiplied with each voice's own gain. There
---     is no removing it: set 1 to return the group to unscaled.
function Audio:setGroupGain(name: string, gain: number)
    self._groupGains[name] = gain
    for slot = 1, #self._voices do
        local voice = self._voices[slot]
        if voice.sounding and voice.group == name then
            applyGain(self, voice)
        end
    end
end

--- Returns a group's gain, or one when none has been set.
---
--- The level, not what is audible: a muted group still answers with the gain
--- an unmute would put back.
---
--- @return 1 for a group nothing has set, which is indistinguishable from one
---     explicitly set to 1.
function Audio:groupGain(name: string): number
    return self._groupGains[name] or 1.0
end

--- Silences a group without discarding the level it was set to.
---
--- Bookkeeping over the gains that already exist rather than anything the
--- mixer receives: every voice in the group contributes zero while
--- this holds, and an unmute puts each one back at its own gain times
--- `groupGain(name)`.
function Audio:setGroupMuted(name: string, muted: boolean)
    local wanted = muted == true
    if (self._groupMuted[name] == true) == wanted then
        return
    end
    self._groupMuted[name] = wanted or nil
    for slot = 1, #self._voices do
        local voice = self._voices[slot]
        if voice.sounding and voice.group == name then
            applyGain(self, voice)
        end
    end
end

--- Reports whether mute applies to a group.
function Audio:groupMuted(name: string): boolean
    return self._groupMuted[name] == true
end

--- Holds every voice in a group where it is, and every voice that joins it
--- later.
---
--- The audio object records the pause as well as sending it, because the
--- mixer's tag pause reaches only voices sounding at that moment. Without the
--- record, a sound started into a
--- paused group would be the one thing still heard.
---
--- @param name Not holder counted: one `resumeGroup` undoes any number of
---     these. A voice `resume`d out of a paused group stays going, and the
---     group's hold still applies to whatever joins next.
function Audio:pauseGroup(name: string)
    self._groupPaused[name] = true
    if self._mixer == nil then
        return
    end
    self._backend.pauseTag(self._mixer, name)
    for slot = 1, #self._voices do
        local voice = self._voices[slot]
        if voice.sounding and voice.group == name then
            voice.paused = true
        end
    end
end

--- Lets a paused group carry on, and lets later joiners start sounding.
function Audio:resumeGroup(name: string)
    self._groupPaused[name] = nil
    if self._mixer == nil then
        return
    end
    self._backend.resumeTag(self._mixer, name)
    for slot = 1, #self._voices do
        local voice = self._voices[slot]
        if voice.sounding and voice.group == name then
            voice.paused = false
        end
    end
end

--- Returns whether a group holds its current and future voices.
function Audio:groupPaused(name: string): boolean
    return self._groupPaused[name] == true
end

--- Appends a name to `names` unless `seen` already holds it.
local function note(names: {string}, seen: {string: boolean}, name: string)
    if seen[name] then
        return
    end
    seen[name] = true
    names[#names + 1] = name
end

--- Every group with a gain, a mute or a pause recorded against it.
local function settledGroups(self: Audio, names: {string}, seen: {string: boolean})
    for name in pairs(self._groupGains) do
        note(names, seen, name)
    end
    for name in pairs(self._groupMuted) do
        note(names, seen, name)
    end
    for name in pairs(self._groupPaused) do
        note(names, seen, name)
    end
end

--- Returns every group known to this instance, including any whose gain, mute,
--- or pause has been
--- set, and one a sounding voice is in. Sorted, so a caller reading it twice
--- reads it the same way.
---
--- @return A fresh table each call, which the caller owns. A group whose only
---     voice has ended and which nothing was set on drops out of it, so this
---     is not a stable list of a game's groups.
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
---
--- Stops the voices, not the group: a gain, mute or pause set on the name
--- survives, and anything that joins afterwards starts under them.
---
--- @param fadeOut Seconds, a duration. Omitted or zero frees the slots within
---     this call. A positive one unpauses the voices it fades, since a paused
---     voice's fade would never finish.
function Audio:stopGroup(name: string, fadeOut?: number)
    if self._mixer == nil then
        return
    end
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
---
--- When a key reaches its limit, `play` **drops the new voice**: it returns zero
--- and leaves every sounding voice alone.
---
--- @param limit nil removes the limit. Lowering `voices` below what the key
---     already holds does not stop any of them; it only refuses the next until
---     enough have ended. The audio object measures `cooldown` from when a voice
---     last started, against the time passed to `update`, so a game that
---     never calls `update` never advances a cooldown.
function Audio:setLimit(key: string, limit: Audio.Limit)
    self._limits[key] = limit
end

--- Returns the limit assigned to a key, or nil.
---
--- @return The record that was set, not a copy, so writing through it changes
---     the limit in force.
function Audio:limit(key: string): Audio.Limit
    return self._limits[key]
end

--- Returns how many voices a key holds now.
---
--- @return Voices counted against the key, paused and fading ones included,
---     since a slot is not given back until the voice ends. 0 for a key that
---     has never held one.
function Audio:keyCount(key: string): integer
    local bucket = self._buckets[key]
    return bucket ~= nil and bucket.count or 0
end

--- Returns every key with a limit or counted voice, sorted.
---
--- @return A fresh table each call, which the caller owns. A key keeps its
---     bucket once one exists, so a key that has played and stopped is still
---     listed.
function Audio:keys(): {string}
    local names: {string} = {}
    local seen: {string: boolean} = {}
    for name in pairs(self._limits) do
        seen[name] = true
        names[#names + 1] = name
    end
    for name in pairs(self._buckets) do
        if not seen[name] then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

-------------------------------------------------------------------------------
-- Looking in
-------------------------------------------------------------------------------

--- Returns every loaded clip in request order.
---
--- For introspection: it builds a list per call, so nothing on a frame's path
--- should read it.
---
--- @return A fresh list each call, holding the live clip records rather than
---     copies, so their `status` moves under a caller that keeps one.
function Audio:clips(): {Audio.Clip}
    local ids: {integer} = {}
    for id in pairs(self._clips) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    local list: {Audio.Clip} = {}
    for index = 1, #ids do
        list[index] = self._clips[ids[index]]
    end
    return list
end

--- Returns every sounding voice, including paused and fading voices.
---
--- For introspection, on the same terms as `clips`. The handles it reports are
--- the ones `playing` and `stop` take, so callers can act on these results.
---
--- @return A fresh list of fresh records each call, ordered by voice slot,
---     which is not the order the voices started in. It is a snapshot: nothing
---     in it follows the voice afterwards.
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
--- The step advances cooldowns. Nothing else here needs
--- time: a fade is the mixer's to run, and a voice is over when the mixer says
--- so rather than when a clock here says it should be.
---
--- Not a world system, and `install` deliberately does not add one: reaping has
--- to continue during a world pause, so an application drives this
--- from the iteration instead.
---
--- @param dt Seconds since the last call. The audio pass adds it to the clock
---     that governs cooldowns.
---     measured against. Omitting it advances nothing, which is what a test
---     stepping voices without time wants.
--- @return Voices still sounding after the reap, the same number `sounding`
---     answers.
function Audio:update(dt?: number): integer
    self._now = self._now + (dt or 0.0)
    -- The loader's own drain, which settles this instance's loads along with
    -- everything else outstanding. An `Audio` outside an `Application` still
    -- sees its clips arrive because of this call.
    assets.update()

    for slot = 1, #self._voices do
        local voice = self._voices[slot]
        if voice.sounding and not voice.paused and not self._backend.playing(voice.track) then
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
--- Queries exclude [`Disabled`](/modules/ecs/#tecs.ecs.Disabled) unless they name
--- it, so the walk below skips disabled rows and the sweep treats their voices
--- as abandoned. The row still names a voice that has gone,
--- which reads on re-enabling as a one-shot that finished, and the sound never
--- comes back. Clearing the handle here is what makes it.
---
--- Archetype-shaped rather than per-row: a disabled entity is in an archetype
--- of its own, so a world with nothing disabled matches nothing and this walks
--- nothing. Only the frame that disables something writes.
local function hush(hushed: types.Query)
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
--- One walk answers all of it. The pass starts a voice for a row asking to
--- sound, follows gain, rate, loop, and position for sounding rows, returns
--- finished rows to rest, and treats a voice with no reference as belonging
--- to an entity that has
--- gone or that the game disabled, so the pass stops it. That last case makes
--- despawning something mid-sound work without an observer on every archetype
--- that might hold one.
---
--- Following is a read and a compare per field per sounding row. Every field
--- on the list is one a game changes without wanting the sound to restart,
--- and every field left off it takes a stop and a fresh start to change
--- anyway, so nothing here is paid for on behalf of a case that cannot use it.
local function reconcile(self: Audio, sounds: types.Query, hushed: types.Query)
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
                local started = start(self, self._clips[entry.clip as integer], rowOptions, true)
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
                        applyPosition(self, voice, entry.x as number, entry.y as number, entry.z as number)
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
--- changed. Voices determine each bucket, and a snapshot restores no voices:
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
                gain = gain or 1.0,
                muted = muted,
                paused = paused,
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
--- This function visits every group this instance knows about, not only the ones the
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
        for name in pairs(saved) do
            note(names, seen, name)
        end
    end

    for _, name in ipairs(names) do
        local entry = (saved ~= nil and saved[name] or nil) as {string: any}
        self:setGroupGain(name, entry ~= nil and (entry.gain as number) or 1.0)
        self:setGroupMuted(name, entry ~= nil and entry.muted == true)
        if entry ~= nil and entry.paused == true then
            self:pauseGroup(name)
        else
            self:resumeGroup(name)
        end
    end

    self:setMasterGain(value ~= nil and (value.masterGain as number) or 1.0)
    self:setMuted(value ~= nil and value.muted == true)
end

-------------------------------------------------------------------------------
-- The plugin
-------------------------------------------------------------------------------

--- Returns the audio installed into a world, or nil.
---
--- What lets something holding only the world reach the mixer, which is what
--- the debug tools have and what a game writing its own systems often has too.
---
--- @return nil before `install` and again after `destroy`, which removes the
---     instance from every world.
function Audio.of(world: types.World): Audio
    return installed[world]
end

--- Adds the system that plays [`Sound`](tealdoc:tecs.audio.Sound) components,
--- and the snapshot handler
--- that carries the mixer.
---
--- `update` is not added here. Reaping voices is not world work: it has to
--- continue during a world pause, and an application drives it from
--- the iteration instead.
---
--- @param world Repoints this instance's pitch variance at the world's
---     `tecs.audio` random stream, so installing into a second world moves the
---     variance to that one's. This interface expects one
---     [`Audio`](tealdoc:tecs.audio.Audio) per world.
function Audio:install(world: types.World)
    installed[world] = self

    -- Pitch variance moves onto the world's stream, so it is seeded with
    -- everything else and a snapshot carries where it had got to. Kept as the
    -- same field the play path already reads: a mixer with no world still has
    -- the generator it was made with.
    self._random = random.stream(world, "tecs.audio")

    local sounds = world:query({
        name = "tecs.Sounds",
        include = {Sound},
    })

    -- Naming `Disabled` opts out of the exclusion every other query gets, so
    -- this is the disabled rows and only those. They are in archetypes of
    -- their own, so it matches nothing until something is disabled.
    local hushed = world:query({
        name = "tecs.DisabledSounds",
        include = {Sound, ecs.Disabled},
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
        save = function(_world: types.World): any return saveMixer(self) end,
        load = function(_world: types.World, value: any) loadMixer(self, value as {string: any}) end,
    })
end

return audio
