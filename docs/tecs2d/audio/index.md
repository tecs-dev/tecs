# Tecs Audio

Tecs Audio integrates [love.audio](https://love2d.org/wiki/love.audio) into the ECS.

- **Spatial audio**: Positional sounds integrated with the `Transform` component
- **Sound groups**: Independent volume control per category (sfx, music, ui)
- **Fading**: Smooth fade in/out on play, pause, stop
- **Effects**: Apply reverb, filters to groups
- **Voice limiting**: Limit concurrent plays of the same sound
- **Cooldowns**: Minimum time between repeated plays
- **Pitch variance**: Vary pitch to prevent repetitive sounds
- **Example**: See the <a href="https://github.com/tecs-dev/tecs/tree/main/examples/audio">audio example</a>

## Quick Start

```lua
local audio = require("tecs2d.audio")
local assets = require("tecs2d.assets")

-- Audio manager is auto-added by tecs2d
local audioManager = world.resources[audio]
local assetManager = world.resources[assets]

local explosionHandle = assetManager:loadAudio("explosion.wav", "static")

-- 2D sound
audioManager:play(explosionHandle, { group = "sfx" })

-- 3D positional sound
audioManager:playAt(explosionHandle, 100, 200, 0, { group = "sfx" })

-- Mark an entity as the audio listener (typically the player)
world:spawn(
    tecs.builtins.Transform(0, 0),
    audio.AudioListener()
)

-- Positioned sound (like a radio)
world:spawn(
    tecs.builtins.Transform(100, 200),
    audio.AudioSource({
        handle = engineHandle,
        looping = true,
        refDistance = 50,
        maxDistance = 500
    })
)
```

## Sound Groups

Control volume for categories of audio independently:

```lua
local audio = require("tecs2d.audio")
local audioManager = world.resources[audio]

-- Default groups: master, music, sfx, ui
audioManager:setGroupVolume("music", 0.5) -- volume is 0-1
audioManager:muteGroup("music", true)
audioManager:setGroupVolume("master", 0.5)  -- Affects all groups
```

## Voice Limiting

Limit how many instances of the same sound can play concurrently:

```lua
audio:setVoiceLimit("explosion", 3)  -- Max 3 concurrent
audio:playAt(handle, x, y, 0, { key = "explosion" })  -- Blocked if at limit
```

## Cooldowns

Minimum time between repeated plays:

```lua
audio:setCooldown("footstep", 0.05)  -- 50ms between plays
```

## Direct Play API

```lua
local audio = require("tecs2d.audio")
local audioManager = world.resources[audio]

audioManager:play(clickHandle, { group = "ui" })
audioManager:playAt(explosionHandle, x, y, z, { group = "sfx", pitchVariance = 0.1 })

-- With fade in and looping
local src = audioManager:play(musicHandle, { group = "music", fadeIn = 2.0, loop = true })
```

## Fading

Smooth volume transitions on play, pause, and stop:

```lua
-- Fade in when playing
audio:play(handle, { fadeIn = 1.0 })  -- 1 second fade in

-- Fade out when stopping
audio:stop(source, 0.5)      -- 0.5s fade out then stop
audio:stopGroup("sfx", 1.0)  -- Fade out entire group
audio:stopAll(2.0)           -- Fade out everything
```

## Pause/Resume

Pause and resume sounds with optional fading:

```lua
-- Pause/resume individual sources
audio:pause(source)
audio:resume(source)

-- Pause/resume entire groups (great for pause menus)
audio:pauseGroup("sfx", 0.3)   -- Fade out over 0.3s then pause
audio:resumeGroup("sfx", 0.3)  -- Resume and fade in
audio:isGroupPaused("sfx")     -- Check if paused
```

## Effects

Apply LÖVE audio effects to groups:

```lua
-- Add reverb to all sfx
audio:setGroupEffect("sfx", "reverb", {
    decaytime = 1.5,
    density = 0.7
})

-- Remove effect
audio:removeGroupEffect("sfx", "reverb")
```

Effects are automatically applied to all current and future sounds in the group. See
[LÖVE's effect documentation](https://love2d.org/wiki/EffectType) for available effect types.

## Configuring Audio

The audio plugin is auto-added by `tecs2d`. Configure the manager directly via the world resource:

```lua
local audio = require("tecs2d.audio")
local audioManager = world.resources[audio]

audioManager:setGroupVolume("music", 0.7)
audioManager:setGroupVolume("sfx", 1.0)
audioManager:setVoiceLimit("explosion", 5)
audioManager:setVoiceLimit("footstep", 3)
audioManager:setCooldown("footstep", 0.05)
```

## Static vs Stream

When loading audio with [Tecs Assets](/tecs2d/assets/):

- **`"static"`**: Loads into memory. Best for sound effects. Can play concurrently.
- **`"stream"`**: Streams from disk. Best for music. Lower memory, single instance only.

```lua
local jumpSound = assets:loadAudio("sounds/jump.wav", "static")
local bgMusic = assets:loadAudio("music/theme.ogg", "stream")
```
