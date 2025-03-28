local compat <const> = require("tecs.internal.utils.compat")
local types <const> = require("tecs_render.types")
local shadows <const> = require("tecs_render.internal.shadows")
local pool <const> = require("tecs.internal.utils.pool")

-- Constants from pipeline module
local UNLIT_FLAG <const> = 0x1

local lg_getShader <const> = love.graphics.getShader
local lg_setShader <const> = love.graphics.setShader
local lg_clear <const> = love.graphics.clear
local lg_setCanvas <const> = love.graphics.setCanvas
local lg_getCanvas <const> = love.graphics.getCanvas
local lg_draw <const> = love.graphics.draw
local lg_setColor <const> = love.graphics.setColor
local lg_setBlendMode <const> = love.graphics.setBlendMode

local band <const> = compat.band
local floor <const> = math.floor
local max <const> = math.max
local min <const> = math.min
local abs <const> = math.abs
local exp <const> = math.exp

--- The camera module provides a default pixel-perfect camera implementation that uses a lightmap for lighting.
local record camera
    --- Scaling mode for final screen presentation.
    enum ScaleMode
        "aspect"   -- Maintain aspect ratio with smooth scaling (default)
        "pixel"    -- Integer scaling for pixel-perfect rendering
        "none"     -- 1:1 rendering, centered on screen
    end

    --- The camera configuration.
    record CameraConfig
        --- Minimum width of the virtual dimensions.
        minWidth: number

        --- The max allowed virtual width. This is optional and defaults to the entire screen width (-1).
        maxWidth: number

        --- The exact required height of the virtual dimensions.
        height: number

        --- Oversample factor for extra detail when zoomed out (e.g., 2 = 2x larger canvas). Defaults to 1.
        oversample: number

        --- The scaling mode for final screen presentation. Defaults to "pixel".
        scaleMode: ScaleMode

        --- Enable smooth camera movement via lerping. Defaults to true.
        lerpingEnabled: boolean

        --- Lerp speed factor (higher = snappier, lower = smoother). Defaults to 8.0.
        lerpSpeed: number
    end

    --- Create a new default camera.
    ---
    --- @param config Camera configuration.
    --- @return A new camera instance.
    newCamera: function(config: CameraConfig): types.Camera
end

local record RenderState
    currentCanvas: love.graphics.Canvas
    scissorX: number
    scissorY: number
    scissorWidth: number
    scissorHeight: number
    x: number
    y: number
end

-------------------------------------------------------------------------------
-- Camera implementation
-------------------------------------------------------------------------------

local record CameraImpl is types.Camera
    --- The oversample factor that determines canvas size relative to virtual dimensions.
    oversample: number
    --- The scaling mode for final screen presentation.
    scaleMode: camera.ScaleMode
    minWidth: number
    maxWidth: number

    --- The target virtual width and height dimensions of the game.
    virtualWidth: number
    virtualHeight: number

    --- The actual screen width and height of the virtual dimensions.
    viewWidth: number
    viewHeight: number

    --- Cached half width and height of the virtual dimensions.
    halfWidth: number
    halfHeight: number

    --- The scaling applied to the virtual dimensions used to render to the screen.
    virtualScale: number

    --- The virtual canvas where the camera is rendered before it's scaled up to the viewport.
    canvas: love.graphics.Canvas
    canvasCenterX: number
    canvasCenterY: number

    --- The offset of the canvas, used for letterboxing.
    canvasOffsetX: number
    canvasOffsetY: number

    --- True or false if the camera should clamp so that nothing outside of pixel 0, 0 or is shown.
    clamp: boolean

    --- The width and height of the screen.
    screenWidth: number
    screenHeight: number

    --- The current center point position where the camera is pointed.
    x: number
    y: number

    --- Lerping configuration
    lerpingEnabled: boolean
    lerpSpeed: number

    --- Target position for lerping
    targetX: number
    targetY: number

    --- The current zoom and quad to apply to the virtual canvas. This is independent of the virtual scale and impacts
    --- how much of the virtual quad can be seen at any given time and how it's scaled.
    zoom: number
    zoomScale: number
    zoomWidth: number
    zoomHeight: number
    zoomQuad: love.graphics.Quad

    --- Lighting
    lightCanvas: love.graphics.Canvas
    shadowShader: love.graphics.Shader
    defaultShadersList: {love.graphics.Shader}

    -- Buffers used for applying multiple shaders to a draw.
    shaderBuffers: {love.graphics.Canvas}
    shaderQuad: love.graphics.Quad

    renderState: RenderState

    -- Cached visible corners and center for culling
    visX1: number
    visY1: number
    visX2: number
    visY2: number
    visCenterX: number  -- Cached center X for culling
    visCenterY: number  -- Cached center Y for culling
    visHalfWidth: number  -- Cached half width for culling
    visHalfHeight: number  -- Cached half height for culling

    captureScreenshots: function(self, smoothX: number, smoothY: number, currentCanvas: love.graphics.Canvas, ...: function(love.graphics.Image))
