local bit <const> = require("bit")
local bor, band, bnot, lshift <const> = bit.bor, bit.band, bit.bnot, bit.lshift

local max, min <const> = math.max, math.min
local abs, exp <const> = math.abs, math.exp
local cos, sin, atan2 <const> = math.cos, math.sin, math.atan2

local function setOrthographic(t: love.math.Transform, camX: number, camY: number,
        zoom: number, rotation: number, w: number, h: number, spX: number, spY: number)
    t:reset()
    t:translate(w / 2 + spX, h / 2 + spY)
    t:rotate(rotation)
    t:scale(zoom, zoom)
    t:translate(-camX, -camY)
end

local function computeAABB(t: love.math.Transform, sw: number, sh: number, pad: number): number, number, number, number
    local x0, y0 = t:inverseTransformPoint(0, 0)
    local x1, y1 = t:inverseTransformPoint(sw, 0)
    local x2, y2 = t:inverseTransformPoint(sw, sh)
    local x3, y3 = t:inverseTransformPoint(0, sh)
    local minX = min(x0, x1, x2, x3) - pad
    local minY = min(y0, y1, y2, y3) - pad
    local maxX = max(x0, x1, x2, x3) + pad
    local maxY = max(y0, y1, y2, y3) + pad
    return minX, minY, maxX, maxY
end

local MIN_ZOOM <const> = 0.001
local LERP_SNAP_THRESHOLD <const> = 0.1
local ROTATION_SNAP_THRESHOLD <const> = 0.001
local ALL_LAYERS_MASK <const> = 0xFFFF

