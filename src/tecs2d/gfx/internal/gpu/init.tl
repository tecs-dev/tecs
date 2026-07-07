--- GPU rendering module for tecs.
--- Provides instanced rendering with compute shader culling and deferred lighting.

local types <const> = require("tecs2d.gfx.internal.gpu.types")
local shaderCode <const> = require("tecs2d.gfx.internal.gpu.shaders")
local forward_blend <const> = require("tecs2d.gfx.internal.gpu.forward_blend")
local retire <const> = require("tecs2d.gfx.internal.gpu.retire")
local C <const> = require("ffi")

local lg <const> = love.graphics

-- `jit.zone` has no Teal type declarations; go through an opaque require.
local function loadUntyped(modName: string): any
    return require(modName)
end
local zone = loadUntyped("jit.zone") as function(?string): string

local setOrthographic <const> = require("tecs2d.gfx.internal.ortho").setOrthographic

-- Shadow-mask view-projection: same camera, shadow-mask resolution, zoom
-- widened so shadowMargin extra world pixels per side land inside the
-- mask. Off-screen occluders within the margin still cast shadows, and
-- the lighting shader inverts this same transform for world->UV, so the
-- expanded coverage is accounted for automatically. Returns the mask
-- dimensions in pixels.
local function setShadowOrthographic(self: types.Renderer, t: love.math.Transform,
        cameraX: number, cameraY: number, cameraZoom: number, rotation: number): integer, integer
    local scale = self.config.shadowMaskScale
    local maskW = math.floor(self.screenWidth * scale)
    local maskH = math.floor(self.screenHeight * scale)
    local margin = self.config.shadowMargin or 200.0
    local zoomScaled = cameraZoom * scale
    local shadowZoom = zoomScaled * maskW / (maskW + 2.0 * margin * zoomScaled)
    setOrthographic(t, cameraX, cameraY, shadowZoom, rotation, maskW, maskH, 0, 0)
    return maskW, maskH
end

-- Methods table for Renderer (used as __index metatable)
local RendererMethods: types.Renderer = {}

local record gpu
    --- Re-export types module
    types: types

    --- Re-export shader code
    shaders: shaderCode

    --- Configuration for the GPU renderer (alias to types.Config)
    type Config = types.Config

    --- The GPU renderer instance (alias to types.Renderer)
    type Renderer = types.Renderer

    --- Create a new GPU renderer
    new: function(config: Config): Renderer
end

gpu.types = types
gpu.shaders = shaderCode