end

local CAMERA_MT <const>: metatable<CameraImpl> = {
    __index = CameraImpl
}

function camera.newCamera(config: camera.CameraConfig): types.Camera
    local shader = shadows.newShadowShader()
    local scaleMode = config.scaleMode or "pixel"  -- Default to pixel mode

    -- Set global Love2D defaults based on scale mode
    if scaleMode == "pixel" then
        love.graphics.setDefaultFilter("nearest", "nearest")
        love.graphics.setLineStyle("rough")
        love.graphics.setLineJoin("miter")
    else
        love.graphics.setDefaultFilter("linear", "linear")
        love.graphics.setLineStyle("smooth")
        love.graphics.setLineJoin("miter")
    end

    local cam: CameraImpl = {
        x = 0,
        y = 0,
        targetX = 0,
        targetY = 0,
        lerpingEnabled = config.lerpingEnabled ~= false,  -- Default to true
        lerpSpeed = config.lerpSpeed or 8.0,
        virtualHeight = assert(config.height, "height is required for the camera"),
        minWidth = assert(config.minWidth, "minWidth is required for the camera"),
        maxWidth = config.maxWidth or -1,
        oversample = config.oversample or 1,
        scaleMode = scaleMode,
        zoom = 1,
        shadowShader = shader,
        defaultShadersList = {shader},
        visX1 = 0,
        visY1 = 0,
        visX2 = 0,
        visY2 = 0,
        visCenterX = 0,
        visCenterY = 0,
        visHalfWidth = 0,
        visHalfHeight = 0,
    }
    setmetatable(cam, CAMERA_MT)
    cam:setScreenSize(love.graphics.getWidth(), love.graphics.getHeight())
    -- updateVisibleCorners is called by updateZoomInfo in setScreenSize
    return cam
end

function CameraImpl:configureCanvas(canvas: love.graphics.Canvas)
    -- Apply filtering based on scale mode
    local texture = canvas as love.graphics.Texture
    if self.scaleMode == "pixel" then
        texture:setFilter("nearest", "nearest")
    else
        texture:setFilter("linear", "linear")
    end
end

function CameraImpl:setClamp(clamp: boolean)
    self.clamp = clamp
end

function CameraImpl:updateVisibleCorners()
    local hw, hh = self.halfWidth, self.halfHeight
    local x, y = self.x, self.y
    self.visX1 = x - hw
    self.visY1 = y - hh
    self.visX2 = x + hw
    self.visY2 = y + hh

    -- Cache center and half dimensions
    self.visCenterX = x
    self.visCenterY = y
    self.visHalfWidth = hw
    self.visHalfHeight = hh
end

