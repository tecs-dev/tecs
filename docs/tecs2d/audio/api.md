# Audio API Reference

## Module: tecs2d.audio

```lua
local audio = require("tecs2d.audio")
```

The main module exports components, types, and the plugin function.

### Types

#### AudioManager

The central audio manager stored in `world.resources[audio]`.

#### PlayOptions

Options for the direct play API:

| Field           | Type    | Default | Description                                         |
| --------------- | ------- | ------- | --------------------------------------------------- |
| `group`         | string  | `"sfx"` | Sound group name                                    |
| `volume`        | number  | `1.0`   | Volume multiplier (0-1)                             |
| `pitch`         | number  | `1.0`   | Pitch multiplier (0-1)                              |
| `pitchVariance` | number  | `0`     | Random pitch offset (e.g. 0.1 gives pitch +/- 0.1)  |
| `key`           | string  | nil     | Required for voice limiting/cooldown to apply       |
| `fadeIn`        | number  | `0`     | Fade in duration in seconds                         |
| `loop`          | boolean | `false` | Loop the sound                                      |

---

## Components

See [Audio Components](./components) for detailed documentation on:

- **AudioListener** - Tag component marking an entity as the audio listener
- **AudioSource** - Component for attaching sounds to entities

---

## AudioManager Methods

### Group Control

#### setGroupVolume

```lua
audio:setGroupVolume(name, volume)
```

Set volume for a sound group. Volume is clamped to 0-1.

#### getGroupVolume

```lua
audio:getGroupVolume(name) --> number
```

Get current volume for a group. Returns 1.0 for unknown groups.

#### muteGroup

```lua
audio:muteGroup(name, muted)
```

Mute or unmute a sound group.

#### isGroupMuted

```lua
audio:isGroupMuted(name) --> boolean
```

Check if a group is muted.

### Voice Limiting

#### setVoiceLimit

```lua
audio:setVoiceLimit(key, maxVoices)
```

Set maximum concurrent voices for a sound key. Set to 0 for unlimited.

### Cooldowns

#### setCooldown

```lua
audio:setCooldown(key, seconds)
```

Set minimum time between plays for a sound key.

#### isOnCooldown

```lua
audio:isOnCooldown(key) --> boolean
```

Check if a sound key is currently on cooldown.

### Play API

#### play

```lua
audio:play(handle, options) --> Source or nil
```

Play a non-positional (2D) sound. Returns the playing source, or nil if blocked by cooldown/voice limit.

#### playAt

```lua
audio:playAt(handle, x, y, z, options) --> Source or nil
```

Play a positional (3D) sound at the specified coordinates.

### Control

#### stop

```lua
audio:stop(source, fadeDuration?)
```

Stop a specific source. Optional fade duration in seconds.

#### stopGroup

```lua
audio:stopGroup(name, fadeDuration?)
```

Stop all sounds in a group. Optional fade duration.

#### stopAll

```lua
audio:stopAll(fadeDuration?)
```

Stop all sounds. Optional fade duration.

#### pause

```lua
audio:pause(source, fadeDuration?)
```

Pause a specific source. Optional fade duration.

#### resume

```lua
audio:resume(source, fadeDuration?)
```

Resume a paused source. Optional fade duration.

#### pauseGroup

```lua
audio:pauseGroup(name, fadeDuration?)
```

Pause all sounds in a group. Optional fade duration.

#### resumeGroup

```lua
audio:resumeGroup(name, fadeDuration?)
```

Resume all paused sounds in a group. Optional fade duration.

#### isGroupPaused

```lua
audio:isGroupPaused(name) --> boolean
```

Check if a group is paused.

### Effects

#### setGroupEffect

```lua
audio:setGroupEffect(groupName, effectType, settings)
```

Apply a LÖVE audio effect to all sounds in a group. The effect applies to both currently playing sources and any new
sources added to the group.

**Parameters:**
- `groupName` - The sound group name (e.g., "sfx", "music")
- `effectType` - LÖVE effect type: "reverb", "chorus", "distortion", "echo", "flanger", "compressor",
  "equalizer", "ringmodulator"
- `settings` - Table of effect-specific parameters

**Example:**
```lua
-- Add reverb to all SFX
audio:setGroupEffect("sfx", "reverb", {
    decaytime = 4.0,
    density = 1.0,
    diffusion = 1.0,
    gain = 0.6,
})

-- Add chorus to music
audio:setGroupEffect("music", "chorus", {
    waveform = "sine",
    rate = 1.0,
    depth = 0.5,
})
```

See [LÖVE Audio Effects](https://love2d.org/wiki/EffectType) for available parameters per effect type.

#### removeGroupEffect

```lua
audio:removeGroupEffect(groupName, effectType)
```

Remove an effect from a group. All sources in the group will stop using the effect.

---

## Plugin

The audio plugin is automatically added by `tecs2d`. It registers the `AudioManager` as a
world resource accessible via `world.resources[audio]`.

---

## Default Sound Groups

Tecs provides the following builtin sound groups:

| Group    | Default Volume | Typical Use                        |
| -------- | -------------- | ---------------------------------- |
| `master` | 1.0            | Parent volume affecting all groups |
| `music`  | 0.8            | Background music                   |
| `sfx`    | 1.0            | Sound effects                      |
| `ui`     | 1.0            | UI feedback sounds                 |

Custom groups are created automatically when you set their volume.
