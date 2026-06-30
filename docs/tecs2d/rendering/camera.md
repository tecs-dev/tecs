# Camera

The camera controls how the game world is presented on screen. It handles virtual resolution, viewport
management, smooth movement, and coordinate conversion. Tecs supports multiple cameras for effects like
minimaps, split-screen, and render-to-texture.

## Configuration

Camera settings are provided via the `render` table in `tecs2d.run`. These configure the **primary camera**,
which renders fullscreen by default.

```teal
local tecs2d = require("tecs2d")

-- Retro pixel art game (integer-scaled, no pixel crawl)
love.run = tecs2d.run({
    fps = 60,
    game = gamePlugin,
    render = {
        virtualHeight = 270,
        pixelMode = true,
    },
})

-- HD game with virtual resolution for consistent world view
love.run = tecs2d.run({
    fps = 60,
    game = gamePlugin,
    render = {
        virtualHeight = 270,         -- always show 270 world units of height
        -- virtualWidth computed from aspect ratio automatically
    },
})
```

All camera settings are optional. Additional options include:

```teal
render = {
    cameraPosition = {0, 0},   -- Initial position (default: {0, 0})
    zoom = 1.0,                -- Initial zoom level (default: 1.0)
    lerpingEnabled = true,     -- Enable smooth camera movement (default: true)
    lerpSpeed = 8.0,           -- Lerp speed factor (default: 8.0)
    clampToBounds = false,     -- Clamp camera to world bounds (default: false)
    worldBounds = {0, 0, 1000, 1000},  -- {minX, minY, maxX, maxY}
}
```

## Accessing the Camera

Access the primary camera through the pipeline resource:

```teal
local gfx = require("tecs2d.gfx")

local pipeline = world.resources[gfx.PIPELINE]
local cam = pipeline:getCamera()
```

All camera methods are called on the camera object directly, not on the pipeline.

## Pixel Modes

The `pixelMode` boolean controls how rendering is scaled to the screen:

| Value   | Description                                                                                           |
| ------- | ----------------------------------------------------------------------------------------------------- |
| `false` | Smooth full-resolution rendering (default)                                                            |
| `true`  | Integer-scaled low-res canvas with nearest-neighbor filtering. Eliminates pixel crawl via blit-shift. |

```teal
-- Change pixel mode at runtime
pipeline:setPixelMode(true)   -- enable retro
pipeline:setPixelMode(false)  -- disable retro

-- Get current pixel mode
local isRetro = pipeline:getPixelMode()
```

### How retro mode works (blit-shift)

Retro mode uses integer scaling with a blit-shift technique that completely eliminates pixel crawl:

1. Camera snaps to the virtual pixel grid: `snappedPos = floor(camPos / worldPixelSize) * worldPixelSize`
2. The render pass uses **zero sub-pixel offset**, so every pixel is perfect at virtual resolution
3. The sub-pixel remainder is applied as an integer screen-pixel offset when blitting the final canvas
4. Every virtual pixel maps to exactly `intScale x intScale` screen pixels
5. A scissor clips to a fixed viewport so letterbox bars remain stable

Because the sub-pixel shift happens at the screen-pixel level (after integer scaling), virtual pixels
never straddle screen pixel boundaries and there is no crawl or shimmer.

When `pixelMode` is `false`, rendering is smooth at full resolution with no snap — the camera scrolls
at fractional positions and bilinear filtering handles any sub-pixel motion.

#### Retro resolution

The integer scale factor and virtual dimensions are computed as follows:

- `intScale = floor(screenHeight / virtualHeight)` (e.g., `floor(720 / 270) = 2`)
- `virtualWidth = floor(screenWidth / intScale)` fills the screen width (e.g., `floor(1280 / 2) = 640`)
- Only small vertical letterbox bars appear from the integer constraint
- The camera FOV adapts to the screen aspect ratio: wider screens see more of the world

### Coordinate conversion

`cam:toWorld()` and `cam:toScreen()` work correctly regardless of `pixelMode`. After rendering, the
pipeline updates the camera's view-projection matrix to account for the render-to-screen mapping, so
mouse coordinates always convert to the correct world positions.

## Camera Controls

### Position

The camera uses **center-based positioning**: the position represents the center of the camera's view.

