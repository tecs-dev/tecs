---
description: "Play sound through a mixing console: Tracks, Buses, effects, one clock, Timelines and Sounds as assets"
order: 50
---

# Audio

Tecs audio is arranged as a mixing console, because that is how a person, or
an agent, building a game thinks about sound.

| Term     | On a console                     | In tecs                                                                                                         |
| -------- | -------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Mixer    | The console                      | `tecs.audio.Audio`, one per world, installed with `tecs.audio.install`                                          |
| Track    | A channel strip                  | `mixer:track()`, or the `Track` component on an entity                                                          |
| Playback | The deck plugged into a strip    | A voice: one Sound rendered into one Track, named by its handle                                                 |
| Sound    | The tape, or the score           | `tecs.audio.Sound`, which an extension makes: a file through `tecs.pcm`, music through `tecs.gm` or `tecs.ymfm` |
| Decoder  | The playback head                | Native, one instance per Playback, from an extension; the core has none                                         |
| Bus      | A subgroup, a return, the master | `mixer:bus(name)`; groups are Buses                                                                             |
| Output   | The main out                     | A device, void (ticks with no device) or memory (renders on demand)                                             |
| Clock    | The word clock                   | The frames the Output consumed, which `mixer:now()` reads                                                       |
| Timeline | The sequencer                    | `mixer:timeline()`: beats with a tempo and a pause, mapped onto the Clock                                       |

## The signal flow

A voice renders into its Track. A Track runs its insert effects, then its
fader (gain, mute, solo) and its pan or position, adds itself into the Bus it
routes to, and copies itself after its fader into the return Buses it sends
to. Buses sum into their parents, deepest first, down to Master, whose fader
comes before its inserts so its limiter, there by default, has the last word.

```nupp
local audio <const> = require("tecs.audio")
local effects <const> = require("tecs.audio.effects")

local mixer <const> = audio.install(world)
mixer:bus("sfx")
mixer:bus("music", {gain = 0.8})
mixer:bus("room", {effects = {effects.reverb({size = 0.7})}})

local pcm <const> = require("tecs.pcm")
local footsteps <const> = mixer:track({bus = "sfx", sends = {room = 0.3}, polyphony = 4})
local step <const> = assert(app.assets:request(pcm.PCM, "sounds/step.wav"))
footsteps:play(step, {pitch = 1.05})
```

Faders and sends glide to a new level over a few milliseconds, so a change
never clicks. A paused Bus holds every voice routed through it. Every strip is
metered as it mixes: `mixer:meters()` reads peak, RMS and clipped samples
since the last read.

A Track holds `polyphony` voices, eight unless told otherwise. Past it the
lowest `priority`, the oldest among equals, is stolen; past `maxVoices` a
voice of strictly lower priority is, or the start is refused. Steals and
refusals are counted in `mixer:stats()` and logged in `mixer:events()`.

`play` with a `group` sounds on that group's Bus's default Track, so code
written against groups keeps working: `setGroupGain`, `pauseGroup` and the
rest act on the Bus.

## One clock

Every `at` is in seconds on the one Clock, `mixer:now()`: the frames the
mixer has rendered. A command carrying one lands on exactly that output
frame. It keeps running through a device reopen, and on a void output, which
keeps time at the wall clock's pace with no device at all. A memory output
moves only when `mixer:step(seconds)` renders it, so every run of the same
calls produces the same samples.

A voice exists from the frame its start is due on; anything sent to it before
then lands on that frame, after the start, and a stop before it cancels it.
Every start ends in exactly one finish, the refused ones included.

## Timelines

A Timeline decides when. Its time is in beats, at a tempo, and it can pause;
its events go out a lookahead ahead with the clock time their beat maps to.

```nupp
local song <const> = mixer:timeline({tempo = 120})
song:play(theme, {track = musicTrack, at = song:nextBar()})
song:pause()  -- the song stops advancing, the Clock does not
```

`mixer:defaultTimeline()` is the one whose time is the Clock. A sequencer, a
MIDI file player for instance, fills the schedule the same way: see
`tecs.audio.sequencer`, whose `Player` can follow a Timeline's pause and
tempo.

## In the world

The `Track` component, which is the `Sound` component under its console name,
puts a sound on an entity. With a `Listener` component on the entity the game
hears from, each spatial row is placed from its `Transform2D` or
`Transform3D` relative to the listener, on an emitter Track of its own. A
`ReverbZone` sends every emitter inside it to a return Bus, more strongly near
its centre.

## Extensions

Every Decoder is an extension: a top-level package of the tecs monorepo that a
game opts into. `tecs-pcm` plays encoded audio files, `tecs-gm` General MIDI
and `tecs-ymfm` the emulated Yamaha FM chips, and a game that needs none of
them carries no codec. See [Audio extensions](extensions.md) for how they plug
in, and how to write one.

## For agents

The debug server reports the console as data and records what was played. See
[Audio for agents](agents.md).