local record Camera
    --- Configuration table for creating a Camera.
    record CameraConfig
        --- Screen width in pixels (required).
        screenWidth: integer
        --- Screen height in pixels (required).
        screenHeight: integer
        --- Virtual resolution height for pixel-perfect modes. Defines the world-to-screen
        --- zoom level: effectiveZoom = cam.zoom * screenHeight / virtualHeight.
        virtualHeight: integer

        --- Screen-space viewport rect {x, y, w, h}. Nil = fullscreen.
        viewport: {number, number, number, number}
        --- Bitmask of visible layers (16-bit). 0 or nil = all layers (0xFFFF).
        layerMask: integer
        --- Convenience: list of layer numbers to make visible (builds mask).
        layers: {integer}
        --- Convenience: {min, max} layer range to make visible (builds mask).
        layerRange: {number, number}
        --- Disable CPU Draw phase for this camera (default: false).
        disableDrawPhase: boolean
        --- Enable smooth camera movement via lerping (default: true).
        lerpingEnabled: boolean
        --- Lerp speed factor (default: 8.0).
        lerpSpeed: number
        --- Initial position {x, y}.
        position: {number, number}
        --- Initial zoom (default: 1.0).
        zoom: number
        --- Render to this canvas instead of blitting to screen.
        --- Use getCanvas() to access the result.
        canvas: love.graphics.Canvas
        --- Camera name (set by pipeline:newCamera).
        name: string
    end
    -- Position
    x: number
    y: number
    targetX: number
    targetY: number

    -- Zoom & rotation
    zoom: number
    rotation: number
    targetRotation: number

    -- Lerp
    lerpingEnabled: boolean
    lerpSpeed: number

    -- Bounds clamping
    clampToBounds: boolean
    worldBounds: {number, number, number, number}

    -- Projection
    _transform: love.math.Transform

    -- Cached visible bounds
    visX1: number
    visY1: number
    visX2: number
    visY2: number
    halfWidth: number
    halfHeight: number

    -- Screen dimensions (set by pipeline on init/resize)
    _screenWidth: integer
    _screenHeight: integer
    _virtualHeight: integer

    -- Render dimensions for bounds/clamping (defaults to screen dims;
    -- pipeline overrides for retro mode to use virtual dims)
    _renderWidth: integer
    _renderHeight: integer

    -- Pixel-mode screen mapping (set by the pipeline each render).
    -- When _screenZoomScale > 0, the screen transform uses
    -- zoom * _screenZoomScale (e.g. the integer upscale factor) plus the
    -- sub-pixel blit offset, matching where content actually renders,
    -- instead of the fractional screenHeight / virtualHeight scale.
    _screenZoomScale: number
    _screenOffsetX: number
    _screenOffsetY: number

    -- Viewport (screen-space rect; 0 values = fullscreen)
    _viewportX: number
    _viewportY: number
    _viewportW: number
    _viewportH: number

    -- Layer bitmask (16-bit; 0xFFFF = all layers visible)
    _layerMask: integer

    -- CPU Draw phase disabled
    _disableDrawPhase: boolean

    -- Name (for lookup)
    _name: string

    -- Active flag
    _active: boolean

    -- Screenshake (trauma-based)
    _trauma: number
    _traumaDecay: number
    _shakeIntensity: number
    _shakeRotation: number
    _shakeOffsetX: number
    _shakeOffsetY: number
    _shakeAngle: number
    _shakeTime: number
    _renderX: number
    _renderY: number
    _renderRotation: number

    -- Render-to-texture dimensions (0 = not a texture camera)
    _textureW: integer
    _textureH: integer

    -- Per-camera intermediate canvas (lazily allocated for secondary cameras)
    _canvas: love.graphics.Canvas

    --- Create a new Camera from a configuration table.
    --- @param config Camera configuration.
    --- @return A new Camera instance.
    new: function(config: Camera.CameraConfig): Camera

    --- Set the camera position immediately, ignoring lerp.
    --- @param x The x position.
    --- @param y The y position.
    setPosition: function(self, x: number, y: number)

    --- Move the camera to a target position. Uses lerp if enabled, otherwise immediate.
    --- @param x The target x position.
    --- @param y The target y position.
    move: function(self, x: number, y: number)

    --- Nudge the camera by a delta amount.
    --- @param dx The change in x.
    --- @param dy The change in y.
    nudge: function(self, dx: number, dy: number)

    --- Get the current camera position.
    --- @return x, y
    getPosition: function(self): number, number

    --- Set the camera zoom level.
    --- @param zoom The zoom level (1 is normal). Clamped to MIN_ZOOM.
    setZoom: function(self, zoom: number)

    --- Get the current zoom level.
    --- @return The zoom level.
    getZoom: function(self): number

    --- Set the camera rotation in radians. Uses lerp if enabled.
    --- @param rotation The rotation in radians.
    setRotation: function(self, rotation: number)

    --- Get the current camera rotation in radians.
    --- @return The rotation in radians.
    getRotation: function(self): number

    --- Enable or disable camera lerping.
    --- @param enabled True to enable lerping.
    setLerpingEnabled: function(self, enabled: boolean)

    --- Set the lerp speed factor.
    --- @param speed The lerp speed (1-20, higher = snappier).
    setLerpSpeed: function(self, speed: number)

    --- Enable or disable bounds clamping.
    --- @param enabled True to clamp camera position to world bounds.
    setClamp: function(self, enabled: boolean)

    --- Set the world bounds for clamping.
    --- @param minX Left edge.
    --- @param minY Top edge.
    --- @param maxX Right edge.
    --- @param maxY Bottom edge.
    setWorldBounds: function(self, minX: number, minY: number, maxX: number, maxY: number)

    --- Get the Transform matrix.
    --- @return The active Transform.
    getTransform: function(self): love.math.Transform

    --- Compute a world-space AABB for the visible viewport.
    --- @param screenWidth Screen width in pixels.
    --- @param screenHeight Screen height in pixels.
    --- @param pad World-space padding (default 0).
    --- @return minX, minY, maxX, maxY
    aabb: function(self, screenWidth: number, screenHeight: number, pad?: number): number, number, number, number

    --- Convert a screen position to a world position.
    --- @param screenX The x position on the screen.
    --- @param screenY The y position on the screen.
    --- @return x, y position in the world.
    toWorld: function(self, screenX: number, screenY: number): number, number

    --- Convert a world position to a screen position.
    --- @param worldX The x position in the world.
    --- @param worldY The y position in the world.
    --- @return x, y position on the screen.
    toScreen: function(self, worldX: number, worldY: number): number, number

    --- Get the visible corners of the camera viewport.
    --- @return x1, y1, x2, y2
    getVisibleCorners: function(self): number, number, number, number

    --- Get the visible dimensions of the camera viewport.
    --- @return width, height
    getVisibleDimensions: function(self): number, number

    --- Check if a rectangle is visible to the camera.
    --- @param x The x position of the rectangle.
    --- @param y The y position of the rectangle.
    --- @param w The width of the rectangle.
    --- @param h The height of the rectangle.
    --- @return true if the rectangle is visible.
    isVisible: function(self, x: number, y: number, w: number, h: number): boolean

    --- Update camera lerp (position + rotation) and recompute bounds.
    --- Called once per frame by the pipeline's CameraLerpUpdate system.
    --- @param dt Delta time in seconds.
    update: function(self, dt: number)

    --- Recompute visible bounds and the Transform.
    --- Called after any change to position, zoom, rotation, or screen size.
    updateBounds: function(self)

    --- Set the pixel-mode screen mapping (pipeline-internal); 0 zoomScale
    --- falls back to the fractional screen/virtual mapping.
    _setScreenMapping: function(self, zoomScale: number, offsetX: number, offsetY: number)

    --- Set the screen dimensions. Called by the pipeline on init and resize.
    --- @param sw Screen width in pixels.
    --- @param sh Screen height in pixels.
    --- @param vh Virtual height for pixel-perfect mode.
    setScreenSize: function(self, sw: integer, sh: integer, vh: integer)

    --- Set the screen-space viewport rect. Also updates screen size for correct aspect ratio.
    --- @param x Left edge in screen pixels.
    --- @param y Top edge in screen pixels.
    --- @param w Width in screen pixels.
    --- @param h Height in screen pixels.
    setViewport: function(self, x: number, y: number, w: number, h: number)

    --- Get the viewport rect.
    --- @return x, y, w, h (0,0,0,0 means fullscreen)
    getViewport: function(self): number, number, number, number

    --- Set the layer visibility bitmask directly.
    --- @param mask 16-bit bitmask (bit N-1 = layer N). 0xFFFF = all visible.
    setLayerMask: function(self, mask: integer)

    --- Get the layer visibility bitmask.
    --- @return The 16-bit bitmask.
    getLayerMask: function(self): integer

    --- Set visible layers from a list of layer numbers.
    --- @param layers List of layer numbers (1-16).
    setLayers: function(self, layers: {integer})

    --- Set visible layers from a contiguous range.
    --- @param minLayer Minimum layer (inclusive).
    --- @param maxLayer Maximum layer (inclusive).
    setLayerRange: function(self, minLayer: integer, maxLayer: integer)

    --- Toggle visibility of a single layer.
    --- @param layer Layer number (1-16).
    --- @param enabled True to make visible, false to hide.
    setLayer: function(self, layer: integer, enabled: boolean)

    --- Check if a specific layer is visible to this camera.
    --- @param layer Layer number (1-16).
    --- @return true if the layer is visible.
    isLayerVisible: function(self, layer: integer): boolean

    --- Enable or disable the CPU Draw phase for this camera.
    --- @param enabled True to run Draw phase during this camera's render.
    setDisableDrawPhase: function(self, disabled: boolean)

    --- Check if the CPU Draw phase is enabled for this camera.
    --- @return true if Draw phase runs for this camera.
    getDisableDrawPhase: function(self): boolean

    --- Get the camera name.
    --- @return The name string.
    getName: function(self): string

    --- Enable or disable this camera.
    --- @param active True to enable rendering, false to skip.
    setActive: function(self, active: boolean)

    --- Check if this camera is active.
    --- @return true if the camera will render.
    isActive: function(self): boolean

    --- Get the rendered canvas (for render-to-texture cameras).
    --- @return The canvas, or nil if not yet rendered.
    getCanvas: function(self): love.graphics.Canvas

    --- Add trauma to trigger screenshake. Stacks with existing trauma, clamped to 0-1.
    --- @param amount Trauma amount to add (0-1).
    shake: function(self, amount: number)

    --- Set the maximum pixel offset at full trauma.
    --- @param intensity Max pixel offset (default: 8).
    setShakeIntensity: function(self, intensity: number)

    --- Set the maximum rotational shake in radians at full trauma.
    --- @param maxAngle Max rotation in radians (default: 0.03).
    setShakeRotation: function(self, maxAngle: number)

    --- Set the trauma decay rate (trauma per second).
    --- @param decay Decay rate (default: 1.5).
    setTraumaDecay: function(self, decay: number)

    --- Get the current trauma level.
    --- @return Trauma level (0-1).
    getTrauma: function(self): number

    --- Capture the camera's durable view state (position, zoom, rotation,
    --- lerp settings, and world bounds) as a plain table for snapshotting.
    --- Screen/viewport dimensions and transient screenshake are excluded; the
    --- pipeline re-establishes those on init and resize.
    --- @return A string.buffer-encodable state table.
    captureState: function(self): {string: any}

    --- Apply state produced by `captureState`, snapping position and rotation
    --- without lerp animation and recomputing bounds.
    --- @param data The captured state table.
    applyState: function(self, data: {string: any})
