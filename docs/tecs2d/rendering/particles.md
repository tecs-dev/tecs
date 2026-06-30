# Particle Emitter

The `ParticleEmitter` component creates particle effects using Love2D's particle system.

## Quick Start

```teal
local gfx = require("tecs2d.gfx")

-- Define emitter configuration
local fireConfig = gfx.ParticleEmitterConfig({
    texture = love.graphics.newImage("particle.png"),
    bufferSize = 500,
    emissionRate = 50,
    lifetime = {0.5, 1.5},
    speed = {50, 100},
    spread = math.pi / 4,
    colors = {
        {1, 0.8, 0.2, 1},    -- Start: yellow
        {1, 0.3, 0.1, 0.5},  -- Mid: orange
        {0.2, 0.1, 0.1, 0}   -- End: fade out
    },
    sizes = {1, 0.5, 0},
    rotation = {0, math.pi * 2},
    spin = {-math.pi, math.pi}
})

-- Spawn emitter at position
world:spawn(
    tecs.builtins.Transform(200, 300, 5),
    gfx.ParticleEmitter(fireConfig)
)
```

## Configuration

| Property                 | Type                 | Description                           |
| ------------------------ | -------------------- | ------------------------------------- |
| `texture`                | Texture              | Particle texture                      |
| `bufferSize`             | integer              | Maximum particle count                |
| `emissionRate`           | number               | Particles per second                  |
| `lifetime`               | `{min, max}`         | Particle lifetime range (seconds)     |
| `speed`                  | `{min, max}`         | Initial speed range (pixels/second)   |
| `spread`                 | number               | Emission angle spread (radians)       |
| `direction`              | number               | Base emission direction (radians)     |
| `colors`                 | array of `{r,g,b,a}` | Color gradient over lifetime          |
| `sizes`                  | `{number...}`        | Size gradient over lifetime (0-1)     |
| `rotation`               | `{min, max}`         | Initial rotation range (radians)      |
| `spin`                   | `{min, max}`         | Rotation speed range (radians/second) |
| `acceleration`           | `{x, y}`             | Linear acceleration (pixels/second²)  |
| `radialAcceleration`     | `{min, max}`         | Radial acceleration                   |
| `tangentialAcceleration` | `{min, max}`         | Tangential acceleration               |

## Emitter Control

```teal
local emitter = world:get(entityId, gfx.ParticleEmitter)
local ps = emitter.system

-- Start/stop emission
ps:start()
ps:stop()

-- Check if emitting
if ps:isActive() then ... end

-- Get current particle count
local count = ps:getCount()
```