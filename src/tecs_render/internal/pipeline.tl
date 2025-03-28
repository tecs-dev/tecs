local tecs <const> = require("tecs")
local types <const> = require("tecs_render.types")
local tecs2d <const> = require("tecs2d")
local levents <const> = tecs2d.events
local pool <const> = require("tecs.internal.utils.pool")
local ffi <const> = require("tecs").ffi
local builtins <const> = require("tecs.internal.builtins")

local type Int32Array = tecs.Int32Array
local type Float32Array = tecs.Float32Array

local Emitter <const> = builtins.Emitter
local newFloat32 <const> = ffi.newFloat32
local newInt32 <const> = ffi.newInt32
local ensureCapacityInt32 <const> = ffi.ensureCapacityInt32
local ensureCapacityFloat32 <const> = ffi.ensureCapacityFloat32
local adjustCapacityInt32 <const> = ffi.adjustCapacityInt32
local adjustCapacityFloat32 <const> = ffi.adjustCapacityFloat32
local compat <const> = require("tecs.internal.utils.compat")
local bnot <const> = compat.bnot
local band <const> = compat.band
local bor <const> = compat.bor
local table_clear <const> = compat.clear
local table_new <const> = compat.new
local table_sort <const> = table.sort

local MAX_LAYERS <const> = 16

--- The pipeline module provides a render pipeline to render sorted draw calls and lighting.
---
--- Ambient lighting and lights are used to render lighting effects. Draw calls are rendered on top of the
--- lighting. Draw calls are sorted by layer, z-index, and their bottom pixels, ensuring that things closer
--- to the camera are rendered on top of things further away.
---
--- A single camera can be attached to the render pipeline. Any draw call that is in the bounds of the
--- attached camera is retained. Note that multile cameras can be attached to the pipeline by implementing
--- a composite camera behing the camera interface.
local record pipeline
    --- The context key that can be used to access the render pipeline.
    PIPELINE: tecs.Key<pipeline.Pipeline>

    --- Create a new render pipeline.
    ---
    --- @param config The configuration of the render pipeline.
    --- @return The render pipeline.
    newPipeline: function(config: RenderConfig): Pipeline

    --- Create a new render pipeline as a plugin.
    ---
    --- @param config The configuration of the render pipeline.
    --- @return The plugin.
    newPlugin: function(config: RenderConfig): tecs.Plugin

    --- The configuration of a render pipeline.
    record RenderConfig
        --- The world to attach the pipeline to.
        world: tecs.World

        --- An optional custom sorting function used to sort draw calls before rendering to a camera.
        --- The function receives draw IDs and the pipeline for accessing draw data.
        sortFunction: function(a: integer, b: integer, pipeline: Pipeline): boolean

        --- The required camera to attach to the pipeline.
        camera: types.Camera
    end

    --- Type alias for layer decorator function.
    type LayerDecorator = types.LayerDecorator

    --- Type alias for the render pipeline interface.
    type Pipeline = types.Pipeline

    --- Type alias for the camera interface.
    type Camera = types.Camera

    --- Type alias for a layer of the render pipeline.
    type Layer = types.Layer

    --- A flag used to indicate a draw call should not be affected by lighting.
    UNLIT_FLAG: integer

    --- A flag used to indicate a draw call is a light.
    LIGHT_FLAG: integer

    --- A flag used to indicate a draw call should be rendered absolutely.
    ABSOLUTE_FLAG: integer

    --- An event that systems *may* choose to emit after creating a draw.
    ---
    --- See `Pipeline:emitOnDraw` for more information.
    record OnDraw is tecs.Event
        --- The draw ID that was created.
        drawId: integer

        --- The render pipeline it was added to.
        pipeline: Pipeline

        metamethod __call: function(self, drawId: integer, pipeline: Pipeline): OnDraw
    end

    --- An observer that makes the draw call use the unlit flag, meaning it isn't affected by lighting.
    UNLIT_OBSERVER: function(event: OnDraw)
end

-------------------------------------------------------------------------------
-- Render constants
-------------------------------------------------------------------------------

pipeline.PIPELINE = tecs.newKey()

-- Bit flags
pipeline.UNLIT_FLAG = 0x1
pipeline.LIGHT_FLAG = 0x2
pipeline.ABSOLUTE_FLAG = 0x4

-------------------------------------------------------------------------------
-- OnDraw
-------------------------------------------------------------------------------

tecs.newEvent(pipeline.OnDraw, function(drawId: integer, p: pipeline.Pipeline): pipeline.OnDraw
    return {drawId = drawId, pipeline = p}
end)

