# Slices and Pivots

Aseprite slices define regions within sprite frames for pivot points, collision boxes, and custom metadata. Slices can
have different values per frame for animation-aware positioning.

## Creating Slices in Aseprite

1. Open your sprite in Aseprite
2. Go to **Frame > Slices** or press `Ctrl+Shift+9`
3. Create a new slice with the slice tool
4. Name the slice (e.g., "pivot", "hitbox", "feet")
5. Optionally set pivot and center points
6. Export with **Slices** enabled in JSON settings

## Pivot Points

Pivot points control the origin for positioning and rotation.

### Default Centering

By default, sprites are centered on the transform position:

```teal
gfx.Sprite.fromAseprite("player.png", "idle", {
    centered = true  -- Default: sprite center at transform
})
```

### Slice-Based Pivots

Use an Aseprite slice as the pivot point:

```teal
gfx.Sprite.fromAseprite("player.png", "attack", {
    pivotSlice = "weapon_origin"  -- Use this slice's pivot
})
```

In Aseprite, set the slice's pivot point:
1. Select the slice
2. In the slice properties, enable **Pivot**
3. Position the pivot within the slice bounds

### Top-Left Origin

For classic sprite positioning (origin at top-left):

```teal
gfx.Sprite.fromAseprite("player.png", "idle", {
    centered = false  -- Origin at (0, 0)
})
```

### Fallback Behavior

When `pivotSlice` is specified but the slice or pivot isn't found:

| `centered`   | Fallback                     |
| ------------ | ---------------------------- |
| `true`       | Use sprite center (0.5, 0.5) |
| `false`      | Use top-left (0, 0)          |

## Per-Frame Pivots

Slices can have different pivot points per frame, useful for:

- Weapon rotation points that shift during swings
- Feet positions for ground-aligned characters
- Hand positions for held items

### Defining Per-Frame Pivots in Aseprite

1. Create a slice
2. Navigate to different frames
3. Adjust the slice position/pivot for each frame
4. Aseprite stores "keys" for frames where the slice changes

The animation system automatically uses the correct pivot for each frame.

### Example: Rotating Sword

```teal
-- In Aseprite:
-- - Create a "sword_pivot" slice
-- - On frame 1: pivot at sword handle
-- - On frame 5: pivot shifts as sword swings

world:spawn(
    tecs.builtins.Transform(100, 100, 5, 0, { rotation = 0 }),
    gfx.Sprite.fromAseprite("sword.png", "swing", {
        pivotSlice = "sword_pivot"
    })
)

-- Rotation will occur around the current frame's pivot
```

## Accessing Slice Data

```teal
local sheet = gfx.SpriteSheet.fromFile("player.png")

local slice = sheet:getSlice("hitbox")
if slice then
    -- User data from Aseprite
    print(slice.data)

    -- Iterate slice keys (per-frame data)
    for i, key in ipairs(slice.keys) do
        print("Frame:", key.frame)
        print("Position:", key.x, key.y)
        print("Size:", key.w, key.h)

        if key.hasPivot then
            print("Pivot:", key.pivotX, key.pivotY)
        end

        if key.hasCenter then
            print("Center:", key.centerX, key.centerY)
        end
    end
end
```

## Slice Key Properties

| Property             | Type    | Description                      |
| -------------------- | ------- | -------------------------------- |
| `frame`              | integer | Frame number this key applies to |
| `x`, `y`             | number  | Slice position within frame      |
| `w`, `h`             | number  | Slice dimensions                 |
| `hasCenter`          | boolean | Whether center point is defined  |
| `centerX`, `centerY` | number  | Center point coordinates         |
| `hasPivot`           | boolean | Whether pivot point is defined   |
| `pivotX`, `pivotY`   | number  | Pivot point coordinates          |

## Common Slice Patterns

### Feet Position

Ground-aligned characters with feet at the bottom:

```teal
-- In Aseprite: Create "feet" slice at character's feet with pivot

world:spawn(
    tecs.builtins.Transform(100, groundY),  -- Transform at ground level
    gfx.Sprite.fromAseprite("player.png", "idle", {
        pivotSlice = "feet"  -- Feet touch the ground
    })
)
```

### Weapon Attach Point

Attach point for weapons or effects:

```teal
-- In Aseprite: Create "hand" slice at character's hand

-- Get hand position for spawning weapon
local sprite = world:get(playerId, gfx.Sprite)
local frame = sprite:getAbsoluteFrame()
local sheet = gfx.SpriteSheet.fromFile("player.png")
local slice = sheet:getSlice("hand")

-- Find key for current frame
for _, key in ipairs(slice.keys) do
    if key.frame == frame then
        -- Spawn weapon at hand position
        local handX = playerX + key.x
        local handY = playerY + key.y
        break
    end
end
```

### Hit/Hurt Boxes

Collision regions for combat:

```teal
-- In Aseprite: Create "hitbox" and "hurtbox" slices

-- Read hitbox for current frame
local sprite = world:get(entityId, gfx.Sprite)
local hitbox = getSliceForFrame(sheet, "hitbox", sprite:getAbsoluteFrame())
```

## Overriding with Pivot Component

The `Pivot` component overrides slice-based pivots:

```teal
-- This uses the Pivot component, not pivotSlice
world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Sprite.fromAseprite("player.png", "idle", {
        pivotSlice = "feet"  -- Ignored when Pivot component exists
    }),
    gfx.Pivot(0.5, 1.0)   -- Bottom-center pivot
)
```

Priority order:
1. `Pivot` component (highest)
2. `pivotSlice` option
3. `centered` option (default: true → center, false → top-left)