end

local CAMERA_MT <const>: metatable<Camera> = {
    __index = Camera
}

--- Clamp position to world bounds if enabled.
local function clampPosition(cam: Camera, x: number, y: number): number, number
    if cam.clampToBounds and cam.worldBounds then
        local bounds = cam.worldBounds
        local pixelScale = cam._screenHeight / cam._virtualHeight
        local effectiveZoom = cam.zoom * pixelScale
        local halfW = (cam._renderWidth / 2) / effectiveZoom
        local halfH = (cam._renderHeight / 2) / effectiveZoom
        x = max(bounds[1] + halfW, min(bounds[3] - halfW, x))
        y = max(bounds[2] + halfH, min(bounds[4] - halfH, y))
    end
    return x, y
end

--- Build a layer mask from a list of layer numbers.
local function buildMaskFromList(layers: {integer}): integer
    local mask = 0
    for _, layer in ipairs(layers) do
        if layer >= 1 and layer <= 16 then
            mask = bor(mask, lshift(1, layer - 1))
        end
    end
    return mask
end

--- Build a layer mask from a contiguous range.
local function buildMaskFromRange(minLayer: integer, maxLayer: integer): integer
    local mask = 0
    for i = minLayer, maxLayer do
        if i >= 1 and i <= 16 then
            mask = bor(mask, lshift(1, i - 1))
        end
    end
    return mask
