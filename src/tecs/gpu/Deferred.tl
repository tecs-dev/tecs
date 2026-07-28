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
---
--- One compute dispatch runs ahead of the graph, binning the lights into a
--- grid over what the camera can see so the lighting pass reads a tile's worth
--- rather than the whole buffer. It is here rather than in the graph because
--- the graph is a graph of render passes; the same is true of the instance
--- cull, which runs ahead of `render` for the same reason.

local loader <const> = require("tecs.ffi.loader")
local sdl <const> = require("tecs.ffi.sdl3")
local PassGraph <const> = require("tecs.gpu.PassGraph")
local Shader <const> = require("tecs.gpu.Shader")
local Buffer <const> = require("tecs.gpu.Buffer")
local GraphicsPipeline <const> = require("tecs.gpu.GraphicsPipeline")
local Frame <const> = require("tecs.gpu.Frame")
local ComputePipeline <const> = require("tecs.gpu.ComputePipeline")
local ComputePass <const> = require("tecs.gpu.ComputePass")
local lightlayout <const> = require("tecs.gpu.lightlayout")

local C <const> = sdl.C

--- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local RGBA8 <const> = 4

local MAX_LIGHTS <const> = lightlayout.MAX
local LIGHT_FLOATS <const> = lightlayout.FLOATS
local LIGHT_STRIDE <const> = lightlayout.BYTES
local TILE_COUNT <const> = lightlayout.TILE_COUNT
local TILE_SLOTS <const> = lightlayout.TILE_SLOTS

--- Threads per binning workgroup, matching the shader's local size.
local BIN_GROUP <const> = 64

--- One point light, positioned in the world the camera is looking at.
---
--- World units rather than target pixels, because a light is a thing in the
--- scene: the view carries it the way it carries geometry, and a light left in
--- target pixels would sit still on screen while everything around it panned.
--- `setView` is what the lighting pass inverts to put a fragment back in this
--- space, and a pipeline that never sets one treats world units as target
--- pixels, which is the same default the renderer's camera takes.
local record Light
    --- Position in world units. Y runs down, as it does everywhere else here.
    x: number
    y: number
    --- Height above the surface, in world units. Zero puts the light in the
    --- surface plane, where a surface facing the viewer receives nothing from
    --- it, since the direction to the light is then perpendicular to the
    --- normal.
    z: number
    --- Reach in world units. Falloff runs smoothly to zero at the radius, so
    --- this bounds what the light costs as well as how far it carries. Values
    --- below one are treated as one, and zoom scales what it covers on screen
    --- rather than what it covers in the world.
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
    --- Lights reaching each tile, as a count per tile and a list of slots per
    --- tile. Written by the binning dispatch and read by the lighting pass,
    --- and sized from a fixed grid so neither is ever reallocated under a
    --- frame that is still reading it.
    _tileCounts: Buffer
    _tileLights: Buffer
    --- The buffer lists the binning pass and the lighting pass hand the pass
    --- API, one per call site and each of a fixed length. Held rather than
    --- built per frame, and rewritten at every use, since a buffer that grew
    --- has a new handle.
    _binWrites: {loader.CValue}
    _binReads: {loader.CValue}
    _lightingBuffers: {loader.CValue}
    --- The binning pass, begun again each frame rather than allocated per
    --- frame; see `ComputePass.begin` for what that asks of a caller.
    _binPass: ComputePass
    _binPipeline: ComputePipeline
    --- Eight floats pushed to the binning dispatch: the world rectangle the
    --- grid covers, then the light count.
    _binUniform: loader.CArray
    _lightingPipeline: GraphicsPipeline
    _compositePipeline: GraphicsPipeline
    --- Sixteen floats pushed to the lighting fragment stage: ambient, then
    --- the target size, then the view, then the grid's world rectangle, each
    --- padded out to a vec4. Held rather than allocated per frame, since the
    --- pass runs every frame.
    _sceneUniform: loader.CArray
    --- The view lights are placed against, as `setView` left it. Zoom and
    --- rotation are kept folded into the two components the shader multiplies
    --- by, so the trig is paid once a frame rather than once a fragment.
    _viewX: number
    _viewY: number
    _viewCos: number
    _viewSin: number
    --- Whether anything has set a view. Until something does, the frame
    --- centres one on its own target, so world units are target pixels and a
    --- pipeline driven without a camera behaves as it reads.
    _viewSet: boolean
    --- The view as `render` resolved it for the frame being drawn, and the
    --- world rectangle the tile grid covers under it. Resolved there rather
    --- than in each of the two places that need it, because the binning
    --- dispatch and the lighting pass have to agree about the grid exactly: a
    --- light binned against one rectangle and looked up against another lands
    --- in a tile nothing reads.
    _frameViewX: number
    _frameViewY: number
    _frameViewCos: number
    _frameViewSin: number
    _boundsMinX: number
    _boundsMinY: number
    _boundsMaxX: number
    _boundsMaxY: number
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
        -- Read by a compute pass as well as by the lighting pass, since the
        -- binning dispatch is what turns the buffer into per-tile lists.
        usage = { "storage", "computeRead" },
        size = MAX_LIGHTS * LIGHT_STRIDE,
    })
    self._lightScratch = loader.newArray("float[?]", MAX_LIGHTS * LIGHT_FLOATS)
    self._sceneUniform = loader.newArray("float[16]")
    self._binUniform = loader.newArray("float[8]")
    self._viewX = 0.0
    self._viewY = 0.0
    self._viewCos = 1.0
    self._viewSin = 0.0
    self._viewSet = false
    self._frameViewX = 0.0
    self._frameViewY = 0.0
    self._frameViewCos = 1.0
    self._frameViewSin = 0.0
    self._boundsMinX = 0.0
    self._boundsMinY = 0.0
    self._boundsMaxX = 0.0
    self._boundsMaxY = 0.0

    -- One binding for the pass that fills them and one for the pass that
    -- reads them, and a fixed size, so a resized window replaces the graph's
    -- targets and leaves these where they are.
    self._tileCounts = Buffer.create(device, {
        usage = { "storage", "computeWrite" },
        size = TILE_COUNT * 4,
        name = "tecs.lightTileCounts",
    })
    self._tileLights = Buffer.create(device, {
        usage = { "storage", "computeWrite" },
        size = TILE_COUNT * TILE_SLOTS * 4,
        name = "tecs.lightTiles",
    })
    self._binPipeline = ComputePipeline.load(device, "deferred.lightbin.comp",
        {})

    -- Seeded with what the buffers hold now, which gives each list its length.
    self._binWrites = { self._tileCounts.handle, self._tileLights.handle }
    self._binReads = { self._lightBuffer.handle }
    self._lightingBuffers = { self._lightBuffer.handle, self._tileCounts.handle,
        self._tileLights.handle }

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
            -- Out to the vec4 the block is laid out in. The light count is
            -- not here: what bounds the pass's loop is a tile's own count,
            -- and a second number saying something close to it is a second
            -- number to keep in step.
            scene[6] = 0.0
            scene[7] = 0.0
            -- As `render` resolved them for this frame, so the grid the
            -- fragment looks a tile up in is the grid the dispatch filled.
            scene[8] = self._frameViewX
            scene[9] = self._frameViewY
            scene[10] = self._frameViewCos
            scene[11] = self._frameViewSin
            scene[12] = self._boundsMinX
            scene[13] = self._boundsMinY
            scene[14] = self._boundsMaxX
            scene[15] = self._boundsMaxY

            local buffers <const> = self._lightingBuffers
            buffers[1] = self._lightBuffer.handle
            buffers[2] = self._tileCounts.handle
            buffers[3] = self._tileLights.handle

            context.pass:bindPipeline(self._lightingPipeline.handle)
            context.pass:bindFragmentStorageBuffers(0, buffers)
            C.SDL_PushGPUFragmentUniformData(context.commandBuffer, 0, scene, 64)
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