function gpu.new(config: gpu.Config): gpu.Renderer
    config = config or {}

    -- Apply defaults for config fields that shape modules read
    config.maxLayers = config.maxLayers or 16
    config.maxZ = config.maxZ or 1000
    config.maxY = config.maxY or 100000
    config.virtualRes = config.virtualRes or {320, 180}
    config.shadowMaskScale = config.shadowMaskScale or 1.0
    config.dropShadowScale = config.dropShadowScale or 0.5
    config.shadowSteps = config.shadowSteps or 24
    config.sizeHints = config.sizeHints or {}

    local renderer: gpu.Renderer = {
        config = config,
    }

    -- Default layer range (all layers visible)
    renderer._layerRange = {0, 65535}

    -- Smooth SDF rendering by default; pipeline flips this when
    -- roughGeometry is set in its config or via setRoughGeometry.
    renderer._roughGeometry = false

    -- Compile shared shaders (per-shape shaders are compiled by each shape module)
    renderer.lightingShader = lg.newShader(shaderCode.LIGHTING)
    renderer.shadowBlurShader = lg.newShader(shaderCode.SHADOW_BLUR)
    renderer.bloomDownsampleShader = lg.newShader(shaderCode.BLOOM_DOWNSAMPLE)
    renderer.bloomUpsampleShader = lg.newShader(shaderCode.BLOOM_UPSAMPLE)

    -- Initialize bloom config (disabled by default)
    renderer.bloom = {
        enabled = false,
        intensity = 0.5,
        radius = 1.0,
        threshold = 0.0,
    }

    -- Dummy material params buffer (1 element, all zeros) for shapes with no materials
    renderer.dummyMaterialParamsBuffer = lg.newBuffer(types.MATERIAL_PARAMS_FORMAT, 1, {usage = "dynamic", shaderstorage = true})

    -- Create camera params SSBO buffers
    renderer.cullParamsByteData = love.data.newByteData(C.sizeof("GPUCullParams"))
    renderer.cullParamsBuffer = lg.newBuffer(types.CULL_PARAMS_FORMAT, 1, {usage = "dynamic", shaderstorage = true})
    renderer.renderParamsByteData = love.data.newByteData(C.sizeof("GPURenderParams"))
    renderer.renderParamsBuffer = lg.newBuffer(types.RENDER_PARAMS_FORMAT, 1, {usage = "dynamic", shaderstorage = true})

    -- Create indirect reset data (shared across all plugins)
    renderer.indirectResetData = love.data.newByteData(16)
    local ptr = C.cast("uint32_t*", renderer.indirectResetData:getFFIPointer()) as {integer}
    ptr[0] = 6   -- vertexCount (2 triangles)
    ptr[1] = 0   -- instanceCount (set by compute shader)
    ptr[2] = 0   -- firstVertex
    ptr[3] = 0   -- firstInstance

    -- Create default white texture
    local imageData = love.image.newImageData(16, 16)
    imageData:mapPixel(function(_x: number, _y: number, _r: number, _g: number, _b: number, _a: number): (number, number, number, number)
        return 1, 1, 1, 1
    end)
    renderer.defaultTexture = lg.newImage(imageData)
    renderer.defaultTexture:setFilter("nearest", "nearest")

    -- 1x1 flat normal texture (neutral normal, alpha=0 means "no normal data")
    local flatNormalData = love.image.newImageData(1, 1)
    flatNormalData:setPixel(0, 0, 0.5, 0.5, 1.0, 0.0)
    renderer.flatNormalTexture = lg.newImage(flatNormalData)
    renderer.flatNormalTexture:setFilter("nearest", "nearest")

    -- 1x1 black emission texture (no glow)
    local blackEmissionData = love.image.newImageData(1, 1)
    blackEmissionData:setPixel(0, 0, 0, 0, 0, 1)
    renderer.blackEmissionTexture = lg.newImage(blackEmissionData)
    renderer.blackEmissionTexture:setFilter("nearest", "nearest")

    -- 1x1 default ORM texture (full AO, mid roughness, non-metallic)
    local defaultORMData = love.image.newImageData(1, 1)
    defaultORMData:setPixel(0, 0, 1.0, 0.5, 0.0, 0.0)
    renderer.defaultORMTexture = lg.newImage(defaultORMData)
    renderer.defaultORMTexture:setFilter("nearest", "nearest")

    -- Initialize screen size and canvases
    renderer.screenWidth = lg.getWidth() as integer
    renderer.screenHeight = lg.getHeight() as integer

    renderer.plugins = {}

    renderer._shadowTransform = love.math.newTransform()
    renderer._lightTransform = love.math.newTransform()
    renderer._lightShadowTransform = love.math.newTransform()
    renderer._renderTransform = love.math.newTransform()

    -- Set metatable before calling methods
    setmetatable(renderer, {__index = RendererMethods})
    renderer:resize(renderer.screenWidth, renderer.screenHeight)

    return renderer
end