end

function Camera.new(config: Camera.CameraConfig): Camera
    local screenWidth = config.screenWidth or (love.graphics.getWidth() as integer)
    local screenHeight = config.screenHeight or (love.graphics.getHeight() as integer)
    -- Default to the screen height (1:1 mapping): updateBounds divides by
    -- it, so a nil virtualHeight would crash in the constructor.
    local virtualHeight = config.virtualHeight or screenHeight

    -- Determine initial layer mask
    local layerMask = ALL_LAYERS_MASK
    if config.layers then
        layerMask = buildMaskFromList(config.layers)
    elseif config.layerRange then
        layerMask = buildMaskFromRange(config.layerRange[1] as integer, config.layerRange[2] as integer)
    elseif config.layerMask then
        layerMask = config.layerMask
        if layerMask == 0 then layerMask = ALL_LAYERS_MASK end
    end

    -- Determine initial position
    local ix, iy = 0.0, 0.0
    if config.position then
        ix = config.position[1] or 0
        iy = config.position[2] or 0
    end

    local self: Camera = setmetatable({
        x = ix,
        y = iy,
        targetX = ix,
        targetY = iy,
        zoom = config.zoom or 1.0,
        rotation = 0.0,
        targetRotation = 0.0,
        lerpingEnabled = config.lerpingEnabled ~= false,
        lerpSpeed = config.lerpSpeed or 8.0,
        clampToBounds = false,
        worldBounds = nil,
        _transform = love.math.newTransform(),
        visX1 = 0, visY1 = 0, visX2 = 0, visY2 = 0,
        halfWidth = 0, halfHeight = 0,
        _screenWidth = screenWidth,
        _screenHeight = screenHeight,
        _virtualHeight = virtualHeight,
        _renderWidth = screenWidth,
        _renderHeight = screenHeight,
        _screenZoomScale = 0,
        _screenOffsetX = 0,
        _screenOffsetY = 0,
        _viewportX = 0,
        _viewportY = 0,
        _viewportW = 0,
        _viewportH = 0,
        _layerMask = layerMask,
        _disableDrawPhase = config.disableDrawPhase or false,
        _name = config.name or "",
        _active = true,
        _trauma = 0,
        _traumaDecay = 1.5,
        _shakeIntensity = 8,
        _shakeRotation = 0.03,
        _shakeOffsetX = 0,
        _shakeOffsetY = 0,
        _shakeAngle = 0,
        _shakeTime = 0,
        _renderX = ix,
        _renderY = iy,
        _renderRotation = 0.0,
        _textureW = 0,
        _textureH = 0,
    } as Camera, CAMERA_MT)

    -- Apply viewport if provided
    if config.viewport then
        local vp = config.viewport
        self._viewportX = vp[1]
        self._viewportY = vp[2]
        self._viewportW = vp[3]
        self._viewportH = vp[4]
        -- VP matrix uses viewport aspect ratio
        self._screenWidth = vp[3] as integer
        self._screenHeight = vp[4] as integer
    end

    -- Apply canvas if provided (render-to-texture, no screen blit)
    if config.canvas then
        self._canvas = config.canvas
        self._textureW = config.canvas:getWidth() as integer
        self._textureH = config.canvas:getHeight() as integer
        -- VP matrix uses texture dimensions for aspect ratio
        self._screenWidth = self._textureW
        self._screenHeight = self._textureH
    end

    self:updateBounds()
    return self
