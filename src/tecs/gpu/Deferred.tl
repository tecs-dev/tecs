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
---
--- Geometry owns the depth attachment, testing and writing, so wherever two
--- instances overlap the nearer one is what the G-buffer keeps. Lighting and
--- composite have none: each covers every pixel exactly once and has nothing
--- to be occluded by, so an attachment there would be state to keep in step
--- for no result.

local loader <const> = require("tecs.ffi.loader")
local sdl <const> = require("tecs.ffi.sdl3")
local PassGraph <const> = require("tecs.gpu.PassGraph")
local Shader <const> = require("tecs.gpu.Shader")
local Buffer <const> = require("tecs.gpu.Buffer")
local GraphicsPipeline <const> = require("tecs.gpu.GraphicsPipeline")
local Frame <const> = require("tecs.gpu.Frame")
local lightlayout <const> = require("tecs.gpu.lightlayout")

local C <const> = sdl.C

--- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local RGBA8 <const> = 4

local MAX_LIGHTS <const> = lightlayout.MAX
local LIGHT_FLOATS <const> = lightlayout.FLOATS
local LIGHT_STRIDE <const> = lightlayout.BYTES

--- One point light, positioned against the pixels it lands on.
---
--- Lighting runs after geometry has been rasterised, so a light is placed in
--- the target's own pixels rather than in world units: whatever put geometry
--- on a pixel is the caller's business, and by this pass it is settled.
local record Light
    --- Position in the lighting target's pixels, from its top-left corner.
    --- The same origin `gl_FragCoord` and `Texture:getPixel` use, so a light
    --- placed at a pixel a readback names lands on that pixel.
    x: number
    y: number
    --- Height above the surface, in those same pixels. Zero puts the light in
    --- the surface plane, where a surface facing the viewer receives nothing
    --- from it, since the direction to the light is then perpendicular to the
    --- normal.
    z: number
    --- Reach in pixels. Falloff runs smoothly to zero at the radius, so this
    --- bounds what the light costs as well as how far it carries. Values below
    --- one are treated as one.
    radius: number
    --- Colour, in 0..1 per channel.
    r: number
    g: number
    b: number
    --- Multiplies the colour before it accumulates. Above one is useful: what
    --- clamps is the target, once the sum has been applied to albedo, so a
    --- bright light saturates towards the surface's own colour rather than
    --- being cut off on its way in.
    intensity: number
end

local record DeferredOptions
    --- Draws into the G-buffer. Writes location 0 for albedo and location 1
    --- for a normal biased into unsigned range.
    ---
    --- Location 1's alpha is what decides lighting: a fragment carrying less
    --- than a half passes through at its own albedo, and one at or above a
    --- half is lit. Geometry that writes a normal and leaves that alpha at
    --- zero is drawn unlit, which reads as lighting doing nothing.
    geometry: function(context: PassGraph.PassContext)
    --- Ambient colour, added to every lit fragment before any light is.
    --- Defaults to a dim neutral. A fragment that asked not to be lit does not
    --- receive it, and neither does a pixel nothing drew over.
    ambient: {number}
end