function CameraImpl:setPosition(x: number, y: number)
    if self.clamp then
        -- Clamp camera center to prevent visible area from showing negative coordinates
        x, y = max(self.halfWidth, x), max(self.halfHeight, y)
    end
    if self.lerpingEnabled then
        self.targetX, self.targetY = x, y
    else
        self.x, self.y = x, y
        self.targetX, self.targetY = x, y
        self:updateVisibleCorners()
    end
end

function CameraImpl:teleport(x: number, y: number)
    if self.clamp then
        -- Clamp camera center to prevent visible area from showing negative coordinates
        x, y = max(self.halfWidth, x), max(self.halfHeight, y)
    end
    -- Always teleport immediately, regardless of lerping setting
    self.x, self.y = x, y
    self.targetX, self.targetY = x, y
    self:updateVisibleCorners()
end

function CameraImpl:getPosition(): number, number
    return self.x, self.y
end

function CameraImpl:updateZoomInfo()
    -- Divide here because the more you zoom in, the less is visible.
    self.zoomWidth = floor(self.virtualWidth / self.zoom)
    self.zoomHeight = floor(self.virtualHeight / self.zoom)
    self.halfWidth = floor(self.zoomWidth / 2)
    self.halfHeight = floor(self.zoomHeight / 2)
    self.zoomScale = self.zoom * self.virtualScale
    local x = floor(max(0, self.canvasCenterX - self.halfWidth))
    local y = floor(max(0, self.canvasCenterY - self.halfHeight))
    self.zoomQuad:setViewport(x - 1, y - 1, self.zoomWidth + 1, self.zoomHeight + 1)
    self:updateVisibleCorners()
end

function CameraImpl:getZoom(): number
    return self.zoom
end

function CameraImpl:setZoom(zoom: number)
    self.zoom = zoom
    self:updateZoomInfo()
end

function CameraImpl:setScreenSize(windowW: number, windowH: number)
    self.screenWidth, self.screenHeight = windowW, windowH

    -- Compute the virtual width based on the computed scale based on the height (we lock on height).
    self.virtualScale = windowH / self.virtualHeight
    self.virtualWidth = max(self.minWidth, floor(windowW / self.virtualScale))
    if self.maxWidth > 0 then
        self.virtualWidth = min(self.virtualWidth, self.maxWidth) -- clamp to max width if set
    end

    -- Compute the actual size of the virtual canvas in screen pixels.
    self.viewWidth, self.viewHeight = self.virtualWidth * self.virtualScale, self.virtualHeight * self.virtualScale
    local canvasWidth, canvasHeight = self.virtualWidth * self.oversample, self.virtualHeight * self.oversample
    self.canvas = love.graphics.newCanvas(canvasWidth, canvasHeight)
    self.canvasCenterX, self.canvasCenterY = floor(canvasWidth / 2), floor(canvasHeight / 2)
    self:configureCanvas(self.canvas)

    -- Letterboxing offsets.
    self.canvasOffsetX, self.canvasOffsetY = floor((windowW - self.viewWidth) / 2), floor((windowH - self.viewHeight) / 2)
    self.zoomQuad = love.graphics.newQuad(0, 0, self.virtualWidth + 2, self.virtualHeight + 2, canvasWidth, canvasHeight)

    -- Recreate lighting canvases and quads.
    self.lightCanvas = love.graphics.newCanvas(canvasWidth, canvasHeight)
    self.shadowShader:send("lightMap", self.lightCanvas as love.graphics.Texture)
    local lw, lh = (self.lightCanvas as love.graphics.Texture):getDimensions()
    self.shadowShader:send("lightMapInvSize", {1 / lw, 1 / lh})

    self.shaderQuad = love.graphics.newQuad(0, 0, 0, 0, canvasWidth, canvasHeight)
    self.shaderBuffers = {
        love.graphics.newCanvas(canvasWidth, canvasHeight),
        love.graphics.newCanvas(canvasWidth, canvasHeight)
    }
    -- Apply filtering to shader buffers too
    for _, buffer in ipairs(self.shaderBuffers) do
        self:configureCanvas(buffer)
    end
    self:updateZoomInfo()