-- Reuse this event for each draw event. Don't hold on to references outside of the callback.
local POOLED_ON_DRAW <const>: pipeline.OnDraw = pipeline.OnDraw(0, nil)

pipeline.UNLIT_OBSERVER = function(event: pipeline.OnDraw)
    if event.drawId > 0 then
        event.pipeline:setDrawFlag(event.drawId, pipeline.UNLIT_FLAG)
    end
end

-------------------------------------------------------------------------------
-- Render implementation
-------------------------------------------------------------------------------

local type Pipeline = types.Pipeline
local type Camera = types.Camera

local record PipelineImpl is Pipeline
    layers: {types.Layer}
    layerNames: {string: integer}  -- Map from name to layer number
    highestLayer: integer
    absoluteDraws: {integer}  -- Indices into SoA arrays
    camera: Camera
    lightingEnabled: boolean
    ambientLight: {number, number, number}
    sortFunction: function(a: integer, b: integer): boolean

    -- SoA tables for draw data (implementation detail, not public API)
    drawCount: integer
    drawLayers: Int32Array
    drawX: Float32Array
    drawY: Float32Array
    drawZ: Float32Array
    drawW: Float32Array
    drawH: Float32Array
    drawF: {function(...: any)}          -- Must remain Lua table
    drawArgs: {{any}}                    -- Must remain Lua table
    drawShaders: {{love.graphics.Shader}} -- Must remain Lua table
    drawDrawOrder: Int32Array
    drawFlags: Int32Array
    drawIndices: {integer}               -- Must remain Lua table for table.sort
    drawSortKeys: {number}               -- Precomputed sort keys for performance
end

local PIPELINE_MT <const>: metatable<PipelineImpl> = {
    __index = PipelineImpl
}

local function makeSorter(self: PipelineImpl): function(a: integer, b: integer): boolean
    -- Use precomputed sort keys for fast comparison
    local keys = self.drawSortKeys
    return function(a: integer, b: integer): boolean
        return keys[a] < keys[b]
    end
end

function pipeline.newPipeline(config: pipeline.RenderConfig): Pipeline
    local w = assert(config.world, "World required for render pipeline")
    local cam = assert(config.camera, "Camera required for render pipeline")
    local self: PipelineImpl = {
        layers = {},
        layerNames = {},
        highestLayer = 0,
        absoluteDraws = {},
        camera = cam,
        lightingEnabled = true,
        ambientLight = {0.5, 0.5, 0.5},
        sortFunction = nil,  -- Will be set below

        -- SoA tables
        drawCount = 0,
        drawLayers = newInt32(512),
        drawX = newFloat32(512),
        drawY = newFloat32(512),
        drawZ = newFloat32(512),
        drawW = newFloat32(512),
        drawH = newFloat32(512),
        drawF = table_new(512, 0) as {function(...: any)},  -- Must remain Lua table
        drawArgs = table_new(512, 0) as {{any}},  -- Must remain Lua table
        drawShaders = table_new(512, 0) as {{love.graphics.Shader}},  -- Must remain Lua table
        drawDrawOrder = newInt32(512),
        drawFlags = newInt32(512),
        drawIndices = table_new(512, 0) as {integer},  -- Must remain Lua table for sorting
        drawSortKeys = table_new(512, 0) as {number},  -- Precomputed sort keys
    }

    -- Set up the sorter function (needs self reference)
    if config.sortFunction then
        -- Wrap the user's sorter to pass the pipeline
        local userSorter = config.sortFunction
        self.sortFunction = function(a: integer, b: integer): boolean
            return userSorter(a, b, self as Pipeline)
        end
    else
        self.sortFunction = makeSorter(self)
    end

    for i = 1, MAX_LAYERS do
        self.layers[i] = {layer = i, draws = {}, lights = {}, visible = true}
    end
    local pipelineInstance = setmetatable(self, PIPELINE_MT) as Pipeline

    -- Register pipeline with world and set up systems
    w.resources[pipeline.PIPELINE] = pipelineInstance

    -- Update camera for lerping
    w:addSystem({
        phase = tecs.phases.Update,
        run = function(dt: number)
            local camera = pipelineInstance:getCamera()
            if camera and camera.update then
                camera:update(dt)
            end
        end
    })

    w:addSystem({
        phase = tecs.phases.PreRender,
        run = function(_dt: number)
            pipelineInstance:clear()
        end
    })

    -- Render the primary camera. Other cameras need to be rendered manually as appropriate.
    w:addSystem({
        phase = tecs.phases.PostRender,
        run = function(_dt: number)
            pipelineInstance:drawCamera(pipelineInstance:getCamera())
        end
    })

    -- Clear here too in case the accumulator prevented any updates from occurring.
    w:addSystem({
        phase = tecs.phases.RenderLast,
        run = function(_dt: number)
            pipelineInstance:clear()
        end
    })

    w:observe(levents.Resize, function(e: levents.Resize)
        pipelineInstance:setScreenSize(e.width, e.height)
    end)

    return pipelineInstance
