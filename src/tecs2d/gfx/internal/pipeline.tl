--- GPU-accelerated render pipeline for tecs.
--- Primary rendering uses GPU instanced draws with depth buffer sorting.
--- CPU draw queue supports love.graphics.* calls (text, custom draws) with proper depth interleaving.

local tecs <const> = require("tecs")
local types <const> = require("tecs2d.gfx.types")
local levents <const> = require("tecs2d.events")

local gpuModule <const> = require("tecs2d.gfx.internal.gpu")
local gpuTypes <const> = require("tecs2d.gfx.internal.gpu.types")
local gpuShaders <const> = require("tecs2d.gfx.internal.gpu.shaders")
local phases <const> = tecs.phases
local layerEffects <const> = require("tecs2d.gfx.internal.layer_effects")
local Camera <const> = require("tecs2d.gfx.Camera")
local sprite_sheet <const> = require("tecs2d.gfx.internal.sprite.sheet")
local bit <const> = require("bit")

local lg <const> = love.graphics
local floor <const> = math.floor
local max <const> = math.max

-- `jit.zone` has no Teal type declarations; go through an opaque require.
local function loadUntyped(modName: string): any
    return require(modName)
end
local zone = loadUntyped("jit.zone") as function(?string): string
local min <const> = math.min
local clamp <const> = function(v: number, lo: number, hi: number): number
    return max(lo, min(hi, v))
end

local function setOrthographic(t: love.math.Transform, camX: number, camY: number,
        zoom: number, rotation: number, w: number, h: number, spX: number, spY: number)
    t:reset()
    t:translate(w / 2 + spX, h / 2 + spY)
    t:rotate(rotation)
    t:scale(zoom, zoom)
    t:translate(-camX, -camY)
end

local MAX_LAYERS <const> = 16
local MAX_Z <const> = 1000
local MAX_Y <const> = 100000

-- Sort mode constants (must match GPU shader)
local SORT_MODE_Z <const> = 1
local SORT_MODE_ISOMETRIC <const> = 2

-- Sort mode lookup tables
local SORT_MODE_TO_INT <const>: {types.SortMode: integer} = {
    ["topdown"] = 0,
    ["z"] = 1,
    ["isometric"] = 2,
}
local SORT_MODE_FROM_INT <const>: {integer: types.SortMode} = {
    [0] = "topdown",
    [1] = "z",
    [2] = "isometric",
}

--- Compute depth value for sorting (matches GPU shader formula).
--- Lower depth = further back in scene.
--- @param layer Layer number (1-16)
--- @param z Z-index within layer
--- @param x X coordinate (used for isometric sort mode)
--- @param bottomY Bottom Y coordinate of the entity
--- @param sortMode Sort mode (0=topdown, 1=z, 2=isometric)
--- @return Depth value in range [0, 1]
local function computeDepth(layer: number, z: number, x: number, bottomY: number, sortMode: integer): number
    local layerBandSize = 1.0 / MAX_LAYERS
    local layerBase = (MAX_LAYERS - layer) * layerBandSize

    local withinBand: number
    if sortMode == SORT_MODE_Z then
        -- Z-only: sort purely by z-index
        withinBand = (1.0 - z / MAX_Z) * layerBandSize * 0.99
    elseif sortMode == SORT_MODE_ISOMETRIC then
        -- Isometric: sort by X + Y + Z
        local normalizedX = (x + MAX_Y) / (2.0 * MAX_Y)
        local normalizedY = (bottomY + MAX_Y) / (2.0 * MAX_Y)
        local isoValue = normalizedX + normalizedY + z / MAX_Z
        withinBand = (1.0 - clamp(isoValue / 3.0, 0.0, 1.0)) * layerBandSize * 0.99
    else
        -- TopDown (default): Y-sort with Z for explicit ordering
        local normalizedY = (bottomY + MAX_Y) / (2.0 * MAX_Y)
        withinBand = (1.0 - (z / MAX_Z * 0.7 + normalizedY * 0.3)) * layerBandSize * 0.99
    end

    return clamp(layerBase + withinBand, 0.001, 0.999)
end

--- The pipeline module provides a GPU-accelerated render pipeline.
local record pipeline
    --- The key to use for storing the pipeline in world resources
    _contextKey: tecs.Key<Pipeline>

    --- Create a new render pipeline.
    newPipeline: function(config: RenderConfig): Pipeline

    --- Create a new render pipeline as a plugin.
    newPlugin: function(config: RenderConfig): tecs.Plugin

    --- The configuration of a render pipeline.
    record RenderConfig
        --- The world to attach the pipeline to.
        world: tecs.World

        --- Virtual resolution height. In retro mode, determines the integer scale factor
        --- (intScale = floor(screenH / virtualH)) and vertical field of view. In non-retro
        --- modes, controls the camera's world-to-screen zoom ratio. Defaults to window height.
        virtualHeight: integer

        --- Optional fixed virtual width. In retro mode with nil, auto-computed to fill screen
        --- width at the integer scale factor (floor(screenW / intScale)). In non-retro modes
        --- with nil, computed from virtualHeight and aspect ratio.
        virtualWidth: integer

        --- Retro rendering: true = low-res + nearest-neighbor upscale. Default: false.
        pixelMode: boolean

        --- When true, SDF shapes (circle, rectangle, ellipse, arc, line) render
        --- with hard pixel edges instead of anti-aliased SDFs. Independent of
        --- `pixelMode`. Default: false.
        roughGeometry: boolean

        --- Lighting mode: "none" or "deferred". Defaults to "deferred".
        lightingMode: string

        --- Enable shadows. Defaults to true.
        shadowsEnabled: boolean

        --- Initial GPU buffer capacity hints, keyed by name. Grows automatically.
        --- Built-in keys and defaults: sprites=4096, circles=4096, ellipses=4096,
        --- arcs=4096, lines=4096, rects=4096, lights=256, tilechunks=256,
        --- textEntities=1024, textGlyphs=16384.
        --- Custom shape plugins can use any string key.
        sizeHints: {string: integer}

        --- The ambient light color as RGB. Defaults to {1.0, 1.0, 1.0} (full brightness).
        ambientLight: {number, number, number}

        --- Enable smooth camera movement via lerping. Defaults to true.
        lerpingEnabled: boolean

        --- Lerp speed factor (higher = snappier). Defaults to 8.
        lerpSpeed: number

        --- Initial camera position {x, y}. Defaults to {0, 0}.
        cameraPosition: {number, number}

        --- Initial zoom level. Defaults to 1.0.
        zoom: number

        --- Clamp camera to world bounds. Defaults to false.
        clampToBounds: boolean

        --- World bounds for clamping {minX, minY, maxX, maxY}.
        worldBounds: {number, number, number, number}

        --- Layer configurations, keyed by layer number (1-16).
        layers: {integer: types.LayerConfig}

        --- Drop shadow AO canvas resolution scale (0.5 = half res, 1.0 = full res).
        --- Lower values reduce fill-rate cost; bilinear filtering smooths the result.
        --- Default: 0.5
        dropShadowScale: number

        --- Bloom post-processing configuration.
        bloom: types.BloomConfig

    end

    --- Type alias for the render pipeline interface.
    type Pipeline = types.Pipeline

    --- Type alias for a layer.
    type Layer = types.Layer
end

-------------------------------------------------------------------------------
-- Pipeline implementation
-------------------------------------------------------------------------------

local type Pipeline = types.Pipeline