local record Deferred
    --- One light, as `setLights` takes them.
    Light: Light
    --- What a geometry callback receives. Re-exported so callers need not
    --- reach into PassGraph for it.
    PassContext: PassGraph.PassContext
    --- The three passes, so a caller can add its own targets and passes around
    --- them or ask what a pass was built with.
    graph: PassGraph
    --- Lights the lighting pass reads. Set by `setLights` and kept until it is
    --- called again, so a frame that says nothing lights as the last one did.
    lightCount: integer
    --- Ambient colour in use, as three components. Written by `create` and
    --- read at the top of every lighting pass, so assigning to it takes effect
    --- on the next frame without rebuilding anything.
    ambient: {number}
    _device: loader.CPtr
    --- The lights themselves, as `MAX_LIGHTS` slots of `LIGHT_STRIDE` bytes.
    --- Written through slot zero and flushed by `render`.
    _lightBuffer: Buffer
    --- Where `setLights` packs records before handing them on, so the packed
    --- form has one writer.
    _lightScratch: loader.CArray
    _lightingPipeline: GraphicsPipeline
    _compositePipeline: GraphicsPipeline
    --- Eight floats pushed to the lighting fragment stage: ambient and a pad,
    --- then target size, light count and a pad. Held rather than allocated per
    --- frame, since the pass runs every frame.
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
---
--- The lighting and composite shaders are loaded and their shader objects
--- released here, since SDL retains what a pipeline needs. What survives is
--- the two pipelines, the light buffer and the graph's targets, all of which
--- `destroy` releases.
--- @param swapchainFormat What composite writes to, from
---     `Device:getSwapchainFormat`. The G-buffer's own formats are fixed and
---     come back out of `geometryFormats`.
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
    self._lightScratch = loader.newArray("float[?]", MAX_LIGHTS * LIGHT_FLOATS)
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
        -- The alpha is what carries here. Zero marks a pixel as unlit, so
        -- anything nothing drew over composites as the albedo clear instead of
        -- picking up ambient over a normal it never wrote. The rgb encodes a
        -- surface facing the viewer, which is what geometry writes, so the
        -- attachment reads consistently either way.
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
        -- Cleared to the far plane every frame, and "lessOrEqual" rather than
        -- "less" so equal depths still resolve to whatever drew last. Draw
        -- order is deterministic and means something here, so depth decides
        -- between instances that differ and leaves the rest alone.
        depth = {
            test = true,
            write = true,
            compare = "lessOrEqual",
            clear = 1.0,
        },
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
--- One block copy into the buffer's mapped staging, because the caller's array
--- is already the shape the shader reads and the whole set is at most eight
--- kilobytes. The upload itself is deferred to `render`, so it rides the
--- frame's command buffer instead of submitting its own.
---
--- Past `lightlayout.MAX` the remainder is dropped rather than reported,
--- because the alternative is a frame that raises over a light nobody would
--- have picked out of the image.
--- @param data Lights already in `lightlayout` order, `FLOATS` per light.
--- @param count Lights in `data`. Zero leaves the buffer as it was and lights
---     nothing, since the count is what the shader loops over.
function Deferred:setLightData(data: loader.CArray, count: integer)
    if count > MAX_LIGHTS then count = MAX_LIGHTS end
    self.lightCount = count
    if count == 0 then return end

    local bytes <const> = count * LIGHT_STRIDE
    loader.copyTo(self._lightBuffer:map(), data as loader.CValue, bytes)
    self._lightBuffer:markDirty(0, bytes)
end

--- Replaces the light set from records rather than from packed floats.
---
--- The record form is what a caller assembling a handful of lights by hand
--- wants. Anything producing a light per entity per frame packs directly and
--- calls `setLightData`, since a record per light per frame is an allocation
--- per light per frame.
--- @param lights Lights to light with, replacing the previous set entirely.
function Deferred:setLights(lights: {Light})
    local count = math.min(#lights, MAX_LIGHTS)
    local scratch = self._lightScratch
    for index = 1, count do
        local light = lights[index]
        local base = (index - 1) * LIGHT_FLOATS
        scratch[base] = light.x or 0.0
        scratch[base + 1] = light.y or 0.0
        scratch[base + 2] = light.z or 32.0
        scratch[base + 3] = light.radius or 128.0
        scratch[base + 4] = light.r or 1.0
        scratch[base + 5] = light.g or 1.0
        scratch[base + 6] = light.b or 1.0
        scratch[base + 7] = light.intensity or 1.0
    end
    self:setLightData(scratch, count)
end

--- Runs the pipeline for one frame.
---
--- Any pending light writes are flushed onto this frame's command buffer
--- first, so the copy is ordered against the lighting pass that reads it
--- rather than racing a separately submitted upload.
--- @param frame The frame to record into. Composite writes to its swapchain
---     texture and the graph sizes its targets to its width and height, so a
---     resized window is picked up here rather than announced.
function Deferred:render(frame: Frame)
    self._lightBuffer:flush(frame.commandBuffer)
    self.graph:execute(frame)
end

--- Returns the two formats a geometry pipeline must be created against.
---
--- In attachment order, so a pipeline passes them straight through as its
--- colour formats and cannot get albedo and normal the wrong way round.
--- @return The albedo target's format, then the normal target's.
function Deferred:geometryFormats(): integer, integer
    return self.graph:formatOf("albedo"), self.graph:formatOf("normal")
end

--- Returns the depth state a geometry pipeline must be created with.
---
--- Taken from the pass rather than restated, so the pipeline cannot disagree
--- with the attachment it draws into.
function Deferred:geometryDepth(): GraphicsPipeline.DepthConfig
    return self.graph:depthOf("geometry")
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
