---
description: "Generating Box2D physics shapes from Aseprite slices via SpriteCollision templates, sensors, and body types"
---

# Sprite Collisions

Tecs can automatically create physics collision shapes from Aseprite slices, allowing you to define collision boxes
visually and have them applied to physics bodies.

## Quick Start

```teal
local tecs = require("tecs")
local physics = require("tecs2d.physics")
local gfx = require("tecs2d.gfx")

local world = tecs.newWorld()

-- Initialize physics
love.physics.setMeter(64)
world:addPlugin(physics.new({ world = love.physics.newWorld(0, 800, true) }))

-- Register a collision template
gfx.SpriteCollision.addTemplate("PLAYER", {
    shape = "circle",
    restitution = 0.0,
    friction = 1.0,
})

-- Spawn sprite with collision from slice
world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Sprite.fromAseprite("player.png", "idle"),
    gfx.SpriteCollision.new({
        bodyType = "dynamic",
        fixedRotation = true,  -- default for SpriteCollision dynamics
        slices = {
            collision = "PLAYER"  -- Use "collision" slice with PLAYER template
        }
    })
)
```

## Defining Collision Slices in Aseprite

1. Open your sprite in Aseprite
2. Create a slice named "collision" (or any name you prefer)
3. Position and size the slice to define your collision box
4. Export with **Slices** enabled

::: tip Platformer Characters
For platformer characters, place the collision slice at the character's feet (lower half). This prevents the head from
catching on platforms.
:::

## SpriteCollision Component

```teal
gfx.SpriteCollision.new({
    bodyType = "dynamic",  -- or "static"
    fixedRotation = true,  -- dynamic only; defaults to true
    slices = {
        collision = "TEMPLATE_NAME",  -- Slice name → template name
        hitbox = "HITBOX",            -- Multiple slices supported
    }
})
```

### Configuration

| Property   | Type   | Description                                       |
| ---------- | ------ | ------------------------------------------------- |
| `bodyType` | string | `"dynamic"` or `"static"`                         |
| `fixedRotation` | boolean | Keeps auto-attached dynamic bodies upright. Defaults to `true`. |
| `slices`   | table  | Map of slice names to templates or inline configs |

### Body Types

| Type        | Description                    | Use For                       |
| ----------- | ------------------------------ | ----------------------------- |
| `"dynamic"` | Affected by forces and gravity | Players, enemies, projectiles |
| `"static"`  | Immovable                      | Platforms, walls, terrain     |

## Collision Templates

Templates define reusable physics configurations. Using templates enables serialization since template names are stored
instead of full configs.

### Registering Templates

```teal
-- Register at startup
gfx.SpriteCollision.addTemplate("PLAYER", {
    shape = "circle",
    restitution = 0.0,
    friction = 1.0,
})

gfx.SpriteCollision.addTemplate("BOUNCY", {
    shape = "circle",
    restitution = 0.8,
    friction = 0.3,
})

gfx.SpriteCollision.addTemplate("TRIGGER", {
    shape = "rectangle",
    sensor = true,  -- Detects overlaps without collision
})
```

### Template Properties

| Property      | Type    | Default       | Description                                     |
| ------------- | ------- | ------------- | ----------------------------------------------- |
| `shape`       | string  | `"rectangle"` | `"circle"` or `"rectangle"`                     |
| `sensor`      | boolean | `false`       | Detect overlaps without physical collision      |
| `restitution` | number  | `0`           | Bounciness (0 = none, 1 = full)                 |
| `friction`    | number  | `0.3`         | Surface friction                                |
| `categories`  | integer | `0xFFFF`      | Collision category bitmask                      |
| `mask`        | integer | `0xFFFF`      | Collision mask bitmask                          |
| `groupIndex`  | integer | `0`           | Group index (-N never collides with same group) |

### Retrieving Templates

```teal
local template = gfx.SpriteCollision.getTemplate("PLAYER")
```

## Inline Configuration

Instead of templates, define collision properties inline:

```teal
gfx.SpriteCollision.new({
    bodyType = "dynamic",
    slices = {
        collision = {
            shape = "circle",
            restitution = 0.0,
            friction = 1.0,
        }
    }
})
```