end

function PipelineImpl:setScreenSize(w: number, h: number)
    self.camera:setScreenSize(w, h)
end

function PipelineImpl:getCamera(): Camera
    return self.camera
end

function PipelineImpl:isLightingEnabled(): boolean
    return self.lightingEnabled
end

function PipelineImpl:enableLighting()
    self.lightingEnabled = true
end

function PipelineImpl:disableLighting()
    self.lightingEnabled = false
end

function PipelineImpl:setAmbientLight(r: number, g: number, b: number)
    self.ambientLight = {r, g, b}
end

function PipelineImpl:getAmbientLight(): number, number, number
    return self.ambientLight[1], self.ambientLight[2], self.ambientLight[3]
end

local function getLayer(self: PipelineImpl, layer: integer): types.Layer
    -- All layers are pre-initialized, just track highest used
    if layer < 1 or layer > MAX_LAYERS then
        error("Layer must be between 1 and " .. MAX_LAYERS .. ", but found " .. layer)
    end
    local l = self.layers[layer]
    if layer > self.highestLayer then
        self.highestLayer = layer
    end
    return l
end

local function computeDrawOrder(y: number, h: number, index: integer): number
    return y + h + (index * 1e-6)
end

-- Helper to resolve layer name to number
local function resolveLayer(self: PipelineImpl, layer: integer | string): integer
    if layer is string then
        local layerNum = self.layerNames[layer]
        if not layerNum then
            error("Unknown layer name: " .. layer)
        end
        return layerNum
    end
    return layer as integer
end

function PipelineImpl:allocateDraw(
    layer: integer,
    x: number,
    y: number,
    z: number,
    w: number,
    h: number,
    drawOrder: number,
    f: function(...: any),
    ...: any
): integer
    local id = self.drawCount + 1

    -- Ensure arrays have capacity
    self.drawLayers = ensureCapacityInt32(self.drawLayers, id)
    self.drawX = ensureCapacityFloat32(self.drawX, id)
    self.drawY = ensureCapacityFloat32(self.drawY, id)
    self.drawZ = ensureCapacityFloat32(self.drawZ, id)
    self.drawW = ensureCapacityFloat32(self.drawW, id)
    self.drawH = ensureCapacityFloat32(self.drawH, id)
    self.drawDrawOrder = ensureCapacityInt32(self.drawDrawOrder, id)
    self.drawFlags = ensureCapacityInt32(self.drawFlags, id)

    self.drawCount = id

    -- Store in SoA arrays - direct indexing for FFI arrays
    (self.drawLayers as {integer})[id] = layer
    (self.drawX as {number})[id] = x
    (self.drawY as {number})[id] = y
    (self.drawZ as {number})[id] = z
    (self.drawW as {number})[id] = w
    (self.drawH as {number})[id] = h
    self.drawF[id] = f  -- Regular Lua table
    (self.drawDrawOrder as {number})[id] = drawOrder
    (self.drawFlags as {integer})[id] = 0

    -- Precompute sort key: layer * 1e9 + z * 1e6 + drawOrder
    -- This gives us clean separation between layers, then z-order, then draw order
    self.drawSortKeys[id] = layer * 1e9 + z * 1e6 + drawOrder

    -- Get args array from pool
    local argCount = select("#", ...)
    local args = pool.acquireArray(argCount) as {any}
    for i = 1, argCount do
        args[i] = select(i, ...)
    end
    self.drawArgs[id] = args

    -- Get shaders array from pool
    local shaders = pool.acquireArray() as {love.graphics.Shader}
    self.drawShaders[id] = shaders

    return id
end

function PipelineImpl:draw(layer: string | integer, x: number, y: number, w: number, h: number,
        f: function(...: any), ...: any): integer
    if not self.camera:isVisible(x, y, w, h) then
        return 0  -- Return 0 for invisible draws
    end

    local layerNum = resolveLayer(self, layer)
    local layerRecord = getLayer(self, layerNum)
    local draws = layerRecord.draws
    local nextDrawIdx = #draws + 1
    local drawOrder = computeDrawOrder(y, h, nextDrawIdx)
    local id = self:allocateDraw(layerNum, x, y, 0, w, h, drawOrder, f, ...)
    draws[nextDrawIdx] = id
    return id