```teal
local cam = pipeline:getCamera()

-- Set position immediately (ignores lerping)
cam:setPosition(100, 200)

-- Move to position with smooth lerping
cam:move(100, 200)

-- Nudge by delta amount (useful for WASD input)
cam:nudge(dx, dy)

-- Get current position
local x, y = cam:getPosition()
```

### Zoom

Zoom controls how much of the world is visible. Values greater than 1 zoom in (less visible area); values less
than 1 zoom out (more visible area).

```teal
-- Set zoom level (1 = normal, 2 = 2x zoom in, 0.5 = 2x zoom out)
cam:setZoom(0.5)

-- Get current zoom
local zoom = cam:getZoom()
```

### Smooth Movement

When lerping is enabled, calls to `move()` and `nudge()` smoothly interpolate to the target position.

```teal
-- Enable/disable smooth movement
cam:setLerpingEnabled(true)
cam:setLerpingEnabled(false)

-- Adjust lerp speed (higher = snappier, lower = smoother)
cam:setLerpSpeed(12.0)  -- Snappy response
cam:setLerpSpeed(4.0)   -- Very smooth but slower
```

**Input-driven camera movement:**

```teal
local input = require("tecs2d.input")
local cam = pipeline:getCamera()
local speed = 200

world:addSystem({
    name = "CameraControls",
    phase = tecs.phases.FixedUpdate,
    run = function(dt)
        if input.isKeyDown("w") then cam:nudge(0, -speed * dt) end
        if input.isKeyDown("a") then cam:nudge(-speed * dt, 0) end
        if input.isKeyDown("s") then cam:nudge(0, speed * dt) end
        if input.isKeyDown("d") then cam:nudge(speed * dt, 0) end
    end
})
```

### World Bounds

Clamp the camera so it cannot scroll past the edges of the world:

```teal
cam:setWorldBounds(0, 0, 3200, 2400)
cam:setClamp(true)
```

### Rotation

```teal
-- Set rotation in radians (uses lerp if enabled)
cam:setRotation(math.pi / 4)

-- Get current rotation
local angle = cam:getRotation()
```

### Screenshake

The camera includes a trauma-based screenshake system. Trauma is a 0-1 value that decays over time; shake
intensity is proportional to trauma squared (`trauma^2`). Perlin noise produces smooth, continuous rumble for
both translational and rotational shake. The shake offsets are applied to the rendered position without
affecting the camera's logical position.

```teal
local cam = pipeline:getCamera()

-- Trigger screenshake (e.g., on hit or explosion)
cam:shake(0.5)       -- Add 0.5 trauma (stacks with existing)
cam:shake(1.0)       -- Full-intensity shake

-- Configure shake parameters
cam:setShakeIntensity(12)    -- Max pixel offset at full trauma (default: 8)
cam:setShakeRotation(0.05)   -- Max rotation in radians at full trauma (default: 0.03)
cam:setTraumaDecay(2.0)      -- Decay rate in trauma/second (default: 1.5)

-- Query current state
local trauma = cam:getTrauma()
```

Screenshake works independently of lerping: it applies to both lerped and non-lerped cameras. The visible
bounds are padded by the max shake intensity (a constant), not the current trauma, to prevent entities at
screen edges from popping in and out as the shake decays.

## Coordinate Conversion

Convert between world and screen coordinates:

```teal
-- Convert screen coordinates to world coordinates (e.g., for mouse input)
local worldX, worldY = cam:toWorld(love.mouse.getPosition())

-- Convert world coordinates to screen coordinates
local screenX, screenY = cam:toScreen(entity.x, entity.y)
```

## Visibility

Query the camera's visible area:

```teal
-- Get visible world bounds
local left, top, right, bottom = cam:getVisibleCorners()

-- Get visible dimensions
local width, height = cam:getVisibleDimensions()

-- Check if a rectangle is visible (useful for culling)
if cam:isVisible(x, y, width, height) then
    -- Entity is on screen
end
```

## CameraTarget Component

The `CameraTarget` component makes the primary camera automatically follow an entity. Add it to any entity
with a Transform.

```teal
local gfx = require("tecs2d.gfx")

-- Make the player the camera target
world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Sprite.fromAseprite("player.png", "idle"),
    gfx.CameraTarget()
)
```