function RendererMethods:resize(width: integer, height: integer)
    self.screenWidth = width
    self.screenHeight = height

    local vw, vh = self.config.virtualRes[1], self.config.virtualRes[2]
    local dsScale = self.config.dropShadowScale
    local scale = self.config.shadowMaskScale

    -- Full-res G-Buffer at native screen resolution (used for non-retro world
    -- rendering and for screen-phase rendering of screen-space layers)
    local scaledW = width
    local scaledH = height

    -- Full-res G-Buffer (at scaled resolution for world phase)
    self.gBufferAlbedo = lg.newCanvas(scaledW, scaledH, {format = "rgba8"})
    self.gBufferNormal = lg.newCanvas(scaledW, scaledH, {format = "rgba8"})
    self.gBufferORM = lg.newCanvas(scaledW, scaledH, {format = "rgba8"})
    self.gBufferEmission = lg.newCanvas(scaledW, scaledH, {format = "rgba8"})
    -- Drop shadow AO canvas (1.0 = no occlusion, 0.0 = full shadow)
    local dsW = math.max(1, math.floor(scaledW * dsScale)) as integer
    local dsH = math.max(1, math.floor(scaledH * dsScale)) as integer
    self.dropShadowAO = lg.newCanvas(dsW, dsH, {format = "rgba8"})
    self.dropShadowAO:setFilter("linear", "linear")
    local maskW = math.max(1, math.floor(scaledW * scale)) as integer
    local maskH = math.max(1, math.floor(scaledH * scale)) as integer
    -- RGBA8 format: R = occluder height, G = occluder flag (1 = actual occluder pixel)
    self.shadowMask = lg.newCanvas(maskW, maskH, {format = "rgba8"})
    self.shadowMaskTemp = lg.newCanvas(maskW, maskH, {format = "rgba8"})
    self.shadowMask:setFilter("linear", "linear")
    self.shadowMaskTemp:setFilter("linear", "linear")

    -- worldLitCanvas is managed by the pipeline (it knows the pixel mode).
    -- See PipelineImpl:_ensureWorldLitCanvas().

    -- Screen-phase rendering uses the main G-buffers (both are at native resolution)
    self.screenDropShadowAO = nil
    self.screenShadowMask = nil

    -- Low-res canvases for pixel-perfect (retro) mode at virtual resolution
    local pixelW = vw as integer
    local pixelH = vh as integer
    self.pixelAlbedo = lg.newCanvas(pixelW, pixelH, {format = "rgba8"})
    self.pixelNormal = lg.newCanvas(pixelW, pixelH, {format = "rgba8"})
    self.pixelORM = lg.newCanvas(pixelW, pixelH, {format = "rgba8"})
    self.pixelEmission = lg.newCanvas(pixelW, pixelH, {format = "rgba8"})
    local pixelDsW = math.max(1, math.floor(pixelW * dsScale)) as integer
    local pixelDsH = math.max(1, math.floor(pixelH * dsScale)) as integer
    self.pixelDropShadowAO = lg.newCanvas(pixelDsW, pixelDsH, {format = "rgba8"})
    self.pixelDropShadowAO:setFilter("linear", "linear")
    self.pixelCanvas = lg.newCanvas(pixelW, pixelH, {format = "rgba8"})

    -- Set nearest-neighbor filtering for pixel-perfect
    self.pixelAlbedo:setFilter("nearest", "nearest")
    self.pixelNormal:setFilter("nearest", "nearest")
    self.pixelORM:setFilter("nearest", "nearest")
    self.pixelEmission:setFilter("nearest", "nearest")
    self.pixelCanvas:setFilter("nearest", "nearest")

    -- Tile-based light binning buffers (sized for max resolution across all phases)
    local TILE_SIZE <const> = 16
    local MAX_LIGHTS_PER_TILE <const> = 128
    local maxTileW = math.max(width, scaledW)
    local maxTileH = math.max(height, scaledH)
    local tilesX = math.ceil(maxTileW / TILE_SIZE) as integer
    local tilesY = math.ceil(maxTileH / TILE_SIZE) as integer
    local totalTiles = tilesX * tilesY
    self.tileGridWidth = tilesX
    self.tileGridHeight = tilesY
    self.tileLightCountBuffer = lg.newBuffer({{format = "uint32"}}, totalTiles, {usage = "dynamic", shaderstorage = true})
    self.tileLightIndexBuffer = lg.newBuffer({{format = "uint32"}}, totalTiles * MAX_LIGHTS_PER_TILE, {usage = "dynamic", shaderstorage = true})
    self.tileCountResetData = love.data.newByteData(totalTiles * 4)

    -- Bloom mip chains (7 levels, each half the previous) -- at scaled resolution
    local BLOOM_MIP_COUNT <const> = 7
    self.bloomMips = {}
    self.bloomMipWidths = {}
    self.bloomMipHeights = {}
    local mipW, mipH = scaledW, scaledH
    for i = 1, BLOOM_MIP_COUNT do
        mipW = math.max(1, math.floor(mipW / 2)) as integer
        mipH = math.max(1, math.floor(mipH / 2)) as integer
        self.bloomMips[i] = lg.newCanvas(mipW, mipH, {format = "rgba8"})
        self.bloomMips[i]:setFilter("linear", "linear")
        self.bloomMipWidths[i] = mipW
        self.bloomMipHeights[i] = mipH
    end

    -- Pixel-perfect bloom mip chains (from scaled virtual resolution)
    self.pixelBloomMips = {}
    self.pixelBloomMipWidths = {}
    self.pixelBloomMipHeights = {}
    local pmipW, pmipH = pixelW as integer, pixelH as integer
    for i = 1, BLOOM_MIP_COUNT do
        pmipW = math.max(1, math.floor(pmipW / 2)) as integer
        pmipH = math.max(1, math.floor(pmipH / 2)) as integer
        self.pixelBloomMips[i] = lg.newCanvas(pmipW, pmipH, {format = "rgba8"})
        self.pixelBloomMips[i]:setFilter("linear", "linear")
        self.pixelBloomMipWidths[i] = pmipW
        self.pixelBloomMipHeights[i] = pmipH
    end
end

function RendererMethods:upload()
    -- Once-per-frame: release GPU objects retired by buffer growth two
    -- frames ago, now that in-flight work no longer references them.
    retire.tick()
    for _, plugin in ipairs(self.plugins) do
        if plugin.upload then
            plugin.upload(self)
        end
    end
end