local record PipelineImpl is Pipeline
    world: tecs.World
    renderer: gpuTypes.Renderer

    -- Multi-camera
    _cameras: {Camera}                -- Ordered list (registration order = render order)
    _camerasByName: {string: Camera}  -- Name lookup
    _primaryCamera: Camera            -- Always _cameras[1]
    _renderCamera: Camera             -- Set during active render pass (for gBufferCallback)

    -- Virtual resolution
    virtualWidth: integer
    virtualHeight: integer
    screenWidth: integer
    screenHeight: integer

    -- Rendering settings
    pixelMode: boolean
    roughGeometry: boolean
    lightingMode: string
    shadowsEnabled: boolean
    ambientLight: {number, number, number}
    scaledWidth: integer
    scaledHeight: integer
    _firstScreenLayer: integer  -- 0 = no screen layers

    -- Integer scaling for retro mode
    _integerScaling: boolean
    _intScale: integer       -- integer multiplier (e.g., 2 = 2x upscale)
    _intOffsetX: integer     -- horizontal letterbox offset in pixels
    _intOffsetY: integer     -- vertical letterbox offset in pixels

    -- Layer configuration
    layers: {types.Layer}
    layerNames: {string: integer}
    screenSpaceMask: integer   -- Bitmask: bit N = layer N+1 is screen-space
    ignoreZoomMask: integer    -- Bitmask: bit N = layer N+1 ignores zoom
    virtualCoordsMask: integer -- Bitmask: bit N = layer N+1 uses virtual coordinates
    unlitMask: integer         -- Bitmask: bit N = layer N+1 is unlit (no lighting)
    parallaxX: {number}        -- Per-layer horizontal parallax factor (1.0 = normal)
    parallaxY: {number}        -- Per-layer vertical parallax factor (1.0 = normal)
    sortModes: {integer}       -- Per-layer sort mode (0=topdown, 1=z, 2=isometric)

    -- Time tracking for animations
    gameTime: number      -- Accumulated game time (respects time scale)
    timeScale: number     -- Time scale multiplier (1.0 = normal)

    -- CPU world shader for Draw phase (full G-buffer MRT output)
    cpuWorldShader: love.graphics.Shader
    cpuWorldShaderActive: boolean

    -- Draw phase state (set during G-buffer rendering for systems in Draw phase)
    drawActive: boolean
    drawCamX: number
    drawCamY: number
    drawZoom: number
    drawRW: number
    drawRH: number

    -- G-buffer callback (created once to avoid per-frame closure allocation)
    _gBufferCallback: function(number, number, number, number, number)

    -- Fluent world shader state (pre-allocated, reused)
    _worldShaderState: types.WorldShaderState

    -- Layer effects manager
    layerEffectsManager: layerEffects.Manager

    -- Current layer range being rendered (for CPU draw filtering)
    currentLayerMin: integer
    currentLayerMax: integer

    -- Shared screen-sized intermediate canvas for secondary camera rendering
    _secondaryCanvas: love.graphics.Canvas

    -- Screen-phase lit canvas (native resolution, for compositing screen layers)
    _screenLitCanvas: love.graphics.Canvas

    -- Recompute scaled dimensions for current pixel mode and screen size
    _recomputeScaledDims: function(PipelineImpl)

    -- Ensure worldLitCanvas matches current G-buffer dimensions
    _ensureWorldLitCanvas: function(PipelineImpl)

    -- Validate layer ordering (screen layers must come after all world/virtual layers)
    _validateLayerOrdering: function(PipelineImpl)

    -- Update camera render dimensions for bounds/clamping in retro mode
    _updateCameraRenderDims: function(PipelineImpl)

    -- Multi-pass rendering with layer effects
    renderWithLayerEffects: function(PipelineImpl, camX: number, camY: number, renderZoom: number, useLowRes: boolean, globalTime: number, rotation: number, subPixelX: number, subPixelY: number)

    -- Primary camera render (supports pixel modes and layer effects)
    _renderPrimary: function(PipelineImpl, cam: Camera, globalTime: number)

    -- Secondary camera render (single-pass, viewport-based)
    _renderSecondary: function(PipelineImpl, cam: Camera, globalTime: number)
end

local PIPELINE_MT <const>: metatable<PipelineImpl> = {
    __index = PipelineImpl
}

function PipelineImpl:_recomputeScaledDims()
    if self.pixelMode then
        -- Integer scale factor from height (the constraining axis)
        local intScale = max(1, floor(self.screenHeight / self.virtualHeight)) as integer
        -- Fill screen width at this scale: minimizes horizontal letterboxing
        self.scaledWidth = max(1, floor(self.screenWidth / intScale)) as integer
        self.scaledHeight = self.virtualHeight
        -- Update virtualWidth to match so camera FOV fills the screen
        self.virtualWidth = self.scaledWidth
        self.renderer.config.virtualRes = {self.scaledWidth, self.scaledHeight}
        self._integerScaling = true
        self._intScale = intScale
        self._intOffsetX = floor((self.screenWidth - self.scaledWidth * intScale) / 2) as integer
        self._intOffsetY = floor((self.screenHeight - self.scaledHeight * intScale) / 2) as integer
    else
        self.scaledWidth = self.screenWidth
        self.scaledHeight = self.screenHeight
        self._integerScaling = false
    end
end

function PipelineImpl:_ensureWorldLitCanvas()
    -- worldLitCanvas must match the G-buffer dimensions used for world-phase rendering.
    -- In retro mode that's pixelAlbedo; otherwise gBufferAlbedo.
    local r = self.renderer
    local isRetro = (self.pixelMode)
    local expectedW = isRetro and r.pixelAlbedo:getWidth() or r.gBufferAlbedo:getWidth()
    local expectedH = isRetro and r.pixelAlbedo:getHeight() or r.gBufferAlbedo:getHeight()
    if r.worldLitCanvas
        and r.worldLitCanvas:getWidth() == expectedW
        and r.worldLitCanvas:getHeight() == expectedH then
        return
    end
    r.worldLitCanvas = lg.newCanvas(expectedW, expectedH, {format = "rgba8"})
    if isRetro then
        r.worldLitCanvas:setFilter("nearest", "nearest")
    else
        r.worldLitCanvas:setFilter("linear", "linear")
    end
end

function PipelineImpl:_validateLayerOrdering()
    -- Scan configured layers only. Screen layers must come after all world/virtual layers.
    -- Track _firstScreenLayer (0 = no screen layers).
    local firstScreen = 0
    local lastWorld = 0
    for i = 1, MAX_LAYERS do
        local l = self.layers[i]
        if l.name then
            if l.space == "screen" then
                if firstScreen == 0 then
                    firstScreen = i
                end
            else
                lastWorld = i
            end
        end
    end
    if firstScreen > 0 and lastWorld > firstScreen then
        error("Screen-space layer " .. firstScreen .. " must come after all world/virtual layers (world layer " .. lastWorld .. " has higher index)")
    end
    self._firstScreenLayer = firstScreen
end

-- Forward-declare WorldShaderState metatable (methods added later in the file)
local WorldShaderState <const> = types.WorldShaderState
local WS_MT <const>: metatable<types.WorldShaderState> = {
    __index = WorldShaderState
}