end

function CameraImpl:toScreen(x: number, y: number): number, number
    local l, t = self:getVisibleCorners()
    return x - l, y - t
end

function CameraImpl:toWorld(x: number, y: number): number, number
    local l, t = self:getVisibleCorners()
    local scale = self.zoomScale
    local offX, offY = self.canvasOffsetX, self.canvasOffsetY

    -- Handle different scale modes
    if self.scaleMode == "none" then
        -- In 'none' mode, scale is always 1:1
        offX = floor((self.screenWidth - self.zoomWidth) / 2)
        offY = floor((self.screenHeight - self.zoomHeight) / 2)
        return x - offX + l, y - offY + t
    elseif self.scaleMode == "pixel" then
        -- In pixel mode, scale is floored
        scale = floor(self.zoomScale)
        if scale < 1 then scale = 1 end
        local pixelWidth = self.zoomWidth * scale
        local pixelHeight = self.zoomHeight * scale
        offX = floor((self.screenWidth - pixelWidth) / 2)
        offY = floor((self.screenHeight - pixelHeight) / 2)
        return (x - offX) / scale + l, (y - offY) / scale + t
    else
        -- Default aspect mode
        return (x - offX) / scale + l, (y - offY) / scale + t
    end
end

function CameraImpl:getVisibleDimensions(): number, number
    return self.zoomWidth, self.zoomHeight
end

function CameraImpl:getVisibleCanvasCorners(): number, number, number, number
    local cx, cy = self.canvasCenterX, self.canvasCenterY
    local x, y = self.x - cx, self.y - cy
    return x, y, x + cx, y + cy
end

function CameraImpl:getVisibleCorners(): number, number, number, number
    return self.visX1, self.visY1, self.visX2, self.visY2
end

function CameraImpl:isVisible(x: number, y: number, w: number, h: number): boolean
    -- Center-based culling (fewer branches than AABB)
    local hx, hy = w * 0.5, h * 0.5
    local cx, cy = x + hx, y + hy
    local dx, dy = abs(cx - self.visCenterX), abs(cy - self.visCenterY)
    return dx <= (hx + self.visHalfWidth) and dy <= (hy + self.visHalfHeight)
end

function CameraImpl:update(dt: number)
    if not self.lerpingEnabled then
        return
    end

    -- Apply exponential lerping for frame-rate independent smoothing
    local factor = 1 - exp(-self.lerpSpeed * dt)
    local dx = self.targetX - self.x
    local dy = self.targetY - self.y

    -- Snap to target if very close (avoid drift)
    if abs(dx) < 0.1 and abs(dy) < 0.1 then
        self.x = self.targetX
        self.y = self.targetY
    else
        self.x = self.x + dx * factor
        self.y = self.y + dy * factor
    end

    -- Update cached corners after position change
    self:updateVisibleCorners()
end

function CameraImpl:setLerpingEnabled(enabled: boolean)
    self.lerpingEnabled = enabled
    if not enabled then
        -- Snap to target immediately when disabling
        self.x = self.targetX
        self.y = self.targetY
        self:updateVisibleCorners()
    end
end

function CameraImpl:setLerpSpeed(speed: number)
    self.lerpSpeed = max(1, min(20, speed))
end

function CameraImpl:attach()
    assert(not self.renderState, "Cannot attach the camera while already drawing.")
    local currentCanvas = lg_getCanvas()
    local scissorX, scissorY, scissorWidth, scissorHeight = love.graphics.getScissor()
    local x, y = self.x - self.canvasCenterX, self.y - self.canvasCenterY

    local state = pool.acquireMap(7) as RenderState  -- 7 fields in RenderState
    state.currentCanvas = currentCanvas
    state.scissorX = scissorX
    state.scissorY = scissorY
    state.scissorWidth = scissorWidth
    state.scissorHeight = scissorHeight
    state.x = x
    state.y = y
    self.renderState = state

    love.graphics.translate(-floor(x), -floor(y))
    lg_setCanvas(self.canvas)
    lg_clear()
    love.graphics.setScissor(self.zoomQuad:getViewport())
