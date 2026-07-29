---
description: "Sound: clips, voices, groups, keyed limits, fades, pitch, loop points, streaming, the Sound component, and the devices underneath"
outline: deep
---

# tecs.audio

`tecs.audio.Audio` is the whole of sound output: load a clip, play it, set a gain, fade it, repeat it, pitch
it, seek it, pan it, put it in a group, cap how often it may start, stop it. It is built on SDL_mixer 3, and an
entity that should make a noise carries a [`Sound`](#the-sound-component) component rather than a handle a game
has to remember to release.

A game does not usually construct one. [`Application`](/modules/Application) creates the audio from its `audio`
config, installs it into the world, calls `update` once per iteration and destroys it on shutdown, so
`app.audio` is the object every example below is calling into.

```teal
local footsteps <const> = app.audio:load("assets/sfx/step.ogg")
app.audio:setLimit("footstep", { voices = 3, cooldown = 0.05 })

app.audio:play(footsteps, { gain = 0.7, key = "footstep", pitchVariance = 0.1 })
```

The [physical devices](#physical-devices-and-microphone-capture) it opens, and microphone capture, are on this
module too rather than one of their own: the mixer and the device it plays through are one subject at two
levels, and a game that wants a particular output names it here and passes its id to `create`.

Five decisions shape everything below.

**The mixer decodes.** A clip is whatever the linked decoders can read: WAV, AIFF, VOC, AU, Ogg Vorbis, Opus,
FLAC, MP3 and WavPack, depending on what the build linked. [`Audio.decoders`](#decoders) reports what this build
has, which is the only honest answer: a decoder whose dependency was missing at configure time is dropped without
complaint.

**A voice is a track.** The mixer sums every track into the buffer the hardware reads, so playing the same clip
three times over is three tracks reading one clip rather than three copies added together in Lua.

**A clip is resident or streamed, and its length decides.** See [residency](#residency).

**Nothing runs on an audio thread.** SDL_mixer can call back when a track stops, and that callback fires on a
thread the Lua VM did not create. So none is installed, and [`update`](#update) asks each sounding voice whether
it is still playing instead. A voice is reaped on the frame after it ended rather than the instant it did, which
is the whole cost.

**Limits are ours; groups are the mixer's.** A [group](#groups) is a tag, and the mixer pauses, resumes and stops
every voice carrying one. A [key](#keyed-limits) is a limit bucket counted in Lua, because the mixer has no
notion of "at most three of these at once, and not twice inside fifty milliseconds", which is what keeps forty
enemies dying together from playing forty identical sounds.

## Lifecycle

### newAudio

Opens the platform's default output.

```teal
function tecs.audio.newAudio(config?: Audio.Config): Audio
```

**Parameters:**

- `config`: see below. Every field is optional.

**Returns:** an audio object, always. This never raises for want of hardware: a machine with no sound card gets an
object whose calls all succeed and produce nothing, because a game that cannot be played without an audio device
is rarer than a test machine without one. [`available`](#fields) says which happened.

Raises only when `maxVoices` is below 1 or at 65536 and above.

#### Audio.Config

| Field           | Type      | Default        | Description                                                                                                |
| --------------- | --------- | -------------- | ---------------------------------------------------------------------------------------------------------- |
| `frequency`     | `integer` | `48000`        | Frames per second the output runs at.                                                                      |
| `channels`      | `integer` | `2`            | Output channels. Two, because that is what a stereo mix needs and mono hardware is the platform's problem. |
| `maxVoices`     | `integer` | `32`           | Voices that may sound at once. Past this, `play` declines rather than stealing.                            |
| `streamSeconds` | `number`  | `10.0`         | Seconds past which a clip streams rather than being held in memory.                                        |
| `backend`       | `Backend` | the platform's | Output backend. The installed platform's by default.                                                       |
| `device`        | `number`  | system default | Physical id returned by `tecs.audio.playbackDevices`.                                                      |

With no `device`, the system migrates the logical output when the default changes and plugged-in headphones need
no handling. An explicit physical id stays on that device until this `Audio` is destroyed.

### Fields

| Field       | Type      | Description                                                                                                           |
| ----------- | --------- | --------------------------------------------------------------------------------------------------------------------- |
| `available` | `boolean` | Whether an output opened. `false` on a machine with no sound, where every call here still works and nothing is heard. |
| `Sound`     | `Sound`   | The component type, also reachable as `tecs.audio.Sound`. See [the Sound component](#the-sound-component).            |

### install

Adds the system that plays `Sound` components, and the snapshot handler that carries the mixer.

```teal
function Audio:install(world: ecs.World)
```

The system is named `tecs.PlaySounds` and runs in the `PostUpdate` phase: after gameplay has decided what exists
and before anything renders, so a sound spawned this frame starts this frame.

`update` is not added here. Reaping voices is not world work, it has to keep happening while the world is paused,
so an application drives it from the iteration instead.

Installing also points pitch variance at the world's `tecs.audio` random stream, so it is seeded with everything
else and a snapshot carries where the variance had got to.

### of

The audio installed into a world, or `nil` when none has been.

```teal
function Audio.of(world: ecs.World): Audio
```

What lets something holding only the world reach the mixer, which is what the debug tools have and what a game
writing its own systems often has too.

### update

Takes finished loads and reaps the voices the mixer has finished with.

```teal
function Audio:update(dt?: number): integer
```

**Parameters:**

- `dt`: the frame's step, in seconds. This is what a key's [cooldown](#keyed-limits) is measured against, and it
  is the only thing here that needs time: a fade is the mixer's to run, and a voice is over when the mixer says
  so rather than when a clock here says it should be.

**Returns:** voices sounding after the sweep.

Call it once per frame. [`Application`](/modules/Application) already does.

### destroy

Stops everything and closes the output.

```teal
function Audio:destroy()
```

Outstanding loads are drained first, every voice is stopped, every clip is released and its status becomes
`"released"`, and every world this was installed into stops naming it, so `Audio.of` answers `nil` rather than
handing out a mixer that can only report being unavailable.

### decoders

The decoders this build linked, in the mixer's own order.

```teal
function Audio.decoders(): {string}
```

What a build asked for and what it got are different questions, since a decoder whose dependency was not found is
dropped silently. This answers the second.

## Clips

### Residency

A clip under `streamSeconds` is decoded once, up front, and every voice reads the same PCM: that is what a sound
effect played forty times a second wants. A clip at or over it holds nothing, and each voice opens the file and
decodes as it plays: that is what a piece of music wants, and it is also what a clip whose length the file cannot
state gets, because a file that will not say how long it is may be very long. `load` takes `stream` to override
the threshold either way.

Loading happens on the asset worker, the same route a decoded image takes, so a load never blocks a frame. A clip
reports that it is still loading and `play` declines until it is not.

### Audio.Clip

| Field      | Type      | Description                                                                                                |
| ---------- | --------- | ---------------------------------------------------------------------------------------------------------- |
| `path`     | `string`  | The path it was loaded from.                                                                               |
| `id`       | `integer` | Index of `path`, which is what a `Sound` component carries.                                                |
| `status`   | `string`  | `"loading"`, `"ready"`, `"failed"`, or `"released"` once the audio object it was loaded into is destroyed. |
| `error`    | `string`  | Set when loading failed.                                                                                   |
| `duration` | `number`  | Seconds of audio, or zero when the file cannot say.                                                        |
| `resident` | `boolean` | Whether the decoded audio is held in memory. `false` for a clip each voice reads from the file for itself. |

### load

Queues a sound for loading and returns its clip immediately.

```teal
function Audio:load(path: string, options?: Audio.LoadOptions): Audio.Clip
```

**Parameters:**

- `path`: the file to read. Loading the same path twice returns the same clip; a clip is the file, and playing it
  twice over is two voices reading one clip.
- `options.stream`: forces streaming when `true` and residency when `false`. Left unset, the clip's duration
  decides against `streamSeconds`.

**Returns:** a clip in `"loading"`, which becomes `"ready"` or `"failed"` once `update` resolves it.

### clip

The clip an index stands for, or `nil` when this instance has not loaded it.

```teal
function Audio:clip(id: integer): Audio.Clip
```

### loading

Clips still being read.

```teal
function Audio:loading(): integer
```

### waitForLoads

Blocks until every queued load has finished.

```teal
function Audio:waitForLoads(timeoutMs?: number)
```

For startup and tests. A frame should let `update` resolve them instead.

### clips

Every clip this instance has loaded, in the order they were asked for.

```teal
function Audio:clips(): {Audio.Clip}
```

For introspection: it builds a list per call, so nothing on a frame's path should read it.

### reload

Re-reads a clip's file over the clip already loaded from it.

```teal
function Audio:reload(path: string): boolean, string
```

**Parameters:**

- `path`: the path the clip was loaded from.

**Returns:** whether the clip was re-read, and a reason when it was not.

A clip's index is its path's, so an edited file comes back under the index every `Sound` row already carries and
nothing in the world is touched. A streamed clip holds nothing to replace, so this only says so: the next voice
to start reads what is on disk now. A resident clip is decoded again and swapped, and it stays resident whatever
the new file's length would have chosen, because rows already pointing at it were started against held samples.
A sound playing across the swap finishes on the samples it started with.

Blocking, like every other reload: it is a debug operation, and answering before the file has been read would
report a success that had not happened yet.

## Voices

[`play`](#play) hands back an integer handle. Every per-voice call takes one, and a handle to a voice that has
finished and had its slot reused refers to nothing rather than to whatever took its place: those calls do
nothing, and the queries answer `false` or `nil`.

Zero is the handle of no voice at all.

### play

Plays a clip, returning a handle.

```teal
function Audio:play(clip: Audio.Clip, options?: Audio.PlayOptions): integer
```

**Returns:** the voice's handle, or zero when it did not start.

Zero means the clip is not loaded, loading failed, a key's limit or cooldown declined it, every voice is busy, or
the machine has no output. None of those is worth raising over: a sound that does not play is not a reason for a
frame to stop.

#### Audio.PlayOptions

| Field           | Type      | Default | Description                                                                                                                                                                                |
| --------------- | --------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `gain`          | `number`  | `1`     | 0 to 1, before the group and the master gains.                                                                                                                                             |
| `loop`          | `boolean` | `false` | Repeats until stopped.                                                                                                                                                                     |
| `loopStart`     | `number`  | `0`     | Seconds from the start of the clip a repeat returns to, so an intro can play once and the rest of it repeat.                                                                               |
| `start`         | `number`  | `0`     | Seconds into the clip the first pass begins.                                                                                                                                               |
| `fadeIn`        | `number`  | `0`     | Seconds of silence-to-full at the start.                                                                                                                                                   |
| `pitch`         | `number`  | `1`     | Playback rate. 1 is unchanged.                                                                                                                                                             |
| `pitchVariance` | `number`  | `0`     | Fraction of `pitch` to vary by, chosen anew for each voice. 0.1 spreads voices over plus or minus a tenth.                                                                                 |
| `group`         | `string`  | none    | Group this voice joins.                                                                                                                                                                    |
| `key`           | `string`  | none    | Limit bucket this voice counts against.                                                                                                                                                    |
| `spatial`       | `boolean` | `false` | Reads `x`, `y` and `z` as a position. See [placement](#placement).                                                                                                                         |
| `x`, `y`, `z`   | `number`  | `0`     | The position, when `spatial`.                                                                                                                                                              |
| `stereo`        | `boolean` | `false` | Pins the voice to the front pair of speakers at `left` and `right`, which is a pan rather than a position. Ignored when `spatial` is set, because the mixer holds one placement per track. |
| `left`, `right` | `number`  | `1`     | The pan gains, when `stereo`.                                                                                                                                                              |

Pitch variance is drawn from the world's `tecs.audio` random stream once [`install`](#install) has run, so a
snapshot carries the rate the next shot fires at rather than restarting the variance.

### stop

Stops a voice.

```teal
function Audio:stop(handle: integer, fadeOut?: number)
```

**Parameters:**

- `handle`: the voice. One that has already ended does nothing.
- `fadeOut`: seconds to fade over. Omitted or zero stops it at once.

A faded stop keeps the voice sounding while it fades, so [`playing`](#playing) stays true until `update` sees the
mixer finish it, and the voice takes no further instruction in the meantime.

### stopAll

Stops everything, over `fadeOut` seconds if that is given.

```teal
function Audio:stopAll(fadeOut?: number)
```

A faded stop leaves each voice sounding until the mixer finishes it, so they are reaped by `update` rather than
here. A voice a pause was holding stops counting as paused when it is faded, because a paused voice does not
advance, so a fade on one would never finish and the slot would never come back.

### playing

Whether a handle still names a sounding voice.

```teal
function Audio:playing(handle: integer): boolean
```

A paused or fading voice still counts: it has not finished.

### paused

Whether a handle names a voice a pause is holding.

```teal
function Audio:paused(handle: integer): boolean
```

### pause

Holds a voice where it is.

```teal
function Audio:pause(handle: integer)
```

It keeps its slot until something resumes or stops it, because a paused voice has not finished. A voice already
paused, or already fading out, is left alone.

### resume

Lets a paused voice carry on.

```teal
function Audio:resume(handle: integer)
```

::: info Neither takes a fade
That is a decision rather than an omission. The mixer ramps on a play and on a stop and nowhere else, so a faded
pause would be a ramp run from Lua: a `setGain` per voice per frame, the pause itself issued only once the ramp
reaches zero, and its length following the frame rate rather than the clock. The mixer does offer the pieces to
fade out and take a sound back where it left off, though: [`tell`](#tell) reads the position, [`stop`](#stop)
fades out, and `play` returns with `start` and `fadeIn`. That re-reads the input rather than holding it, so it is
a different thing from a pause, and which of the two a moment wants is a game's answer rather than this layer's.
:::

### sounding

Voices sounding right now, including paused and fading ones.

```teal
function Audio:sounding(): integer
```

### maxVoices

Voices that may sound at once, as `maxVoices` configured it.

```teal
function Audio:maxVoices(): integer
```

## Gain, pitch and position

### setGain

Sets a voice's gain, before its group and the master.

```teal
function Audio:setGain(handle: integer, gain: number)
```

### setPitch

Sets a voice's playback rate.

```teal
function Audio:setPitch(handle: integer, ratio: number)
```

1 is unchanged, 2 is an octave up and half as long.

### setLoop

Changes whether a voice repeats, part way through.

```teal
function Audio:setLoop(handle: integer, loop: boolean)
```

The mixer replaces the count it was started with, so clearing this on a repeating piece of music lets it play out
to its end rather than cutting it, and setting it on a one-shot keeps it going. It reaches a sounding voice only:
a stopped one takes its count from the next play.

### looping

Whether a voice repeats when it reaches the end.

```teal
function Audio:looping(handle: integer): boolean
```

### seek

Moves a voice's read position, in seconds from the start of its clip.

```teal
function Audio:seek(handle: integer, seconds: number): boolean
```

**Returns:** `false` when the handle names nothing, or when the input cannot seek: a decoder is allowed not to be
able to, and some can only reach a time rather than an exact sample.

### tell

Seconds into its clip a voice is reading.

```teal
function Audio:tell(handle: integer): number
```

**Returns:** the position, or `nil` when the handle names nothing or the mixer cannot say.

A paused voice reports where it stopped, which with `seek` and `fadeIn` is what taking a sound back where it left
off is built from.

### Placement

The two ways to place a voice are exclusive rather than layered. The mixer holds one placement per track, so the
later call replaces the earlier one, and one `clearSpatial` answers for both.

#### setPosition

Places a voice in space.

```teal
function Audio:setPosition(handle: integer, x: number, y: number, z: number)
```

The coordinates are the mixer's: a right-handed system whose listener sits at the origin and cannot be moved,
with x positive to the right, y positive up and z positive behind. See [the `Sound` component](#position) for the
three jobs that leaves to a caller.

#### setStereo

Pins a voice to the front pair of speakers at explicit gains.

```teal
function Audio:setStereo(handle: integer, left: number, right: number)
```

A pan rather than a position, and usually what a game laid out on a plane wants: there is no listener to subtract
and no distance model to argue with, only "how much of this comes out of each side". `left` at 0.8 and `right` at
0.2 is a sound over to the left, whatever the speakers are. Negative reads as silence and above 1 is louder, on
the same terms as a gain.

#### clearSpatial

Returns a voice to unpositioned mixing, out of either placement.

```teal
function Audio:clearSpatial(handle: integer)
```

## The master

### setMasterGain

Scales everything.

```teal
function Audio:setMasterGain(gain: number)
```

One number on the mixer, so this costs the same whether one voice is sounding or every voice is. Setting it while
muted changes the level a later unmute returns to and nothing that is audible now, which is what a volume slider
moved with the sound off should do.

### masterGain

The master gain, whether or not a mute is holding it down.

```teal
function Audio:masterGain(): number
```

### setMuted

Silences everything without discarding the master gain.

```teal
function Audio:setMuted(muted: boolean)
```

The mixer's own number again, so it costs one call however many voices are sounding. It does not fan out to the
groups: `groupMuted` answers "is this group silenced", and writing every group's bit here would overwrite the
answers an unmute has to put back. That is the same loss as setting a gain to zero, which is what a mute exists
instead of.

### muted

Whether a master mute is holding the output down.

```teal
function Audio:muted(): boolean
```

## Groups

A group is a name a voice joins on `play`, and the mixer's tag underneath. A group's gain, mute, pause, resume
and stop reach every voice carrying it.

**A group's settings outlive the voices in it.** A gain, a mute and a pause are recorded against the name and
consulted when a voice starts, so a sound that begins after "hold every effect for the menu" is held rather than
heard. The mixer cannot answer that on its own: its tag pause reaches what is sounding at the moment it is called
and nothing that starts afterwards.

**Example:**

```teal
app.audio:setGroupGain("music", 0.4)
app.audio:pauseGroup("sfx")
-- ... the menu closes ...
app.audio:resumeGroup("sfx")
```

### setGroupGain

Scales every voice in a group, and every voice that joins it later.

```teal
function Audio:setGroupGain(name: string, gain: number)
```

Composed in Lua rather than through the mixer's per-tag gain, which writes each tagged track's own gain and would
overwrite what the voice asked for. What reaches a track is the voice's gain times its group's, as one product.

### groupGain

A group's gain. 1 for one nothing has set.

```teal
function Audio:groupGain(name: string): number
```

The level, not what is audible: a muted group still answers with the gain an unmute would put back.

### setGroupMuted

Silences a group without discarding the level it was set to.

```teal
function Audio:setGroupMuted(name: string, muted: boolean)
```

Bookkeeping over the gains that already exist rather than anything the mixer is told about: every voice in the
group is composed at zero while this holds, and an unmute puts each one back at its own gain times
`groupGain(name)`.

### groupMuted

Whether a group is muted.

```teal
function Audio:groupMuted(name: string): boolean
```

### pauseGroup

Holds every voice in a group where it is, and every voice that joins it later.

```teal
function Audio:pauseGroup(name: string)
```

### resumeGroup

Lets a paused group carry on, and lets later joiners start sounding.

```teal
function Audio:resumeGroup(name: string)
```

### groupPaused

Whether a group is holding its voices, including the ones not started yet.

```teal
function Audio:groupPaused(name: string): boolean
```

### stopGroup

Ends every voice in a group, over `fadeOut` seconds if that is given.

```teal
function Audio:stopGroup(name: string, fadeOut?: number)
```

A faded stop leaves the voices sounding until they finish, so they are reaped by `update` rather than here, and a
voice a pause was holding stops counting as paused for the same reason as in [`stopAll`](#stopall).

### groups

Every group this instance knows of: one whose gain, mute or pause has been set, and one a sounding voice is in.

```teal
function Audio:groups(): {string}
```

**Returns:** the names, sorted, so a caller reading it twice reads it the same way.

## Keyed limits

A key is not a group. A group says where a sound's gain comes from and what a pause reaches; a key says how many
of one sound the mix will carry. The two are set independently on `play`, so "at most three footsteps at once,
all of them in the effects group" is the ordinary case and neither name has to know about the other.

### Audio.Limit

| Field      | Type      | Description                                                     |
| ---------- | --------- | --------------------------------------------------------------- |
| `voices`   | `integer` | Voices this key may hold at once. Zero or absent is no ceiling. |
| `cooldown` | `number`  | Seconds after one starts before another may. Zero is none.      |

The cooldown is measured against the time `update` has been told about, so it advances with the frame's `dt`.

### setLimit

Caps how many voices a key may hold and how often it may start one.

```teal
function Audio:setLimit(key: string, limit: Audio.Limit)
```

Passing `nil` removes the limit. Voices already sounding are left alone.

### limit

The limit a key carries, or `nil`.

```teal
function Audio:limit(key: string): Audio.Limit
```

### keyCount

Voices a key is holding right now.

```teal
function Audio:keyCount(key: string): integer
```

### keys

Every key with a limit set or a voice counted against it, sorted.

```teal
function Audio:keys(): {string}
```

## Interned names

A clip's path is its identity, and a group's name is its identity, for the same reason: an FFI component holds
numbers, so what a `Sound` carries is an integer handed out in the order names were first seen. That order is not
something a snapshot can rely on reproducing, which is why an index belongs in a component and never in a file.

Indices start at one, so zero is "no clip" and "no group", which is what a `Sound` carries until something names
one.

### clipId

Index of a clip path, assigning one the first time it is seen.

```teal
function Audio.clipId(path: string): integer
```

Raises on an empty path.

### clipPath

Path a clip index stands for, or `nil` when it names nothing.

```teal
function Audio.clipPath(id: integer): string
```

### groupId

Index of a group name, assigning one the first time it is seen.

```teal
function Audio.groupId(name: string): integer
```

Raises on an empty name.

### groupName

Name a group index stands for, or `nil` when it names nothing.

```teal
function Audio.groupName(id: integer): string
```

## The Sound component

A sound attached to an entity. Presence is the instruction: an entity carrying this with a loaded clip starts
sounding on the next audio pass, and stops when the component or the entity goes away. That is what makes sound
an entity rather than a handle a game has to remember to release, and it is why despawning something mid-sound
does the obvious thing.

`Sound` is declared by this module rather than in [`components`](/modules/gfx/), and is reachable as
`tecs.audio.Sound`. It is an FFI component, so its columns are contiguous C memory and it holds numbers only.

| Field     | Type     | Default | Description                                                                                                                                                                         |
| --------- | -------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `clip`    | `number` | `0`     | Clip index, from [`Audio.clipId`](#clipid). Zero plays nothing.                                                                                                                     |
| `playing` | `number` | `1`     | Nonzero sounds, zero does not. The instruction rather than a report: clearing it stops the voice and setting it again starts one, including on a one-shot that has already run out. |
| `gain`    | `number` | `1.0`   | 0 to 1, before the master gain.                                                                                                                                                     |
| `loop`    | `number` | `0`     | Nonzero repeats. Clearing it part way through lets the voice play out to its end rather than cutting it.                                                                            |
| `pitch`   | `number` | `1.0`   | Playback rate. 1 is unchanged, 2 is an octave up and half as long.                                                                                                                  |
| `spatial` | `number` | `0`     | Nonzero reads `x`, `y` and `z`; zero mixes without a position.                                                                                                                      |
| `x`       | `number` | `0.0`   | See [position](#position).                                                                                                                                                          |
| `y`       | `number` | `0.0`   |                                                                                                                                                                                     |
| `z`       | `number` | `0.0`   |                                                                                                                                                                                     |
| `group`   | `number` | `0`     | Group index, from [`Audio.groupId`](#groupid). Zero joins no group.                                                                                                                 |
| `voice`   | `number` | `0`     | Voice the audio pass assigned: zero before it starts, negative once a one-shot has finished. Written by the engine; setting it back to zero is how a game asks for the sound again. |

**Example:**

```teal
local Sound <const> = tecs.audio.Sound
local siren <const> = app.audio:load("assets/sfx/siren.ogg")

world:spawn(Sound(siren.id, 1, 0.8, 1, 1.0, 0, 0.0, 0.0, 0.0,
    tecs.audio.Audio.groupId("sfx")))
```

::: warning batchSpawn skips FFI defaults
A `Sound` written through `world:batchSpawn` gets no defaults at all, so the callback has to set every field,
`playing` and `pitch` included. A row left at zero pitch is not a sound anyone asked for.
:::

### What is followed

`playing`, `gain`, `loop`, `pitch` and the position are followed for as long as the voice sounds, so writing any
of them is enough and nothing has to be restarted to make one take. Each is a read and a compare per sounding row
per frame, and a call into the mixer only on the frame the value moved.

`clip` and `group` are not on that list. Both take an untag, a retag and a fresh input to change, neither is
something a game writes often, and following them would put that cost on every row that never does. Moving a
sound into another group is setting `group` and clearing `voice`, which is the same thing changing its clip
takes.

One walk per frame answers all of it: a row asking to sound with no voice starts one, a sounding row has its
fields followed, a row that has stopped asking or whose voice has ended is put back to rest, and any voice no
component referred to during the walk is stopped, which is what makes despawning something mid-sound work without
an observer on every archetype that might hold one.

::: warning Writing through world:get does not mark it dirty
`Sound` is an FFI component, so a direct cdata write reached through `world:get` needs an explicit
`world:markComponentDirty(entity, Sound)`. Writes through `getMut` mark the column themselves.
:::

### Disabling

Disabling an entity silences its sound, and re-enabling starts it again. `Disabled` is excluded from every query
that does not name it, so a disabled row is not followed and its voice is taken back; the audio pass clears the
handle in the same frame, which is what lets the sound return with the entity rather than reading as a one-shot
that had finished.

A second query naming `Disabled` is what sees those rows, and because a disabled entity sits in an archetype of
its own, a world with nothing disabled matches nothing and walks nothing.

### Position

Position is passed to the mixer and nothing more. `spatial` switches it on, and `x`, `y` and `z` are read as the
mixer reads them: a right-handed system whose listener sits at the origin and cannot be moved, with x positive to
the right, y positive up and z positive behind.

So a caller with a camera and a world has three jobs this component does not do for it, and doing any of them
here would fix answers that belong to a game:

1. **Subtract the listener.** There is no listener component and no rule that the camera is one, so whatever a
   game decides is listening is what it subtracts before writing these fields.
2. **Choose a scale.** The mixer attenuates with distance on its own, and how loud a sound a hundred world units
   away should be is a question about a game's units, not about audio.
3. **Decide what a screen-space sound means.** A sound on a layer that does not move with the camera has no world
   position to convert, and the answer is to leave `spatial` at zero.

[`setStereo`](#setstereo) is the other way to place a voice, and usually the one a game laid out on a plane
wants.

### Serialization

A `Sound` crosses a snapshot as names rather than indices: `clip` is written as its path and `group` as its
group's name, because an integer in a save file would name whatever the next run happened to intern in its place.

The voice is not restored. A snapshot records that an entity has a sound, not how far through it the mixer had
got, so the sound starts again on load.

## Looking in

### voices

Every sounding voice, paused and fading ones included.

```teal
function Audio:voices(): {Audio.VoiceInfo}
```

For introspection, on the same terms as `clips`: it builds a list per call. The handles it reports are the ones
`playing` and `stop` take, so what this shows can be acted on.

#### Audio.VoiceInfo

| Field           | Type      | Description                                                         |
| --------------- | --------- | ------------------------------------------------------------------- |
| `handle`        | `integer` | The handle a game holds, which `playing` and `stop` take.           |
| `clip`          | `string`  | Path of the clip it is reading, or `nil` once it has been released. |
| `gain`          | `number`  | What the voice asked for, before its group and the master.          |
| `applied`       | `number`  | What reached the track, the group's gain and mute included.         |
| `pitch`         | `number`  | Its playback rate.                                                  |
| `group`         | `string`  | Its group, or `nil`.                                                |
| `key`           | `string`  | Its limit bucket, or `nil`.                                         |
| `paused`        | `boolean` | Whether a pause is holding it.                                      |
| `stopping`      | `boolean` | Whether a fade-out is running it down.                              |
| `owned`         | `boolean` | Whether a `Sound` component started this rather than `play`.        |
| `loop`          | `boolean` | Whether it repeats when it reaches the end.                         |
| `spatial`       | `boolean` | Whether it is placed, and at what coordinates.                      |
| `x`, `y`, `z`   | `number`  | The position, when `spatial`.                                       |
| `stereo`        | `boolean` | Whether it is pinned to the front pair.                             |
| `left`, `right` | `number`  | The pan gains, when `stereo`.                                       |

## In a snapshot

[`install`](#install) adds a snapshot handler named `tecs.audio` that carries the master gain, the master mute
and every group's gain, mute and pause. A player who turned the music down and held the effects for a menu
expects to find it that way after a load, and none of that is in the world, so nothing else would carry it.

Loading visits every group this run knows about, not only the ones the snapshot names, so a save made before a
group was ever touched puts that group back to its defaults rather than leaving this run's settings on it. It
goes through the ordinary setters, which is what makes the voices already sounding follow.

Keyed limits are not in it, and neither is what a bucket holds. A limit is a rule the build states at startup
beside the clip it governs, so restoring one from a file would let an old save override a rule the build has
since changed. A bucket is derived from voices, and a snapshot restores no voices: a `Sound` comes back with its
voice cleared and starts again.

## Physical devices and microphone capture

The same module covers the devices the mixer opens and audio flowing the other way, into the game. A game names
a device here and passes its id as `Audio.Config.device`; nothing above needs to know these came from a
different file.

```teal
function audio.playbackDevices(): {audio.Device}, string
function audio.recordingDevices(): {audio.Device}, string
```

Both return the devices attached now plus an error only when the audio subsystem could not start. A device has
`id`, `name`, `frequency`, and `channels`; the last two are zero if its preferred format was unavailable.

### openMicrophone

```teal
function audio.openMicrophone(config?: audio.MicrophoneConfig): audio.Microphone, string
```

Opens the system-default recording device, or `config.device`. SDL converts its input to `config.frequency`
(48000 by default), `config.channels` (one by default), and interleaved native-endian float32 samples.

No Lua callback is installed. SDL's audio thread fills its own stream and the game pulls completed samples on
the main thread:

```teal
local microphone <const>, err <const> = tecs.audio.openMicrophone()
if microphone ~= nil then
    local bytes <const> = microphone:read(1024)
    -- `bytes` contains at most 1024 complete mono float32 frames.
end
```

| Method                 | Meaning                                                    |
| ---------------------- | ---------------------------------------------------------- |
| `availableFrames()`    | Complete frames ready without blocking                     |
| `read(maxFrames?)`     | Up to the limit as float32 bytes; `""` when none are ready |
| `pause()` / `resume()` | Stops or resumes capture, returning `(boolean, error?)`    |
| `destroy()`            | Closes the stream and device; safe more than once          |

`read` returns `(bytes, nil)` or `(nil, error)`. A frame contains `channels * 4` bytes. It never returns a partial
frame, and reading a destroyed microphone is an error.
<!-- @generated by `cargo xtask docs-reference` from src/tecs/audio.tl, src/tecs/platform/audio.tl. Do not edit below this line. -->

## Reference

Every function and type this module carries, rendered from `src/tecs/audio.tl` and `src/tecs/platform/audio.tl`.

<a id="tecs.audio.Audio"></a>

### tecs.audio.Audio

<pre><code v-pre>record <a href="#tecs.audio.Audio">tecs.audio.Audio</a>
</code></pre>

One audio output and the voices sounding on it.

Units, in one place, because none of them is in a signature:

- **Time is seconds** everywhere on this surface: a fade, a seek, a loop
  point, a cooldown, a clip's duration. Milliseconds appear only below the
  platform seam. Every fade is a duration to run for, never a moment to
  finish at, so calling one twice restarts it rather than moving a
  deadline.
- **Gain is linear amplitude, not decibels.** 0 is silence and 1 is the
  sound as recorded. Above 1 is louder and may clip. The level a voice
  reaches the hardware at is its own gain times its group's gain times the
  master gain, and a mute at either level composes as a zero without
  discarding the gain underneath it.
- **Pitch is a playback rate, not an interval.** 1 is unchanged, 2 is an
  octave up and half as long, 0.5 an octave down and twice as long. It
  resamples, so it changes duration; there is no time-stretch here.
- **Position is the mixer's frame, not the world's.** The listener is
  fixed at the origin and cannot be moved, x is positive to the right, y
  is positive **up**, and z is positive behind. World Y runs down, so a
  caller feeding world coordinates in has to flip Y as well as subtract
  whatever it decided is listening. See `Sound`.

A voice handle is a generation and a slot packed into one integer. It stays
meaningful for exactly as long as the voice sounds: once the voice ends, or
is stopped, or is reaped by `update`, every call taking the handle becomes a
no-op, and it never starts naming the next voice to take that slot. Nothing
has to be released, and holding a stale handle is not an error.

Nothing here is thread safe, and nothing here calls back. Everything runs on
the thread that calls it.

<a id="tecs.audio.Audio.Config"></a>

### tecs.audio.Audio.Config

<pre><code v-pre>record <a href="#tecs.audio.Audio.Config">tecs.audio.Audio.Config</a>
</code></pre>

What `newAudio` takes. Every field is optional.

<a id="tecs.audio.Audio.Config.frequency"></a>

### tecs.audio.Audio.Config.frequency

<pre><code v-pre><a href="#tecs.audio.Audio.Config.frequency">tecs.audio.Audio.Config.frequency</a>: integer
</code></pre>

Frames per second. Defaults to 48000.

<a id="tecs.audio.Audio.Config.channels"></a>

### tecs.audio.Audio.Config.channels

<pre><code v-pre><a href="#tecs.audio.Audio.Config.channels">tecs.audio.Audio.Config.channels</a>: integer
</code></pre>

Output channels. Defaults to 2.

<a id="tecs.audio.Audio.Config.maxVoices"></a>

### tecs.audio.Audio.Config.maxVoices

<pre><code v-pre><a href="#tecs.audio.Audio.Config.maxVoices">tecs.audio.Audio.Config.maxVoices</a>: integer
</code></pre>

Voices that may sound at once. Defaults to 32.

<a id="tecs.audio.Audio.Config.streamSeconds"></a>

### tecs.audio.Audio.Config.streamSeconds

<pre><code v-pre><a href="#tecs.audio.Audio.Config.streamSeconds">tecs.audio.Audio.Config.streamSeconds</a>: number
</code></pre>

Seconds at which a clip streams instead of being held resident.
Defaults to 10.

<a id="tecs.audio.Audio.Config.backend"></a>

### tecs.audio.Audio.Config.backend

<pre><code v-pre><a href="#tecs.audio.Audio.Config.backend">tecs.audio.Audio.Config.backend</a>: Backend
</code></pre>

Output backend. Defaults to the installed platform's.

<a id="tecs.audio.Audio.Config.device"></a>

### tecs.audio.Audio.Config.device

<pre><code v-pre><a href="#tecs.audio.Audio.Config.device">tecs.audio.Audio.Config.device</a>: number
</code></pre>

Physical output device id from `tecs.audio.playbackDevices`.
Omitted follows the operating-system default as it changes.

<a id="tecs.audio.Audio.Clip"></a>

### tecs.audio.Audio.Clip

<pre><code v-pre>record <a href="#tecs.audio.Audio.Clip">tecs.audio.Audio.Clip</a>
</code></pre>

A loaded sound.

Returned by `load` before the file has been read, so check `status`
rather than assuming it is playable. The instance is shared: loading the
same path twice hands back the same table, and its fields are updated in
place as the load settles, so a caller holding one sees it become ready
without asking again.

<a id="tecs.audio.Audio.Clip.path"></a>

### tecs.audio.Audio.Clip.path

<pre><code v-pre><a href="#tecs.audio.Audio.Clip.path">tecs.audio.Audio.Clip.path</a>: string
</code></pre>

The path it was loaded from, exactly as given. This is a clip's
identity, so two spellings of one file are two clips.

<a id="tecs.audio.Audio.Clip.id"></a>

### tecs.audio.Audio.Clip.id

<pre><code v-pre><a href="#tecs.audio.Audio.Clip.id">tecs.audio.Audio.Clip.id</a>: integer
</code></pre>

Index of `path`, which is what a `Sound` component carries.

<a id="tecs.audio.Audio.Clip.status"></a>

### tecs.audio.Audio.Clip.status

<pre><code v-pre><a href="#tecs.audio.Audio.Clip.status">tecs.audio.Audio.Clip.status</a>: string
</code></pre>

"loading", "ready", "failed", or "released" once the audio object
it was loaded into has been destroyed.

<a id="tecs.audio.Audio.Clip.error"></a>

### tecs.audio.Audio.Clip.error

<pre><code v-pre><a href="#tecs.audio.Audio.Clip.error">tecs.audio.Audio.Clip.error</a>: string
</code></pre>

Set when loading failed.

<a id="tecs.audio.Audio.Clip.duration"></a>

### tecs.audio.Audio.Clip.duration

<pre><code v-pre><a href="#tecs.audio.Audio.Clip.duration">tecs.audio.Audio.Clip.duration</a>: number
</code></pre>

Seconds of audio, or zero when the file cannot say.

<a id="tecs.audio.Audio.Clip.resident"></a>

### tecs.audio.Audio.Clip.resident

<pre><code v-pre><a href="#tecs.audio.Audio.Clip.resident">tecs.audio.Audio.Clip.resident</a>: boolean
</code></pre>

Whether the decoded audio is held in memory. False for a clip each
voice reads from the file for itself.

<a id="tecs.audio.Audio.LoadOptions"></a>

### tecs.audio.Audio.LoadOptions

<pre><code v-pre>record <a href="#tecs.audio.Audio.LoadOptions">tecs.audio.Audio.LoadOptions</a>
</code></pre>

What `load` takes. The one field is optional.

<a id="tecs.audio.Audio.LoadOptions.stream"></a>

### tecs.audio.Audio.LoadOptions.stream

<pre><code v-pre><a href="#tecs.audio.Audio.LoadOptions.stream">tecs.audio.Audio.LoadOptions.stream</a>: boolean
</code></pre>

Forces streaming when true and residency when false. Left unset,
the clip's duration decides against `streamSeconds`.

<a id="tecs.audio.Audio.PlayOptions"></a>

### tecs.audio.Audio.PlayOptions

<pre><code v-pre>record <a href="#tecs.audio.Audio.PlayOptions">tecs.audio.Audio.PlayOptions</a>
</code></pre>

What `play` takes. Every field is optional, and the whole table may be
omitted.

Read once, when the voice starts. Changing the table afterwards reaches
nothing: use `setGain`, `setPitch`, `setLoop`, `setPosition` and
`setStereo` on the handle instead. The table is not retained, so one
table may be filled and reused for every play.

<a id="tecs.audio.Audio.PlayOptions.gain"></a>

### tecs.audio.Audio.PlayOptions.gain

<pre><code v-pre><a href="#tecs.audio.Audio.PlayOptions.gain">tecs.audio.Audio.PlayOptions.gain</a>: number
</code></pre>

0 to 1, before the group and the master gains. Defaults to 1.

<a id="tecs.audio.Audio.PlayOptions.loop"></a>

### tecs.audio.Audio.PlayOptions.loop

<pre><code v-pre><a href="#tecs.audio.Audio.PlayOptions.loop">tecs.audio.Audio.PlayOptions.loop</a>: boolean
</code></pre>

Repeats until stopped. Defaults to false.

<a id="tecs.audio.Audio.PlayOptions.loopStart"></a>

### tecs.audio.Audio.PlayOptions.loopStart

<pre><code v-pre><a href="#tecs.audio.Audio.PlayOptions.loopStart">tecs.audio.Audio.PlayOptions.loopStart</a>: number
</code></pre>

Seconds from the start of the clip a repeat returns to, so an
intro can play once and the rest of it loop. Defaults to 0.

<a id="tecs.audio.Audio.PlayOptions.start"></a>

### tecs.audio.Audio.PlayOptions.start

<pre><code v-pre><a href="#tecs.audio.Audio.PlayOptions.start">tecs.audio.Audio.PlayOptions.start</a>: number
</code></pre>

Seconds into the clip the first pass begins. Defaults to 0.

<a id="tecs.audio.Audio.PlayOptions.fadeIn"></a>

### tecs.audio.Audio.PlayOptions.fadeIn

<pre><code v-pre><a href="#tecs.audio.Audio.PlayOptions.fadeIn">tecs.audio.Audio.PlayOptions.fadeIn</a>: number
</code></pre>

Seconds of silence-to-full at the start. Defaults to 0.

<a id="tecs.audio.Audio.PlayOptions.pitch"></a>

### tecs.audio.Audio.PlayOptions.pitch

<pre><code v-pre><a href="#tecs.audio.Audio.PlayOptions.pitch">tecs.audio.Audio.PlayOptions.pitch</a>: number
</code></pre>

Playback rate. 1 is unchanged. Defaults to 1.

<a id="tecs.audio.Audio.PlayOptions.pitchVariance"></a>

### tecs.audio.Audio.PlayOptions.pitchVariance

<pre><code v-pre><a href="#tecs.audio.Audio.PlayOptions.pitchVariance">tecs.audio.Audio.PlayOptions.pitchVariance</a>: number
</code></pre>

Fraction of `pitch` to vary by, chosen anew for each voice. 0.1
spreads voices over plus or minus a tenth. Defaults to 0.

<a id="tecs.audio.Audio.PlayOptions.group"></a>

### tecs.audio.Audio.PlayOptions.group

<pre><code v-pre><a href="#tecs.audio.Audio.PlayOptions.group">tecs.audio.Audio.PlayOptions.group</a>: string
</code></pre>

Group this voice joins. Defaults to none.

<a id="tecs.audio.Audio.PlayOptions.key"></a>

### tecs.audio.Audio.PlayOptions.key

<pre><code v-pre><a href="#tecs.audio.Audio.PlayOptions.key">tecs.audio.Audio.PlayOptions.key</a>: string
</code></pre>

Limit bucket this voice counts against. Defaults to none.

<a id="tecs.audio.Audio.PlayOptions.spatial"></a>

### tecs.audio.Audio.PlayOptions.spatial

<pre><code v-pre><a href="#tecs.audio.Audio.PlayOptions.spatial">tecs.audio.Audio.PlayOptions.spatial</a>: boolean
</code></pre>

Position, when `spatial`. See `Sound` for what the numbers mean.

<a id="tecs.audio.Audio.PlayOptions.x"></a>

### tecs.audio.Audio.PlayOptions.x

<pre><code v-pre><a href="#tecs.audio.Audio.PlayOptions.x">tecs.audio.Audio.PlayOptions.x</a>: number
</code></pre>

Positive to the right of the listener. Defaults to 0.

<a id="tecs.audio.Audio.PlayOptions.y"></a>

### tecs.audio.Audio.PlayOptions.y

<pre><code v-pre><a href="#tecs.audio.Audio.PlayOptions.y">tecs.audio.Audio.PlayOptions.y</a>: number
</code></pre>

Positive **above** the listener, which is the opposite sign from
world Y. Defaults to 0.

<a id="tecs.audio.Audio.PlayOptions.z"></a>

### tecs.audio.Audio.PlayOptions.z

<pre><code v-pre><a href="#tecs.audio.Audio.PlayOptions.z">tecs.audio.Audio.PlayOptions.z</a>: number
</code></pre>

Positive behind the listener. Defaults to 0.

<a id="tecs.audio.Audio.PlayOptions.stereo"></a>

### tecs.audio.Audio.PlayOptions.stereo

<pre><code v-pre><a href="#tecs.audio.Audio.PlayOptions.stereo">tecs.audio.Audio.PlayOptions.stereo</a>: boolean
</code></pre>

Pins the voice to the front pair of speakers at `left` and
`right`, which is a pan rather than a position. Ignored when
`spatial` is set, because the mixer holds one placement per track.
Both gains default to 1.

<a id="tecs.audio.Audio.PlayOptions.left"></a>

### tecs.audio.Audio.PlayOptions.left

<pre><code v-pre><a href="#tecs.audio.Audio.PlayOptions.left">tecs.audio.Audio.PlayOptions.left</a>: number
</code></pre>

Gain out of the left speaker, on the same linear scale as `gain`.
Negative reads as silence and above 1 is louder. Defaults to 1.

<a id="tecs.audio.Audio.PlayOptions.right"></a>

### tecs.audio.Audio.PlayOptions.right

<pre><code v-pre><a href="#tecs.audio.Audio.PlayOptions.right">tecs.audio.Audio.PlayOptions.right</a>: number
</code></pre>

Gain out of the right speaker, on the same terms as `left`.

<a id="tecs.audio.Audio.Limit"></a>

### tecs.audio.Audio.Limit

<pre><code v-pre>record <a href="#tecs.audio.Audio.Limit">tecs.audio.Audio.Limit</a>
</code></pre>

What a key allows.

<a id="tecs.audio.Audio.Limit.voices"></a>

### tecs.audio.Audio.Limit.voices

<pre><code v-pre><a href="#tecs.audio.Audio.Limit.voices">tecs.audio.Audio.Limit.voices</a>: integer
</code></pre>

Voices this key may hold at once. Zero or absent is no ceiling.

<a id="tecs.audio.Audio.Limit.cooldown"></a>

### tecs.audio.Audio.Limit.cooldown

<pre><code v-pre><a href="#tecs.audio.Audio.Limit.cooldown">tecs.audio.Audio.Limit.cooldown</a>: number
</code></pre>

Seconds after one starts before another may. Zero is none.

<a id="tecs.audio.Audio.VoiceInfo"></a>

### tecs.audio.Audio.VoiceInfo

<pre><code v-pre>record <a href="#tecs.audio.Audio.VoiceInfo">tecs.audio.Audio.VoiceInfo</a>
</code></pre>

One sounding voice, as something looking in reads it.

<a id="tecs.audio.Audio.VoiceInfo.handle"></a>

### tecs.audio.Audio.VoiceInfo.handle

<pre><code v-pre><a href="#tecs.audio.Audio.VoiceInfo.handle">tecs.audio.Audio.VoiceInfo.handle</a>: integer
</code></pre>

The handle a game holds, which `playing` and `stop` take.

<a id="tecs.audio.Audio.VoiceInfo.clip"></a>

### tecs.audio.Audio.VoiceInfo.clip

<pre><code v-pre><a href="#tecs.audio.Audio.VoiceInfo.clip">tecs.audio.Audio.VoiceInfo.clip</a>: string
</code></pre>

Path of the clip it is reading, or nil once it has been released.

<a id="tecs.audio.Audio.VoiceInfo.gain"></a>

### tecs.audio.Audio.VoiceInfo.gain

<pre><code v-pre><a href="#tecs.audio.Audio.VoiceInfo.gain">tecs.audio.Audio.VoiceInfo.gain</a>: number
</code></pre>

What the voice asked for, before its group and the master.

<a id="tecs.audio.Audio.VoiceInfo.applied"></a>

### tecs.audio.Audio.VoiceInfo.applied

<pre><code v-pre><a href="#tecs.audio.Audio.VoiceInfo.applied">tecs.audio.Audio.VoiceInfo.applied</a>: number
</code></pre>

What reached the track, the group's gain and mute included. The
master gain is not in it: that is the mixer's own number and is not
multiplied per voice.

<a id="tecs.audio.Audio.VoiceInfo.pitch"></a>

### tecs.audio.Audio.VoiceInfo.pitch

<pre><code v-pre><a href="#tecs.audio.Audio.VoiceInfo.pitch">tecs.audio.Audio.VoiceInfo.pitch</a>: number
</code></pre>

Playback rate as the track carries it, so the pitch variance a
`play` drew is already in it rather than the rate that was asked
for.

<a id="tecs.audio.Audio.VoiceInfo.group"></a>

### tecs.audio.Audio.VoiceInfo.group

<pre><code v-pre><a href="#tecs.audio.Audio.VoiceInfo.group">tecs.audio.Audio.VoiceInfo.group</a>: string
</code></pre>

Group tag, or nil for a voice in none.

<a id="tecs.audio.Audio.VoiceInfo.key"></a>

### tecs.audio.Audio.VoiceInfo.key

<pre><code v-pre><a href="#tecs.audio.Audio.VoiceInfo.key">tecs.audio.Audio.VoiceInfo.key</a>: string
</code></pre>

Limit bucket, or nil for a voice counted against none.

<a id="tecs.audio.Audio.VoiceInfo.paused"></a>

### tecs.audio.Audio.VoiceInfo.paused

<pre><code v-pre><a href="#tecs.audio.Audio.VoiceInfo.paused">tecs.audio.Audio.VoiceInfo.paused</a>: boolean
</code></pre>

Whether a pause is holding it, whether its own or its group's.

<a id="tecs.audio.Audio.VoiceInfo.stopping"></a>

### tecs.audio.Audio.VoiceInfo.stopping

<pre><code v-pre><a href="#tecs.audio.Audio.VoiceInfo.stopping">tecs.audio.Audio.VoiceInfo.stopping</a>: boolean
</code></pre>

Whether a fade-out is running it down.

<a id="tecs.audio.Audio.VoiceInfo.owned"></a>

### tecs.audio.Audio.VoiceInfo.owned

<pre><code v-pre><a href="#tecs.audio.Audio.VoiceInfo.owned">tecs.audio.Audio.VoiceInfo.owned</a>: boolean
</code></pre>

Whether a `Sound` component started this rather than `play`.

<a id="tecs.audio.Audio.VoiceInfo.loop"></a>

### tecs.audio.Audio.VoiceInfo.loop

<pre><code v-pre><a href="#tecs.audio.Audio.VoiceInfo.loop">tecs.audio.Audio.VoiceInfo.loop</a>: boolean
</code></pre>

Whether it repeats when it reaches the end.

<a id="tecs.audio.Audio.VoiceInfo.spatial"></a>

### tecs.audio.Audio.VoiceInfo.spatial

<pre><code v-pre><a href="#tecs.audio.Audio.VoiceInfo.spatial">tecs.audio.Audio.VoiceInfo.spatial</a>: boolean
</code></pre>

Whether it is placed in space. Never true at the same time as
`stereo`: the mixer holds one placement per track.

<a id="tecs.audio.Audio.VoiceInfo.x"></a>

### tecs.audio.Audio.VoiceInfo.x

<pre><code v-pre><a href="#tecs.audio.Audio.VoiceInfo.x">tecs.audio.Audio.VoiceInfo.x</a>: number
</code></pre>

Last position pushed, in the mixer's frame: positive right.
Meaningless unless `spatial`.

<a id="tecs.audio.Audio.VoiceInfo.y"></a>

### tecs.audio.Audio.VoiceInfo.y

<pre><code v-pre><a href="#tecs.audio.Audio.VoiceInfo.y">tecs.audio.Audio.VoiceInfo.y</a>: number
</code></pre>

Last position pushed, positive up. Meaningless unless `spatial`.

<a id="tecs.audio.Audio.VoiceInfo.z"></a>

### tecs.audio.Audio.VoiceInfo.z

<pre><code v-pre><a href="#tecs.audio.Audio.VoiceInfo.z">tecs.audio.Audio.VoiceInfo.z</a>: number
</code></pre>

Last position pushed, positive behind. Meaningless unless
`spatial`.

<a id="tecs.audio.Audio.VoiceInfo.stereo"></a>

### tecs.audio.Audio.VoiceInfo.stereo

<pre><code v-pre><a href="#tecs.audio.Audio.VoiceInfo.stereo">tecs.audio.Audio.VoiceInfo.stereo</a>: boolean
</code></pre>

Whether it is pinned to the front pair, and at what gains.

<a id="tecs.audio.Audio.VoiceInfo.left"></a>

### tecs.audio.Audio.VoiceInfo.left

<pre><code v-pre><a href="#tecs.audio.Audio.VoiceInfo.left">tecs.audio.Audio.VoiceInfo.left</a>: number
</code></pre>

Left speaker gain last pushed. Meaningless unless `stereo`.

<a id="tecs.audio.Audio.VoiceInfo.right"></a>

### tecs.audio.Audio.VoiceInfo.right

<pre><code v-pre><a href="#tecs.audio.Audio.VoiceInfo.right">tecs.audio.Audio.VoiceInfo.right</a>: number
</code></pre>

Right speaker gain last pushed. Meaningless unless `stereo`.

<a id="tecs.audio.Audio.Sound"></a>

### tecs.audio.Audio.Sound

<pre><code v-pre><a href="#tecs.audio.Audio.Sound">tecs.audio.Audio.Sound</a>: <a href="#tecs.audio.Sound">Sound</a>
</code></pre>

The `Sound` component, for a game that wants to query or set it. See
the record's own documentation for what its fields mean.

<a id="tecs.audio.Audio.available"></a>

### tecs.audio.Audio.available

<pre><code v-pre><a href="#tecs.audio.Audio.available">tecs.audio.Audio.available</a>: boolean
</code></pre>

Whether an output opened. False on a machine with no sound, where
every call here still works and nothing is heard.

<a id="tecs.audio.Audio.clipId"></a>

### tecs.audio.Audio.clipId

<pre><code v-pre>function <a href="#tecs.audio.Audio.clipId">tecs.audio.Audio.clipId</a>(path: string): integer
</code></pre>

Index of a clip path, assigning one the first time it is seen.

#### Parameters

| Type                      | Name                    | Description                                                                                                                            |
| ------------------------- | ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | <code v-pre>path</code> | Must be non-empty; an empty one raises. Not checked against the filesystem, so this hands out an index for a path that does not exist. |

#### Returns

| Type                       | Description                                                                                                                                                           |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | An index from 1 up, shared by every `Audio` in the process. It is this run's numbering and means nothing in a file, which is why `Sound` serializes the path instead. |

<a id="tecs.audio.Audio.clipPath"></a>

### tecs.audio.Audio.clipPath

<pre><code v-pre>function <a href="#tecs.audio.Audio.clipPath">tecs.audio.Audio.clipPath</a>(id: integer): string
</code></pre>

Path a clip index stands for, or nil when it names nothing.

#### Parameters

| Type                       | Name                  | Description                                                                       |
| -------------------------- | --------------------- | --------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | <code v-pre>id</code> | Zero is the index of no clip and answers nil, as does any index never handed out. |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| <code v-pre>string</code> |             |

<a id="tecs.audio.Audio.groupId"></a>

### tecs.audio.Audio.groupId

<pre><code v-pre>function <a href="#tecs.audio.Audio.groupId">tecs.audio.Audio.groupId</a>(name: string): integer
</code></pre>

Index of a group name, assigning one the first time it is seen.

What a `Sound` carries in `group`. The index means nothing outside the run
that handed it out, so it belongs in a component and never in a file.

#### Parameters

| Type                      | Name                    | Description                                                                                                   |
| ------------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | <code v-pre>name</code> | Must be non-empty; an empty one raises. A group needs no declaring: naming one here is all it takes to exist. |

#### Returns

| Type                       | Description                                                 |
| -------------------------- | ----------------------------------------------------------- |
| <code v-pre>integer</code> | An index from 1 up, shared by every `Audio` in the process. |

<a id="tecs.audio.Audio.groupName"></a>

### tecs.audio.Audio.groupName

<pre><code v-pre>function <a href="#tecs.audio.Audio.groupName">tecs.audio.Audio.groupName</a>(id: integer): string
</code></pre>

Name a group index stands for, or nil when it names nothing.

#### Parameters

| Type                       | Name                  | Description                                                                                 |
| -------------------------- | --------------------- | ------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | <code v-pre>id</code> | Zero is the index of no group and answers nil, which is what a `Sound` in no group carries. |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| <code v-pre>string</code> |             |

<a id="tecs.audio.Audio.decoders"></a>

### tecs.audio.Audio.decoders

<pre><code v-pre>function <a href="#tecs.audio.Audio.decoders">tecs.audio.Audio.decoders</a>(): {string}
</code></pre>

The decoders this build linked, in the mixer's own order.

What a build asked for and what it got are different questions: a decoder
whose dependency was not found is dropped silently. This answers the second.

#### Returns

| Type                        | Description                                                                                                                                                      |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>{string}</code> | Decoder names such as `"WAV"` and `"OGG"`, in the mixer's own order rather than sorted, and empty when the mixer will not start at all. A fresh table each call. |

<a id="tecs.audio.Audio.destroy"></a>

### tecs.audio.Audio.destroy

<pre><code v-pre>function <a href="#tecs.audio.Audio.destroy">tecs.audio.Audio.destroy</a>(self: <a href="#tecs.audio.Audio">Audio</a>)
</code></pre>

Stops everything and closes the output.

Blocks until loads in flight have settled, since a clip arriving afterwards
would hold a pointer into a library that has released everything it made.
Every voice is stopped without a fade, every clip goes to `"released"`, and
every world this was installed into stops answering from `Audio.of`. There
is no reopening: make a new instance instead.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code> |             |

<a id="tecs.audio.Audio.load"></a>

### tecs.audio.Audio.load

<pre><code v-pre>function <a href="#tecs.audio.Audio.load">tecs.audio.Audio.load</a>(self: <a href="#tecs.audio.Audio">Audio</a>, path: string, options: <a href="#tecs.audio.Audio.LoadOptions">Audio.LoadOptions</a>): <a href="#tecs.audio.Audio.Clip">Audio.Clip</a>
</code></pre>

Queues a sound for loading and returns its clip immediately.

Loading the same path twice returns the same clip; a clip is the file, and
playing it twice over is two voices reading one clip. `options.stream`
overrides the duration threshold that otherwise decides whether the clip is
held in memory.

#### Parameters

| Type                                                                             | Name                       | Description                                                                                                                                                              |
| -------------------------------------------------------------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code>                         | <code v-pre>self</code>    |                                                                                                                                                                          |
| <code v-pre>string</code>                                                        | <code v-pre>path</code>    | Must be non-empty. Not checked here: a path that does not exist returns a clip that settles to `"failed"` a frame or two later, so this never raises for a missing file. |
| <code v-pre><a href="#tecs.audio.Audio.LoadOptions">Audio.LoadOptions</a></code> | <code v-pre>options</code> |                                                                                                                                                                          |

#### Returns

| Type                                                               | Description                                                                                                                                                                                                                                                            |
| ------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio.Clip">Audio.Clip</a></code> | A clip whose `status` is `"loading"` on the first call for a path and whatever it has since become on a later one. Never nil. The instance belongs to this `Audio` and is the same table every call for that path returns, so `options` is honoured only by the first. |

<a id="tecs.audio.Audio.clip"></a>

### tecs.audio.Audio.clip

<pre><code v-pre>function <a href="#tecs.audio.Audio.clip">tecs.audio.Audio.clip</a>(self: <a href="#tecs.audio.Audio">Audio</a>, id: integer): <a href="#tecs.audio.Audio.Clip">Audio.Clip</a>
</code></pre>

The clip an index stands for, or nil when this instance has not loaded it.

#### Parameters

| Type                                                     | Name                    | Description                                                                                                                                                           |
| -------------------------------------------------------- | ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code> |                                                                                                                                                                       |
| <code v-pre>integer</code>                               | <code v-pre>id</code>   | From `Audio.clipId`, or off a `Sound.clip` field. Clip indices are shared across the process but clips are not, so an index another instance loaded answers nil here. |

#### Returns

| Type                                                               | Description |
| ------------------------------------------------------------------ | ----------- |
| <code v-pre><a href="#tecs.audio.Audio.Clip">Audio.Clip</a></code> |             |

<a id="tecs.audio.Audio.waitForLoads"></a>

### tecs.audio.Audio.waitForLoads

<pre><code v-pre>function <a href="#tecs.audio.Audio.waitForLoads">tecs.audio.Audio.waitForLoads</a>(self: <a href="#tecs.audio.Audio">Audio</a>, timeoutMs: number)
</code></pre>

Blocks until every queued load has finished.

For startup and tests. A frame should let `update` resolve them instead.

#### Parameters

| Type                                                     | Name                         | Description                                                                                                                                                                                                                                                                                                                |
| -------------------------------------------------------- | ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code>      |                                                                                                                                                                                                                                                                                                                            |
| <code v-pre>number</code>                                | <code v-pre>timeoutMs</code> | **Milliseconds**, unlike the seconds everything else on this surface takes, because it is a wait on the asset worker rather than an audio duration. Omitting it does not wait forever: it takes a 5000 ms default. Running out is not reported, so read `loading` afterwards to tell a finished wait from a timed-out one. |

<a id="tecs.audio.Audio.loading"></a>

### tecs.audio.Audio.loading

<pre><code v-pre>function <a href="#tecs.audio.Audio.loading">tecs.audio.Audio.loading</a>(self: <a href="#tecs.audio.Audio">Audio</a>): integer
</code></pre>

Clips still being read.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description                                                                                                                                                                               |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | Loads not yet settled. Counts loads rather than clips, and a clip that failed is settled, so this reaching zero means every `load` has an answer and not that every answer was a success. |

<a id="tecs.audio.Audio.reload"></a>

### tecs.audio.Audio.reload

<pre><code v-pre>function <a href="#tecs.audio.Audio.reload">tecs.audio.Audio.reload</a>(self: <a href="#tecs.audio.Audio">Audio</a>, path: string): boolean, string
</code></pre>

Re-reads a clip's file over the clip already loaded from it.

The counterpart to `Renderer:replaceImage`, and it keeps identity on the
same terms. A clip's index is its path's, so an edited file comes back under
the index every `Sound` row already carries and nothing in the world is
touched.

A streamed clip holds nothing to replace. Each voice opens the file for
itself, so the next one to start reads what is on disk now and this has only
to say so. Voices already sounding read the stream they opened, which is
what happens to a file edited under a running voice with or without a
reload.

A resident clip is decoded again and swapped, and it stays resident whatever
the new file's length would have chosen: rows already pointing at it were
started against held samples, and turning it into a stream under them would
change what a voice is, not what it sounds like. The clip it replaces is
destroyed here, which is safe with voices still on it: the mixer counts a
reference per track and frees at the last one, so a sound playing across the
swap finishes on the samples it started with.

Blocking, like every other reload: it is a debug operation, and answering
before the file has been read would report a success that had not happened
yet.

#### Parameters

| Type                                                     | Name                    | Description                        |
| -------------------------------------------------------- | ----------------------- | ---------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code> |                                    |
| <code v-pre>string</code>                                | <code v-pre>path</code> | The path the clip was loaded from. |

#### Returns

| Type                       | Description                                                 |
| -------------------------- | ----------------------------------------------------------- |
| <code v-pre>boolean</code> | Whether the clip was re-read, and a reason when it was not. |
| <code v-pre>string</code>  |                                                             |

<a id="tecs.audio.Audio.play"></a>

### tecs.audio.Audio.play

<pre><code v-pre>function <a href="#tecs.audio.Audio.play">tecs.audio.Audio.play</a>(self: <a href="#tecs.audio.Audio">Audio</a>, clip: <a href="#tecs.audio.Audio.Clip">Audio.Clip</a>, options: <a href="#tecs.audio.Audio.PlayOptions">Audio.PlayOptions</a>): integer
</code></pre>

Plays `clip`, returning a handle, or zero when it did not start.

Zero means the clip is not loaded, loading failed, a key's limit or
cooldown declined it, every voice is busy, or the machine has no output.
None of those is worth raising over: a sound that does not play is not a
reason for a frame to stop.

A key's limit **drops the new voice**; it never steals an older one. A
sound that stops halfway through because something else started is harder
to explain than one that never started, and the same reasoning is why a
full voice pool declines rather than stealing.

#### Parameters

| Type                                                                             | Name                       | Description                                                                                     |
| -------------------------------------------------------------------------------- | -------------------------- | ----------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code>                         | <code v-pre>self</code>    |                                                                                                 |
| <code v-pre><a href="#tecs.audio.Audio.Clip">Audio.Clip</a></code>               | <code v-pre>clip</code>    | nil is accepted and returns zero, so a `load` result may be passed straight in without a guard. |
| <code v-pre><a href="#tecs.audio.Audio.PlayOptions">Audio.PlayOptions</a></code> | <code v-pre>options</code> | Read once, here. Nothing in it is followed afterwards.                                          |

#### Returns

| Type                       | Description                                                                                                                                                                                                                                   |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | A handle for `stop`, `playing`, `setGain` and the rest, or zero when nothing started. It stays valid while the voice sounds and goes inert for good once it does not; it is never reissued for a later voice, and nothing has to be released. |

<a id="tecs.audio.Audio.stop"></a>

### tecs.audio.Audio.stop

<pre><code v-pre>function <a href="#tecs.audio.Audio.stop">tecs.audio.Audio.stop</a>(self: <a href="#tecs.audio.Audio">Audio</a>, handle: integer, fadeOut: number)
</code></pre>

Stops a voice. A handle to one that already ended does nothing.

`fadeOut` seconds keeps the voice sounding while it fades, so `playing`
stays true until `update` sees the mixer finish it.

#### Parameters

| Type                                                     | Name                       | Description                                                                                                                                                                                                                |
| -------------------------------------------------------- | -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code>    |                                                                                                                                                                                                                            |
| <code v-pre>integer</code>                               | <code v-pre>handle</code>  | A stale one is a no-op, as is one already fading out: a second stop does not shorten a fade in progress.                                                                                                                   |
| <code v-pre>number</code>                                | <code v-pre>fadeOut</code> | Seconds to ramp down over, a duration and not a moment to finish at. Omitted or zero stops at once and frees the slot within this call. The ramp is the mixer's, so it follows the audio clock rather than the frame rate. |

<a id="tecs.audio.Audio.stopAll"></a>

### tecs.audio.Audio.stopAll

<pre><code v-pre>function <a href="#tecs.audio.Audio.stopAll">tecs.audio.Audio.stopAll</a>(self: <a href="#tecs.audio.Audio">Audio</a>, fadeOut: number)
</code></pre>

Stops everything, over `fadeOut` seconds if that is given.

A faded stop leaves each voice sounding until the mixer finishes it, so
they are reaped by `update` rather than here. The ramp is the mixer's, on
the same terms as `stop` and `stopGroup`.

Reaches every voice, whichever group it is in and whether a `Sound`
component started it or `play` did. A row still asking to sound starts a
fresh voice on the next audio pass, so this silences a world rather than
keeping it silent.

#### Parameters

| Type                                                     | Name                       | Description                                                                                                                                                                                   |
| -------------------------------------------------------- | -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code>    |                                                                                                                                                                                               |
| <code v-pre>number</code>                                | <code v-pre>fadeOut</code> | Seconds, a duration. Omitted or zero frees every slot within this call. A positive one unpauses the voices it fades, because a paused voice does not advance and its fade would never finish. |

<a id="tecs.audio.Audio.playing"></a>

### tecs.audio.Audio.playing

<pre><code v-pre>function <a href="#tecs.audio.Audio.playing">tecs.audio.Audio.playing</a>(self: <a href="#tecs.audio.Audio">Audio</a>, handle: integer): boolean
</code></pre>

Whether a handle still names a sounding voice. A paused or fading voice
still counts: it has not finished.

#### Parameters

| Type                                                     | Name                      | Description |
| -------------------------------------------------------- | ------------------------- | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code>   |             |
| <code v-pre>integer</code>                               | <code v-pre>handle</code> |             |

#### Returns

| Type                       | Description                                                                                                                                                                                                          |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | false for a handle whose voice has ended, for zero, and for one from another `Audio`. A voice that ended on its own reads true until the next `update` reaps it, since nothing here is told the instant it finished. |

<a id="tecs.audio.Audio.paused"></a>

### tecs.audio.Audio.paused

<pre><code v-pre>function <a href="#tecs.audio.Audio.paused">tecs.audio.Audio.paused</a>(self: <a href="#tecs.audio.Audio">Audio</a>, handle: integer): boolean
</code></pre>

Whether a handle names a voice a pause is holding.

#### Parameters

| Type                                                     | Name                      | Description |
| -------------------------------------------------------- | ------------------------- | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code>   |             |
| <code v-pre>integer</code>                               | <code v-pre>handle</code> |             |

#### Returns

| Type                       | Description                                                                                                                                                  |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre>boolean</code> | true whether the hold came from `pause` on this handle or from `pauseGroup` on its group; the two are not told apart. false for a handle that names nothing. |

<a id="tecs.audio.Audio.pause"></a>

### tecs.audio.Audio.pause

<pre><code v-pre>function <a href="#tecs.audio.Audio.pause">tecs.audio.Audio.pause</a>(self: <a href="#tecs.audio.Audio">Audio</a>, handle: integer)
</code></pre>

Holds a voice where it is. It keeps its slot until something resumes or
stops it, because a paused voice has not finished.

Neither this nor `resume` takes a fade, and that is a decision rather than
an omission. The mixer ramps on a play and on a stop and nowhere else, so a
faded pause has to be a ramp run from here: a list of voices in flight, a
`setGain` per voice per frame, and the pause itself issued only once the
ramp reaches zero, which makes this a command that takes effect later and
needs its own answer for what a stop, a group gain or a second pause
during the ramp means. Each step also lands on a frame boundary, so a
quarter-second fade at 60 frames a second is fifteen steps on a stream
running at 48000, and its length follows the frame rate rather than the
clock. Drift and cost of exactly that kind are what handing fades to the
mixer avoids, and one voice held for a menu is not worth giving it up.

The mixer does offer the pieces to fade out and take a sound back where it
left off: `tell` reads the position, `stop` fades out, and `play` returns
with `start` and `fadeIn`. That re-reads the input rather than holding it,
so it is a different thing from a pause, and which of the two a moment
wants is a game's answer rather than this layer's.

#### Parameters

| Type                                                     | Name                      | Description                                                                                                                                                                                   |
| -------------------------------------------------------- | ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code>   |                                                                                                                                                                                               |
| <code v-pre>integer</code>                               | <code v-pre>handle</code> | A no-op for a handle that names nothing, one already paused, and one fading out, since a paused fade would never finish. Not holder counted: one `resume` undoes any number of `pause` calls. |

<a id="tecs.audio.Audio.resume"></a>

### tecs.audio.Audio.resume

<pre><code v-pre>function <a href="#tecs.audio.Audio.resume">tecs.audio.Audio.resume</a>(self: <a href="#tecs.audio.Audio">Audio</a>, handle: integer)
</code></pre>

Lets a paused voice carry on.

#### Parameters

| Type                                                     | Name                      | Description                                                                                                                                                                                                     |
| -------------------------------------------------------- | ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code>   |                                                                                                                                                                                                                 |
| <code v-pre>integer</code>                               | <code v-pre>handle</code> | A no-op for a handle that names nothing and for one that is not paused. Resumes a voice its group paused, and the group's hold does not put it back; a voice starting into that group afterwards is still held. |

<a id="tecs.audio.Audio.setGain"></a>

### tecs.audio.Audio.setGain

<pre><code v-pre>function <a href="#tecs.audio.Audio.setGain">tecs.audio.Audio.setGain</a>(self: <a href="#tecs.audio.Audio">Audio</a>, handle: integer, gain: number)
</code></pre>

Sets a voice's gain, before its group and the master.

#### Parameters

| Type                                                     | Name                      | Description                                                                                                                                                                                                                                 |
| -------------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code>   |                                                                                                                                                                                                                                             |
| <code v-pre>integer</code>                               | <code v-pre>handle</code> | A no-op for one that names nothing.                                                                                                                                                                                                         |
| <code v-pre>number</code>                                | <code v-pre>gain</code>   | Linear amplitude, not decibels: 0 is silence, 1 is the clip as recorded, above 1 is louder and may clip. Takes effect on the next buffer the mixer fills rather than ramping, so a large jump on a sounding voice can be audible as a step. |

<a id="tecs.audio.Audio.setPitch"></a>

### tecs.audio.Audio.setPitch

<pre><code v-pre>function <a href="#tecs.audio.Audio.setPitch">tecs.audio.Audio.setPitch</a>(self: <a href="#tecs.audio.Audio">Audio</a>, handle: integer, ratio: number)
</code></pre>

Sets a voice's playback rate. 1 is unchanged.

#### Parameters

| Type                                                     | Name                      | Description                                                                                                                                                                                 |
| -------------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code>   |                                                                                                                                                                                             |
| <code v-pre>integer</code>                               | <code v-pre>handle</code> |                                                                                                                                                                                             |
| <code v-pre>number</code>                                | <code v-pre>ratio</code>  | A resampling rate, not an interval: 2 is an octave up and half as long, 0.5 an octave down and twice as long. It changes how long the clip takes, so a looped voice's period moves with it. |

<a id="tecs.audio.Audio.setLoop"></a>

### tecs.audio.Audio.setLoop

<pre><code v-pre>function <a href="#tecs.audio.Audio.setLoop">tecs.audio.Audio.setLoop</a>(self: <a href="#tecs.audio.Audio">Audio</a>, handle: integer, loop: boolean)
</code></pre>

Changes whether a voice repeats, part way through.

The mixer replaces the count it was started with, so clearing this on a
looping piece of music lets it play out to its end rather than cutting it,
and setting it on a one-shot keeps it going. It reaches a sounding voice
only: a stopped one takes its count from the next play.

#### Parameters

| Type                                                     | Name                      | Description                                                                                                                                                       |
| -------------------------------------------------------- | ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code>   |                                                                                                                                                                   |
| <code v-pre>integer</code>                               | <code v-pre>handle</code> |                                                                                                                                                                   |
| <code v-pre>boolean</code>                               | <code v-pre>loop</code>   | true repeats forever; there is no finite repeat count here. Setting it does not move the loop point, which is fixed by the `loopStart` the voice was played with. |

<a id="tecs.audio.Audio.looping"></a>

### tecs.audio.Audio.looping

<pre><code v-pre>function <a href="#tecs.audio.Audio.looping">tecs.audio.Audio.looping</a>(self: <a href="#tecs.audio.Audio">Audio</a>, handle: integer): boolean
</code></pre>

Whether a voice repeats when it reaches the end.

#### Parameters

| Type                                                     | Name                      | Description |
| -------------------------------------------------------- | ------------------------- | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code>   |             |
| <code v-pre>integer</code>                               | <code v-pre>handle</code> |             |

#### Returns

| Type                       | Description                                                                                        |
| -------------------------- | -------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | What this layer last told the mixer, not a reading from it. false for a handle that names nothing. |

<a id="tecs.audio.Audio.seek"></a>

### tecs.audio.Audio.seek

<pre><code v-pre>function <a href="#tecs.audio.Audio.seek">tecs.audio.Audio.seek</a>(self: <a href="#tecs.audio.Audio">Audio</a>, handle: integer, seconds: number): boolean
</code></pre>

Moves a voice's read position, in seconds from the start of its clip.

False when the handle names nothing, or when the input cannot seek: a
decoder is allowed not to be able to, and some can only reach a time
rather than an exact sample.

#### Parameters

| Type                                                     | Name                       | Description                                                                                                                                                                                  |
| -------------------------------------------------------- | -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code>    |                                                                                                                                                                                              |
| <code v-pre>integer</code>                               | <code v-pre>handle</code>  |                                                                                                                                                                                              |
| <code v-pre>number</code>                                | <code v-pre>seconds</code> | From the start of the clip, not from where the voice is now, and not from the loop point. Converted through the track's own rate, so it lands on a sample frame rather than on a mixer tick. |

#### Returns

| Type                       | Description                                                                                                                                                       |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | false when the handle names nothing or the input refused the seek. A true does not promise the exact sample: some decoders reach only the nearest point they can. |

<a id="tecs.audio.Audio.tell"></a>

### tecs.audio.Audio.tell

<pre><code v-pre>function <a href="#tecs.audio.Audio.tell">tecs.audio.Audio.tell</a>(self: <a href="#tecs.audio.Audio">Audio</a>, handle: integer): number
</code></pre>

Seconds into its clip a voice is reading, or nil.

Nil when the handle names nothing or the mixer cannot say. A paused voice
reports where it stopped, which with `seek` and `fadeIn` is what taking a
sound back where it left off is built from.

#### Parameters

| Type                                                     | Name                      | Description |
| -------------------------------------------------------- | ------------------------- | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code>   |             |
| <code v-pre>integer</code>                               | <code v-pre>handle</code> |             |

#### Returns

| Type                      | Description                                                                                                                                                                                                               |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>number</code> | Seconds from the start of the clip, so a looped voice's reading falls back at each repeat rather than accumulating. nil when the handle names nothing and nil when the mixer will not say, which are not told apart here. |

<a id="tecs.audio.Audio.setPosition"></a>

### tecs.audio.Audio.setPosition

<pre><code v-pre>function <a href="#tecs.audio.Audio.setPosition">tecs.audio.Audio.setPosition</a>(self: <a href="#tecs.audio.Audio">Audio</a>, handle: integer, x: number, y: number, z: number)
</code></pre>

Places a voice in space. See `Sound` for what the numbers mean.

Replaces a pan set by `setStereo` rather than combining with it.

Puts the voice in the mixer's 3D mode, which folds its input down to mono
before placing it, so a stereo clip loses its stereo image when positioned.

#### Parameters

| Type                                                     | Name                      | Description                                                                                                  |
| -------------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------ |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code>   |                                                                                                              |
| <code v-pre>integer</code>                               | <code v-pre>handle</code> |                                                                                                              |
| <code v-pre>number</code>                                | <code v-pre>x</code>      | Positive to the right of the listener, which is fixed at the origin and cannot be moved.                     |
| <code v-pre>number</code>                                | <code v-pre>y</code>      | Positive **above** the listener. World Y runs down, so world coordinates need their Y negated on the way in. |
| <code v-pre>number</code>                                | <code v-pre>z</code>      | Positive behind the listener.                                                                                |

<a id="tecs.audio.Audio.setStereo"></a>

### tecs.audio.Audio.setStereo

<pre><code v-pre>function <a href="#tecs.audio.Audio.setStereo">tecs.audio.Audio.setStereo</a>(self: <a href="#tecs.audio.Audio">Audio</a>, handle: integer, left: number, right: number)
</code></pre>

Pins a voice to the front pair of speakers at explicit gains.

A pan rather than a position, and usually what a game laid out on a plane
wants: there is no listener to subtract and no distance model to argue
with, only "how much of this comes out of each side". `left` at 0.8 and
`right` at 0.2 is a sound over to the left, whatever the speakers are.
Negative reads as silence and above 1 is louder, on the same terms as a
gain.

Replaces a position set by `setPosition` rather than combining with it:
the mixer holds one placement per track, and each call writes it.

#### Parameters

| Type                                                     | Name                      | Description                                                                                                                                                                                      |
| -------------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code>   |                                                                                                                                                                                                  |
| <code v-pre>integer</code>                               | <code v-pre>handle</code> |                                                                                                                                                                                                  |
| <code v-pre>number</code>                                | <code v-pre>left</code>   | Gain out of the left speaker, on the same linear scale as `setGain`. It multiplies with the voice, group and master gains rather than replacing any of them, so a pan of 1 and 1 is not silence. |
| <code v-pre>number</code>                                | <code v-pre>right</code>  | Gain out of the right speaker. There is no normalization between the two: 1 and 1 is the sound at full out of both sides, not half out of each.                                                  |

<a id="tecs.audio.Audio.clearSpatial"></a>

### tecs.audio.Audio.clearSpatial

<pre><code v-pre>function <a href="#tecs.audio.Audio.clearSpatial">tecs.audio.Audio.clearSpatial</a>(self: <a href="#tecs.audio.Audio">Audio</a>, handle: integer)
</code></pre>

Returns a voice to unpositioned mixing, out of either placement.

One call answers for both, because clearing either mode in the mixer clears
the other. A no-op for a handle that names nothing and for a voice that was
never placed.

#### Parameters

| Type                                                     | Name                      | Description |
| -------------------------------------------------------- | ------------------------- | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code>   |             |
| <code v-pre>integer</code>                               | <code v-pre>handle</code> |             |

<a id="tecs.audio.Audio.setMasterGain"></a>

### tecs.audio.Audio.setMasterGain

<pre><code v-pre>function <a href="#tecs.audio.Audio.setMasterGain">tecs.audio.Audio.setMasterGain</a>(self: <a href="#tecs.audio.Audio">Audio</a>, gain: number)
</code></pre>

Scales everything. One number on the mixer, so this costs the same whether
one voice is sounding or every voice is.

Setting this while muted changes the level a later unmute returns to and
nothing that is audible now, which is what a volume slider moved with the
sound off should do.

#### Parameters

| Type                                                     | Name                    | Description                                                                                                                            |
| -------------------------------------------------------- | ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code> |                                                                                                                                        |
| <code v-pre>number</code>                                | <code v-pre>gain</code> | Linear amplitude, not decibels, on the same scale as a voice's: 0 silences, 1 leaves the mix as mixed, above 1 is louder and may clip. |

<a id="tecs.audio.Audio.masterGain"></a>

### tecs.audio.Audio.masterGain

<pre><code v-pre>function <a href="#tecs.audio.Audio.masterGain">tecs.audio.Audio.masterGain</a>(self: <a href="#tecs.audio.Audio">Audio</a>): number
</code></pre>

The master gain, whether or not a mute is holding it down.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code> |             |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| <code v-pre>number</code> |             |

<a id="tecs.audio.Audio.setMuted"></a>

### tecs.audio.Audio.setMuted

<pre><code v-pre>function <a href="#tecs.audio.Audio.setMuted">tecs.audio.Audio.setMuted</a>(self: <a href="#tecs.audio.Audio">Audio</a>, muted: boolean)
</code></pre>

Silences everything without discarding the master gain.

The mixer's own number again, so it costs one call however many voices are
sounding. It does not fan out to the groups: `groupMuted` answers "is this
group silenced", and writing every group's bit here would overwrite the
answers an unmute has to put back. That is the same loss as setting a gain
to zero, which is what a mute exists instead of.

#### Parameters

| Type                                                     | Name                     | Description |
| -------------------------------------------------------- | ------------------------ | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code>  |             |
| <code v-pre>boolean</code>                               | <code v-pre>muted</code> |             |

<a id="tecs.audio.Audio.muted"></a>

### tecs.audio.Audio.muted

<pre><code v-pre>function <a href="#tecs.audio.Audio.muted">tecs.audio.Audio.muted</a>(self: <a href="#tecs.audio.Audio">Audio</a>): boolean
</code></pre>

Whether a master mute is holding the output down.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.audio.Audio.sounding"></a>

### tecs.audio.Audio.sounding

<pre><code v-pre>function <a href="#tecs.audio.Audio.sounding">tecs.audio.Audio.sounding</a>(self: <a href="#tecs.audio.Audio">Audio</a>): integer
</code></pre>

Voices sounding right now, including paused and fading ones.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description                                                                                                                        |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | Slots in use, so it drops only when `update` reaps a voice, not the instant one ends. `play` declines once it reaches `maxVoices`. |

<a id="tecs.audio.Audio.maxVoices"></a>

### tecs.audio.Audio.maxVoices

<pre><code v-pre>function <a href="#tecs.audio.Audio.maxVoices">tecs.audio.Audio.maxVoices</a>(self: <a href="#tecs.audio.Audio">Audio</a>): integer
</code></pre>

Voices that may sound at once, as `maxVoices` configured it.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description                                                                                                                            |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | The ceiling `play` refuses at, fixed for the instance's life. Not a hardware limit: it is what `newAudio` was given, defaulting to 32. |

<a id="tecs.audio.Audio.setGroupGain"></a>

### tecs.audio.Audio.setGroupGain

<pre><code v-pre>function <a href="#tecs.audio.Audio.setGroupGain">tecs.audio.Audio.setGroupGain</a>(self: <a href="#tecs.audio.Audio">Audio</a>, name: string, gain: number)
</code></pre>

Scales every voice in a group, and every voice that joins it later.

Composed here rather than through the mixer's per-tag gain, which writes
each tagged track's own gain and would overwrite what the voice asked for.

#### Parameters

| Type                                                     | Name                    | Description                                                                                                                                                                                     |
| -------------------------------------------------------- | ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code> |                                                                                                                                                                                                 |
| <code v-pre>string</code>                                | <code v-pre>name</code> | Needs no declaring, and setting a gain on a name nothing is in is how a game configures a group before anything joins it. Recorded against the name, so it outlives every voice that was in it. |
| <code v-pre>number</code>                                | <code v-pre>gain</code> | Linear amplitude, multiplied with each voice's own gain. There is no removing it: set 1 to return the group to unscaled.                                                                        |

<a id="tecs.audio.Audio.groupGain"></a>

### tecs.audio.Audio.groupGain

<pre><code v-pre>function <a href="#tecs.audio.Audio.groupGain">tecs.audio.Audio.groupGain</a>(self: <a href="#tecs.audio.Audio">Audio</a>, name: string): number
</code></pre>

A group's gain. 1 for one nothing has set.

The level, not what is audible: a muted group still answers with the gain
an unmute would put back.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code> |             |
| <code v-pre>string</code>                                | <code v-pre>name</code> |             |

#### Returns

| Type                      | Description                                                                             |
| ------------------------- | --------------------------------------------------------------------------------------- |
| <code v-pre>number</code> | 1 for a group nothing has set, which is indistinguishable from one explicitly set to 1. |

<a id="tecs.audio.Audio.setGroupMuted"></a>

### tecs.audio.Audio.setGroupMuted

<pre><code v-pre>function <a href="#tecs.audio.Audio.setGroupMuted">tecs.audio.Audio.setGroupMuted</a>(self: <a href="#tecs.audio.Audio">Audio</a>, name: string, muted: boolean)
</code></pre>

Silences a group without discarding the level it was set to.

Bookkeeping over the gains that already exist rather than anything the
mixer is told about: every voice in the group is composed at zero while
this holds, and an unmute puts each one back at its own gain times
`groupGain(name)`.

#### Parameters

| Type                                                     | Name                     | Description |
| -------------------------------------------------------- | ------------------------ | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code>  |             |
| <code v-pre>string</code>                                | <code v-pre>name</code>  |             |
| <code v-pre>boolean</code>                               | <code v-pre>muted</code> |             |

<a id="tecs.audio.Audio.groupMuted"></a>

### tecs.audio.Audio.groupMuted

<pre><code v-pre>function <a href="#tecs.audio.Audio.groupMuted">tecs.audio.Audio.groupMuted</a>(self: <a href="#tecs.audio.Audio">Audio</a>, name: string): boolean
</code></pre>

Whether a group is muted.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code> |             |
| <code v-pre>string</code>                                | <code v-pre>name</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.audio.Audio.pauseGroup"></a>

### tecs.audio.Audio.pauseGroup

<pre><code v-pre>function <a href="#tecs.audio.Audio.pauseGroup">tecs.audio.Audio.pauseGroup</a>(self: <a href="#tecs.audio.Audio">Audio</a>, name: string)
</code></pre>

Holds every voice in a group where it is, and every voice that joins it
later.

Recorded as well as sent, because the mixer's tag pause reaches what is
sounding when it is called: without the record, a sound started into a
paused group would be the one thing still heard.

#### Parameters

| Type                                                     | Name                    | Description                                                                                                                                                                       |
| -------------------------------------------------------- | ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code> |                                                                                                                                                                                   |
| <code v-pre>string</code>                                | <code v-pre>name</code> | Not holder counted: one `resumeGroup` undoes any number of these. A voice `resume`d out of a paused group stays going, and the group's hold still applies to whatever joins next. |

<a id="tecs.audio.Audio.resumeGroup"></a>

### tecs.audio.Audio.resumeGroup

<pre><code v-pre>function <a href="#tecs.audio.Audio.resumeGroup">tecs.audio.Audio.resumeGroup</a>(self: <a href="#tecs.audio.Audio">Audio</a>, name: string)
</code></pre>

Lets a paused group carry on, and lets later joiners start sounding.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code> |             |
| <code v-pre>string</code>                                | <code v-pre>name</code> |             |

<a id="tecs.audio.Audio.groupPaused"></a>

### tecs.audio.Audio.groupPaused

<pre><code v-pre>function <a href="#tecs.audio.Audio.groupPaused">tecs.audio.Audio.groupPaused</a>(self: <a href="#tecs.audio.Audio">Audio</a>, name: string): boolean
</code></pre>

Whether a group is holding its voices, including the ones not started yet.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code> |             |
| <code v-pre>string</code>                                | <code v-pre>name</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.audio.Audio.groups"></a>

### tecs.audio.Audio.groups

<pre><code v-pre>function <a href="#tecs.audio.Audio.groups">tecs.audio.Audio.groups</a>(self: <a href="#tecs.audio.Audio">Audio</a>): {string}
</code></pre>

Every group this instance knows of: one whose gain, mute or pause has been
set, and one a sounding voice is in. Sorted, so a caller reading it twice
reads it the same way.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code> |             |

#### Returns

| Type                        | Description                                                                                                                                                                       |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>{string}</code> | A fresh table each call, which the caller owns. A group whose only voice has ended and which nothing was set on drops out of it, so this is not a stable list of a game's groups. |

<a id="tecs.audio.Audio.stopGroup"></a>

### tecs.audio.Audio.stopGroup

<pre><code v-pre>function <a href="#tecs.audio.Audio.stopGroup">tecs.audio.Audio.stopGroup</a>(self: <a href="#tecs.audio.Audio">Audio</a>, name: string, fadeOut: number)
</code></pre>

Ends every voice in a group, over `fadeOut` seconds if that is given.

A faded stop leaves the voices sounding until they finish, so they are
reaped by `update` rather than here.

Stops the voices, not the group: a gain, mute or pause set on the name
survives, and anything that joins afterwards starts under them.

#### Parameters

| Type                                                     | Name                       | Description                                                                                                                                                         |
| -------------------------------------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code>    |                                                                                                                                                                     |
| <code v-pre>string</code>                                | <code v-pre>name</code>    |                                                                                                                                                                     |
| <code v-pre>number</code>                                | <code v-pre>fadeOut</code> | Seconds, a duration. Omitted or zero frees the slots within this call. A positive one unpauses the voices it fades, since a paused voice's fade would never finish. |

<a id="tecs.audio.Audio.setLimit"></a>

### tecs.audio.Audio.setLimit

<pre><code v-pre>function <a href="#tecs.audio.Audio.setLimit">tecs.audio.Audio.setLimit</a>(self: <a href="#tecs.audio.Audio">Audio</a>, key: string, limit: <a href="#tecs.audio.Audio.Limit">Audio.Limit</a>)
</code></pre>

Caps how many voices a key may hold and how often it may start one.

A key is not a group. A group says where a sound's gain comes from and what
a pause reaches; a key says how many of one sound the mix will carry. The
two are set independently on `play`, so "at most three footsteps at once,
all of them in the effects group" is the ordinary case and neither name has
to know about the other.

Passing nil removes the limit. Voices already sounding are left alone.

When a limit is reached the **new voice is dropped**: `play` returns zero
and nothing already sounding is stolen or cut short.

#### Parameters

| Type                                                                 | Name                     | Description                                                                                                                                                                                                                                                                                                                 |
| -------------------------------------------------------------------- | ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code>             | <code v-pre>self</code>  |                                                                                                                                                                                                                                                                                                                             |
| <code v-pre>string</code>                                            | <code v-pre>key</code>   |                                                                                                                                                                                                                                                                                                                             |
| <code v-pre><a href="#tecs.audio.Audio.Limit">Audio.Limit</a></code> | <code v-pre>limit</code> | nil removes the limit. Lowering `voices` below what the key already holds does not stop any of them; it only refuses the next until enough have ended. `cooldown` is measured from when a voice last started, against the time `update` has been told about, so a game that never calls `update` never advances a cooldown. |

<a id="tecs.audio.Audio.limit"></a>

### tecs.audio.Audio.limit

<pre><code v-pre>function <a href="#tecs.audio.Audio.limit">tecs.audio.Audio.limit</a>(self: <a href="#tecs.audio.Audio">Audio</a>, key: string): <a href="#tecs.audio.Audio.Limit">Audio.Limit</a>
</code></pre>

The limit a key carries, or nil.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code> |             |
| <code v-pre>string</code>                                | <code v-pre>key</code>  |             |

#### Returns

| Type                                                                 | Description                                                                            |
| -------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio.Limit">Audio.Limit</a></code> | The record that was set, not a copy, so writing through it changes the limit in force. |

<a id="tecs.audio.Audio.keyCount"></a>

### tecs.audio.Audio.keyCount

<pre><code v-pre>function <a href="#tecs.audio.Audio.keyCount">tecs.audio.Audio.keyCount</a>(self: <a href="#tecs.audio.Audio">Audio</a>, key: string): integer
</code></pre>

Voices a key is holding right now.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code> |             |
| <code v-pre>string</code>                                | <code v-pre>key</code>  |             |

#### Returns

| Type                       | Description                                                                                                                                                |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | Voices counted against the key, paused and fading ones included, since a slot is not given back until the voice ends. 0 for a key that has never held one. |

<a id="tecs.audio.Audio.keys"></a>

### tecs.audio.Audio.keys

<pre><code v-pre>function <a href="#tecs.audio.Audio.keys">tecs.audio.Audio.keys</a>(self: <a href="#tecs.audio.Audio">Audio</a>): {string}
</code></pre>

Every key with a limit set or a voice counted against it, sorted.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code> |             |

#### Returns

| Type                        | Description                                                                                                                                   |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>{string}</code> | A fresh table each call, which the caller owns. A key keeps its bucket once one exists, so a key that has played and stopped is still listed. |

<a id="tecs.audio.Audio.clips"></a>

### tecs.audio.Audio.clips

<pre><code v-pre>function <a href="#tecs.audio.Audio.clips">tecs.audio.Audio.clips</a>(self: <a href="#tecs.audio.Audio">Audio</a>): {<a href="#tecs.audio.Audio.Clip">Audio.Clip</a>}
</code></pre>

Every clip this instance has loaded, in the order they were asked for.

For introspection: it builds a list per call, so nothing on a frame's path
should read it.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code> |             |

#### Returns

| Type                                                                 | Description                                                                                                                      |
| -------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>{<a href="#tecs.audio.Audio.Clip">Audio.Clip</a>}</code> | A fresh list each call, holding the live clip records rather than copies, so their `status` moves under a caller that keeps one. |

<a id="tecs.audio.Audio.voices"></a>

### tecs.audio.Audio.voices

<pre><code v-pre>function <a href="#tecs.audio.Audio.voices">tecs.audio.Audio.voices</a>(self: <a href="#tecs.audio.Audio">Audio</a>): {<a href="#tecs.audio.Audio.VoiceInfo">Audio.VoiceInfo</a>}
</code></pre>

Every sounding voice, paused and fading ones included.

For introspection, on the same terms as `clips`. The handles it reports are
the ones `playing` and `stop` take, so what this shows can be acted on.

#### Parameters

| Type                                                     | Name                    | Description |
| -------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code> |             |

#### Returns

| Type                                                                           | Description                                                                                                                                                                 |
| ------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>{<a href="#tecs.audio.Audio.VoiceInfo">Audio.VoiceInfo</a>}</code> | A fresh list of fresh records each call, ordered by voice slot, which is not the order the voices started in. It is a snapshot: nothing in it follows the voice afterwards. |

<a id="tecs.audio.Audio.update"></a>

### tecs.audio.Audio.update

<pre><code v-pre>function <a href="#tecs.audio.Audio.update">tecs.audio.Audio.update</a>(self: <a href="#tecs.audio.Audio">Audio</a>, dt: number): integer
</code></pre>

Takes finished loads and reaps the voices the mixer has finished with.
Call once per frame, with the frame's step.

The step is what a cooldown is measured against. Nothing else here needs
time: a fade is the mixer's to run, and a voice is over when the mixer says
so rather than when a clock here says it should be.

Not a world system, and `install` deliberately does not add one: reaping has
to keep happening while the world is paused, so an application drives this
from the iteration instead.

#### Parameters

| Type                                                     | Name                    | Description                                                                                                                                                            |
| -------------------------------------------------------- | ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code> |                                                                                                                                                                        |
| <code v-pre>number</code>                                | <code v-pre>dt</code>   | Seconds since the last call, added to the clock cooldowns are measured against. Omitting it advances nothing, which is what a test stepping voices without time wants. |

#### Returns

| Type                       | Description                                                               |
| -------------------------- | ------------------------------------------------------------------------- |
| <code v-pre>integer</code> | Voices still sounding after the reap, the same number `sounding` answers. |

<a id="tecs.audio.Audio.of"></a>

### tecs.audio.Audio.of

<pre><code v-pre>function <a href="#tecs.audio.Audio.of">tecs.audio.Audio.of</a>(world: types.World): <a href="#tecs.audio.Audio">Audio</a>
</code></pre>

The audio installed into a world, or nil when none has been.

What lets something holding only the world reach the mixer, which is what
the debug tools have and what a game writing its own systems often has too.

#### Parameters

| Type                           | Name                     | Description |
| ------------------------------ | ------------------------ | ----------- |
| <code v-pre>types.World</code> | <code v-pre>world</code> |             |

#### Returns

| Type                                                     | Description                                                                                                                      |
| -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | nil before `install` and again after the instance is destroyed, since a destroyed one stops answering for every world it was in. |

<a id="tecs.audio.Audio.install"></a>

### tecs.audio.Audio.install

<pre><code v-pre>function <a href="#tecs.audio.Audio.install">tecs.audio.Audio.install</a>(self: <a href="#tecs.audio.Audio">Audio</a>, world: types.World)
</code></pre>

Adds the system that plays `Sound` components, and the snapshot handler
that carries the mixer.

`update` is not added here. Reaping voices is not world work: it has to
keep happening while the world is paused, and an application drives it from
the iteration instead.

#### Parameters

| Type                                                     | Name                     | Description                                                                                                                                                                                             |
| -------------------------------------------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | <code v-pre>self</code>  |                                                                                                                                                                                                         |
| <code v-pre>types.World</code>                           | <code v-pre>world</code> | Repoints this instance's pitch variance at the world's `tecs.audio` random stream, so installing into a second world moves the variance to that one's. One `Audio` per world is the shape this expects. |

<a id="tecs.audio.Clip"></a>

### tecs.audio.Clip

<pre><code v-pre>type <a href="#tecs.audio.Clip">tecs.audio.Clip</a> = <a href="#tecs.audio.Audio.Clip">Audio.Clip</a>
</code></pre>

A loaded clip, or one still loading.

<a id="tecs.audio.Config"></a>

### tecs.audio.Config

<pre><code v-pre>type <a href="#tecs.audio.Config">tecs.audio.Config</a> = <a href="#tecs.audio.Audio.Config">Audio.Config</a>
</code></pre>

What `newAudio` takes.

<a id="tecs.audio.Device"></a>

### tecs.audio.Device

<pre><code v-pre><a href="#tecs.audio.Device">tecs.audio.Device</a>: Device
</code></pre>

<a id="tecs.audio.Limit"></a>

### tecs.audio.Limit

<pre><code v-pre>type <a href="#tecs.audio.Limit">tecs.audio.Limit</a> = <a href="#tecs.audio.Audio.Limit">Audio.Limit</a>
</code></pre>

How many voices a key allows at once, and how soon it may repeat.

<a id="tecs.audio.LoadOptions"></a>

### tecs.audio.LoadOptions

<pre><code v-pre>type <a href="#tecs.audio.LoadOptions">tecs.audio.LoadOptions</a> = <a href="#tecs.audio.Audio.LoadOptions">Audio.LoadOptions</a>
</code></pre>

What `Audio:load` takes.

<a id="tecs.audio.Microphone"></a>

### tecs.audio.Microphone

<pre><code v-pre><a href="#tecs.audio.Microphone">tecs.audio.Microphone</a>: Microphone
</code></pre>

<a id="tecs.audio.MicrophoneConfig"></a>

### tecs.audio.MicrophoneConfig

<pre><code v-pre><a href="#tecs.audio.MicrophoneConfig">tecs.audio.MicrophoneConfig</a>: MicrophoneConfig
</code></pre>

<a id="tecs.audio.PlayOptions"></a>

### tecs.audio.PlayOptions

<pre><code v-pre>type <a href="#tecs.audio.PlayOptions">tecs.audio.PlayOptions</a> = <a href="#tecs.audio.Audio.PlayOptions">Audio.PlayOptions</a>
</code></pre>

What `Audio:play` takes.

<a id="tecs.audio.Sound"></a>

### tecs.audio.Sound

<pre><code v-pre><a href="#tecs.audio.Sound">tecs.audio.Sound</a>: Sound
</code></pre>

Play a clip by putting this on an entity.

<a id="tecs.audio.VoiceInfo"></a>

### tecs.audio.VoiceInfo

<pre><code v-pre>type <a href="#tecs.audio.VoiceInfo">tecs.audio.VoiceInfo</a> = <a href="#tecs.audio.Audio.VoiceInfo">Audio.VoiceInfo</a>
</code></pre>

What `Audio:voices` reports about one voice.

<a id="tecs.audio.newAudio"></a>

### tecs.audio.newAudio

<pre><code v-pre>function <a href="#tecs.audio.newAudio">tecs.audio.newAudio</a>(config: <a href="#tecs.audio.Audio.Config">Audio.Config</a>): <a href="#tecs.audio.Audio">Audio</a>
</code></pre>

Builds the mixer a game plays sound through, opening the platform's
default output.

Never raises for want of hardware. A machine with no sound card gets an
object whose calls all succeed and produce nothing, because a game that
cannot be played without an audio device is rarer than a test machine
without one.

#### Parameters

| Type                                                                   | Name                      | Description                                                                                                                                                         |
| ---------------------------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio.Config">Audio.Config</a></code> | <code v-pre>config</code> | Omitted takes the defaults. `maxVoices` outside 1 to 65535 raises, which is the one field here that does; every other one out of range is the platform's to refuse. |

#### Returns

| Type                                                     | Description                                                                                                                                                                                 |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Audio">Audio</a></code> | The mixer, which the caller has to `destroy`. Check `available` for whether an output actually opened; it is false on a machine with no sound, and every call still succeeds and is silent. |

<a id="tecs.audio.openMicrophone"></a>

### tecs.audio.openMicrophone

<pre><code v-pre>function <a href="#tecs.audio.openMicrophone">tecs.audio.openMicrophone</a>(config: <a href="#tecs.audio.MicrophoneConfig">MicrophoneConfig</a>): <a href="#tecs.audio.Microphone">Microphone</a>, string
</code></pre>

Opens a microphone as interleaved native-endian 32-bit float samples.

No callback is installed. SDL's audio thread fills its own stream and the
game pulls completed bytes from the main thread with `read`.

#### Parameters

| Type                                                                           | Name                      | Description                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------------------------------------------------------------ | ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.MicrophoneConfig">MicrophoneConfig</a></code> | <code v-pre>config</code> | May be nil, which opens the system's current default recording device at 48000 Hz in mono. `frequency` has to be a positive integer and `channels` an integer from 1 to 32; either outside that range is reported rather than raised. SDL converts the device's real format to what is asked for, so these are what `read` returns and not what the hardware runs at. |

#### Returns

| Type                                                               | Description                                                                                                                                                                                                                             |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.audio.Microphone">Microphone</a></code> | An open microphone, already recording: the stream is resumed before this returns, so samples accumulate from here whether or not anything reads them. Nil on failure, with the reason beside it, and nothing is left open in that case. |
| <code v-pre>string</code>                                          | The reason, when the first return is nil.                                                                                                                                                                                               |

<a id="tecs.audio.playbackDevices"></a>

### tecs.audio.playbackDevices

<pre><code v-pre>function <a href="#tecs.audio.playbackDevices">tecs.audio.playbackDevices</a>(): {<a href="#tecs.audio.Device">Device</a>}, string
</code></pre>

Physical playback devices attached now.

A snapshot, not a subscription: devices come and go while a game runs, so
an id held across a hotplug may name nothing.

#### Returns

| Type                                                         | Description                                                                                                                                                                    |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre>{<a href="#tecs.audio.Device">Device</a>}</code> | The devices, listed afresh each call and the caller's to keep. Empty rather than nil when the audio subsystem cannot start, so a caller that only iterates needs no nil check. |
| <code v-pre>string</code>                                    | SDL's reason, when something went wrong. Nil on success, including for a machine that genuinely has no playback device.                                                        |

<a id="tecs.audio.recordingDevices"></a>

### tecs.audio.recordingDevices

<pre><code v-pre>function <a href="#tecs.audio.recordingDevices">tecs.audio.recordingDevices</a>(): {<a href="#tecs.audio.Device">Device</a>}, string
</code></pre>

Physical recording devices attached now.

#### Returns

| Type                                                         | Description                                           |
| ------------------------------------------------------------ | ----------------------------------------------------- |
| <code v-pre>{<a href="#tecs.audio.Device">Device</a>}</code> | The devices, read as `playbackDevices` reads its own. |
| <code v-pre>string</code>                                    | SDL's reason, when something went wrong.              |