function RendererMethods:cull(cameraX: number, cameraY: number, cameraZoom: number, useLowRes: boolean, globalTime: number, screenSpaceMask: integer, ignoreZoomMask: integer, virtualCoordsMask: integer, unlitMask: integer, parallaxX: {number}, parallaxY: {number}, sortModes: {integer}, rotation: number, cameraLayerMask: integer)
    rotation = rotation or 0.0
    self._hasDropShadows = false
    local sw, sh = self.screenWidth, self.screenHeight
    local pad = 50 / cameraZoom

    local minX, minY, maxX, maxY = self.camera:aabb(sw, sh, pad)
    local viewport: {number} = { minX, minY, maxX, maxY }

    local cameraPos = { cameraX, cameraY }

    -- Pack parallax arrays into mat4 format (column-major: [col][row] = layer col*4+row+1)
    -- Default to 1.0 if not provided
    parallaxX = parallaxX or {}
    parallaxY = parallaxY or {}
    local parallaxMatX = {
        parallaxX[1] or 1.0, parallaxX[2] or 1.0, parallaxX[3] or 1.0, parallaxX[4] or 1.0,
        parallaxX[5] or 1.0, parallaxX[6] or 1.0, parallaxX[7] or 1.0, parallaxX[8] or 1.0,
        parallaxX[9] or 1.0, parallaxX[10] or 1.0, parallaxX[11] or 1.0, parallaxX[12] or 1.0,
        parallaxX[13] or 1.0, parallaxX[14] or 1.0, parallaxX[15] or 1.0, parallaxX[16] or 1.0,
    }
    local parallaxMatY = {
        parallaxY[1] or 1.0, parallaxY[2] or 1.0, parallaxY[3] or 1.0, parallaxY[4] or 1.0,
        parallaxY[5] or 1.0, parallaxY[6] or 1.0, parallaxY[7] or 1.0, parallaxY[8] or 1.0,
        parallaxY[9] or 1.0, parallaxY[10] or 1.0, parallaxY[11] or 1.0, parallaxY[12] or 1.0,
        parallaxY[13] or 1.0, parallaxY[14] or 1.0, parallaxY[15] or 1.0, parallaxY[16] or 1.0,
    }

    -- Pack sort modes into mat4 format (0=topdown, 1=z-only, 2=isometric)
    sortModes = sortModes or {}
    local sortModesMat = {
        sortModes[1] or 0, sortModes[2] or 0, sortModes[3] or 0, sortModes[4] or 0,
        sortModes[5] or 0, sortModes[6] or 0, sortModes[7] or 0, sortModes[8] or 0,
        sortModes[9] or 0, sortModes[10] or 0, sortModes[11] or 0, sortModes[12] or 0,
        sortModes[13] or 0, sortModes[14] or 0, sortModes[15] or 0, sortModes[16] or 0,
    }

    local cfg = self.config
    local virtualRes = cfg.virtualRes
    local virtualSize = { virtualRes[1], virtualRes[2] }
    screenSpaceMask = screenSpaceMask or 0
    ignoreZoomMask = ignoreZoomMask or 0
    virtualCoordsMask = virtualCoordsMask or 0
    unlitMask = unlitMask or 0

    -- Store masks for render to use
    self.screenSpaceMask = screenSpaceMask
    self.ignoreZoomMask = ignoreZoomMask
    self.virtualCoordsMask = virtualCoordsMask
    self.unlitMask = unlitMask
    self.sortModesMat = sortModesMat

    -- Populate CullParams SSBO (uploaded once, sent to all cull shaders)
    local cullPtr = C.cast("GPUCullParams*", self.cullParamsByteData:getFFIPointer()) as {integer: types.CullParamsRecord}
    cullPtr[0].viewMinX = viewport[1] as number
    cullPtr[0].viewMinY = viewport[2] as number
    cullPtr[0].viewMaxX = viewport[3] as number
    cullPtr[0].viewMaxY = viewport[4] as number
    cullPtr[0].camX = cameraX
    cullPtr[0].camY = cameraY
    cullPtr[0].cameraZoom = cameraZoom
    cullPtr[0].maxLayer = cfg.maxLayers
    cullPtr[0].maxZ = cfg.maxZ
    cullPtr[0].maxY = cfg.maxY
    cullPtr[0].virtualW = virtualSize[1] as number
    cullPtr[0].virtualH = virtualSize[2] as number
    cullPtr[0].screenW = sw as number
    cullPtr[0].screenH = sh as number
    -- Pack uint16 layer mask into float via reinterpret cast
    cameraLayerMask = cameraLayerMask or 0xFFFF
    local maskU32 = C.new("uint32_t[1]") as {integer: integer}
    maskU32[0] = cameraLayerMask
    local maskF32 = C.cast("float*", maskU32) as {integer: number}
    cullPtr[0]._cameraLayerMask = maskF32[0]
    cullPtr[0]._pad1 = 0
    cullPtr[0].screenSpaceMask = screenSpaceMask
    cullPtr[0].ignoreZoomMask = ignoreZoomMask
    cullPtr[0].virtualCoordsMask = virtualCoordsMask
    cullPtr[0].unlitMask = unlitMask
    for i = 0, 15 do
        cullPtr[0].parallaxX[i] = parallaxMatX[i + 1] as number
        cullPtr[0].parallaxY[i] = parallaxMatY[i + 1] as number
        cullPtr[0].sortModes[i] = sortModesMat[i + 1] as number
    end
    self.cullParamsBuffer:setArrayData(self.cullParamsByteData)
    local cullParamsBuffer <const> = self.cullParamsBuffer

    -- Cache cull-phase data for plugins that use individual uniforms
    self._cullViewport = viewport
    -- Unpadded viewport for tile-based light binning.
    -- Must match renderLighting()'s InvViewProj exactly: use render dimensions from
    -- the G-buffer canvases.
    local rw: number
    local rh: number
    if useLowRes then
        rw = self.pixelAlbedo:getWidth()
        rh = self.pixelAlbedo:getHeight()
    else
        rw = self.gBufferAlbedo:getWidth()
        rh = self.gBufferAlbedo:getHeight()
    end
    local tileHW = rw / (2 * cameraZoom)
    local tileHH = rh / (2 * cameraZoom)
    if rotation ~= 0 then
        -- For rotated cameras, compute AABB of the rotated screen rectangle
        local cosR = math.abs(math.cos(rotation))
        local sinR = math.abs(math.sin(rotation))
        local aabbHW = tileHW * cosR + tileHH * sinR
        local aabbHH = tileHW * sinR + tileHH * cosR
        tileHW = aabbHW
        tileHH = aabbHH
    end
    self._tileViewport = { cameraX - tileHW, cameraY - tileHH, cameraX + tileHW, cameraY + tileHH }
    -- Effective tile grid dims must match renderLighting's TileGridDims
    local TILE_SIZE <const> = 16
    self._effectiveTileGridW = math.ceil(rw / TILE_SIZE) as integer
    self._effectiveTileGridH = math.ceil(rh / TILE_SIZE) as integer
    self._cullCameraPos = cameraPos
    self._cullParallaxMatX = parallaxMatX
    self._cullParallaxMatY = parallaxMatY
    self._cullGlobalTime = globalTime or 0.0
    self._cullCameraLayerMask = cameraLayerMask or 0xFFFF

    -- Reset indirect buffers via plugins
    for _, plugin in ipairs(self.plugins) do
        if plugin.resetIndirect then
            plugin.resetIndirect(self)
        end
    end

    -- Cull via plugins
    for _, plugin in ipairs(self.plugins) do
        if plugin.cull then
            plugin.cull(self, cullParamsBuffer)
        end
    end