--- Says where the view is, so the lighting pass can invert it.
---
--- Lights are placed in world units and the lighting pass runs over target
--- pixels, so something has to relate the two, and it has to be the same
--- relation the geometry pass drew with or a light lands away from what it is
--- lighting. Four numbers rather than a matrix, because the projection is
--- orthographic: its inverse is a rotation, a scale and an offset, and the
--- shader applies it in two multiply-adds.
---
--- Called every frame by whatever owns the camera. A pipeline nothing calls
--- this on centres a view on the target instead, which makes world units
--- target pixels.
--- @param x Centre of the view in world units.
--- @param y Centre of the view in world units, with Y running down.
--- @param zoom Above one magnifies. Zero is treated as one rather than
---     dividing through, since a view that shows nothing is not what a caller
---     assigning a zoom of zero meant.
--- @param rotation Radians, the same sense the camera turns in.
function Deferred:setView(x: number, y: number, zoom: number,
                          rotation: number)
    self._viewSet = true
    self._viewX = x
    self._viewY = y
    local inverse <const> = zoom ~= 0.0 and 1.0 / zoom or 1.0
    self._viewCos = math.cos(rotation) * inverse
    self._viewSin = math.sin(rotation) * inverse
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

--- Resolves the view for a frame of this size, and the grid it implies.
---
--- One derivation, read by the binning dispatch and by the lighting pass. The
--- world rectangle is the axis-aligned bound of what the camera can see, which
--- is wider than the view when the camera is turned: every fragment's world
--- position lands inside it either way, which is what a grid a fragment
--- indexes into has to promise.
local function resolveView(self: Deferred, width: number, height: number)
    if self._viewSet then
        self._frameViewX = self._viewX
        self._frameViewY = self._viewY
        self._frameViewCos = self._viewCos
        self._frameViewSin = self._viewSin
    else
        -- Centred on the target at zoom one, which puts a world unit on a
        -- target pixel and the world origin in the corner. The size is only
        -- known here, which is why the default is applied per frame rather
        -- than at creation.
        self._frameViewX = width * 0.5
        self._frameViewY = height * 0.5
        self._frameViewCos = 1.0
        self._frameViewSin = 0.0
    end

    -- Half the target against the view's own axes. The two components already
    -- carry the reciprocal zoom, so this is the half extent in world units:
    -- the same `width / (2 * zoom)` the cull works from, with the rotation
    -- folded in rather than applied after.
    local halfWidth <const> = width * 0.5
    local halfHeight <const> = height * 0.5
    local across <const> = math.abs(self._frameViewCos)
    local down <const> = math.abs(self._frameViewSin)
    local extentX <const> = halfWidth * across + halfHeight * down
    local extentY <const> = halfWidth * down + halfHeight * across
    self._boundsMinX = self._frameViewX - extentX
    self._boundsMinY = self._frameViewY - extentY
    self._boundsMaxX = self._frameViewX + extentX
    self._boundsMaxY = self._frameViewY + extentY