end

function Camera:setPosition(x: number, y: number)
    x, y = clampPosition(self, x, y)
    self.x, self.y = x, y
    self.targetX, self.targetY = x, y
    self:updateBounds()
end

function Camera:move(x: number, y: number)
    x, y = clampPosition(self, x, y)
    if self.lerpingEnabled then
        self.targetX, self.targetY = x, y
    else
        self.x, self.y = x, y
        self.targetX, self.targetY = x, y
        self:updateBounds()
    end
end

function Camera:nudge(dx: number, dy: number)
    self:move(self.targetX + dx, self.targetY + dy)
end

function Camera:getPosition(): number, number
    return self.x, self.y
end

function Camera:setZoom(zoom: number)
    self.zoom = max(MIN_ZOOM, zoom)
    -- Re-clamp position for new visible area
    if self.clampToBounds and self.worldBounds then
        self.targetX, self.targetY = clampPosition(self, self.targetX, self.targetY)
        self.x, self.y = clampPosition(self, self.x, self.y)
    end
    self:updateBounds()
end

function Camera:getZoom(): number
    return self.zoom
end

function Camera:setRotation(rotation: number)
    if self.lerpingEnabled then
        self.targetRotation = rotation
    else
        self.rotation = rotation
        self.targetRotation = rotation
        self:updateBounds()
    end
end

function Camera:getRotation(): number
    return self.rotation
end

function Camera:setLerpingEnabled(enabled: boolean)
    self.lerpingEnabled = enabled
    if not enabled then
        self.x = self.targetX
        self.y = self.targetY
        self.rotation = self.targetRotation
        self:updateBounds()
    end
end

function Camera:setLerpSpeed(speed: number)
    self.lerpSpeed = max(1, min(20, speed))
end