end

-------------------------------------------------------------------------------
-- Item drawing and shader handling
-------------------------------------------------------------------------------

local function drawWithShaders(self: CameraImpl, drawId: integer, pipeline: types.Pipeline)
    -- Render an item with multiple shaders by rendering each to intermediate canvases.
    local currentCanvas = lg_getCanvas()
    local currentShader = lg_getShader()
    local primary, secondary = self.shaderBuffers[1], self.shaderBuffers[2]
    local f, args = pipeline:getDrawFunction(drawId)
    local shaders, _flags = pipeline:getDrawModifiers(drawId)

    local shaderCount = #shaders
    for i = 1, shaderCount do
        local shader = shaders[i]
        local isLast = i == shaderCount
        -- Set correct render target (last shader renders to screen)
        lg_setCanvas(isLast and currentCanvas or primary)
        -- Clear only when writing to an intermediate buffer
        if not isLast then
            lg_clear()
        end
        lg_setShader(shader)
        if i == 1 then
            -- First pass: Draw the actual content
            f(table.unpack(args))
        else
            -- Ensure screen-space alignment when drawing the buffer
            love.graphics.push()
            love.graphics.origin()
            lg_draw(secondary as love.graphics.Drawable, 0, 0)
            love.graphics.pop()
        end
        -- Swap buffers for next iteration
        primary, secondary = secondary, primary
    end

    lg_setCanvas(currentCanvas)
    lg_setShader(currentShader)
end