end

function RendererMethods:renderGBuffer(cameraX: number, cameraY: number, cameraZoom: number, useLowRes: boolean, globalTime: number, gBufferDrawCallback?: function(number, number, number, number, number, number), rotation?: number, subPixelX?: number, subPixelY?: number)

    -- Select canvases based on render phase
    local albedo: love.graphics.Canvas
    local normal: love.graphics.Canvas
    local orm: love.graphics.Canvas
    local emission: love.graphics.Canvas
    if useLowRes and self._renderPhase ~= "screen" then
        albedo = self.pixelAlbedo
        normal = self.pixelNormal
        orm = self.pixelORM
        emission = self.pixelEmission
    else
        albedo = self.gBufferAlbedo
        normal = self.gBufferNormal
        orm = self.gBufferORM
        emission = self.gBufferEmission
    end
    local rw = albedo:getWidth()
    local rh = albedo:getHeight()

    -- Camera is already snapped by the pipeline; use passed sub-pixel offsets
    subPixelX = subPixelX or 0.0
    subPixelY = subPixelY or 0.0

    -- Populate RenderParams SSBO (uploaded once, sent to all render shaders)
    forward_blend.populateRenderParams(self, cameraX, cameraY, cameraZoom, subPixelX, subPixelY, rw, rh, rotation or 0.0)
    local renderParamsBuffer <const> = self.renderParamsBuffer

    zone("clear")
    lg.setCanvas({albedo, normal, orm, emission, depthstencil = true} as love.graphics.CanvasSetup)
    lg.clear({0, 0, 0, 0}, {0, 0, 0, 0}, {1, 0.5, 0, 1}, {0, 0, 0, 0}, true, true)
    lg.setColor(1, 1, 1, 1)  -- Ensure full brightness for instanced draws
    zone()

    -- Render G-buffer draws (tilemaps, etc.) before GPU shapes
    -- These render WITHOUT depth writes so GPU shapes can render on top
    if gBufferDrawCallback then
        zone("draws")
        lg.setDepthMode()  -- Disable depth testing/writing for G-buffer draws
        gBufferDrawCallback(cameraX, cameraY, cameraZoom, rw, rh, rotation or 0.0)
        zone()
    end

    -- Enable depth mode for GPU shapes
    lg.setDepthMode("lequal", true)
    -- Use replace blend mode for G-buffer to ensure accurate values (no alpha blending)
    -- This is critical for the unlit flag in normal.a to work correctly
    lg.setBlendMode("replace")

    -- Render G-buffer shapes via plugins
    zone("shapes")
    for _, plugin in ipairs(self.plugins) do
        if plugin.renderGBuffer then
            plugin.renderGBuffer(self, renderParamsBuffer, globalTime)
        end
    end
    zone()

    lg.setShader()
    lg.setDepthMode()
    lg.setCanvas()

    -- Drop shadow AO pass (two-pass: darken shadows, then lighten stamp-out)
    if self._hasDropShadows then
        zone("dropShadowAO")
        local aoBuf: love.graphics.Canvas
        if self._renderPhase == "screen" then
            aoBuf = self.screenDropShadowAO or self.dropShadowAO
        elseif useLowRes then
            aoBuf = self.pixelDropShadowAO
        else
            aoBuf = self.dropShadowAO
        end
        local dsScale = self.config.dropShadowScale
        lg.setCanvas({aoBuf} as love.graphics.Canvas)
        lg.clear(1, 1, 1, 1)  -- white = no occlusion
        -- Scale transform so full-res vertex positions map to the reduced canvas
        if dsScale < 1.0 then
            lg.push()
            lg.scale(dsScale, dsScale)
        end
        lg.setBlendMode("darken", "premultiplied")
        for _, plugin in ipairs(self.plugins) do
            if plugin.renderDropShadowAO then
                plugin.renderDropShadowAO(self, renderParamsBuffer)
            end
        end
        lg.setBlendMode("alpha")
        if dsScale < 1.0 then
            lg.pop()
        end
        lg.setCanvas()
        zone()
    end