function pipeline.newPipeline(config: pipeline.RenderConfig): Pipeline
    local w = assert(config.world, "Missing required 'world' for render pipeline")

    -- Compute virtual dimensions
    local screenWidth = lg.getWidth() as integer
    local screenHeight = lg.getHeight() as integer
    local virtualHeight = config.virtualHeight or screenHeight
    local virtualWidth = config.virtualWidth
    if not virtualWidth then
        virtualWidth = floor(virtualHeight * screenWidth / screenHeight) as integer
    end

    local renderer = gpuModule.new({
        sizeHints = config.sizeHints,
        maxLayers = MAX_LAYERS,
        maxZ = 1000,
        maxY = 100000,
        virtualRes = {virtualWidth, virtualHeight},
        dropShadowScale = config.dropShadowScale,
    })
    renderer._roughGeometry = config.roughGeometry == true

    -- Create primary camera
    local cam = Camera.new({
        screenWidth = screenWidth,
        screenHeight = screenHeight,
        virtualHeight = virtualHeight,
        layerMask = 0xFFFF,
        lerpingEnabled = config.lerpingEnabled ~= false,
        lerpSpeed = config.lerpSpeed or 8.0,
        position = config.cameraPosition,
        zoom = config.zoom or 1.0,
        name = "__primary",
    })
    cam.clampToBounds = config.clampToBounds or false
    cam.worldBounds = config.worldBounds
    if cam.clampToBounds and cam.worldBounds then
        cam:updateBounds()
    end

    local self: PipelineImpl = {
        world = w,
        renderer = renderer,

        -- Multi-camera
        _cameras = { cam },
        _camerasByName = { ["__primary"] = cam },
        _primaryCamera = cam,
        _renderCamera = cam,

        -- Virtual resolution
        virtualWidth = virtualWidth,
        virtualHeight = virtualHeight,
        screenWidth = screenWidth,
        screenHeight = screenHeight,

        -- Rendering settings
        pixelMode = config.pixelMode == true,
        roughGeometry = config.roughGeometry == true,
        lightingMode = config.lightingMode or "deferred",
        shadowsEnabled = config.shadowsEnabled ~= false,
        ambientLight = config.ambientLight or {1.0, 1.0, 1.0},
        scaledWidth = 0,   -- computed by _recomputeScaledDims
        scaledHeight = 0,  -- computed by _recomputeScaledDims
        _firstScreenLayer = 0,  -- 0 = no screen layers

        -- Layers
        layers = {},
        layerNames = {},
        screenSpaceMask = 0,
        ignoreZoomMask = 0,
        virtualCoordsMask = 0,
        unlitMask = 0,
        parallaxX = {},
        parallaxY = {},
        sortModes = {},

        -- Time tracking
        gameTime = 0.0,
        timeScale = 1.0,

        -- Layer range for current render pass (CPU draw filtering)
        currentLayerMin = 1,
        currentLayerMax = MAX_LAYERS,

        -- Draw phase state
        drawActive = false,
        drawCamX = 0,
        drawCamY = 0,
        drawZoom = 1,
        drawRW = 0,
        drawRH = 0,
    }

    -- Apply bloom config if provided
    if config.bloom then
        local b = config.bloom
        local rb = renderer.bloom
        if b.enabled ~= nil then rb.enabled = b.enabled end
        if b.intensity ~= nil then rb.intensity = b.intensity end
        if b.radius ~= nil then rb.radius = b.radius end
        if b.threshold ~= nil then rb.threshold = b.threshold end
    end

    -- Create CPU world shader for Draw phase (G-buffer MRT output)
    self.cpuWorldShader = lg.newShader(gpuShaders.CPU_WORLD)
    self.cpuWorldShaderActive = false

    -- Pre-allocate world shader state for fluent API
    self._worldShaderState = setmetatable({
        _pipeline = self,
        _layer = 1, _z = 0, _x = 0, _bottomY = 0,
        _isUnlit = false, _shader = nil, _normalMap = nil,
    } as types.WorldShaderState, WS_MT)

    -- Create G-buffer callback once (avoid per-frame closure allocation)
    self._gBufferCallback = function(effCamX: number, effCamY: number, zoom: number, rw: number, rh: number)
        -- Run Draw phase for CPU draws that need depth interleaving
        -- Set up state for depth shader methods
        self.drawActive = true
        self.drawCamX = effCamX
        self.drawCamY = effCamY
        self.drawZoom = zoom
        self.drawRW = rw
        self.drawRH = rh

        -- Enable depth mode for Draw phase draws
        lg.setDepthMode("lequal", true)

        -- Apply camera transform (same as renderGBufferDraws)
        local screenHalfX = rw * 0.5
        local screenHalfY = rh * 0.5
        lg.push()
        lg.translate(screenHalfX, screenHalfY)
        lg.rotate(-self._renderCamera._renderRotation)
        lg.scale(zoom, zoom)
        lg.translate(-effCamX, -effCamY)

        -- Run the Draw phase
        self.world:runPhase(phases.Draw, 0)

        -- Clean up
        lg.pop()
        lg.setDepthMode()
        lg.setShader()
        self.drawActive = false
    end

    -- Initialize layers
    for i = 1, MAX_LAYERS do
        self.layers[i] = {layer = i, draws = {}, lights = {}, visible = true, space = "world"}
        self.parallaxX[i] = 1.0
        self.parallaxY[i] = 1.0
        self.sortModes[i] = 0  -- 0 = topdown (default)
    end

    -- Layer effects manager
    self.layerEffectsManager = layerEffects.new(MAX_LAYERS, screenWidth, screenHeight)

    local pipelineInstance = setmetatable(self, PIPELINE_MT) as Pipeline

    -- Compute scaled dimensions and allocate worldLitCanvas.
    -- _recomputeScaledDims may update virtualWidth (retro integer scaling fills screen width),
    -- so re-resize the renderer to pick up the new virtualRes.
    local pImpl = pipelineInstance as PipelineImpl
    pImpl:_recomputeScaledDims()
    renderer:resize(screenWidth, screenHeight)
    pImpl:_ensureWorldLitCanvas()
    pImpl._screenLitCanvas = lg.newCanvas(screenWidth, screenHeight, {format = "rgba8"})
    pImpl:_updateCameraRenderDims()

    -- Apply layer configurations from config
    if config.layers then
        for layerNum, layerConfig in pairs(config.layers) do
            pipelineInstance:configureLayer(layerNum, layerConfig)
        end
    end

    -- Register Draw phase with the world's pipeline
    w:registerPhase(phases.Draw)

    -- Register pipeline with world
    w.resources[pipeline._contextKey] = pipelineInstance

    -- Persist camera view state (position, zoom, rotation, bounds) across
    -- snapshots. The camera is a pipeline resource, so it lives outside the
    -- ECS and the core snapshot never sees it. Cameras are matched by name on
    -- restore: the primary and any cameras recreated during setup get their
    -- state written back; a camera created dynamically at runtime that no
    -- longer exists on a fresh-process load is skipped.
    w:addSnapshotHandler({
        name = "tecs2d.render.cameras",
        save = function(_world: tecs.World): any
            local cams: {{string: any}} = {}
            for i = 1, #self._cameras do
                cams[i] = self._cameras[i]:captureState()
            end
            return { cameras = cams }
        end,
        load = function(_world: tecs.World, value: any)
            local data = value as {string: any}
            local cams = data.cameras as {{string: any}}
            if not cams then return end
            for i = 1, #cams do
                local cs = cams[i]
                local name = cs.name as string
                local namedCam = name and self._camerasByName[name]
                if namedCam then namedCam:applyState(cs) end
            end
        end,
    })

    -- Camera lerp update: delegates to Camera:update(dt) for all cameras
    w:addSystem({
        name = "CameraLerpUpdate",
        phase = tecs.phases.Update,
        run = function(dt: number)
            for _, c in ipairs(self._cameras) do
                if c:isActive() then
                    c:update(dt)
                end
            end
        end
    })

    -- Render system (Render phase so UI overlays can draw in PostRender/RenderLast)
    w:addSystem({
        name = "GPURender",
        phase = tecs.phases.Render,
        run = function(_dt: number)
            pipelineInstance:render()
        end
    })

    -- Resize handler
    w:observe(0, levents.Resize, function(e: levents.Resize)
        self.screenWidth = e.width as integer
        self.screenHeight = e.height as integer
        -- Recalculate virtual width to match new aspect ratio
        self.virtualWidth = floor(self.virtualHeight * self.screenWidth / self.screenHeight) as integer
        self.renderer.config.virtualRes = {self.virtualWidth, self.virtualHeight}
        pImpl:_recomputeScaledDims()
        self.renderer:resize(self.screenWidth, self.screenHeight)
        pImpl:_ensureWorldLitCanvas()
        pImpl._screenLitCanvas = lg.newCanvas(self.screenWidth, self.screenHeight, {format = "rgba8"})
        self.layerEffectsManager:resize(pImpl.scaledWidth, pImpl.scaledHeight)
        self.layerEffectsManager:resizeScreen(self.screenWidth, self.screenHeight)
        -- Primary camera always fullscreen
        self._primaryCamera:setScreenSize(self.screenWidth, self.screenHeight, self.virtualHeight)
        pImpl:_updateCameraRenderDims()
        -- Secondary cameras keep their viewport size; users manage viewport resize
    end)

    return pipelineInstance
end

-------------------------------------------------------------------------------
-- Camera access
-------------------------------------------------------------------------------