The camera uses its lerping settings to smoothly follow the target.

### Configuration

| Property       | Type      | Default   | Description                                                    |
| -------------- | --------- | --------- | -------------------------------------------------------------- |
| `offsetX`      | number    | 0         | Horizontal offset from entity center                           |
| `offsetY`      | number    | 0         | Vertical offset from entity center                             |
| `active`       | boolean   | true      | Whether the camera should follow this target                   |
| `deadZoneW`    | number    | 0         | Half-width of dead zone in world units (0 = disabled)          |
| `deadZoneH`    | number    | 0         | Half-height of dead zone in world units (0 = disabled)         |
| `lookAheadX`   | number    | 0         | Horizontal look-ahead factor (0 = disabled)                    |
| `lookAheadY`   | number    | 0         | Vertical look-ahead factor (0 = disabled)                      |

```teal
-- Camera focuses above and to the right of the entity
gfx.CameraTarget({ offsetX = 20, offsetY = -30 })

-- Camera target that starts inactive
gfx.CameraTarget({ active = false })
```

### Dead Zone and Look-Ahead

The **dead zone** defines a rectangular area around the screen center where the target can move without the
camera following. The camera only moves when the target exits the dead zone, keeping it at the edge. This
reduces camera motion for small movements, making gameplay feel smoother.

**Look-ahead** shifts the camera in the direction the target is moving, giving the player more visibility
ahead. The look-ahead offset is smoothed with framerate-independent exponential decay.

```teal
-- Dead zone: camera stays still for small movements
gfx.CameraTarget({
    deadZoneW = 40,   -- 40 world units half-width
    deadZoneH = 30,   -- 30 world units half-height
})

-- Look-ahead: camera leads the target's movement
gfx.CameraTarget({
    lookAheadX = 3.0,   -- 3x velocity look-ahead horizontally
    lookAheadY = 2.0,   -- 2x velocity look-ahead vertically
})

-- Both together
gfx.CameraTarget({
    deadZoneW = 32,
    deadZoneH = 24,
    lookAheadX = 2.5,
    lookAheadY = 1.5,
})
```

**Teleport detection:** If the target moves more than 500 world units from the camera in a single frame
(e.g., map transition or respawn), the camera snaps immediately instead of lerping.

### Pausing and Resuming

Toggle `active` to pause or resume camera following:

```teal
-- Pause following (e.g., during cutscene)
local target = world:get(playerId, gfx.CameraTarget)
target.active = false

-- Pan camera manually during cutscene
cam:move(cutsceneX, cutsceneY)

-- Resume following
target.active = true
```

### Multiple Targets

If multiple entities have active `CameraTarget` components, the camera follows whichever one is processed last.
For predictable behavior, ensure only one entity has an active `CameraTarget` at a time.

## Multiple Cameras

Create additional cameras for minimaps, split-screen, or render-to-texture effects using `pipeline:newCamera()`
(e.g., a security camera rendered in-game). Each camera renders the scene independently with its own position, zoom,
and viewport.

### Camera Config

When creating a camera with `pipeline:newCamera()`, you can pass an optional config table:

| **Field**            | **Type**          | **Default**    | **Description**                                       |
| -------------------- | ----------------- | -------------- | ----------------------------------------------------- |
| `position`           | `{x, y}`          | `{0, 0}`       | Initial camera position                               |
| `zoom`               | `number`          | `1.0`          | Initial zoom level                                    |
| `lerpingEnabled`     | `boolean`         | `true`         | Enable smooth movement                                |
| `lerpSpeed`          | `number`          | `8.0`          | Lerp speed factor                                     |
| `viewport`           | `{x, y, w, h}`    | `fullscreen`   | Screen-space viewport rectangle for split-screen      |
| `canvas`             | `Canvas`          | `none`         | Render to this canvas instead of blitting to screen   |
| `layerMask`          | `integer`         | `0xFFFF`       | 16-bit bitmask of visible layers                      |
| `layers`             | `{integer}`       | `all`          | List of visible layer numbers (builds mask)           |
| `layerRange`         | `{min, max}`      | `all`          | Contiguous range of visible layers (builds mask)      |
| `disableDrawPhase`   | `boolean`         | `false`        | Disable CPU Draw-phase systems for this camera        |