end

function RendererMethods:renderShadowMask(cameraX: number, cameraY: number, cameraZoom: number, rotation: number)
    rotation = rotation or 0.0
    -- Select shadow mask based on render phase
    local mask: love.graphics.Canvas
    if self._renderPhase == "screen" then
        mask = self.screenShadowMask or self.shadowMask
    else
        mask = self.shadowMask
    end
    -- Clear shadow mask and render occluders with MAX/lighten blend (tallest wins)
    lg.setCanvas(mask)
    lg.clear(0, 0, 0, 0)

    -- Set lighten blend mode for shadow mask rendering
    -- MAX/lighten: tallest occluder wins per pixel
    lg.setBlendMode("lighten", "premultiplied")

    local svt = self._shadowTransform
    local maskW, maskH = setShadowOrthographic(self, svt, cameraX, cameraY, cameraZoom, rotation)

    -- Render shadow casters via plugins
    for _, plugin in ipairs(self.plugins) do
        if plugin.renderShadowMask then
            plugin.renderShadowMask(self, svt)
        end
    end

    -- Separable Gaussian blur of shadow mask height channel
    -- Blurs height (R), preserves occluder flag (G) from center pixel
    -- Must use "replace" blend to fully overwrite temp canvas
    lg.setBlendMode("replace")
    local blurShader = self.shadowBlurShader
    local texelSize = {1.0 / maskW, 1.0 / maskH}
    lg.setShader(blurShader)
    blurShader:send("TexelSize", texelSize)
    blurShader:send("BlurRadius", 1.5)

    -- Horizontal blur: mask -> temp
    lg.setCanvas(self.shadowMaskTemp)
    blurShader:send("BlurDirection", {1.0, 0.0})
    lg.draw(mask)

    -- Vertical blur: temp -> mask
    lg.setCanvas(mask)
    blurShader:send("BlurDirection", {0.0, 1.0})
    lg.draw(self.shadowMaskTemp)

    lg.setShader()
    lg.setBlendMode("alpha")
    lg.setCanvas()
end