function Camera:setClamp(enabled: boolean)
    self.clampToBounds = enabled
    -- Immediately clamp current/target position so the camera doesn't stay
    -- out of bounds until the next movement update.
    if enabled and self.worldBounds then
        self.targetX, self.targetY = clampPosition(self, self.targetX, self.targetY)
        self.x, self.y = clampPosition(self, self.x, self.y)
        self:updateBounds()
    end
end

function Camera:setWorldBounds(minX: number, minY: number, maxX: number, maxY: number)
    self.worldBounds = {minX, minY, maxX, maxY}
    -- Re-clamp immediately if clamping is active; otherwise the camera
    -- can remain out of bounds until the next move.
    if self.clampToBounds then
        self.targetX, self.targetY = clampPosition(self, self.targetX, self.targetY)
        self.x, self.y = clampPosition(self, self.x, self.y)
        self:updateBounds()
    end
end

function Camera:getTransform(): love.math.Transform
    return self._transform
end

function Camera:aabb(screenWidth: number, screenHeight: number, pad?: number): number, number, number, number
    return computeAABB(self._transform, screenWidth, screenHeight, pad or 0)
end

function Camera:toWorld(screenX: number, screenY: number): number, number
    return self._transform:inverseTransformPoint(screenX, screenY)
end

function Camera:toScreen(worldX: number, worldY: number): number, number
    return self._transform:transformPoint(worldX, worldY)
end

function Camera:getVisibleCorners(): number, number, number, number
    return self.visX1, self.visY1, self.visX2, self.visY2
end

function Camera:getVisibleDimensions(): number, number
    return self.halfWidth * 2, self.halfHeight * 2
end

function Camera:isVisible(x: number, y: number, w: number, h: number): boolean
    local hx, hy = w * 0.5, h * 0.5
    local cx, cy = x + hx, y + hy
    local dx, dy = abs(cx - self.x), abs(cy - self.y)
    return dx <= (hx + self.halfWidth) and dy <= (hy + self.halfHeight)
end

function Camera:update(dt: number)
    if self.lerpingEnabled then
        local factor = 1 - exp(-self.lerpSpeed * dt)
        local dx = self.targetX - self.x
        local dy = self.targetY - self.y

        if abs(dx) < LERP_SNAP_THRESHOLD and abs(dy) < LERP_SNAP_THRESHOLD then
            self.x = self.targetX
            self.y = self.targetY
        else
            self.x = self.x + dx * factor
            self.y = self.y + dy * factor
        end

        -- Re-clamp interpolated position (zoom may have changed since target was set)
        if self.clampToBounds and self.worldBounds then
            self.x, self.y = clampPosition(self, self.x, self.y)
        end

        -- Rotation lerp with shortest-path interpolation
        local dRot = self.targetRotation - self.rotation
        -- Normalize to [-pi, pi] to take the short path
        dRot = atan2(sin(dRot), cos(dRot))
        if abs(dRot) < ROTATION_SNAP_THRESHOLD then
            self.rotation = self.targetRotation
        else
            self.rotation = self.rotation + dRot * factor
        end
    end

    -- Screenshake: compute Perlin noise offsets from trauma
    if self._trauma > 0 then
        self._shakeTime = self._shakeTime + dt
        self._trauma = max(0, self._trauma - self._traumaDecay * dt)
        local amount = self._trauma * self._trauma
        local t = self._shakeTime * 10
        -- love.math.perlinNoise returns 0-1; remap to -1..1
        self._shakeOffsetX = (love.math.perlinNoise(t, 0) * 2 - 1) * amount * self._shakeIntensity
        self._shakeOffsetY = (love.math.perlinNoise(0, t) * 2 - 1) * amount * self._shakeIntensity
        self._shakeAngle = (love.math.perlinNoise(t, t) * 2 - 1) * amount * self._shakeRotation
    else
        self._shakeOffsetX = 0
        self._shakeOffsetY = 0
        self._shakeAngle = 0
    end

    self:updateBounds()
end