### Minimap Camera

A minimap camera renders the entire world to a small off-screen texture. Pass a `canvas` to render off-screen
without blitting to the display, then draw that canvas wherever you want (screen overlay, in-game TV, etc.).

```teal
local MINIMAP_W, MINIMAP_H = 200, 150
local WORLD_W, WORLD_H = 3200, 2400
local VIRTUAL_HEIGHT = 360

local minimapPixelScale = MINIMAP_H / VIRTUAL_HEIGHT
local zoomX = MINIMAP_W / WORLD_W
local zoomY = MINIMAP_H / WORLD_H

local minimapCam = pipeline:newCamera("minimap", {
    canvas = love.graphics.newCanvas(MINIMAP_W, MINIMAP_H),
    lerpingEnabled = false,
    position = {WORLD_W / 2, WORLD_H / 2},
    zoom = math.min(zoomX, zoomY) / minimapPixelScale,
})
```

Draw the minimap as a screen overlay in PostRender:

```teal
world:addSystem({
    name = "MinimapOverlay",
    phase = tecs.phases.PostRender,
    run = function()
        local canvas = minimapCam:getCanvas()
        if not canvas then return end

        -- Draw minimap in top-right corner
        local mx = love.graphics.getWidth() - MINIMAP_W - 10
        local my = 10
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(canvas, mx, my)

        -- Draw viewport indicator
        local cx, cy = cam:getPosition()
        local vw, vh = cam:getVisibleDimensions()
        local x1 = mx + (cx - vw / 2) / WORLD_W * MINIMAP_W
        local y1 = my + (cy - vh / 2) / WORLD_H * MINIMAP_H
        local w = vw / WORLD_W * MINIMAP_W
        local h = vh / WORLD_H * MINIMAP_H
        love.graphics.setColor(1, 1, 1, 0.9)
        love.graphics.setLineWidth(1)
        love.graphics.rectangle("line", x1, y1, w, h)
    end
})
```

Draw the minimap as an in-game TV in the Draw phase (world coordinates):

```teal
world:addSystem({
    name = "TVDraw",
    phase = tecs.phases.Draw,
    run = function()
        local canvas = minimapCam:getCanvas()
        if canvas then
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.draw(canvas, 400, 400, 0, 300 / MINIMAP_W, 225 / MINIMAP_H)
        end
    end
})
```

### Split-Screen

A split-screen setup uses `viewport` to assign each camera a portion of the screen:

```teal
local screenW = love.graphics.getWidth()
local screenH = love.graphics.getHeight()
local halfW = math.floor(screenW / 2) - 1

-- Deactivate primary camera
local primaryCam = pipeline:getCamera()
primaryCam:setActive(false)

-- Left viewport
local leftCam = pipeline:newCamera("left", {
    viewport = {0, 0, halfW, screenH},
    lerpingEnabled = true,
    lerpSpeed = 8,
    position = {WORLD_W * 0.3, WORLD_H / 2},
})
leftCam:setWorldBounds(0, 0, WORLD_W, WORLD_H)
leftCam:setClamp(true)

-- Right viewport
local rightCam = pipeline:newCamera("right", {
    viewport = {halfW + 2, 0, halfW, screenH},
    lerpingEnabled = true,
    lerpSpeed = 8,
    position = {WORLD_W * 0.7, WORLD_H / 2},
})
rightCam:setWorldBounds(0, 0, WORLD_W, WORLD_H)
rightCam:setClamp(true)
```

Each camera can be controlled independently:

```teal
-- Left camera: WASD
if input.isKeyDown("w") then leftCam:nudge(0, -speed * dt) end
if input.isKeyDown("a") then leftCam:nudge(-speed * dt, 0) end

-- Right camera: arrow keys
if input.isKeyDown("up") then rightCam:nudge(0, -speed * dt) end
if input.isKeyDown("left") then rightCam:nudge(-speed * dt, 0) end
```

Draw a divider between viewports in PostRender:

```teal
world:addSystem({
    name = "Divider",
    phase = tecs.phases.PostRender,
    run = function()
        love.graphics.setColor(0.2, 0.2, 0.2, 1)
        love.graphics.rectangle("fill", halfW, 0, 2, screenH)
    end
})
```