## Multiple Slices

Define multiple shapes from different slices:

```teal
gfx.SpriteCollision.addTemplate("BODY", {
    shape = "circle",
    restitution = 0.0,
})

gfx.SpriteCollision.addTemplate("HITBOX", {
    shape = "rectangle",
    sensor = true,  -- No physical collision
})

world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Sprite.fromAseprite("player.png", "idle"),
    gfx.SpriteCollision.new({
        bodyType = "dynamic",
        fixedRotation = true,
        slices = {
            collision = "BODY",   -- Physical collision
            hitbox = "HITBOX",    -- Damage detection sensor
        }
    })
)
```

## Shape Calculation

### Circle Shapes

For circles, the radius is calculated as `min(width, height) / 2` from the slice bounds.

### Rectangle Shapes

Rectangles use the full width and height of the slice bounds.

### Offset Calculation

Shape positions are offset from the sprite's geometric center:

```
offsetX = (slice.x + slice.width/2) - (spriteWidth/2)
offsetY = (slice.y + slice.height/2) - (spriteHeight/2)
```

A slice centered on the sprite has offset (0, 0). A slice at the sprite's feet has a positive Y offset.

## Sensors

Sensors detect overlaps without causing physical collision:

```teal
gfx.SpriteCollision.addTemplate("PICKUP_ZONE", {
    shape = "circle",
    sensor = true,
})
```

**Use cases:**
- Hitboxes for combat
- Trigger zones for events
- Pickup detection for items
- Ground detection for jumping

## Required Components

`SpriteCollision` expects these systems/components to be available:

| Component                                   | Purpose                |
| ------------------------------------------- | ---------------------- |
| `Sprite`                                    | Provides slice data    |
| `physics` plugin                            | Creates Box2D bodies   |

When physics is available, `SpriteCollision` auto-attaches a default `physics.Collider` plus either
`physics.RigidBody` or `physics.StaticBody` based on `bodyType`.

```teal
world:spawn(
    tecs.builtins.Transform(x, y),
    gfx.Sprite.fromAseprite("player.png", "idle"),
    gfx.SpriteCollision.new({
        bodyType = "dynamic",
        fixedRotation = true,  -- optional; default is true
        slices = { ... },
    })
)
```

## Collision Events

Handle collision events using the physics event system:

```teal
world:observe(playerId, physics.BeginContact, function(event: physics.BeginContact)
    print("Collided with:", event.other)
    -- Access slice name via shape user data
    local data = event.shape:getUserData()
    if data then print("Slice:", data.name) end
end)

world:observe(playerId, physics.EndContact, function(event)
    print("Stopped colliding with:", event.other)
end)
```

## Limitations

::: warning First Frame Only
Collision shapes are created from the slice position in the **first frame** of the current animation tag. If your
slice has per-frame keys, only the first frame is used. For animated collision shapes, you'll need to update shapes
manually.
:::

## Example: Platformer Character

```teal
gfx.SpriteCollision.addTemplate("PLAYER_BODY", {
    shape = "circle",
    restitution = 0.0,
    friction = 0.0,  -- Low friction for responsive movement
})

gfx.SpriteCollision.addTemplate("GROUND_SENSOR", {
    shape = "rectangle",
    sensor = true,
})

local playerId = world:spawn(
    tecs.builtins.Transform(100, 300),
    gfx.Sprite.fromAseprite("player.png", "idle"),
    gfx.SpriteCollision.new({
        bodyType = "dynamic",
        fixedRotation = true,
        slices = {
            collision = "PLAYER_BODY",
            feet = "GROUND_SENSOR",
        }
    })
)

-- Track ground contact
local onGround = false
world:observe(playerId, physics.BeginContact, function(event: physics.BeginContact)
    local data = event.shape:getUserData()
    if data and data.name == "feet" then
        onGround = true
    end
end)
world:observe(playerId, physics.EndContact, function(event: physics.EndContact)
    local data = event.shape:getUserData()
    if data and data.name == "feet" then
        onGround = false
    end
end)
```
