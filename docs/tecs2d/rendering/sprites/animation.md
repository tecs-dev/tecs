# Animation

Sprites support frame-based animation using Aseprite frame tags. Each tag defines a named sequence of frames with timing
and playback direction.

## Frame Tags

Frame tags are named animation sequences defined in Aseprite (e.g., "idle", "walk", "attack").

### Defining Tags in Aseprite

1. Select frames in the timeline
2. Right-click and choose **New Tag**
3. Name the tag and set properties:
   - **Direction**: Forward, Reverse, or Ping-pong
   - **Repeat**: Number of times to loop (0 = infinite)

### Using Tags in Code

```lua
local gfx = require("tecs2d.gfx")

-- Create sprite with initial tag
world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Sprite.fromAseprite("player.png", "idle")
)

-- Change tag at runtime
local sprite = world:get(entityId, gfx.Sprite)
sprite:setTag("walk")
```

### Empty Tag

Passing an empty string (`""`) plays all frames in order:

```lua
gfx.Sprite.fromAseprite("player.png", "")  -- All frames
```

## Playback Directions

Tags support three playback directions:

| Direction   | Constant   | Behavior               |
| ----------- | ---------- | ---------------------- |
| Forward     | `0`        | Frames 1 → N, loop     |
| Reverse     | `1`        | Frames N → 1, loop     |
| Ping-pong   | `2`        | Frames 1 → N → 1, loop |

```lua
local sheet = gfx.SpriteSheet.fromFile("player.png")
local tag = sheet:getFrameTag("bounce")
if tag.direction == 2 then  -- Ping-pong
    print("This animation bounces back and forth")
end
```

## Playback Control

### Pause and Resume

```lua
local sprite = world:get(entityId, gfx.Sprite)

-- Pause at current frame
sprite:pause()

-- Resume from paused frame
sprite:resume()

-- Synchronized batch pause (all sprites pause at same visual frame)
local currentTime = love.timer.getTime()
for entity in entities do
    local spr = world:get(entity, gfx.Sprite)
    spr:pause(currentTime)
end
```

### Seek to Frame

```lua
-- Jump to first frame and pause
sprite:pauseAtStart()

-- Jump to last frame and pause
sprite:pauseAtEnd()

-- Jump to specific frame (0-indexed within current tag)
sprite:gotoFrame(3)
```

### Query Current Frame

```lua
-- Frame index within current tag (0-indexed)
local frame = sprite:getFrame()

-- Absolute frame number in sheet (1-indexed)
local absFrame = sprite:getAbsoluteFrame()

-- Current tag name
local tag = sprite:getTag()
```

## Speed Control

### At Creation

```lua
gfx.Sprite.fromAseprite("player.png", "walk", {
    speed = 0.5   -- Half speed (slow motion)
})

gfx.Sprite.fromAseprite("player.png", "run", {
    speed = 2.0   -- Double speed
})
```

### Speed Values

| Value   | Effect                   |
| ------- | ------------------------ |
| `1.0`   | Normal speed (default)   |
| `0.5`   | Half speed (slow motion) |
| `2.0`   | Double speed             |
| `0.0`   | Effectively paused       |

**Note:** Speed is set at sprite creation and cached in the instance. To change speed, create a new sprite or use
different speed values.

## Frame Timing

Each frame can have its own duration, set in Aseprite's timeline.

### Variable Frame Timing

In Aseprite:
1. Select a frame in the timeline
2. Right-click and choose **Frame Properties**
3. Set the duration in milliseconds

Tecs respects per-frame durations, enabling effects like:
- Hold poses at the end of an attack
- Quick anticipation frames before an action
- Slower impact frames for emphasis

### Accessing Timing

```lua
local sheet = gfx.SpriteSheet.fromFile("player.png")

-- Single frame duration
local frame = sheet:getFrame(1)
print(frame.duration)  -- Duration in seconds

-- Total tag duration
local tag = sheet:getFrameTag("attack")
print(tag.duration)  -- Total duration in seconds
```

## Staggered Start Times

To prevent synchronized animations looking unnatural, use `startTime`:

```lua
-- Spawn crowd with staggered animations
for i = 1, 20 do
    world:spawn(
        tecs.builtins.Transform(i * 30, 100),
        gfx.Sprite.fromAseprite("npc.png", "idle", {
            startTime = math.random() * 2.0  -- Random 0-2 second offset
        })
    )
end
```

## Animation Events

For callbacks when animation tags change, see [Events](./events).

## Common Patterns

### One-Shot Animation

Play an animation once and freeze on the last frame:

```lua
local sprite = world:get(entityId, gfx.Sprite)
sprite:playOnce("attack")
```

### Hold Last Frame

Play animation once, then switch to idle:

```lua
local sprite = world:get(entityId, gfx.Sprite)
sprite:playOnce("death", function(anim)
    anim:setTag("idle")
end)
```

`playOnce` uses the same CPU timing data as sprite playback, so the callback runs when the animation reaches its terminal
frame without needing GPU readback.

## Tiled Animated Tiles

Tiles with animation defined in Tiled are automatically spawned as Sprite entities with globally-synced animation.
Each animated tile includes a [TileSource](/tecs2d/tiled/tile-source) component that provides access to the original tile's
metadata (properties, class, tileset info).

See [TileSource Component](/tecs2d/tiled/tile-source) for querying and working with animated tiles from Tiled maps.