function PipelineImpl:newCamera(name: string, config?: Camera.CameraConfig): Camera
    assert(name, "Camera name is required")
    assert(not self._camerasByName[name], "Camera already exists: " .. name)

    local camConfig: Camera.CameraConfig = config or {} as Camera.CameraConfig
    camConfig.name = name
    -- Default to current screen/virtual dimensions
    if not camConfig.screenWidth then
        camConfig.screenWidth = self.screenWidth
    end
    if not camConfig.screenHeight then
        camConfig.screenHeight = self.screenHeight
    end
    if not camConfig.virtualHeight then
        camConfig.virtualHeight = self.virtualHeight
    end

    local cam = Camera.new(camConfig)
    self._cameras[#self._cameras + 1] = cam
    self._camerasByName[name] = cam
    return cam
end

function PipelineImpl:getCamera(name?: string): Camera
    if not name then
        return self._primaryCamera
    end
    return self._camerasByName[name]
end

function PipelineImpl:removeCamera(name: string)
    assert(name ~= "__primary", "Cannot remove the primary camera")
    local cam = self._camerasByName[name]
    if not cam then return end

    self._camerasByName[name] = nil

    -- Remove from ordered list
    for i = 1, #self._cameras do
        if self._cameras[i] == cam then
            table.remove(self._cameras, i)
            break
        end
    end
end

function PipelineImpl:setPixelMode(mode: boolean)
    self.pixelMode = mode
    -- Reset virtualWidth from aspect ratio; retro will override in _recomputeScaledDims
    self.virtualWidth = floor(self.virtualHeight * self.screenWidth / self.screenHeight) as integer
    self.renderer.config.virtualRes = {self.virtualWidth, self.virtualHeight}
    self:_recomputeScaledDims()
    -- Recreate canvases at the updated virtualRes (pixel canvases change size)
    self.renderer:resize(self.screenWidth, self.screenHeight)
    self:_ensureWorldLitCanvas()
    self:_updateCameraRenderDims()
end

--- Update camera render dimensions to match the actual rendering resolution.
--- In retro mode, bounds/clamping use scaled (virtual) dims; otherwise screen dims.
function PipelineImpl:_updateCameraRenderDims()
    local cam = self._primaryCamera
    if self.pixelMode then
        cam._renderWidth = self.scaledWidth
        cam._renderHeight = self.scaledHeight
    else
        cam._renderWidth = self.screenWidth
        cam._renderHeight = self.screenHeight
    end
end

function PipelineImpl:setRoughGeometry(mode: boolean)
    self.roughGeometry = mode
    self.renderer._roughGeometry = mode
end

function PipelineImpl:getRoughGeometry(): boolean
    return self.roughGeometry
end

function PipelineImpl:getPixelMode(): boolean
    return self.pixelMode
end


function PipelineImpl:setTimeScale(scale: number)
    self.timeScale = max(0.0, min(10.0, scale))
end

function PipelineImpl:getTimeScale(): number
    return self.timeScale
end

function PipelineImpl:getGameTime(): number
    return self.gameTime
end

function PipelineImpl:getTime(): number
    return self.gameTime
end

-------------------------------------------------------------------------------
-- Lighting interface
-------------------------------------------------------------------------------

function PipelineImpl:isLightingEnabled(): boolean
    return self.lightingMode ~= "none"
end

function PipelineImpl:enableLighting()
    self.lightingMode = "deferred"
end

function PipelineImpl:disableLighting()
    self.lightingMode = "none"
end

function PipelineImpl:setAmbientLight(r: number, g: number, b: number)
    self.ambientLight = {r, g, b}
end

function PipelineImpl:getAmbientLight(): number, number, number
    return self.ambientLight[1], self.ambientLight[2], self.ambientLight[3]
end

function PipelineImpl:setBloom(config: types.BloomConfig)
    local b = self.renderer.bloom
    if config.enabled ~= nil then b.enabled = config.enabled end
    if config.intensity ~= nil then b.intensity = config.intensity end
    if config.radius ~= nil then b.radius = config.radius end
    if config.threshold ~= nil then b.threshold = config.threshold end
end

function PipelineImpl:getBloom(): types.BloomConfig
    return self.renderer.bloom
end

-------------------------------------------------------------------------------
-- Light cookie (gobo) registration
-------------------------------------------------------------------------------

local COOKIE_ARRAY_SIZE <const> = 256
local COOKIE_MAX_LAYERS <const> = 64

function PipelineImpl:registerCookie(name: string, spriteSheet: any, tag?: string): integer
    local r = self.renderer
    local ss = spriteSheet as sprite_sheet.SpriteSheet

    -- Validate name uniqueness
    if r._cookieNameToId and r._cookieNameToId[name] then
        error("Cookie already registered: " .. name)
    end

    -- Initialize registry tables on first use
    if not r._cookieRegistry then
        r._cookieRegistry = {}
        r._cookieNameToId = {}
        r._cookieNextLayer = 0
    end

    -- Determine frames to upload
    local frameTag = ss:getFrameTag(tag or "")
    local frameFrom = frameTag.from
    local frameTo = frameTag.to
    local frameCount = frameTo - frameFrom + 1

    -- Check layer budget
    if r._cookieNextLayer + frameCount > COOKIE_MAX_LAYERS then
        error("Cookie array full: need " .. frameCount .. " layers, " .. (COOKIE_MAX_LAYERS - r._cookieNextLayer) .. " remaining")
    end

    -- Lazily allocate the array texture on first registration
    if not r.cookieTextureArray then
        r.cookieTextureArray = lg.newCanvas(COOKIE_ARRAY_SIZE, COOKIE_ARRAY_SIZE, COOKIE_MAX_LAYERS, {
            type = "array",
            format = "rgba8",
        })
    end

    local baseSlice = r._cookieNextLayer
    local image = ss:getImage()
    local spriteW, spriteH = ss:getSpriteSize()
    local scaleX = COOKIE_ARRAY_SIZE / spriteW
    local scaleY = COOKIE_ARRAY_SIZE / spriteH

    -- Upload each frame as a layer in the array texture
    local drawFn = lg.draw as function(any, any, number, number, number, number, number)
    for f = frameFrom, frameTo do
        local layerIdx = baseSlice + (f - frameFrom)
        local quad = ss:getQuad(f)
        lg.setCanvas(r.cookieTextureArray as love.graphics.Canvas, layerIdx + 1)
        lg.clear(0, 0, 0, 0)
        lg.setBlendMode("replace")
        drawFn(image, quad, 0, 0, 0, scaleX, scaleY)
        lg.setBlendMode("alpha")
        lg.setCanvas()
    end

    r._cookieNextLayer = r._cookieNextLayer + frameCount

    -- Register cookie data
    local cookieId = #r._cookieRegistry + 1
    local cookieData: gpuTypes.CookieData = {
        name = name,
        baseSlice = baseSlice,
        frameCount = frameCount,
        tagName = tag or "",
        sheet = ss,
    }
    r._cookieRegistry[cookieId] = cookieData
    r._cookieNameToId[name] = cookieId

    return cookieId
end

function PipelineImpl:getCookie(name: string): integer
    local nameToId = self.renderer._cookieNameToId
    if nameToId then
        return nameToId[name] or 0
    end
    return 0
end

function PipelineImpl:getCookieName(id: integer): string
    local registry = self.renderer._cookieRegistry
    if registry and registry[id] then
        return registry[id].name
    end
    return nil
end

-------------------------------------------------------------------------------
-- GPU renderer access
-------------------------------------------------------------------------------

function PipelineImpl:registerPlugin(plugin: types.RenderPlugin)
    self.renderer:registerPlugin(plugin as gpuTypes.RenderPlugin)
end

function PipelineImpl:getRenderer(): any
    return self.renderer
end

-------------------------------------------------------------------------------
-- Layer management
-------------------------------------------------------------------------------

function PipelineImpl:configureLayer(layer: integer, config: types.LayerConfig)
    if layer < 1 or layer > MAX_LAYERS then
        error("Layer must be between 1 and " .. MAX_LAYERS)
    end
    local l = self.layers[layer]

    -- Handle name
    if config.name then
        if l.name then
            self.layerNames[l.name] = nil
        end
        self.layerNames[config.name] = layer
        l.name = config.name
    end

    -- Handle visibility
    if config.visible ~= nil then
        l.visible = config.visible
    end

    -- Handle space (defaults to "world")
    local space = config.space or "world"
    if space ~= "world" and space ~= "virtual" and space ~= "screen" then
        error("LayerConfig.space must be 'world', 'virtual', or 'screen'; got '" .. tostring(space) .. "'")
    end
    l.space = space

    -- Compute bitmasks from space enum
    -- "world": not screen-space, respects zoom, world coordinates
    -- "virtual": screen-space, ignores zoom, virtual coordinates
    -- "screen": screen-space, ignores zoom, screen pixel coordinates
    local bitIndex = layer - 1
    local bitMask = bit.lshift(1, bitIndex)
    local notBitMask = bit.bnot(bitMask)

    if space == "world" then
        self.screenSpaceMask = bit.band(self.screenSpaceMask, notBitMask)
        self.ignoreZoomMask = bit.band(self.ignoreZoomMask, notBitMask)
        self.virtualCoordsMask = bit.band(self.virtualCoordsMask, notBitMask)
    elseif space == "virtual" then
        self.screenSpaceMask = bit.bor(self.screenSpaceMask, bitMask)
        self.ignoreZoomMask = bit.bor(self.ignoreZoomMask, bitMask)
        self.virtualCoordsMask = bit.bor(self.virtualCoordsMask, bitMask)
    elseif space == "screen" then
        self.screenSpaceMask = bit.bor(self.screenSpaceMask, bitMask)
        self.ignoreZoomMask = bit.bor(self.ignoreZoomMask, bitMask)
        self.virtualCoordsMask = bit.band(self.virtualCoordsMask, notBitMask)
    end

    -- Screen layers are always unlit (world-space lighting is meaningless)
    if space == "screen" then
        self.unlitMask = bit.bor(self.unlitMask, bitMask)
    elseif config.unlit then
        self.unlitMask = bit.bor(self.unlitMask, bitMask)
    else
        self.unlitMask = bit.band(self.unlitMask, notBitMask)
    end

    -- Validate layer ordering (screen layers must come after all world/virtual layers)
    self:_validateLayerOrdering()

    -- Handle parallax (defaults to 1.0 = moves with camera)
    if config.parallaxX ~= nil then
        self.parallaxX[layer] = config.parallaxX
    end
    if config.parallaxY ~= nil then
        self.parallaxY[layer] = config.parallaxY
    end

    -- Handle sort mode (defaults to "topdown")
    if config.sortMode then
        self.sortModes[layer] = SORT_MODE_TO_INT[config.sortMode] or 0
    end
end

function PipelineImpl:setLayerVisibility(layer: integer | string, visible: boolean)
    local layerNum: integer
    if layer is string then
        layerNum = self.layerNames[layer] or error("Unknown layer: " .. layer)
    else
        layerNum = layer as integer
    end
    self.layers[layerNum].visible = visible
end

function PipelineImpl:isLayerVisible(layer: integer | string): boolean
    local layerNum: integer
    if layer is string then
        layerNum = self.layerNames[layer]
        if not layerNum then return true end
    else
        layerNum = layer as integer
    end
    return self.layers[layerNum].visible ~= false
end

function PipelineImpl:setLayerUnlit(layer: integer | string, unlit: boolean)
    local layerNum: integer
    if layer is string then
        layerNum = self.layerNames[layer] or error("Unknown layer: " .. layer)
    else
        layerNum = layer as integer
    end
    local bitIndex = layerNum - 1
    local bitMask = bit.lshift(1, bitIndex)
    if unlit then
        -- Set the bit (layer is unlit)
        self.unlitMask = bit.bor(self.unlitMask, bitMask)
    else
        -- Clear the bit (layer receives lighting)
        self.unlitMask = bit.band(self.unlitMask, bit.bnot(bitMask))
    end
end

function PipelineImpl:isLayerUnlit(layer: integer | string): boolean
    local layerNum: integer
    if layer is string then
        layerNum = self.layerNames[layer]
        if not layerNum then return false end  -- unknown layer defaults to lit (not unlit)
    else
        layerNum = layer as integer
    end
    local bitIndex = layerNum - 1
    local bitMask = bit.lshift(1, bitIndex)
    return bit.band(self.unlitMask, bitMask) ~= 0
end

function PipelineImpl:setLayerParallax(layer: integer | string, parallaxX: number, parallaxY: number)
    local layerNum: integer
    if layer is string then
        layerNum = self.layerNames[layer] or error("Unknown layer: " .. layer)
    else
        layerNum = layer as integer
    end
    self.parallaxX[layerNum] = parallaxX
    self.parallaxY[layerNum] = parallaxY or parallaxX
end

function PipelineImpl:getLayerParallax(layer: integer | string): number, number
    local layerNum: integer
    if layer is string then
        layerNum = self.layerNames[layer]
        if not layerNum then return 1.0, 1.0 end
    else
        layerNum = layer as integer
    end
    return self.parallaxX[layerNum], self.parallaxY[layerNum]
end

function PipelineImpl:setLayerSortMode(layer: integer | string, mode: types.SortMode)
    local layerNum: integer
    if layer is string then
        layerNum = self.layerNames[layer] or error("Unknown layer: " .. layer)
    else
        layerNum = layer as integer
    end
    self.sortModes[layerNum] = assert(SORT_MODE_TO_INT[mode], "Invalid sort mode: " .. tostring(mode))
end

function PipelineImpl:getLayerSortMode(layer: integer | string): types.SortMode
    local layerNum: integer
    if layer is string then
        layerNum = self.layerNames[layer]
        if not layerNum then return "topdown" end
    else
        layerNum = layer as integer
    end
    return SORT_MODE_FROM_INT[self.sortModes[layerNum]] or "topdown"
end

-------------------------------------------------------------------------------
-- Layer Effects
-------------------------------------------------------------------------------

function PipelineImpl:setLayerEffect(layer: integer | string, shader: any, uniforms?: {string: any}, options?: types.LayerEffectOptions)
    local layerNum: integer
    if layer is string then
        layerNum = self.layerNames[layer] or error("Unknown layer: " .. layer)
    else
        layerNum = layer as integer
    end
    self.layerEffectsManager:setEffect(layerNum, shader, uniforms, options as layerEffects.EffectOptions)
end

function PipelineImpl:clearLayerEffect(layer: integer | string)
    local layerNum: integer
    if layer is string then
        layerNum = self.layerNames[layer] or error("Unknown layer: " .. layer)
    else
        layerNum = layer as integer
    end
    self.layerEffectsManager:clearEffect(layerNum)
end

-------------------------------------------------------------------------------
-- Screen size
-------------------------------------------------------------------------------

function PipelineImpl:setScreenSize(w: number, h: number)
    self.screenWidth = w as integer
    self.screenHeight = h as integer
    -- Recalculate virtual width to match new aspect ratio
    self.virtualWidth = floor(self.virtualHeight * self.screenWidth / self.screenHeight) as integer
    self.renderer.config.virtualRes = {self.virtualWidth, self.virtualHeight}
    self:_recomputeScaledDims()
    self.renderer:resize(self.screenWidth, self.screenHeight)
    self:_ensureWorldLitCanvas()
    self._screenLitCanvas = lg.newCanvas(self.screenWidth, self.screenHeight, {format = "rgba8"})
    -- Layer effects: world-phase at scaled resolution, screen-phase at native
    self.layerEffectsManager:resize(self.scaledWidth, self.scaledHeight)
    self.layerEffectsManager:resizeScreen(self.screenWidth, self.screenHeight)
    self._primaryCamera:setScreenSize(self.screenWidth, self.screenHeight, self.virtualHeight)
    self:_updateCameraRenderDims()
end

-------------------------------------------------------------------------------
-- Main render function
-------------------------------------------------------------------------------

function PipelineImpl:render()
    zone("upload")
    self.renderer:upload()
    zone()

    local globalTime = self.gameTime

    for _, cam in ipairs(self._cameras) do
        if not cam:isActive() then goto continue end

        if cam == self._primaryCamera then
            self:_renderPrimary(cam, globalTime)
        else
            self:_renderSecondary(cam, globalTime)
        end

        ::continue::
    end
end

--- Render the primary camera (supports pixel modes and layer effects).
function PipelineImpl:_renderPrimary(cam: Camera, globalTime: number)
    self._renderCamera = cam

    local useLowRes = self.pixelMode

    -- Use render position (includes screenshake offset) for actual rendering
    local camX, camY = cam._renderX, cam._renderY
    local pixelScale = self.screenHeight / self.virtualHeight
    local effectiveZoom = cam.zoom * pixelScale

    -- Render zoom: the zoom value used for all render passes.
    -- In retro mode, the canvas is at virtual resolution and gets upscaled by
    -- pixelScale when blitted. Using effectiveZoom (which includes pixelScale)
    -- would zoom 4x too much. Use cam.zoom instead so that retro and off mode
    -- show the same world area at the same user zoom level.
    local renderZoom = useLowRes and cam.zoom or effectiveZoom

    -- For pixel-perfect rendering, snap camera to world-pixel grid and compute
    -- sub-pixel remainder. This is the single snap point; downstream passes
    -- (G-buffer, lighting, forward blend) all receive the snapped camera.
    local subPixelX, subPixelY = 0.0, 0.0
    -- renderSubPixel: what gets passed to G-buffer/lighting/forward blend.
    -- With integer scaling, render is pixel-perfect (zero sub-pixel); the sub-pixel
    -- remainder is applied as a screen-pixel offset on the final blit instead.
    local renderSubPixelX, renderSubPixelY = 0.0, 0.0
    if useLowRes and renderZoom > 0.1 then
        local vh <const> = self.virtualHeight
        local rh = useLowRes and self.scaledHeight or self.screenHeight
        local rPixelScale = rh / vh
        local worldPixelSize = rPixelScale / renderZoom
        local snappedX = math.floor(camX / worldPixelSize) * worldPixelSize
        local snappedY = math.floor(camY / worldPixelSize) * worldPixelSize
        subPixelX = (snappedX - camX) * renderZoom
        subPixelY = (snappedY - camY) * renderZoom
        camX = snappedX
        camY = snappedY
        if not self._integerScaling then
            renderSubPixelX = subPixelX
            renderSubPixelY = subPixelY
        end
    end

    -- Set camera on renderer for VP access
    self.renderer.camera = cam
    

    local rot = cam._renderRotation
    local hasScreenLayers = self._firstScreenLayer > 0
    local worldMaxLayer = hasScreenLayers and (self._firstScreenLayer - 1) or MAX_LAYERS

    -- G-buffer callback only if this camera runs Draw phase
    local gBufferCb = not cam._disableDrawPhase and self._gBufferCallback or nil

    ---------------------------------------------------------------------------
    -- Phase 1: World/virtual layers (at scaled resolution)
    ---------------------------------------------------------------------------
    self.renderer._renderPhase = "world"

    -- Run culling compute shaders (uses scaled G-buffer dims for tile viewport).
    -- Restrict the cull's layer mask to the world layers: screen-layer
    -- entities are culled and drawn by the screen phase, and world
    -- entities must not survive into it.
    local worldLayerMask = bit.band(cam._layerMask, bit.lshift(1, worldMaxLayer) - 1)
    zone("cull")
    self.renderer:cull(camX, camY, renderZoom, useLowRes, globalTime, self.screenSpaceMask, self.ignoreZoomMask, self.virtualCoordsMask, self.unlitMask, self.parallaxX, self.parallaxY, self.sortModes, rot, worldLayerMask)
    zone()

    if hasScreenLayers then
        self.renderer:setLayerRange(1, worldMaxLayer)
    else
        self.renderer:resetLayerRange()
    end

    -- Check if layer effects are active
    if self.layerEffectsManager:hasEffects() then
        zone("layerEffects")
        self:renderWithLayerEffects(camX, camY, renderZoom, useLowRes, globalTime, rot, renderSubPixelX, renderSubPixelY)
        zone()
    else
        -- Standard single-pass rendering (no effects) for world layers
        zone("gBuffer")
        self.renderer:renderGBuffer(camX, camY, renderZoom, useLowRes, globalTime, gBufferCb, rot, renderSubPixelX, renderSubPixelY)
        zone()

        if self.shadowsEnabled and self.lightingMode == "deferred" then
            zone("shadowMask")
            self.renderer:renderShadowMask(camX, camY, renderZoom, rot)
            zone()
        end

        if self.lightingMode == "deferred" then
            zone("lighting")
            self.renderer:renderLighting(useLowRes, self.shadowsEnabled, self.ambientLight, camX, camY, renderZoom, nil, rot, renderSubPixelX, renderSubPixelY)
            zone()

            zone("bloom")
            self.renderer:renderBloom(useLowRes, self.renderer.worldLitCanvas)
            zone()
        else
            -- No lighting: copy albedo to worldLitCanvas
            lg.setColor(1, 1, 1, 1)
            local albedo = useLowRes and self.renderer.pixelAlbedo or self.renderer.gBufferAlbedo
            lg.setCanvas(self.renderer.worldLitCanvas)
            lg.clear(0, 0, 0, 1)
            lg.draw(albedo, 0, 0)
            lg.setCanvas()
        end

        -- Forward pass for blend-mode shapes (render to worldLitCanvas)
        zone("forwardBlend")
        lg.setCanvas(self.renderer.worldLitCanvas)
        self.renderer:renderForwardBlend(camX, camY, renderZoom, useLowRes, renderSubPixelX, renderSubPixelY)
        lg.setCanvas()
        zone()
    end

    -- Upscale worldLitCanvas to screen
    local sw <const> = self.screenWidth
    local sh <const> = self.screenHeight
    local worldLit = self.renderer.worldLitCanvas
    local worldLitW = worldLit:getWidth()
    local worldLitH = worldLit:getHeight()
    lg.setColor(1, 1, 1, 1)
    if self._integerScaling then
        -- Integer scaling: pixel-perfect upscale with letterboxing.
        -- Sub-pixel camera remainder is applied as a screen-pixel blit offset
        -- (not in the render pass) so every virtual pixel maps to exactly
        -- intScale x intScale screen pixels, eliminating pixel crawl.
        -- Scissor clips the content to a fixed viewport so letterbox bars don't shift.
        local intScale <const> = self._intScale
        local blitOffsetX = floor(subPixelX * intScale + 0.5) as integer
        local blitOffsetY = floor(subPixelY * intScale + 0.5) as integer
        local vpX <const> = self._intOffsetX
        local vpY <const> = self._intOffsetY
        local vpW <const> = self.scaledWidth * intScale
        local vpH <const> = self.scaledHeight * intScale
        lg.clear(0, 0, 0, 1)
        lg.setScissor(vpX, vpY, vpW, vpH)
        worldLit:setFilter("nearest", "nearest")
        lg.draw(worldLit, vpX + blitOffsetX, vpY + blitOffsetY, 0, intScale, intScale)
        lg.setScissor()
    elseif useLowRes then
        -- Retro fallback (shouldn't normally happen since retro always uses integer scaling)
        worldLit:setFilter("nearest", "nearest")
        lg.draw(worldLit, 0, 0, 0, sw / worldLitW, sh / worldLitH)
    else
        -- Non-pixel or modern: bilinear filtering
        worldLit:setFilter("linear", "linear")
        lg.draw(worldLit, 0, 0, 0, sw / worldLitW, sh / worldLitH)
    end

    ---------------------------------------------------------------------------
    -- Phase 2: Screen layers (only if _firstScreenLayer > 0)
    ---------------------------------------------------------------------------
    if hasScreenLayers then
        zone("screenLayers")
        self.renderer._renderPhase = "screen"
        self.renderer:setLayerRange(self._firstScreenLayer, MAX_LAYERS)

        -- Screen layers use native resolution, no camera transform, no pixel mode
        -- Override renderer screen dims to native for this phase
        local prevW = self.renderer.screenWidth
        local prevH = self.renderer.screenHeight
        self.renderer.screenWidth = sw
        self.renderer.screenHeight = sh

        -- Cull with screen-space viewport (screen dims, identity camera).
        -- Restrict the layer mask to the screen layers: without this,
        -- every world entity passes the screen-phase cull (its zoom is
        -- 1.0 and the viewport comes from the world camera's AABB, so
        -- zoomed-out views re-emit the whole world) and gets drawn just
        -- to be rejected by LayerRange in the vertex shader.
        local screenLayerMask = bit.band(cam._layerMask, bit.band(0xFFFF, bit.bnot(bit.lshift(1, self._firstScreenLayer - 1) - 1)))
        self.renderer:cull(0, 0, 1.0, false, globalTime, self.screenSpaceMask, self.ignoreZoomMask, self.virtualCoordsMask, self.unlitMask, self.parallaxX, self.parallaxY, self.sortModes, 0.0, screenLayerMask)

        -- Render G-buffer at native resolution (screen-phase canvases)
        self.renderer:renderGBuffer(0, 0, 1.0, false, globalTime, gBufferCb, 0.0, 0.0, 0.0)

        -- Skip shadow mask (all screen layers are unlit)

        -- Render screen-phase lighting to a canvas (all pixels hit unlit early-exit)
        local screenLit = self._screenLitCanvas
        if self.lightingMode == "deferred" then
            self.renderer:renderLighting(false, false, self.ambientLight, 0, 0, 1.0, screenLit, 0.0, 0.0, 0.0)
        else
            local albedo = self.renderer.screenAlbedo or self.renderer.gBufferAlbedo
            lg.setCanvas(screenLit)
            lg.clear(0, 0, 0, 0)
            lg.setColor(1, 1, 1, 1)
            lg.draw(albedo, 0, 0)
            lg.setCanvas()
        end

        -- Forward pass for blend-mode screen-layer shapes
        lg.setCanvas(screenLit)
        self.renderer:renderForwardBlend(0, 0, 1.0, false, 0.0, 0.0)
        lg.setCanvas()

        -- Composite screen layers on top of world with alpha blending
        lg.setBlendMode("alpha", "premultiplied")
        lg.setColor(1, 1, 1, 1)
        lg.draw(screenLit, 0, 0)
        lg.setBlendMode("alpha")

        -- Restore renderer state
        self.renderer.screenWidth = prevW
        self.renderer.screenHeight = prevH
        zone()
    end

    -- Reset layer range and render phase
    self.renderer:resetLayerRange()
    self.renderer._renderPhase = nil

    -- Update camera VP to match the actual screen->world mapping for accurate toWorld/toScreen.
    -- In pixel modes, the render VP uses render dimensions (virtual res in retro mode) which
    -- differ from screen dimensions. Scale zoom and sub-pixel offset so mouse coordinates
    -- (in screen space) correctly map to rendered world positions.
    if useLowRes then
        if self._integerScaling then
            -- Integer scaling: each render pixel = intScale screen pixels, centered on screen.
            -- The VP maps the full screen (sw x sh), so zoom = renderZoom * intScale.
            local intScale = self._intScale
            setOrthographic(cam._transform,
                camX, camY,
                renderZoom * intScale,
                rot, sw, sh,
                subPixelX * intScale, subPixelY * intScale
            )
        else
            local rw = useLowRes and self.scaledWidth or sw
            local rh = useLowRes and self.scaledHeight or sh
            setOrthographic(cam._transform,
                camX, camY,
                renderZoom * sw / rw,
                rot, sw, sh,
                subPixelX * sw / rw, subPixelY * sh / rh
            )
        end
    end
end

--- Render a secondary camera to its per-camera canvas, then blit to screen.
--- Uses single-pass rendering (no layer effects), always pixelMode off.
function PipelineImpl:_renderSecondary(cam: Camera, globalTime: number)
    local prevRenderCamera = self._renderCamera
    local prevCamera = self.renderer.camera
    local prevPhase = self.renderer._renderPhase
    self._renderCamera = cam
    self.renderer.camera = cam

    -- Secondary cameras always use the main G-buffers (gBufferAlbedo etc.)
    -- at native resolution, with pixelMode=0. Set _renderPhase to nil so the
    -- phase-aware canvas selection in renderGBuffer/renderLighting falls through
    -- to the default (non-screen, non-lowres) path.
    self.renderer._renderPhase = nil

    -- Use render position (includes screenshake offset) for actual rendering
    local camX, camY = cam._renderX, cam._renderY
    local rot = cam._renderRotation
    local useLowRes = false

    -- Determine output mode: textureSize, viewport, or fullscreen overlay
    local vpX, vpY, vpW, vpH = cam:getViewport()
    local hasViewport = vpW > 0 and vpH > 0
    local hasTexture = cam._textureW > 0 and cam._textureH > 0

    -- Canvas dimensions for rendering
    local canvasW = hasTexture and cam._textureW or (hasViewport and vpW or 0)
    local canvasH = hasTexture and cam._textureH or (hasViewport and vpH or 0)
    local hasCanvas = canvasW > 0 and canvasH > 0

    -- Override renderer screen dimensions so that populateRenderParams,
    -- lighting, and forward shaders use the correct resolution
    local prevRendererW = self.renderer.screenWidth
    local prevRendererH = self.renderer.screenHeight
    if hasCanvas then
        self.renderer.screenWidth = canvasW as integer
        self.renderer.screenHeight = canvasH as integer
    end

    -- effectiveZoom uses the camera's screen-based pixelScale
    local pixelScale = cam._screenHeight / cam._virtualHeight
    local effectiveZoom = cam.zoom * pixelScale

    -- Run culling for this camera's view
    self.renderer:cull(camX, camY, effectiveZoom, useLowRes, globalTime, self.screenSpaceMask, self.ignoreZoomMask, self.virtualCoordsMask, self.unlitMask, self.parallaxX, self.parallaxY, self.sortModes, rot, cam._layerMask)

    -- G-buffer callback if this camera runs Draw phase
    local gBufferCb = not cam._disableDrawPhase and self._gBufferCallback or nil

    -- Single-pass rendering (no layer effects for secondary cameras)
    self.renderer:resetLayerRange()
    self.renderer:renderGBuffer(camX, camY, effectiveZoom, useLowRes, globalTime, gBufferCb, rot)

    if self.shadowsEnabled and self.lightingMode == "deferred" then
        self.renderer:renderShadowMask(camX, camY, effectiveZoom, rot)
    end

    if hasCanvas then
        -- For viewport cameras (no user-provided canvas), lazily allocate/resize
        if not hasTexture then
            if not cam._canvas
                or cam._canvas:getWidth() ~= canvasW
                or cam._canvas:getHeight() ~= canvasH then
                cam._canvas = lg.newCanvas(canvasW as integer, canvasH as integer)
            end
        end

        -- Render lit scene to per-camera canvas
        if self.lightingMode == "deferred" then
            self.renderer:renderLighting(useLowRes, self.shadowsEnabled, self.ambientLight, camX, camY, effectiveZoom, cam._canvas, rot)
            self.renderer:renderBloom(useLowRes, cam._canvas)
        else
            local albedo = self.renderer.screenAlbedo or self.renderer.gBufferAlbedo
            lg.setCanvas(cam._canvas)
            lg.clear(0, 0, 0, 0)
            lg.setColor(1, 1, 1, 1)
            lg.draw(albedo, 0, 0)
            lg.setCanvas()
        end

        -- Forward pass for blend-mode shapes
        lg.setCanvas(cam._canvas)
        self.renderer:renderForwardBlend(camX, camY, effectiveZoom, useLowRes, 0.0, 0.0)
        lg.setCanvas()

        -- Blit to screen only for viewport cameras (not textureSize)
        if hasViewport and not hasTexture then
            lg.setColor(1, 1, 1, 1)
            lg.draw(cam._canvas, vpX, vpY)
        end
    else
        -- No canvas: secondary camera renders directly to screen (full-screen overlay)
        if self.lightingMode == "deferred" then
            self.renderer:renderLighting(useLowRes, self.shadowsEnabled, self.ambientLight, camX, camY, effectiveZoom, nil, rot)
            self.renderer:renderBloom(useLowRes)
        else
            local albedo = self.renderer.screenAlbedo or self.renderer.gBufferAlbedo
            lg.setColor(1, 1, 1, 1)
            lg.draw(albedo, 0, 0)
        end
        self.renderer:renderForwardBlend(camX, camY, effectiveZoom, useLowRes, 0.0, 0.0)
    end

    -- Restore renderer state
    self.renderer.screenWidth = prevRendererW
    self.renderer.screenHeight = prevRendererH
    self._renderCamera = prevRenderCamera
    self.renderer.camera = prevCamera
    self.renderer._renderPhase = prevPhase
end

--- Multi-pass rendering with layer effects.
--- Each layer group is rendered to the G-buffer, lit, optionally effected,
--- and composited to the accumulator.
function PipelineImpl:renderWithLayerEffects(camX: number, camY: number, renderZoom: number, useLowRes: boolean, globalTime: number, rotation: number, subPixelX: number, subPixelY: number)
    local groups = self.layerEffectsManager:getGroups()
    local mgr = self.layerEffectsManager

    -- G-buffer textures for effect auto-uniforms (resolution matches render target)
    local normalBuf = useLowRes and self.renderer.pixelNormal or self.renderer.gBufferNormal
    local emissionBuf = useLowRes and self.renderer.pixelEmission or self.renderer.gBufferEmission

    -- Clear the accumulator
    lg.setCanvas(mgr.accumulator)
    lg.clear(0, 0, 0, 0)
    lg.setCanvas()

    for _, group in ipairs(groups) do
        -- Set layer range for GPU shape shaders
        self.renderer:setLayerRange(group.minLayer, group.maxLayer)

        -- Set layer range for CPU draw filtering (checked in attachWorldShader)
        self.currentLayerMin = group.minLayer
        self.currentLayerMax = group.maxLayer

        -- Render G-buffer for this layer range.
        -- Pass gBufferCallback every pass; CPU draws self-filter via attachWorldShader
        self.renderer:renderGBuffer(camX, camY, renderZoom, useLowRes, globalTime, self._gBufferCallback, rotation, subPixelX, subPixelY)

        -- Render shadow mask and lighting for this group
        if self.lightingMode == "deferred" then
            if self.shadowsEnabled then
                self.renderer:renderShadowMask(camX, camY, renderZoom, rotation)
            end

            -- Render lighting to the litLayer canvas
            self.renderer:renderLighting(useLowRes, self.shadowsEnabled, self.ambientLight, camX, camY, renderZoom, mgr.litLayer, rotation, subPixelX, subPixelY)
            self.renderer:renderBloom(useLowRes, mgr.litLayer)

            -- Forward pass for blend-mode shapes (render to litLayer after lighting)
            lg.setCanvas(mgr.litLayer)
            self.renderer:renderForwardBlend(camX, camY, renderZoom, useLowRes, subPixelX, subPixelY)
            lg.setCanvas()
        else
            -- No lighting: copy albedo to litLayer as opaque content.
            -- The G-buffer uses depth testing (opaque writes), so entities with
            -- alpha < 1 are NOT transparent in the G-buffer, the depth test
            -- winner takes all. The opaque copy shader pre-multiplies alpha
            -- into color and forces alpha=1, matching single-pass semantics
            -- where alpha only applies once at the final screen draw.
            local albedo = useLowRes and self.renderer.pixelAlbedo or self.renderer.gBufferAlbedo
            lg.setCanvas(mgr.litLayer)
            lg.clear(0, 0, 0, 0)
            lg.setShader(mgr.compositeShader)
            lg.setColor(1, 1, 1, 1)
            lg.setBlendMode("replace")
            lg.draw(albedo, 0, 0)
            lg.setShader()
            lg.setBlendMode("alpha")

            -- Forward pass for blend-mode shapes (render to litLayer)
            self.renderer:renderForwardBlend(camX, camY, renderZoom, useLowRes, subPixelX, subPixelY)
            lg.setCanvas()
        end

        -- Apply effect if this group has one
        if group.effect then
            local effect = group.effect
            local shaders = effect.shaders

            if group.applyToAccumulator then
                -- "Layers below" mode: composite first, then apply effect to accumulator.
                -- This makes the effect affect this layer AND all previously composited layers.
                lg.setCanvas(mgr.accumulator)
                lg.setColor(1, 1, 1, 1)
                lg.draw(mgr.litLayer, 0, 0)
                lg.setCanvas()

                -- Multi-pass: ping-pong between accumulator and effectTemp
                local src = mgr.accumulator
                local dst = mgr.effectTemp

                for i, s in ipairs(shaders) do
                    lg.setCanvas(dst)
                    lg.clear(0, 0, 0, 0)
                    lg.setShader(s)

                    -- Send shared uniforms
                    for name, value in pairs(effect.uniforms) do
                        if s:hasUniform(name) then
                            local send = (s as {string:any}).send as function(any, string, any)
                            send(s, name, value)
                        end
                    end

                    -- Send standard uniforms
                    if s:hasUniform("tecs_SceneBelow") then
                        -- For accumulator mode, scene below is the pre-effect accumulator
                        s:send("tecs_SceneBelow", src)
                    end
                    if s:hasUniform("tecs_PassIndex") then
                        s:send("tecs_PassIndex", i - 1)
                    end
                    if s:hasUniform("tecs_Normal") then
                        s:send("tecs_Normal", normalBuf)
                    end
                    if s:hasUniform("tecs_Emission") then
                        s:send("tecs_Emission", emissionBuf)
                    end

                    lg.setColor(1, 1, 1, 1)
                    lg.draw(src, 0, 0)
                    lg.setShader()
                    lg.setCanvas()

                    -- Swap for next pass
                    src, dst = dst, src
                end

                -- After the loop, src holds the final result
                -- If result ended up in effectTemp, copy it back to accumulator
                if src ~= mgr.accumulator then
                    lg.setCanvas(mgr.accumulator)
                    lg.setBlendMode("replace")
                    lg.setColor(1, 1, 1, 1)
                    lg.draw(src, 0, 0)
                    lg.setBlendMode("alpha")
                    lg.setCanvas()
                end
            else
                -- Single-layer mode: apply effect to litLayer first, then composite.
                -- Multi-pass: ping-pong between litLayer and effectTemp.
                local src = mgr.litLayer
                local dst = mgr.effectTemp

                for i, s in ipairs(shaders) do
                    lg.setCanvas(dst)
                    lg.clear(0, 0, 0, 0)
                    lg.setShader(s)

                    -- Send shared uniforms
                    for name, value in pairs(effect.uniforms) do
                        if s:hasUniform(name) then
                            local send = (s as {string:any}).send as function(any, string, any)
                            send(s, name, value)
                        end
                    end

                    -- Send standard uniforms
                    if s:hasUniform("tecs_SceneBelow") then
                        s:send("tecs_SceneBelow", mgr.accumulator)
                    end
                    if s:hasUniform("tecs_PassIndex") then
                        s:send("tecs_PassIndex", i - 1)
                    end
                    if s:hasUniform("tecs_Normal") then
                        s:send("tecs_Normal", normalBuf)
                    end
                    if s:hasUniform("tecs_Emission") then
                        s:send("tecs_Emission", emissionBuf)
                    end

                    lg.setColor(1, 1, 1, 1)
                    lg.draw(src, 0, 0)
                    lg.setShader()
                    lg.setCanvas()

                    -- Swap for next pass
                    src, dst = dst, src
                end

                -- After the loop, src holds the final result
                local finalResult = src

                -- Composite effected layer to accumulator
                lg.setCanvas(mgr.accumulator)
                lg.setColor(1, 1, 1, 1)
                lg.draw(finalResult, 0, 0)
                lg.setCanvas()
            end
        else
            -- No effect: composite litLayer directly to accumulator.
            -- litLayer content is already opaque from the copy step above.
            lg.setCanvas(mgr.accumulator)
            lg.setColor(1, 1, 1, 1)
            lg.draw(mgr.litLayer, 0, 0)
            lg.setCanvas()
        end
    end

    -- Reset layer range
    self.renderer:resetLayerRange()
    self.currentLayerMin = 1
    self.currentLayerMax = MAX_LAYERS

    -- Copy the final composited result to worldLitCanvas for upscale by pipeline
    lg.setCanvas(self.renderer.worldLitCanvas)
    lg.clear(0, 0, 0, 1)
    lg.setColor(1, 1, 1, 1)
    lg.setBlendMode("replace")
    lg.draw(mgr.accumulator, 0, 0)
    lg.setBlendMode("alpha")
    lg.setCanvas()
end

-------------------------------------------------------------------------------
-- Draw phase support - depth shader methods for CPU draws
-------------------------------------------------------------------------------

--- Compute a depth value for sorting (matches GPU shader formula).
--- Lower depth = further back in scene.
--- @param layer Layer number (1-16)
--- @param z Z-index within layer
--- @param x X coordinate (used for isometric sort mode)
--- @param bottomY Bottom Y coordinate of the entity
--- @return Depth value in range [0, 1]
function PipelineImpl:computeDepth(layer: number, z: number, x: number, bottomY: number): number
    local sortMode = self.sortModes[layer as integer] or 0
    return computeDepth(layer, z, x, bottomY, sortMode)
end

-- Pre-allocated default normal (flat, facing camera) to avoid per-call allocations
local DEFAULT_NORMAL <const> = {0, 0, 1}

-------------------------------------------------------------------------------
-- WorldShaderState: fluent API for CPU draws during Draw phase
-------------------------------------------------------------------------------

--- Set depth sorting position. z, x, and bottomY default to 0 if omitted.
--- @param layer Render layer (1-16)
--- @param z Z-index within layer (default 0)
--- @param x X coordinate for isometric sorting (default 0)
--- @param bottomY Bottom Y coordinate for isometric sorting (default 0)
--- @return self for chaining
function WorldShaderState:at(layer: number, z: number, x: number, bottomY: number): types.WorldShaderState
    self._layer = layer
    self._z = z or 0
    self._x = x or 0
    self._bottomY = bottomY or 0
    return self
end

--- Mark this draw as unlit (full brightness, no lighting).
--- @return self for chaining
function WorldShaderState:unlit(): types.WorldShaderState
    self._isUnlit = true
    return self
end

--- Set a custom Love2D shader. Custom shaders MUST be MRT-aware and output to both:
---   love_Canvases[0] = albedo color
---   love_Canvases[1] = vec4(normal * 0.5 + 0.5, lit ? 1.0 : 0.0)
--- @param loveShader A love.graphics.Shader
--- @return self for chaining
function WorldShaderState:shader(loveShader: any): types.WorldShaderState
    self._shader = loveShader
    return self
end

--- Set a normal map texture for per-pixel normals.
--- @param texture The normal map texture
--- @return self for chaining
function WorldShaderState:normalMap(texture: love.graphics.Texture): types.WorldShaderState
    self._normalMap = texture
    return self
end

--- Apply the world shader with the accumulated settings. Draw after this call,
--- then call pipeline:detachWorldShader() when done.
function WorldShaderState:attach()
    local p = self._pipeline as PipelineImpl
    if not p.drawActive then
        error("worldShader():attach() can only be called during Draw phase")
    end

    local layer = self._layer
    local z = self._z
    local x = self._x
    local bottomY = self._bottomY

    -- Filter draws outside the current layer range (for multi-pass layer effects).
    -- Can't return early because user code will draw after this call;
    -- disable color writes so the draw is a no-op.
    local layerInt = layer as integer
    if layerInt < p.currentLayerMin or layerInt > p.currentLayerMax then
        lg.setColorMask(false, false, false, false)
        lg.setDepthMode()  -- Disable depth writes too
        p.cpuWorldShaderActive = false
        return
    end

    -- Restore color/depth writes if they were disabled by a previous filtered call
    lg.setColorMask(true, true, true, true)
    lg.setDepthMode("lequal", true)

    local sortMode = p.sortModes[layerInt] or 0
    local depth = computeDepth(layer, z, x, bottomY, sortMode)

    local customShader = self._shader as love.graphics.Shader

    if customShader then
        -- Custom shader: use it directly with MRT uniforms
        -- Shader MUST output to both love_Canvases[0] (albedo) and love_Canvases[1] (normal)
        lg.setShader(customShader)

        -- Send tecs_ prefixed uniforms (like Love2D's love_ convention)
        if customShader:hasUniform("tecs_Depth") then
            customShader:send("tecs_Depth", depth)
        end

        -- Send normal map (use flat normal as fallback)
        if customShader:hasUniform("tecs_NormalMap") then
            local flatNormal = p.renderer.flatNormalTexture as love.graphics.Texture
            customShader:send("tecs_NormalMap", self._normalMap or flatNormal)
        end

        -- Send lit status
        if customShader:hasUniform("tecs_Lit") then
            customShader:send("tecs_Lit", self._isUnlit and 0.0 or 1.0)
        end

        -- Send game time for animated effects
        if customShader:hasUniform("tecs_Time") then
            customShader:send("tecs_Time", p.gameTime)
        end

        p.cpuWorldShaderActive = false  -- Track that we're using custom shader
    else
        -- Standard world shader with lit/unlit support
        if not p.cpuWorldShaderActive then
            lg.setShader(p.cpuWorldShader)
            p.cpuWorldShaderActive = true
        end
        p.cpuWorldShader:send("tecs_Depth", depth)
        p.cpuWorldShader:send("tecs_Lit", self._isUnlit and 0.0 or 1.0)

        p.cpuWorldShader:send("tecs_Normal", DEFAULT_NORMAL)
        if self._normalMap then
            p.cpuWorldShader:send("tecs_NormalMap", self._normalMap)
            p.cpuWorldShader:send("tecs_UseNormalMap", true)
        else
            p.cpuWorldShader:send("tecs_UseNormalMap", false)
        end
    end
end

--- Get the pre-allocated WorldShaderState for fluent configuration.
--- Resets all fields to defaults. Chain methods and call :attach() to apply.
--- @return WorldShaderState for chaining
function PipelineImpl:worldShader(): types.WorldShaderState
    local ws = self._worldShaderState
    ws._layer = 1
    ws._z = 0
    ws._x = 0
    ws._bottomY = 0
    ws._isUnlit = false
    ws._shader = nil
    ws._normalMap = nil
    return ws
end

--- Detach the world shader after CPU draws.
--- This resets both the standard cpuWorldShader and any custom shaders.
function PipelineImpl:detachWorldShader()
    -- Always reset the shader, whether using cpuWorldShader or custom shader
    lg.setShader()
    -- Restore color/depth writes (may have been disabled by layer filtering)
    lg.setColorMask(true, true, true, true)
    lg.setDepthMode("lequal", true)
    self.cpuWorldShaderActive = false
end

--- Query the lighting brightness at a world position.
--- Returns 0-1 luminance including shadow occlusion.
--- Lazy: first call activates an intermediate canvas (zero cost until called).
--- The first frame after activation returns 0 (no data yet).
--- Query the lit pixel luminance at a world position.
---
--- NOTE: This is a debug/tooling API. It does a GPU->CPU readback
--- via `lg.readbackTexture`, which is expensive (stalls the GPU pipeline).
--- Do not call per-frame from gameplay code. Intended for editor tools,
--- stealth detection debug overlays, or infrequent checks.
---
--- @param worldX World-space X coordinate.
--- @param worldY World-space Y coordinate.
--- @return Perceptual luminance in [0, 1] (ITU-R BT.709), or 0 if off-screen.
function PipelineImpl:queryLightAt(worldX: number, worldY: number): number
    local cam = self._primaryCamera
    local renderer = self.renderer

    -- The lit result always lands in worldLitCanvas (retro mode renders
    -- at virtual resolution, other modes at screen resolution).
    local canvas = renderer.worldLitCanvas
    if not canvas then return 0 end

    -- Convert world to screen coordinates via the camera transform.
    local screenX, screenY = cam:toScreen(worldX, worldY)

    -- In retro mode, worldLitCanvas is at virtual resolution, so map
    -- screen-space coords to virtual-space.
    if self.pixelMode then
        screenX = screenX * self.virtualWidth / self.screenWidth
        screenY = screenY * self.virtualHeight / self.screenHeight
    end

    -- Clamp to canvas bounds
    local cw = canvas:getWidth() as integer
    local ch = canvas:getHeight() as integer
    local px = math.floor(screenX) as integer
    local py = math.floor(screenY) as integer
    if px < 0 or px >= cw or py < 0 or py >= ch then
        return 0
    end

    -- Read single pixel (GPU stall; see note above).
    local data = lg.readbackTexture(canvas, 1, 1, px, py, 1, 1)
    local r, g, b = data:getPixel(0, 0)

    -- Return perceptual luminance (ITU-R BT.709)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
end

--- Check if Draw phase is currently active.
--- @return true if within Draw phase render context
function PipelineImpl:isDrawActive(): boolean
    return self.drawActive
end


-------------------------------------------------------------------------------
-- Render plugin
-------------------------------------------------------------------------------

function pipeline.newPlugin(config: pipeline.RenderConfig): tecs.Plugin
    return function(w: tecs.World)
        local configWithWorld: pipeline.RenderConfig = {
            world = w,
            virtualHeight = config.virtualHeight,
            virtualWidth = config.virtualWidth,
            pixelMode = config.pixelMode,
            roughGeometry = config.roughGeometry,
            lightingMode = config.lightingMode,
            shadowsEnabled = config.shadowsEnabled,
            sizeHints = config.sizeHints,
            ambientLight = config.ambientLight,
            lerpingEnabled = config.lerpingEnabled,
            lerpSpeed = config.lerpSpeed,
            cameraPosition = config.cameraPosition,
            zoom = config.zoom,
            clampToBounds = config.clampToBounds,
            worldBounds = config.worldBounds,
            layers = config.layers,
            dropShadowScale = config.dropShadowScale,
            bloom = config.bloom,
        }
        pipeline.newPipeline(configWithWorld)
    end
end

return pipeline