function RendererMethods:renderLighting(useLowRes: boolean, shadowsEnabled: boolean, ambient: {number, number, number}, cameraX: number, cameraY: number, cameraZoom: number, outputCanvas?: love.graphics.Canvas, rotation?: number, subPixelX?: number, subPixelY?: number)
    rotation = rotation or 0.0
    subPixelX = subPixelX or 0.0
    subPixelY = subPixelY or 0.0

    -- Select G-buffer canvases based on render phase
    local albedo: love.graphics.Canvas
    local normal: love.graphics.Canvas
    local ormBuf: love.graphics.Canvas
    local emissionBuf: love.graphics.Canvas
    local mask: love.graphics.Canvas
    if self._renderPhase == "screen" then
        albedo = self.gBufferAlbedo
        normal = self.gBufferNormal
        ormBuf = self.gBufferORM
        emissionBuf = self.gBufferEmission
        mask = self.screenShadowMask or self.shadowMask
    elseif useLowRes then
        albedo = self.pixelAlbedo
        normal = self.pixelNormal
        ormBuf = self.pixelORM
        emissionBuf = self.pixelEmission
        mask = self.shadowMask
    else
        albedo = self.gBufferAlbedo
        normal = self.gBufferNormal
        ormBuf = self.gBufferORM
        emissionBuf = self.gBufferEmission
        mask = self.shadowMask
    end
    local rw = albedo:getWidth()
    local rh = albedo:getHeight()

    -- Determine output target
    -- When rendering world phase without explicit outputCanvas, use worldLitCanvas
    if outputCanvas then
        lg.setCanvas(outputCanvas)
    elseif self._renderPhase == "world" or useLowRes then
        lg.setCanvas(self.worldLitCanvas)
    end
    if outputCanvas then
        lg.clear(0, 0, 0, 0)
    else
        lg.clear(0, 0, 0, 1)
    end
    lg.setBlendMode("alpha")

    local lvt = self._lightTransform
    setOrthographic(lvt,
        cameraX, cameraY, cameraZoom, rotation,
        rw, rh, subPixelX, subPixelY
    )

    local lsvt = self._lightShadowTransform
    setShadowOrthographic(self, lsvt, cameraX, cameraY, cameraZoom, rotation)

    -- Always use lighting shader to apply ambient (even with 0 lights)
    -- Tile-based light binning: fragment shader reads per-tile light lists
    local shader = self.lightingShader
    lg.setShader(shader)
    shader:send("gAlbedo", albedo)
    shader:send("gNormal", normal)
    shader:send("gORM", ormBuf)
    shader:send("gEmission", emissionBuf)
    shader:send("shadowMask", mask)
    shader:send("shadowsActive", shadowsEnabled)
    shader:send("ambient", ambient)
    shader:send("dropShadowsActive", self._hasDropShadows == true)
    if self._hasDropShadows then
        local aoBuf: love.graphics.Canvas
        if self._renderPhase == "screen" then
            aoBuf = self.screenDropShadowAO or self.dropShadowAO
        elseif useLowRes then
            aoBuf = self.pixelDropShadowAO
        else
            aoBuf = self.dropShadowAO
        end
        shader:send("gDropShadowAO", aoBuf)
    end
    shader:send("LightBuffer", self.lightOutputBuffer)
    -- Tile-based light binning buffers
    shader:send("TileLightCounts", self.tileLightCountBuffer)
    shader:send("TileLightIndices", self.tileLightIndexBuffer)
    -- Compute effective tile grid dims for current resolution
    local TILE_SIZE <const> = 16
    local effectiveTilesX = math.ceil(rw / TILE_SIZE)
    local effectiveTilesY = math.ceil(rh / TILE_SIZE)
    shader:send("TileGridDims", {effectiveTilesX, effectiveTilesY})
    shader:send("TileSize", TILE_SIZE * 1.0)
    local shadowSteps = self.config.shadowSteps
    if useLowRes then shadowSteps = shadowSteps * 2 end
    shader:send("MaxShadowSteps", shadowSteps)
    -- Light cookies
    local hasCookies = self.cookieTextureArray ~= nil
    if shader:hasUniform("cookiesActive") then
        shader:send("cookiesActive", hasCookies)
        if hasCookies and shader:hasUniform("CookieTex") then
            local cookieTex = self.cookieTextureArray as love.graphics.Texture
            cookieTex:setFilter("linear", "linear")
            cookieTex:setWrap("clampzero", "clampzero")
            shader:send("CookieTex", cookieTex)
        end
    end
    shader:send("InvViewProj", lvt:inverse())
    shader:send("ShadowViewProj", lsvt)
    lg.draw(albedo, 0, 0)
    lg.setShader()

    if outputCanvas or self._renderPhase == "world" or useLowRes then
        -- World phase renders to worldLitCanvas; the pipeline handles upscale
        lg.setCanvas()
    end
end

function RendererMethods:renderForwardBlend(cameraX: number, cameraY: number, cameraZoom: number, useLowRes: boolean, subPixelX: number, subPixelY: number)
    subPixelX = subPixelX or 0.0
    subPixelY = subPixelY or 0.0
    for _, plugin in ipairs(self.plugins) do
        if plugin.renderForwardBlend then
            plugin.renderForwardBlend(self, cameraX, cameraY, cameraZoom, useLowRes, subPixelX, subPixelY)
        end
    end
end

local BLOOM_MIP_COUNT <const> = 7

