---
description: "Plug Decoders and Effects into the mixer through versioned C vtables, as tecs-gm and tecs-ymfm do"
order: 51
---

# Audio extensions

A kind of Sound is a Nupp module and a native Decoder registered together.
The Nupp half parses at control rate and can sequence; the native half renders
at audio rate, in the callback, where it must not allocate, lock or block.

## The two in the monorepo

- **`tecs-gm`**: General MIDI from a SoundFont (`rustysynth`). `tecs.gm` loads
  SoundFonts and plays a `Synth` as a voice; `tecs.gm.midi` loads Standard MIDI
  Files as assets and plays them.
- **`tecs-ymfm`**: the 24 Yamaha FM chips `ymfm-oxide` emulates. `tecs.ymfm`
  plays a chip as a voice; `tecs.ymfm.music` plays VGM, VGZ and DRO logs.

Neither is compiled in by default. Build their native libraries with
`nupp task extensions`, and run their tests with `nupp task test-gm` and
`nupp task test-ymfm`. Each is its own Nupp project over the tecs sources, and
finds its library the way tecs finds its own services, or through
`TECS_GM_LIBRARY` and `TECS_YMFM_LIBRARY`.

Both drive their voices with Decoder events on the mixer's one clock, so a
note or a register write lines up with every clip by arithmetic.

## The Decoder ABI

`tecs-audio-abi` holds the types. A library exports a `DecoderVTable`:

| Entry                                    | Thread  | Purpose                                                                             |
| ---------------------------------------- | ------- | ----------------------------------------------------------------------------------- |
| `abi_version`, `struct_size`             | Load    | Compatibility: the version must match and the size be at least what the mixer reads |
| `describe(params, bytes, rate) → format` | Control | Channels, rate, length, and whether it takes events                                 |
| `open(params, bytes, rate) → instance`   | Control | One instance per Playback, allocating everything here                               |
| `render(instance, out, frames) → frames` | Audio   | Fewer frames than asked means the Playback has ended                                |
| `event(instance, frame, data)`           | Audio   | A timed event, delivered on its frame                                               |
| `seek(instance, seconds)`                | Control | Optional                                                                            |
| `close(instance)`                        | Control | Never called on the audio thread                                                    |

`mixer:registerDecoder(vtable)` returns an id; `mixer:playDecoded(id, params,
bytes, options)` starts a Playback; `mixer:event(handle, data, at)` sends it an
event. An event's top bits, from bit 40, name an operation every sequenced
Decoder is asked for (notes off, reset); below them is the Decoder's own
payload. The PCM Decoder is built in and speaks the same vtable.

## The Effect ABI

An `EffectVTable` has `describe` (latency and tail), `open` for a rate and
channel count, `process` in place on the audio thread, `param` (a target, on a
frame, ramped by the effect), `reset` and `close`. `mixer:registerEffect`
returns a kind that `tecs.audio.effects.custom` builds a spec for.

## Threads

The control side, the game thread today, only sends messages. The render side,
the device callback, the void output's supervisor, or the caller stepping a
memory output, applies them before it mixes, through a lock-free queue, and
hands back what it observed and what it finished with through another. Queries
read what the render side published. A Decoder or an Effect must not assume
which control thread calls it.
