--- The standard deferred pipeline, assembled on a PassGraph.
---
--- Three passes: geometry fills a G-buffer, lighting resolves it against a
--- buffer of lights, and composite puts the result on screen. Geometry is a
--- callback because what to draw is the caller's problem; everything else is
--- the engine's opinion and is built in.
---
--- Deferred is what makes light count independent of object count: geometry is
--- rasterised once regardless of how many lights touch it, and lighting runs
--- once per pixel regardless of how many objects overlap it.

local loader <const> = require("tecs.ffi.loader")
local sdl <const> = require("tecs.ffi.sdl3")
local PassGraph <const> = require("tecs.gpu.PassGraph")
local Shader <const> = require("tecs.gpu.Shader")
local Buffer <const> = require("tecs.gpu.Buffer")
local GraphicsPipeline <const> = require("tecs.gpu.GraphicsPipeline")
local Frame <const> = require("tecs.gpu.Frame")

local C <const> = sdl.C

--- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local RGBA8 <const> = 4

--- Most lights the lighting pass will consider in one frame.
local MAX_LIGHTS <const> = 256

--- Bytes per light: vec4 position and radius, vec4 colour and intensity.
local LIGHT_STRIDE <const> = 32

local record Light
    x: number
    y: number
    --- Height above the surface. Zero puts the light in the surface plane,
    --- where it contributes nothing through the Lambert term.
    z: number
    radius: number
    r: number
    g: number
    b: number
    intensity: number
end

local record DeferredOptions
    --- Draws into the G-buffer. Writes location 0 for albedo and location 1
    --- for a normal biased into unsigned range.
    geometry: function(context: PassGraph.PassContext)
    --- Ambient colour applied everywhere. Defaults to a dim neutral.
    ambient: {number}
end

local record Deferred
    Light: Light
    --- What a geometry callback receives. Re-exported so callers need not
    --- reach into PassGraph for it.
    PassContext: PassGraph.PassContext
    graph: PassGraph
    --- Lights considered this frame, replaced by `setLights`.
    lightCount: integer
    ambient: {number}
    _device: loader.CPtr
    _lightBuffer: Buffer
    _lightingPipeline: GraphicsPipeline
    _compositePipeline: GraphicsPipeline
    _sceneUniform: loader.CArray
    _destroyed: boolean
end

local DeferredMT <const>: metatable<Deferred> = { __index = Deferred }

local function buildPipeline(device: loader.CPtr, fragmentName: string,
                             format: integer, name: string): GraphicsPipeline
    local vertex = Shader.load(device, "deferred.fullscreen.vert", {})
    local fragment = Shader.load(device, fragmentName, {})
    local pipeline = GraphicsPipeline.create(device, {
        vertexShader = vertex,
        fragmentShader = fragment,
        colorFormat = format,
        name = name,
    })
    vertex:destroy()
    fragment:destroy()
    return pipeline
end

--- Builds the pipeline and its graph.
function Deferred.create(device: loader.CPtr, swapchainFormat: integer,
                         options: DeferredOptions): Deferred
    options = options or {}

    local self = setmetatable({} as Deferred, DeferredMT)
    self._device = device
    self.lightCount = 0
    self.ambient = options.ambient or { 0.08, 0.08, 0.10 }
    self._destroyed = false

    self._lightBuffer = Buffer.create(device, {
        usage = { "storage" },
        size = MAX_LIGHTS * LIGHT_STRIDE,
    })
    self._sceneUniform = loader.newArray("float[8]")

    local graph = PassGraph.create(device, swapchainFormat)
    graph:target({
        name = "albedo",
        format = RGBA8,
        clear = { r = 0, g = 0, b = 0, a = 0 },
    })
    graph:target({
        name = "normal",
        format = RGBA8,
        -- Encodes a surface facing the viewer, so geometry that writes no
        -- normal still lights plausibly rather than going black.
        clear = { r = 0.5, g = 0.5, b = 1.0, a = 0 },
    })
    graph:target({
        name = "lit",
        format = RGBA8,
        clear = { r = 0, g = 0, b = 0, a = 1 },
    })

    self._lightingPipeline = buildPipeline(device, "deferred.lighting.frag",
        RGBA8, "lighting")
    self._compositePipeline = buildPipeline(device, "deferred.composite.frag",
        swapchainFormat, "composite")

    graph:pass({
        name = "geometry",
        outputs = { "albedo", "normal" },
        execute = function(context: PassGraph.PassContext)
            if options.geometry ~= nil then options.geometry(context) end
        end,
    })

    graph:pass({
        name = "lighting",
        inputs = { "albedo", "normal" },
        outputs = { "lit" },
        execute = function(context: PassGraph.PassContext)
            local scene = self._sceneUniform
            scene[0] = self.ambient[1]
            scene[1] = self.ambient[2]
            scene[2] = self.ambient[3]
            scene[3] = 0.0
            scene[4] = context.width
            scene[5] = context.height
            scene[6] = self.lightCount
            scene[7] = 0.0

            context.pass:bindPipeline(self._lightingPipeline.handle)
            context.pass:bindFragmentStorageBuffers(0, { self._lightBuffer.handle })
            C.SDL_PushGPUFragmentUniformData(context.commandBuffer, 0, scene, 32)
            context.pass:draw(3)
        end,
    })

    graph:pass({
        name = "composite",
        inputs = { "lit" },
        outputs = {},
        execute = function(context: PassGraph.PassContext)
            context.pass:bindPipeline(self._compositePipeline.handle)
            context.pass:draw(3)
        end,
    })

    self.graph = graph
    return self
end

--- Replaces the light set for subsequent frames.
---
--- Writes straight into the buffer's mapped staging: there is no intermediate
--- array to fill and then copy. The upload itself is deferred to `render`, so
--- it rides the frame's command buffer instead of submitting its own.
function Deferred:setLights(lights: {Light})
    local count = math.min(#lights, MAX_LIGHTS)
    self.lightCount = count
    if count == 0 then return end

    local staging = self._lightBuffer:mapAs("float *")
    for index = 1, count do
        local light = lights[index]
        local base = (index - 1) * 8
        staging[base] = light.x or 0.0
        staging[base + 1] = light.y or 0.0
        staging[base + 2] = light.z or 32.0
        staging[base + 3] = light.radius or 128.0
        staging[base + 4] = light.r or 1.0
        staging[base + 5] = light.g or 1.0
        staging[base + 6] = light.b or 1.0
        staging[base + 7] = light.intensity or 1.0
    end
    self._lightBuffer:markDirty(0, count * LIGHT_STRIDE)
end

--- Runs the pipeline for one frame.
---
--- Any pending light writes are flushed onto this frame's command buffer
--- first, so the copy is ordered against the lighting pass that reads it
--- rather than racing a separately submitted upload.
function Deferred:render(frame: Frame)
    self._lightBuffer:flush(frame.commandBuffer)
    self.graph:execute(frame)
end

--- Returns the format a geometry pipeline must be created against.
function Deferred:geometryFormats(): integer, integer
    return self.graph:formatOf("albedo"), self.graph:formatOf("normal")
end

--- Releases everything the pipeline owns. Safe to call more than once.
function Deferred:destroy()
    if self._destroyed then return end
    self._destroyed = true
    self.graph:destroy()
    self._lightingPipeline:destroy()
    self._compositePipeline:destroy()
    self._lightBuffer:destroy()
end

return Deferred