:::info See the example
See the `multi-cam` example for a complete implementation that combines minimap, in-game TV, and split-screen cameras.
:::

## Pipeline Camera API

### pipeline:getCamera

Get a camera by name. Called with no arguments, returns the primary camera.

```teal
function Pipeline:getCamera(name?: string): Camera
```

**Parameters:**

- `name` (optional): The camera name. If omitted, returns the primary camera.

**Returns:**

- The `Camera` instance, or `nil` if no camera with that name exists.

**Example:**

```teal
local cam = pipeline:getCamera()            -- primary camera
local mini = pipeline:getCamera("minimap")  -- named camera
```

### pipeline:newCamera

Create and register a new camera.

```teal
function Pipeline:newCamera(name: string, config?: CameraConfig): Camera
```

**Parameters:**

- `name`: Unique name for the camera.
- `config` (optional): A [CameraConfig](#camera-config) table. Screen dimensions and virtual height default to the
  pipeline's current values.

**Returns:**

- The newly created `Camera`.

**Notes:**

- Throws an error if a camera with the same name already exists.
- The camera starts active. Call `setActive(false)` to defer rendering.

**Example:**

```teal
local minimapCam = pipeline:newCamera("minimap", {
    canvas = love.graphics.newCanvas(200, 150),
    position = {1600, 1200},
})
```

### pipeline:removeCamera

Remove a registered camera by name.

```teal
function Pipeline:removeCamera(name: string)
```

**Parameters:**

- `name`: The camera name to remove.

**Notes:**

- The primary camera cannot be removed.
- No-op if the name is not found.

## Camera API

### setPosition

Set the camera position immediately, bypassing lerp interpolation. Both the current and target positions are updated.

```teal
function Camera:setPosition(x: number, y: number)
```

**Parameters:**

- `x`: The x position (world coordinates).
- `y`: The y position (world coordinates).

### move

Move the camera to a target position. If lerping is enabled, the camera smoothly interpolates to the target.
Otherwise, the position is set immediately.

```teal
function Camera:move(x: number, y: number)
```

**Parameters:**

- `x`: The target x position (world coordinates).
- `y`: The target y position (world coordinates).

### nudge

Move the camera by a delta amount relative to its current target position. Useful for input-driven movement.

```teal
function Camera:nudge(dx: number, dy: number)
```

**Parameters:**

- `dx`: Horizontal delta.
- `dy`: Vertical delta.

**Example:**

```teal
-- Move camera right at 200 units/sec
cam:nudge(200 * dt, 0)
```

### getPosition

Get the current interpolated camera position.

```teal
function Camera:getPosition(): number, number
```

**Returns:**

- `x`: Current x position.
- `y`: Current y position.

### setZoom

Set the camera zoom level. Values greater than 1 zoom in; values less than 1 zoom out. Clamped to a minimum of 0.001.

```teal
function Camera:setZoom(zoom: number)
```

**Parameters:**

- `zoom`: The zoom level.

**Notes:**

- If bounds clamping is enabled, the position is re-clamped after the zoom change to account for the new visible area.

### getZoom

Get the current zoom level.

```teal
function Camera:getZoom(): number
```

**Returns:**

- The current zoom level.

### setRotation

Set the camera rotation. If lerping is enabled, the rotation smoothly interpolates via the shortest angular path.

```teal
function Camera:setRotation(rotation: number)
```

**Parameters:**

- `rotation`: Rotation angle in radians.

### getRotation

Get the current camera rotation.

```teal
function Camera:getRotation(): number
```

**Returns:**

- The current rotation in radians.

### setLerpingEnabled

Enable or disable smooth camera interpolation. When disabled, the camera snaps to its target position immediately.

```teal
function Camera:setLerpingEnabled(enabled: boolean)
```

**Parameters:**

- `enabled`: `true` to enable lerping, `false` to disable.

**Notes:**

- Disabling lerp immediately snaps the camera to its target position.

### setLerpSpeed

Set the lerp speed factor. Higher values produce snappier movement; lower values produce smoother, slower tracking.

```teal
function Camera:setLerpSpeed(speed: number)
```

**Parameters:**

- `speed`: Lerp speed factor, clamped to the range 1-20.

### setClamp

Enable or disable clamping the camera position to world bounds.

```teal
function Camera:setClamp(enabled: boolean)
```

**Parameters:**

- `enabled`: `true` to clamp, `false` to allow free scrolling.

### setWorldBounds

Set the world bounds used for clamping. The camera will not scroll past these edges when clamping is enabled.

```teal
function Camera:setWorldBounds(minX: number, minY: number, maxX: number, maxY: number)
```

**Parameters:**

- `minX`: Left edge of the world.
- `minY`: Top edge of the world.
- `maxX`: Right edge of the world.
- `maxY`: Bottom edge of the world.

### toWorld

Convert screen-space coordinates to world-space coordinates, accounting for camera position, zoom, and rotation.

```teal
function Camera:toWorld(screenX: number, screenY: number): number, number
```

**Parameters:**

- `screenX`: X position on the screen.
- `screenY`: Y position on the screen.

**Returns:**

- `worldX`: X position in the world.
- `worldY`: Y position in the world.

**Example:**

```teal
local wx, wy = cam:toWorld(love.mouse.getPosition())
```

### toScreen

Convert world-space coordinates to screen-space coordinates.

```teal
function Camera:toScreen(worldX: number, worldY: number): number, number
```

**Parameters:**

- `worldX`: X position in the world.
- `worldY`: Y position in the world.

**Returns:**

- `screenX`: X position on the screen.
- `screenY`: Y position on the screen.

### getVisibleCorners

Get the world-space bounding box of the camera's visible area.

```teal
function Camera:getVisibleCorners(): number, number, number, number
```

**Returns:**

- `x1`: Left edge.
- `y1`: Top edge.
- `x2`: Right edge.
- `y2`: Bottom edge.

**Notes:**

- When the camera is rotated, this returns the axis-aligned bounding box of the rotated viewport, which is slightly
  larger than the actual visible area.

### getVisibleDimensions

Get the width and height of the camera's visible area in world units.

```teal
function Camera:getVisibleDimensions(): number, number
```

**Returns:**

- `width`: Visible width in world units.
- `height`: Visible height in world units.

### isVisible

Check if a world-space rectangle is within the camera's visible area. Useful for culling expensive draw calls.

```teal
function Camera:isVisible(x: number, y: number, w: number, h: number): boolean
```

**Parameters:**

- `x`: Left edge of the rectangle.
- `y`: Top edge of the rectangle.
- `w`: Width of the rectangle.
- `h`: Height of the rectangle.

**Returns:**

- `true` if any part of the rectangle overlaps the visible area.

### setActive

Enable or disable this camera. Inactive cameras are skipped during rendering.

```teal
function Camera:setActive(active: boolean)
```

**Parameters:**

- `active`: `true` to enable rendering, `false` to skip.

### isActive

Check if this camera is currently active.

```teal
function Camera:isActive(): boolean
```

**Returns:**

- `true` if the camera will render.

### setViewport

Set the screen-space viewport rectangle. This also updates the camera's internal screen dimensions to match the
viewport aspect ratio.

```teal
function Camera:setViewport(x: number, y: number, w: number, h: number)
```

**Parameters:**

- `x`: Left edge in screen pixels.
- `y`: Top edge in screen pixels.
- `w`: Width in screen pixels.
- `h`: Height in screen pixels.

**Notes:**

- Use `0, 0, 0, 0` to reset to fullscreen rendering.

### getViewport

Get the current viewport rectangle.

```teal
function Camera:getViewport(): number, number, number, number
```

**Returns:**

- `x`, `y`, `w`, `h`: The viewport rect. `0, 0, 0, 0` means fullscreen.

### setLayerMask

Set the 16-bit layer visibility bitmask. Bit N-1 corresponds to layer N. For example, `0x0003` makes layers 1 and 2
visible.

```teal
function Camera:setLayerMask(mask: integer)
```

**Parameters:**

- `mask`: 16-bit bitmask. `0xFFFF` makes all layers visible.

### getLayerMask

Get the current layer visibility bitmask.

```teal
function Camera:getLayerMask(): integer
```

**Returns:**

- The 16-bit layer mask.

### setLayers

Set visible layers from a list of layer numbers. Replaces the current mask.

```teal
function Camera:setLayers(layers: {integer})
```

**Parameters:**

- `layers`: List of layer numbers (1-16).

**Example:**

```teal
cam:setLayers({1, 2, 5})  -- Only layers 1, 2, and 5 visible
```

### setLayerRange

Set visible layers from a contiguous range. Replaces the current mask.

```teal
function Camera:setLayerRange(minLayer: integer, maxLayer: integer)
```

**Parameters:**

- `minLayer`: First visible layer (inclusive).
- `maxLayer`: Last visible layer (inclusive).

### setLayer

Toggle visibility of a single layer without affecting other layers.

```teal
function Camera:setLayer(layer: integer, enabled: boolean)
```

**Parameters:**

- `layer`: Layer number (1-16).
- `enabled`: `true` to make visible, `false` to hide.

### isLayerVisible

Check if a specific layer is visible to this camera.

```teal
function Camera:isLayerVisible(layer: integer): boolean
```

**Parameters:**

- `layer`: Layer number (1-16).

**Returns:**

- `true` if the layer is visible.

### setRunDrawPhase

Enable or disable the CPU Draw phase for this camera. When enabled, systems registered in `tecs.phases.Draw` will run
during this camera's render pass with the camera's transform applied.

```teal
function Camera:setRunDrawPhase(enabled: boolean)
```

**Parameters:**

- `enabled`: `true` to run Draw-phase systems.

**Notes:**

- The primary camera always runs the Draw phase. Secondary cameras only run it when explicitly enabled.
- Required for texture cameras that need custom CPU drawing (e.g., minimap with in-game TV overlay).

### getRunDrawPhase

Check if the CPU Draw phase is enabled for this camera.

```teal
function Camera:getRunDrawPhase(): boolean
```

**Returns:**

- `true` if Draw-phase systems run for this camera.

### getName

Get the camera's name as set during creation.

```teal
function Camera:getName(): string
```

**Returns:**

- The name string. The primary camera's name is `"__primary"`.

### getCanvas

Get the rendered canvas for render-to-texture cameras (created with `canvas`).

```teal
function Camera:getCanvas(): love.graphics.Canvas
```

**Returns:**

- The canvas containing the camera's rendered output, or `nil` for viewport cameras.

**Notes:**

- Returns the canvas passed to the constructor, so `getCanvas()` returns a valid canvas even before the first render
  frame.
- Draw this canvas in a PostRender system (screen overlay) or a Draw system (in-game display).

### shake

Add trauma to trigger screenshake. Stacks with existing trauma, clamped to 0-1.

```teal
function Camera:shake(amount: number)
```

**Parameters:**

- `amount`: Trauma amount to add (0-1). Values above 1 are clamped.

**Example:**

```teal
cam:shake(0.5)   -- Medium shake
cam:shake(1.0)   -- Maximum shake
```

### setShakeIntensity

Set the maximum pixel offset at full trauma (trauma = 1).

```teal
function Camera:setShakeIntensity(intensity: number)
```

**Parameters:**

- `intensity`: Max pixel offset (default: 8). Clamped to >= 0.

### setShakeRotation

Set the maximum rotational shake in radians at full trauma.

```teal
function Camera:setShakeRotation(maxAngle: number)
```

**Parameters:**

- `maxAngle`: Max rotation in radians (default: 0.03, approximately 1.7 degrees). Clamped to >= 0.

### setTraumaDecay

Set the trauma decay rate.

```teal
function Camera:setTraumaDecay(decay: number)
```

**Parameters:**

- `decay`: Decay rate in trauma per second (default: 1.5). Higher values make the shake end faster.

### getTrauma

Get the current trauma level.

```teal
function Camera:getTrauma(): number
```

**Returns:**

- The current trauma level (0-1).

### setScreenSize

Update the camera's screen dimensions. Called automatically by the pipeline on window resize.

```teal
function Camera:setScreenSize(sw: integer, sh: integer, vh: integer)
```

**Parameters:**

- `sw`: Screen width in pixels.
- `sh`: Screen height in pixels.
- `vh`: Virtual height for resolution scaling.

:::tip
You typically do not need to call this directly; the pipeline handles it on resize.
:::