function Camera:updateBounds()
    local pixelScale = self._screenHeight / self._virtualHeight
    local effectiveZoom = self.zoom * pixelScale
    -- Use render dimensions for visible bounds: in retro mode these are virtual
    -- dims (smaller), giving correct halfW for clamping and visibility checks.
    local halfW = (self._renderWidth / 2) / effectiveZoom
    local halfH = (self._renderHeight / 2) / effectiveZoom

    -- Pad visible bounds by max shake intensity to prevent edge-popping
    local pad = self._shakeIntensity > 0 and self._shakeIntensity / effectiveZoom or 0

    if self.rotation == 0.0 then
        self.halfWidth = halfW + pad
        self.halfHeight = halfH + pad
        self.visX1 = self.x - halfW - pad
        self.visY1 = self.y - halfH - pad
        self.visX2 = self.x + halfW + pad
        self.visY2 = self.y + halfH + pad
    else
        -- When rotated, compute AABB of the rotated screen rectangle
        local cosR = abs(cos(self.rotation))
        local sinR = abs(sin(self.rotation))
        local aabbHalfW = halfW * cosR + halfH * sinR
        local aabbHalfH = halfW * sinR + halfH * cosR
        self.halfWidth = aabbHalfW + pad
        self.halfHeight = aabbHalfH + pad
        self.visX1 = self.x - aabbHalfW - pad
        self.visY1 = self.y - aabbHalfH - pad
        self.visX2 = self.x + aabbHalfW + pad
        self.visY2 = self.y + aabbHalfH + pad
    end

    -- Compute render position (logical + shake offset)
    self._renderX = self.x + self._shakeOffsetX
    self._renderY = self.y + self._shakeOffsetY
    self._renderRotation = self.rotation + self._shakeAngle

    -- Screen transform for toWorld/toScreen. In pixel modes the pipeline
    -- supplies the actual render mapping (integer upscale + sub-pixel
    -- blit offset); the fractional effectiveZoom only matches where
    -- content renders when no such mapping is set.
    local screenZoom = effectiveZoom
    local offsetX, offsetY = 0.0, 0.0
    if self._screenZoomScale > 0 then
        screenZoom = self.zoom * self._screenZoomScale
        offsetX, offsetY = self._screenOffsetX, self._screenOffsetY
    end
    setOrthographic(self._transform,
        self._renderX, self._renderY, screenZoom, self._renderRotation,
        self._screenWidth, self._screenHeight, offsetX, offsetY
    )
end

--- Set the pixel-mode screen mapping (pipeline-internal). zoomScale is
--- the factor the render path multiplies camera zoom by to reach screen
--- pixels (e.g. the integer upscale); offsets are the sub-pixel blit
--- offset in screen pixels. Pass 0 to fall back to the fractional
--- screen/virtual mapping.
function Camera:_setScreenMapping(zoomScale: number, offsetX: number, offsetY: number)
    if self._screenZoomScale == zoomScale
        and self._screenOffsetX == offsetX
        and self._screenOffsetY == offsetY then
        return
    end
    self._screenZoomScale = zoomScale
    self._screenOffsetX = offsetX
    self._screenOffsetY = offsetY
    self:updateBounds()
end

function Camera:setScreenSize(sw: integer, sh: integer, vh: integer)
    self._screenWidth = sw
    self._screenHeight = sh
    self._virtualHeight = vh
    -- Reset render dims to screen; pipeline overrides for retro mode
    self._renderWidth = sw
    self._renderHeight = sh
    self:updateBounds()
end

function Camera:setViewport(x: number, y: number, w: number, h: number)
    self._viewportX = x
    self._viewportY = y
    self._viewportW = w
    self._viewportH = h
    -- VP matrix uses viewport aspect ratio for correct rendering
    self._screenWidth = w as integer
    self._screenHeight = h as integer
    self:updateBounds()
end

function Camera:getViewport(): number, number, number, number
    return self._viewportX, self._viewportY, self._viewportW, self._viewportH
end

