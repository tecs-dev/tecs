---
description: "AudioListener and AudioSource components for spatial and relative positional sound with attenuation and pitch variance"
---

# Audio Components

Tecs Audio provides two ECS components for attaching audio to entities: `AudioListener` and `AudioSource`.

## AudioListener

A tag component marking an entity as the audio listener. The listener's position determines how spatial audio is
perceived (volume falloff, panning). The audio system updates `love.audio.setPosition()` each frame based on the
listener entity's Transform. All spatial audio attenuation is calculated relative to this position.

```teal
local audio = require("tecs2d.audio")

-- Mark the player as the audio listener
world:spawn(
    tecs.builtins.Transform(0, 0),
    Player(),
    audio.AudioListener()
)
```

### Requirements

- **Only one listener**: Only the first entity with `AudioListener` is used each frame
- **Requires Transform**: The entity must have a `Transform` component for positioning

## AudioSource

A component for continuous or looping sounds attached to entities. Use this for sounds that should be emitted in world
space (e.g., footsteps, engines, ambient emitters).

```teal
local audio = require("tecs2d.audio")
local assets = require("tecs2d.assets")

local engineHandle = assets.loadAudio("sounds/engine.wav", "static")

-- Positional sound (follows entity position)
world:spawn(
    tecs.builtins.Transform(100, 200),
    audio.AudioSource({
        handle = engineHandle,
        looping = true,
        refDistance = 50,
        maxDistance = 500
    })
)

-- Relative sound (always follows the listener, no attenuation)
world:spawn(
    audio.AudioSource({
        handle = musicHandle,
        group = "music",
        looping = true,
        relative = true
    })
)
```

### Configuration

| Field           | Type    | Default  | Description                                                |
| --------------- | ------- | -------- | ---------------------------------------------------------- |
| `handle`        | Handle  | required | Audio asset handle from `assets:loadAudio()`               |
| `group`         | string  | `"sfx"`  | Sound group for volume control                             |
| `volume`        | number  | `1.0`    | Volume multiplier (0-1)                                    |
| `pitch`         | number  | `1.0`    | Pitch multiplier (0-1)                                     |
| `pitchVariance` | number  | `0`      | Random pitch offset (e.g. 0.1 gives pitch +/- 0.1)         |
| `looping`       | boolean | `false`  | Whether the sound loops                                    |
| `playing`       | boolean | `true`   | Whether to start playing immediately                       |
| `relative`      | boolean | `false`  | If true, sound follows the listener with no attenuation    |
| `refDistance`   | number  | `100`    | Distance in pixels where volume begins to fade             |
| `maxDistance`   | number  | `1000`   | Distance in pixels where the sound becomes silent          |

### Positional vs Relative

**Positional (default)**: The sound exists in world space. Volume and panning change based on the listener's
distance and orientation, like hearing a car drive past you.

```teal
-- Engine sound follows a vehicle
world:spawn(
    tecs.builtins.Transform(vehicleX, vehicleY),
    audio.AudioSource({
        handle = engineHandle,
        looping = true
    })
)
```

**Relative**: The sound is attached to the listener, like wearing headphones. It plays at full volume regardless
of where the listener is in the world. Use for background music, UI sounds, or ambient audio.

```teal
-- Background music (plays "in the listener's ears")
world:spawn(
    audio.AudioSource({
        handle = musicHandle,
        group = "music",
        looping = true,
        relative = true
    })
)
```

### Attenuation Settings

Control how sound volume falls off with distance. Distances are measured in pixels, matching your Transform
coordinates.

```teal
audio.AudioSource({
    handle = soundHandle,
    refDistance = 50,   -- Full volume within 50px
    maxDistance = 500   -- Silent beyond 500px
})
```

The attenuation follows Love2D's default model (inverse distance clamped).

### Controlling Playback

Modify the component to control playback:

```teal
-- Get the component mutably so dirty-gated audio systems observe the writes.
local source = world:getMut(entityId, audio.AudioSource)

-- Stop playback
source.playing = false

-- Start playback
source.playing = true

-- Change volume
source.volume = 0.5

-- Change pitch (takes effect on the next audio-system update)
source.pitch = 1.2
```

### Pitch Variance

Add random pitch variance to prevent repetitive sounds:

```teal
audio.AudioSource({
    handle = footstepHandle,
    pitch = 1.0,
    pitchVariance = 0.1  -- Pitch will vary +/- 0.1
})
```

Pitch variance is rolled when playback is triggered or retriggered and held for that playback. Love looping does not
re-roll the variance at each loop boundary.