end

function PipelineImpl:drawTransform(transform: builtins.Transform, w: number, h: number,
        f: function(...: any), ...: any): integer
    local id = self:draw(transform.layer, transform.x, transform.y, w, h, f, ...)
    if id > 0 then
        self.drawZ[id] = transform.z
    end
    return id
end

function PipelineImpl:drawAbsolute(f: function(...: any), ...: any): integer
    local drawOrder = computeDrawOrder(0, 0, #self.absoluteDraws + 1)
    local id = self:allocateDraw(0, 0, 0, 1, 0, 0, drawOrder, f, ...)
    (self.drawFlags as {integer})[id] = pipeline.ABSOLUTE_FLAG
    self.absoluteDraws[#self.absoluteDraws + 1] = id
    return id
end

function PipelineImpl:drawLight(layer: string | integer, x: number, y: number, w: number, h: number,
        f: function(...: any), ...: any): integer
    if not self.camera:isVisible(x, y, w, h) then
        return 0  -- Return 0 for invisible draws
    end

    local layerNum = resolveLayer(self, layer)
    local layerRecord = getLayer(self, layerNum)
    local lights = layerRecord.lights
    local nextLightIdx = #lights + 1
    local drawOrder = computeDrawOrder(y, h, nextLightIdx)
    local id = self:allocateDraw(layerNum, x, y, 0, w, h, drawOrder, f, ...)
    (self.drawFlags as {integer})[id] = pipeline.LIGHT_FLAG
    lights[nextLightIdx] = id
    return id
end

local function sortPipeline(self: PipelineImpl)
    local layers = self.layers
    local sortFunction = self.sortFunction
    local highestLayer = self.highestLayer
    for i = 1, highestLayer do
        table_sort(layers[i].draws, sortFunction)
    end
    local absoluteDraws = self.absoluteDraws
    if #absoluteDraws > 1 then
        table_sort(absoluteDraws, sortFunction)
    end
end

function PipelineImpl:drawCamera(camera: Camera)
    -- Skip if nothing to draw
    if self.highestLayer == 0 and #self.absoluteDraws == 0 then
        return
    end

    sortPipeline(self)
    camera:attach()
    local layers = self.layers
    local highestLayer = self.highestLayer
    for i = 1, highestLayer do
        local layer = layers[i]
        -- Skip empty layers
        if #layer.draws > 0 or #layer.lights > 0 then
            camera:drawLayer(layer, self)
        end
    end
    camera:detach(self.absoluteDraws, self)
end

function PipelineImpl:emitOnDraw(archetype: tecs.Archetype, row: integer, drawId: integer)
    if drawId < 1 or drawId > self.drawCount then
        return
    end

    local emitterColumn = archetype[Emitter]
    if emitterColumn then
        local emitter = emitterColumn[row]
        if emitter:hasObservers(pipeline.OnDraw) then
            POOLED_ON_DRAW.drawId = drawId
            POOLED_ON_DRAW.pipeline = self
            emitter:emit(POOLED_ON_DRAW)
        end
    end
end

function PipelineImpl:nameLayer(layer: integer, name: string)
    if layer < 1 or layer > MAX_LAYERS then
        error("Layer must be between 1 and " .. MAX_LAYERS .. ", but found " .. layer)
    end
    -- Remove old name mapping if this layer had a different name
    local l = self.layers[layer]  -- Always exists due to pre-initialization
    if l.name then
        self.layerNames[l.name] = nil
    end
    -- Set new name
    self.layerNames[name] = layer
    l.name = name
end

function PipelineImpl:setLayerDecorator(layer: integer | string, decorator: types.LayerDecorator)
    local layerNum = resolveLayer(self, layer)
    local l = getLayer(self, layerNum)
    l.decorator = decorator
end

function PipelineImpl:setLayerVisibility(layer: integer | string, visible: boolean)
    local layerNum = resolveLayer(self, layer)
    local l = getLayer(self, layerNum)
    l.visible = visible
end

function PipelineImpl:isLayerVisible(layer: integer | string): boolean
    local layerNum = resolveLayer(self, layer)
    local l = self.layers[layerNum]
    if not l then
        return true  -- Non-existent layers are visible by default
    end
    return l.visible ~= false  -- nil or true means visible
end

function PipelineImpl:setDrawFlag(id: integer, flag: integer)
    if id > 0 and id <= self.drawCount then
        local flags = self.drawFlags as {integer}
        flags[id] = bor(flags[id], flag)
    end
end

function PipelineImpl:removeDrawFlag(id: integer, flag: integer)
    if id > 0 and id <= self.drawCount then
        local flags = self.drawFlags as {integer}
        flags[id] = band(flags[id], bnot(flag))
    end
end

function PipelineImpl:setDrawFlags(id: integer, flags: integer)
    if id > 0 and id <= self.drawCount then
        (self.drawFlags as {integer})[id] = flags
    end
end

function PipelineImpl:hasDrawFlag(id: integer, flag: integer): boolean
    if id > 0 and id <= self.drawCount then
        return band((self.drawFlags as {integer})[id], flag) ~= 0
    end
    return false
end

function PipelineImpl:addDrawShader(id: integer, shader: love.graphics.Shader)
    if id > 0 and id <= self.drawCount then
        local shaders = self.drawShaders[id]
        shaders[#shaders + 1] = shader
    end
end

function PipelineImpl:setDrawZ(id: integer, z: number)
    if id > 0 and id <= self.drawCount then
        self.drawZ[id] = z
    end
end

function PipelineImpl:getDrawData(id: integer): number, number, number, number,
                                                function(...: any), {any}, {love.graphics.Shader}, integer
    if id > 0 and id <= self.drawCount then
        return self.drawX[id], self.drawY[id], self.drawW[id], self.drawH[id],
               self.drawF[id], self.drawArgs[id], self.drawShaders[id], self.drawFlags[id]
    end
    return 0, 0, 0, 0, function() end, pool.EMPTY, pool.EMPTY as {love.graphics.Shader}, 0
end

function PipelineImpl:getDrawCoordinates(id: integer): number, number, number, number
    if id > 0 and id <= self.drawCount then
        return self.drawX[id], self.drawY[id], self.drawW[id], self.drawH[id]
    end
    return 0, 0, 0, 0
end

function PipelineImpl:getDrawFunction(id: integer): function(...: any), {any}
    if id > 0 and id <= self.drawCount then
        return self.drawF[id], self.drawArgs[id]
    end
    return function() end, pool.EMPTY
end

function PipelineImpl:getDrawModifiers(id: integer): {love.graphics.Shader}, integer
    if id > 0 and id <= self.drawCount then
        return self.drawShaders[id], self.drawFlags[id]
    end
    return pool.EMPTY as {love.graphics.Shader}, 0
end

function PipelineImpl:clear()
    local drawCount = self.drawCount
    table_clear(self.absoluteDraws)

    -- Clear layer-specific draws and lights
    local layers = self.layers
    local highestLayer = self.highestLayer
    for i = 1, highestLayer do
        local layer = layers[i]
        table_clear(layer.draws)
        table_clear(layer.lights)
    end

    -- Return arrays to pool in batch
    if drawCount > 0 then
        local drawArgs = self.drawArgs
        local drawShaders = self.drawShaders
        for i = 1, drawCount do
            pool.releaseArray(drawArgs[i])
            pool.releaseArray(drawShaders[i])
        end

        -- Batch clear all arrays efficiently
        ffi.batchClear(drawCount,
            self.drawLayers,
            self.drawX,
            self.drawY,
            self.drawZ,
            self.drawW,
            self.drawH,
            self.drawDrawOrder,
            self.drawFlags
        )

        -- Adjust capacity only if significantly oversized
        if drawCount > 1024 then
            self.drawLayers = adjustCapacityInt32(self.drawLayers, drawCount)
            self.drawX = adjustCapacityFloat32(self.drawX, drawCount)
            self.drawY = adjustCapacityFloat32(self.drawY, drawCount)
            self.drawZ = adjustCapacityFloat32(self.drawZ, drawCount)
            self.drawW = adjustCapacityFloat32(self.drawW, drawCount)
            self.drawH = adjustCapacityFloat32(self.drawH, drawCount)
            self.drawDrawOrder = adjustCapacityInt32(self.drawDrawOrder, drawCount)
            self.drawFlags = adjustCapacityInt32(self.drawFlags, drawCount)
        end

        -- Clear Lua tables
        table_clear(self.drawF)
        table_clear(self.drawArgs)
        table_clear(self.drawShaders)
        table_clear(self.drawIndices)
        table_clear(self.drawSortKeys)
    end

    self.drawCount = 0
    self.highestLayer = 0
end

-------------------------------------------------------------------------------
-- Render plugin
-------------------------------------------------------------------------------

function pipeline.newPlugin(config: pipeline.RenderConfig): tecs.Plugin
    return function(w: tecs.World)
        -- Set the world in config and call newPipeline
        local configWithWorld = {
            world = w,
            camera = config.camera,
            sortFunction = config.sortFunction
        }
        pipeline.newPipeline(configWithWorld)
    end
end

return pipeline