function RendererMethods:renderBloom(useLowRes: boolean, outputCanvas?: love.graphics.Canvas)
    if not self.bloom.enabled then return end

    local usePixelMips = useLowRes

    -- Select emission buffer and mip chain based on render phase
    local emission: love.graphics.Canvas
    local mips: {love.graphics.Canvas}
    local mipWidths: {integer}
    local mipHeights: {integer}
    if self._renderPhase == "screen" then
        emission = self.gBufferEmission
        mips = self.bloomMips  -- screen phase uses full-res mips
        mipWidths = self.bloomMipWidths
        mipHeights = self.bloomMipHeights
    elseif usePixelMips then
        emission = self.pixelEmission
        mips = self.pixelBloomMips
        mipWidths = self.pixelBloomMipWidths
        mipHeights = self.pixelBloomMipHeights
    else
        emission = self.gBufferEmission
        mips = self.bloomMips
        mipWidths = self.bloomMipWidths
        mipHeights = self.bloomMipHeights
    end

    local downShader = self.bloomDownsampleShader
    local upShader = self.bloomUpsampleShader

    -- Downsample chain: emission -> mip[1] -> mip[2] -> ... -> mip[N]
    lg.setBlendMode("replace")

    -- First pass: emission -> mip[1] (premultiply rgb * a + threshold)
    lg.setCanvas(mips[1])
    lg.setShader(downShader)
    downShader:send("HalfTexelSize", {0.5 / emission:getWidth(), 0.5 / emission:getHeight()})
    downShader:send("Offset", self.bloom.radius)
    downShader:send("Threshold", self.bloom.threshold)
    downShader:send("FirstPass", 1)
    lg.setColor(1, 1, 1, 1)
    lg.draw(emission, 0, 0, 0, mipWidths[1] / emission:getWidth(), mipHeights[1] / emission:getHeight())

    -- Subsequent passes: mip[i-1] -> mip[i]
    downShader:send("FirstPass", 0)
    for i = 2, BLOOM_MIP_COUNT do
        lg.setCanvas(mips[i])
        downShader:send("HalfTexelSize", {0.5 / mipWidths[i - 1], 0.5 / mipHeights[i - 1]})
        lg.draw(mips[i - 1], 0, 0, 0, mipWidths[i] / mipWidths[i - 1], mipHeights[i] / mipHeights[i - 1])
    end

    -- Upsample chain: mip[N] -> mip[N-1] -> ... -> mip[1] (additive blend)
    lg.setBlendMode("add")
    lg.setShader(upShader)
    upShader:send("Offset", self.bloom.radius)

    for i = BLOOM_MIP_COUNT, 2, -1 do
        lg.setCanvas(mips[i - 1])
        upShader:send("HalfTexelSize", {0.5 / mipWidths[i], 0.5 / mipHeights[i]})
        lg.draw(mips[i], 0, 0, 0, mipWidths[i - 1] / mipWidths[i], mipHeights[i - 1] / mipHeights[i])
    end

    lg.setShader()
    lg.setCanvas()

    -- Composite: draw mip[1] additively onto the output
    -- mip[1] is at half the source resolution; scale to output resolution
    local outW: number
    local outH: number
    if outputCanvas then
        lg.setCanvas(outputCanvas)
        outW = outputCanvas:getWidth()
        outH = outputCanvas:getHeight()
    else
        outW = self.screenWidth
        outH = self.screenHeight
    end

    lg.setBlendMode("add")
    lg.setColor(self.bloom.intensity, self.bloom.intensity, self.bloom.intensity, 1)
    lg.draw(mips[1], 0, 0, 0, outW / mipWidths[1], outH / mipHeights[1])
    lg.setColor(1, 1, 1, 1)
    lg.setBlendMode("alpha")

    if outputCanvas then
        lg.setCanvas()
    end
end

function RendererMethods:registerPlugin(plugin: types.RenderPlugin)
    self.plugins[#self.plugins + 1] = plugin
end


-------------------------------------------------------------------------------
-- Layer Effects Support
-------------------------------------------------------------------------------

--- Set the layer range for all render shaders.
--- Used for multi-pass rendering with layer effects.
--- @param minLayer Minimum layer (inclusive), 0 to render all
--- @param maxLayer Maximum layer (inclusive), 65535 to render all
function RendererMethods:setLayerRange(minLayer: number, maxLayer: number)
    local range = {minLayer, maxLayer}
    self._layerRange = range

    -- Delegate to each plugin's setLayerRange hook
    for _, plugin in ipairs(self.plugins) do
        if plugin.setLayerRange then
            plugin.setLayerRange(self, range)
        end
    end
end

--- Reset layer range to render all layers (default state).
function RendererMethods:resetLayerRange()
    self:setLayerRange(0, 65535)
end

return gpu