end

--- Runs the pipeline for one frame.
---
--- Any pending light writes are flushed onto this frame's command buffer
--- first, so the copy is ordered against the binning dispatch and the lighting
--- pass that read it rather than racing a separately submitted upload.
---
--- Binning runs every frame, including one with nothing lighting anything. It
--- is the only writer of the tile counts, so a frame that skipped it would
--- leave the last frame's lists standing and light the scene by lights that
--- have gone. A thousand threads writing a zero is cheaper than the guard that
--- would be needed to make skipping safe.
--- @param frame The frame to record into. Composite writes to its swapchain
---     texture and the graph sizes its targets to its width and height, so a
---     resized window is picked up here rather than announced.
function Deferred:render(frame: Frame)
    self._lightBuffer:flush(frame.commandBuffer)
    resolveView(self, frame.width, frame.height)

    local bin <const> = self._binUniform
    bin[0] = self._boundsMinX
    bin[1] = self._boundsMinY
    bin[2] = self._boundsMaxX
    bin[3] = self._boundsMaxY
    bin[4] = self.lightCount
    bin[5] = 0.0
    bin[6] = 0.0
    bin[7] = 0.0

    local writes <const> = self._binWrites
    writes[1] = self._tileCounts.handle
    writes[2] = self._tileLights.handle
    local reads <const> = self._binReads
    reads[1] = self._lightBuffer.handle

    local pass <const> = ComputePass.begin(frame.commandBuffer, writes,
        self._binPass)
    self._binPass = pass
    pass:bindPipeline(self._binPipeline.handle)
    pass:bindStorageBuffers(0, reads)
    C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0, bin, 32)
    pass:dispatch(math.ceil(TILE_COUNT / BIN_GROUP))
    pass:finish()

    self.graph:execute(frame)
end

--- Rebuilds the lighting and composite pipelines from their shaders.
---
--- The same formats and the same graph: only the two pipeline objects change,
--- and both passes read them through `self` when they execute, so the next
--- frame binds the new ones with nothing rebuilt around them.
---
--- Both are built before either old one is released, so a shader that no longer
--- compiles leaves the pipeline exactly as it was and raises. Must not run
--- inside a pass: what it releases is what a recorded pass is still reading.
function Deferred:rebuildPipelines()
    local device <const> = self._device
    C.SDL_WaitForGPUIdle(device)

    local lighting: GraphicsPipeline = nil
    local composite: GraphicsPipeline = nil
    local bin: ComputePipeline = nil
    local built, reason = pcall(function(): string
        lighting = buildPipeline(device, "deferred.lighting.frag", RGBA8,
            "lighting")
        composite = buildPipeline(device, "deferred.composite.frag",
            self.graph.swapchainFormat, "composite")
        bin = ComputePipeline.load(device, "deferred.lightbin.comp", {})
    end)
    if not built then
        if lighting ~= nil then lighting:destroy() end
        if composite ~= nil then composite:destroy() end
        if bin ~= nil then bin:destroy() end
        error(reason, 0)
    end

    local oldLighting <const> = self._lightingPipeline
    local oldComposite <const> = self._compositePipeline
    local oldBin <const> = self._binPipeline
    self._lightingPipeline = lighting
    self._compositePipeline = composite
    self._binPipeline = bin
    oldLighting:destroy()
    oldComposite:destroy()
    oldBin:destroy()
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
    self._binPipeline:destroy()
    self._lightBuffer:destroy()
    self._tileCounts:destroy()
    self._tileLights:destroy()
end

return Deferred