function Camera:captureState(): {string: any}
    local state: {string: any} = {
        name = self._name,
        x = self.x,
        y = self.y,
        targetX = self.targetX,
        targetY = self.targetY,
        zoom = self.zoom,
        rotation = self.rotation,
        targetRotation = self.targetRotation,
        lerpingEnabled = self.lerpingEnabled,
        lerpSpeed = self.lerpSpeed,
        clampToBounds = self.clampToBounds,
        layerMask = self._layerMask,
    }
    -- worldBounds is {minX, minY, maxX, maxY} or nil; copy so the snapshot
    -- doesn't alias the live camera's bounds table.
    if self.worldBounds then
        local b = self.worldBounds
        state.worldBounds = {b[1], b[2], b[3], b[4]}
    end
    return state
end

function Camera:applyState(data: {string: any})
    if not data then return end

    -- Bounds first: clampPosition (called via updateBounds and any later
    -- setter) reads these, so restore them before the position.
    self.clampToBounds = data.clampToBounds == true
    local bounds = data.worldBounds as {number}
    if bounds then
        self.worldBounds = {bounds[1], bounds[2], bounds[3], bounds[4]}
    else
        self.worldBounds = nil
    end

    if data.zoom ~= nil then
        self.zoom = max(MIN_ZOOM, data.zoom as number)
    end
    if data.lerpingEnabled ~= nil then
        self.lerpingEnabled = data.lerpingEnabled == true
    end
    if data.lerpSpeed ~= nil then
        self.lerpSpeed = data.lerpSpeed as number
    end
    if data.layerMask ~= nil then
        self._layerMask = data.layerMask as integer
    end

    -- Snap both current and target so no lerp animation plays from the
    -- pre-load pose toward the restored one.
    local x = (data.x as number) or self.x
    local y = (data.y as number) or self.y
    self.x, self.y = x, y
    self.targetX = (data.targetX as number) or x
    self.targetY = (data.targetY as number) or y

    local rotation = (data.rotation as number) or self.rotation
    self.rotation = rotation
    self.targetRotation = (data.targetRotation as number) or rotation

    self:updateBounds()
end

function Camera:setLayerMask(mask: integer)
    self._layerMask = mask
end

function Camera:getLayerMask(): integer
    return self._layerMask
end

function Camera:setLayers(layers: {integer})
    self._layerMask = buildMaskFromList(layers)
end

function Camera:setLayerRange(minLayer: integer, maxLayer: integer)
    self._layerMask = buildMaskFromRange(minLayer, maxLayer)
end

function Camera:setLayer(layer: integer, enabled: boolean)
    if layer < 1 or layer > 16 then return end
    local bitMask = lshift(1, layer - 1)
    if enabled then
        self._layerMask = bor(self._layerMask, bitMask)
    else
        self._layerMask = band(self._layerMask, bnot(bitMask))
    end
end

function Camera:isLayerVisible(layer: integer): boolean
    if layer < 1 or layer > 16 then return false end
    local bitMask = lshift(1, layer - 1)
    return band(self._layerMask, bitMask) ~= 0
end

function Camera:setDisableDrawPhase(disabled: boolean)
    self._disableDrawPhase = disabled
end

function Camera:getDisableDrawPhase(): boolean
    return self._disableDrawPhase
end

function Camera:getName(): string
    return self._name
end

function Camera:setActive(active: boolean)
    self._active = active
end

function Camera:isActive(): boolean
    return self._active
end

function Camera:getCanvas(): love.graphics.Canvas
    return self._canvas
end

function Camera:shake(amount: number)
    self._trauma = min(1, self._trauma + amount)
end

function Camera:setShakeIntensity(intensity: number)
    self._shakeIntensity = max(0, intensity)
end

function Camera:setShakeRotation(maxAngle: number)
    self._shakeRotation = max(0, maxAngle)
end

function Camera:setTraumaDecay(decay: number)
    self._traumaDecay = max(0, decay)
end

function Camera:getTrauma(): number
    return self._trauma
end

return Camera