local function drawItem(self: CameraImpl, drawId: integer, pipeline: types.Pipeline)
    local f, args = pipeline:getDrawFunction(drawId)
    local shaders, flags = pipeline:getDrawModifiers(drawId)
    local needsShadow = band(flags, UNLIT_FLAG) == 0
    local shaderCount = #shaders
    if needsShadow then
        if shaderCount == 0 then
            -- Use default shadow shader
            if lg_getShader() ~= self.shadowShader then
                lg_setShader(self.shadowShader)
            end
            f(table.unpack(args))
            return
        else
            -- Add shadow shader to the list temporarily
            shaders[shaderCount + 1] = self.shadowShader
            shaderCount = shaderCount + 1
        end
    end

    if shaderCount == 0 then
        f(table.unpack(args))
    elseif shaderCount == 1 then
        local shader = shaders[1]
        if lg_getShader() ~= shader then
            lg_setShader(shader)
        end
        f(table.unpack(args))
    else
        drawWithShaders(self, drawId, pipeline)
    end

    -- Remove temporarily added shadow shader
    if needsShadow and #shaders > 0 then
        shaders[#shaders] = nil
    end
end

-------------------------------------------------------------------------------
-- Layer drawing
-------------------------------------------------------------------------------

-- Pre-existing functions that accept positional arguments (no allocations)
local function drawLayerLights(cam: CameraImpl, layer: types.Layer, pipeline: types.Pipeline)
    local lights = layer.lights
    local lightCount = #lights
    if lightCount > 0 then
        lg_setCanvas(cam.lightCanvas)
        if pipeline:isLightingEnabled() then
            lg_clear(pipeline:getAmbientLight())
        else
            -- Clear to white so that the light map shows everything as fully lit.
            lg_clear(1, 1, 1, 1)
        end
        lg_setColor(1, 1, 1, 1)
        lg_setBlendMode("add", "alphamultiply")
        for i = 1, lightCount do
            local drawId = lights[i]
            local x, y, w, h, f, args = pipeline:getDrawData(drawId)
            if cam:isVisible(x, y, w, h) then
                f(table.unpack(args))
            end
        end
        lg_setBlendMode("alpha", "alphamultiply")
    end
end

local function drawLayerRenders(cam: CameraImpl, layer: types.Layer, pipeline: types.Pipeline)
    lg_setCanvas(cam.canvas)
    local draws = layer.draws
    local drawCount = #draws
    for index = 1, drawCount do
        drawItem(cam, draws[index], pipeline)
    end
    if lg_getShader() then
        lg_setShader()
    end
end

function CameraImpl:drawLayer(layer: types.Layer, pipeline: types.Pipeline)
    if not layer.visible then
        return
    elseif layer.decorator then
        layer.decorator(self, layer, pipeline, drawLayerLights, drawLayerRenders)
    else
        drawLayerLights(self, layer, pipeline)
        drawLayerRenders(self, layer, pipeline)
    end
end

-------------------------------------------------------------------------------
-- Detach and screenshot handling
-------------------------------------------------------------------------------

function CameraImpl:detach(uiDraws: {integer}, pipeline: types.Pipeline, ...: function(love.graphics.Image))
    assert(self.renderState, "Cannot detach the camera while not drawing.")
    local state = self.renderState
    self.renderState = nil

    love.graphics.setScissor(state.scissorX, state.scissorY, state.scissorWidth, state.scissorHeight)
    love.graphics.translate(floor(state.x), floor(state.y))
    lg_setCanvas(state.currentCanvas)

    local smoothX, smoothY <const> = floor(state.x + 0.5) - state.x, floor(state.y + 0.5) - state.y
    local vx, vy = self.canvasOffsetX - smoothX, self.canvasOffsetY - smoothY
    local finalScale = self.zoomScale

    -- Apply scaling mode
    if self.scaleMode == "pixel" then
        -- Integer scaling only
        finalScale = floor(self.zoomScale)
        if finalScale < 1 then finalScale = 1 end

        -- Recalculate offsets for pixel-perfect centering
        local pixelWidth = self.zoomWidth * finalScale
        local pixelHeight = self.zoomHeight * finalScale
        vx = floor((self.screenWidth - pixelWidth) / 2)
        vy = floor((self.screenHeight - pixelHeight) / 2)

    elseif self.scaleMode == "none" then
        -- 1:1 rendering, centered
        finalScale = 1
        vx = floor((self.screenWidth - self.zoomWidth) / 2)
        vy = floor((self.screenHeight - self.zoomHeight) / 2)
    end
    -- else aspect mode uses default behavior

    lg_draw(self.canvas as love.graphics.Texture, self.zoomQuad, vx, vy, 0, finalScale, finalScale)

    -- Draw UI elements using absolute positioning (no scaling)
    if #uiDraws > 0 then
        for i = 1, #uiDraws do
            local drawId = uiDraws[i]
            local f, args = pipeline:getDrawFunction(drawId)
            f(table.unpack(args))
        end
    end

    if select("#", ...) > 0 then
        self:captureScreenshots(smoothX, smoothY, state.currentCanvas, ...)
    end

    -- Release the render state back to the pool
    pool.releaseMap(state)
end

function CameraImpl:captureScreenshots(smoothX: number, smoothY: number, currentCanvas: love.graphics.Canvas, ...: function(love.graphics.Image))
    local c = love.graphics.newCanvas(self.virtualWidth, self.virtualHeight)
    lg_setCanvas(c)
    local q = love.graphics.newQuad(
        self.canvasCenterX - (self.virtualWidth / 2) - 1,
        self.canvasCenterY - (self.virtualHeight / 2) - 1,
        self.virtualWidth + 1,
        self.virtualHeight + 1,
        self.canvasCenterX * 2,
        self.canvasCenterY * 2
    )
    lg_draw(self.canvas as love.graphics.Texture, q, smoothX, smoothY)
    lg_setCanvas(currentCanvas)
    local image = love.graphics.newImage(c:newImageData())

    for i = 1, select("#", ...) do
        select(i, ...)(image)
    end
end

return camera