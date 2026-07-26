--- Feeds the deferred pipeline from a world.
---
--- This is the bridge, and the only module that knows about both archetypes
--- and GPU buffers. Everything below it is renderer; above it is Tecs.
---
--- The sync walks archetype columns and writes instances straight into mapped
--- staging. There is no intermediate array: the column is contiguous C memory
--- and so is the destination, so a row becomes a handful of float stores into
--- driver memory rather than a copy between two buffers.
---
--- Instances pack as four vec4s: a 2x2 basis, an origin, a colour, and a UV
--- rect. A precomputed basis costs less on the GPU than a per-vertex sincos.
---
--- Images live in one array texture, so the texture is a per-instance integer
--- and the whole scene is one draw. That is also what frees the instance
--- layout: with nothing to sort by, each archetype keeps a contiguous run,
--- and a run whose components did not change does not have to be rewritten.
---
--- That dirty gating is the point. Walking every entity every frame is the
--- cost that decides whether a large world is affordable, and most frames
--- change very little. Layer zero is a white pixel, so an entity with no
--- Sprite samples it and textured and untextured geometry share one path.
---
--- What is drawn is decided on the GPU. A compute pass tests each instance
--- against the view, compacts the survivors into an index list, and writes the
--- draw arguments, so the draw touches only what is visible and the CPU never
--- learns how many that was. The instance buffer stays archetype-contiguous
--- for the dirty gate; the compacted list is rebuilt every frame and is a
--- separate array, so the two do not fight.

local ecs <const> = require("tecs.ecs")
local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local Buffer <const> = require("tecs.gpu.Buffer")
local Shader <const> = require("tecs.gpu.Shader")
local Frame <const> = require("tecs.gpu.Frame")
local GraphicsPipeline <const> = require("tecs.gpu.GraphicsPipeline")
local Deferred <const> = require("tecs.gpu.Deferred")
local Sampler <const> = require("tecs.gpu.Sampler")
local ComputePipeline <const> = require("tecs.gpu.ComputePipeline")
local ComputePass <const> = require("tecs.gpu.ComputePass")
local TextureArray <const> = require("tecs.gpu.TextureArray")
local Texture <const> = require("tecs.gpu.Texture")
local Camera <const> = require("tecs.gfx.Camera")
local assets <const> = require("tecs.assets")
local components <const> = require("tecs.components")
local timing <const> = require("tecs.timing")

local C <const> = sdl.C

--- Extraction: the world-facing half of the frame, and the half that moves to
--- the simulation thread when the pipeline splits.
local EXTRACT <const> = timing.stage("extract")

--- Floats per instance: four vec4s.
local INSTANCE_FLOATS <const> = 16
local INSTANCE_BYTES <const> = INSTANCE_FLOATS * 4

--- Floats per cull bound: centre xy and half extent xy.
---
--- Kept apart from the instance because the cull reads it for every entity
--- every frame, drawn or not, while the instance is only read for what
--- survives. Sixteen bytes streamed beats sixty-four bytes gathered.
local BOUND_FLOATS <const> = 4
local BOUND_BYTES <const> = BOUND_FLOATS * 4

--- Indices per quad, over four distinct corners.
local QUAD_INDICES <const> = 6

--- Threads per cull workgroup, matching the scan shaders' local size.
local CULL_GROUP <const> = 256

local abs <const> = math.abs

--- Layers the image array holds, including the white default in layer zero.
local MAX_LAYERS <const> = 64

--- Cell size of the image array. Every image must fit within it.
local DEFAULT_CELL <const> = 512

--- Instances the buffer is sized for. This is a ceiling, not a hint: rows
--- beyond it are dropped rather than growing the buffer mid-frame.
local DEFAULT_CAPACITY <const> = 65536

local record RendererOptions
    --- Ambient colour applied everywhere.
    ambient: {number}
    --- Instances the buffer is sized for.
    capacity: integer
    --- Cell size of the image array.
    cell: integer
    --- Layers the image array holds.
    layers: integer
end

local record Renderer
    --- Seconds the last extraction took. Zero unless timing is on.
    _extractSeconds: number
    deferred: Deferred
    instances: Buffer
    pipeline: GraphicsPipeline
    sampler: Sampler
    --- Every image, one binding, so the scene is one draw.
    images: TextureArray
    capacity: integer
    --- Instances the last sync left resident.
    count: integer
    --- Instances the last sync could not fit.
    dropped: integer
    --- Instances the last sync actually rewrote. Zero on a still frame.
    rewritten: integer
    _mark: ComputePipeline
    _scan: ComputePipeline
    _compact: ComputePipeline
    _bounds: Buffer
    _slots: Buffer
    _blocks: Buffer
    _visible: Buffer
    _drawArgs: Buffer
    _indices: Buffer
    --- What the view is looking at. Centred on the viewport the first time a
    --- frame is drawn, so a scene that never mentions a camera sees world
    --- coordinates as screen coordinates.
    camera: Camera
    _centred: boolean
    _cullUniform: loader.CArray
    _device: loader.CPtr
    _lights: {Deferred.Light}
    _renderables: ecs.Query
    _lightSources: ecs.Query
    --- UV extent of the white pixel within its cell. An image smaller than a
    --- cell does not reach the cell's edge, so sampling 0..1 would read the
    --- undefined remainder rather than the image.
    _whiteU1: number
    _whiteV1: number
    _runs: {ecs.Archetype: Run}
    _seen: {ecs.Archetype: integer}
    _destroyed: boolean
end

local RendererMT <const>: metatable<Renderer> = { __index = Renderer }

--- Writes every renderable archetype into mapped staging.
---
--- Columns are read, not mutated, so `get` is correct here. Taking `getMut`
--- would mark these components dirty on every archetype every frame and
--- defeat every dirty-gated consumer downstream.
--- One archetype's contiguous run in the instance buffer.
local record Run
    offset: integer
    length: integer
end

--- Writes one archetype's rows into its run.
---
--- Columns are read, not mutated, so `get` is correct here. Taking `getMut`
--- would mark these components dirty on every archetype every frame, which
--- would make the gate below always true and defeat its own purpose.
local function writeRun(self: Renderer, archetype: ecs.Archetype,
                        length: integer, offset: integer)
    local floats = self.instances:mapAs("float *")
    local bounds = self._bounds:mapAs("float *")
    local transforms = archetype:get(components.Transform2D)
    local tints = archetype:get(components.Tint)
    local sprites = archetype:get(components.Sprite)
    local materialColumn = archetype:get(components.Material)

    for row = 1, length do
        local transform = transforms[row]
        local tint = tints[row]

        local layer = 0.0
        local u0, v0 = 0.0, 0.0
        local u1, v1 = self._whiteU1, self._whiteV1
        if sprites ~= nil then
            local sprite = sprites[row]
            layer = sprite.slot
            u0, v0, u1, v1 = sprite.u0, sprite.v0, sprite.u1, sprite.v1
        end

        -- Material and parameter share one float: the integer part selects and
        -- the fraction carries the parameter, which is a ratio in 0..1 for
        -- every material that has one. Keeps the instance at four vec4s.
        local material = 0.0
        if materialColumn ~= nil then
            local entry = materialColumn[row]
            local param = entry.param
            if param < 0.0 then
                param = 0.0
            elseif param > 0.999 then
                param = 0.999
            end
            material = entry.id + param
        end

        local angle = transform.rotation
        local scaleX = transform.scaleX
        local scaleY = transform.scaleY

        local base = (offset + row - 1) * INSTANCE_FLOATS
        floats[base] = angle
        floats[base + 1] = scaleX
        floats[base + 2] = scaleY
        floats[base + 3] = 0.0

        floats[base + 4] = transform.x
        floats[base + 5] = transform.y
        floats[base + 6] = layer
        floats[base + 7] = material

        floats[base + 8] = tint.r
        floats[base + 9] = tint.g
        floats[base + 10] = tint.b
        floats[base + 11] = tint.a

        floats[base + 12] = u0
        floats[base + 13] = v0
        floats[base + 14] = u1
        floats[base + 15] = v1

        -- Extents without a trigonometric call. Unrotated, each axis is its
        -- own scale. Rotated, half the sum of both scales covers every angle,
        -- which is looser than the true extent but never smaller, so the cull
        -- can only ever keep something it might have dropped.
        local ex: number
        local ey: number
        if angle == 0.0 then
            ex = 0.5 * abs(scaleX)
            ey = 0.5 * abs(scaleY)
        else
            ex = 0.5 * (abs(scaleX) + abs(scaleY))
            ey = ex
        end

        local bound = (offset + row - 1) * BOUND_FLOATS
        bounds[bound] = transform.x
        bounds[bound + 1] = transform.y
        bounds[bound + 2] = ex
        bounds[bound + 3] = ey
    end

    self.instances:markDirty(offset * INSTANCE_BYTES, length * INSTANCE_BYTES)
    self._bounds:markDirty(offset * BOUND_BYTES, length * BOUND_BYTES)
end

--- Rewrites only what changed.
---
--- The layout is rebuilt when the set of archetypes or their lengths move,
--- because a run cannot grow in place without shifting its neighbours. Short
--- of that, an archetype whose Transform2D, Tint, and Sprite columns are all
--- clean is skipped entirely: its bytes are already resident and correct.
local function syncInstances(self: Renderer): integer, integer, integer
    local runs = self._runs
    local seen = self._seen
    for archetype in pairs(seen) do seen[archetype] = nil end

    local total = 0
    local relayout = false
    for archetype, length in self._renderables:iter() do
        seen[archetype] = length
        local run = runs[archetype]
        if run == nil or run.length ~= length or run.offset ~= total then
            relayout = true
        end
        total = total + length
    end

    -- An archetype that went away leaves a hole, so the layout must move.
    for archetype in pairs(runs) do
        if seen[archetype] == nil then
            runs[archetype] = nil
            relayout = true
        end
    end

    local dropped = 0
    if total > self.capacity then
        dropped = total - self.capacity
        total = self.capacity
    end

    local rewritten = 0
    local offset = 0
    for archetype, length in self._renderables:iter() do
        if offset >= self.capacity then break end
        if offset + length > self.capacity then
            length = self.capacity - offset
        end

        local run = runs[archetype]
        local dirty = relayout
            or archetype:isComponentDirty(components.Transform2D)
            or archetype:isComponentDirty(components.Tint)
            or archetype:isComponentDirty(components.Sprite)
            or archetype:isComponentDirty(components.Material)

        if dirty then
            writeRun(self, archetype, length, offset)
            rewritten = rewritten + length
        end

        if run == nil then
            runs[archetype] = { offset = offset, length = length }
        else
            run.offset = offset
            run.length = length
        end
        offset = offset + length
    end

    return total, dropped, rewritten
end

--- Collects lights from the world.
local function syncLights(self: Renderer): {Deferred.Light}
    local lights = self._lights
    for index = #lights, 1, -1 do lights[index] = nil end

    for archetype, length in self._lightSources:iter() do
        local transforms = archetype:get(components.Transform2D)
        local sources = archetype:get(components.PointLight)
        for row = 1, length do
            local transform = transforms[row]
            local source = sources[row]
            lights[#lights + 1] = {
                x = transform.x,
                y = transform.y,
                z = source.height,
                radius = source.radius,
                r = source.r,
                g = source.g,
                b = source.b,
                intensity = source.intensity,
            }
        end
    end
    return lights
end

--- Builds a renderer for `device`.
function Renderer.create(device: loader.CPtr, swapchainFormat: integer,
                         options: RendererOptions): Renderer
    options = options or {}

    local self = setmetatable({} as Renderer, RendererMT)
    self._device = device
    self.capacity = options.capacity or DEFAULT_CAPACITY
    self.count = 0
    self.dropped = 0
    self.rewritten = 0
    self._lights = {}
    self._runs = {}
    self._seen = {}
    self._destroyed = false

    self.sampler = Sampler.create(device, { filter = "nearest", address = "clamp" })
    self.images = TextureArray.create(device, {
        width = options.cell or DEFAULT_CELL,
        height = options.cell or DEFAULT_CELL,
        layers = options.layers or MAX_LAYERS,
    })

    -- Layer zero is a single white pixel. Entities without a Sprite sample it,
    -- so textured and untextured geometry share one shader and one pipeline
    -- rather than needing a branch or a second path.
    local pixel = loader.newArray("uint8_t[4]")
    pixel[0], pixel[1], pixel[2], pixel[3] = 255, 255, 255, 255
    local white = self.images:add(pixel as loader.CValue, 1, 1, 4)
    self._whiteU1 = white.u1
    self._whiteV1 = white.v1

    self.instances = Buffer.create(device, {
        usage = { "storage", "computeRead" },
        size = self.capacity * INSTANCE_BYTES,
    })
    self._bounds = Buffer.create(device, {
        usage = { "computeRead" },
        size = self.capacity * BOUND_BYTES,
    })
    self._slots = Buffer.create(device, {
        usage = { "computeRead", "computeWrite" },
        size = self.capacity * 4,
    })
    self._blocks = Buffer.create(device, {
        usage = { "computeRead", "computeWrite" },
        size = math.ceil(self.capacity / CULL_GROUP) * 4,
    })
    self._visible = Buffer.create(device, {
        usage = { "storage", "computeWrite" },
        size = self.capacity * 4,
    })
    self._drawArgs = Buffer.create(device, {
        -- Five uints: SDL_GPUIndexedIndirectDrawCommand.
        usage = { "indirect", "computeWrite" },
        size = 32,
    })

    -- Every field but the instance count is constant, and the scan writes that
    -- one. So the arguments are seeded once here rather than by a compute pass
    -- that reruns every frame to write the same five numbers back.
    local args = loader.newArray("uint32_t[8]")
    args[0] = QUAD_INDICES
    for slot = 1, 7 do args[slot] = 0 end
    self._drawArgs:upload(args, 32)

    -- Two triangles over four corners, uploaded once and never touched again.
    self._indices = Buffer.create(device, {
        usage = { "index" },
        size = QUAD_INDICES * 2,
    })
    local quad = loader.newArray("uint16_t[6]")
    quad[0], quad[1], quad[2] = 0, 1, 2
    quad[3], quad[4], quad[5] = 1, 3, 2
    self._indices:upload(quad, QUAD_INDICES * 2)
    self.camera = Camera.create()
    self._centred = false
    -- Two vec4s: the world rectangle the camera sees, then the counts.
    self._cullUniform = loader.newArray("float[8]")

    self._mark = ComputePipeline.load(device, "instance.mark.comp", {})
    self._scan = ComputePipeline.load(device, "instance.scan.comp", {})
    self._compact = ComputePipeline.load(device, "instance.compact.comp", {})

    self.deferred = Deferred.create(device, swapchainFormat, {
        ambient = options.ambient,
        geometry = function(context: Deferred.PassContext)
            if self.count == 0 then return end
            context.pass:bindPipeline(self.pipeline.handle)

            context.pass:pushVertexUniform(0,
                self.camera:matrix(context.width, context.height), 64)
            context.pass:bindVertexStorageBuffers(0,
                { self.instances.handle, self._visible.handle })
            context.pass:bindTextures(0, { self.images.handle }, self.sampler.handle)
            context.pass:bindIndexBuffer(self._indices.handle)
            -- One draw for the scene, with its instance count decided by the
            -- cull rather than by anything here.
            context.pass:drawIndexedIndirect(self._drawArgs.handle, 0, 1)
        end,
    })

    local albedoFormat, normalFormat = self.deferred:geometryFormats()
    local vertex = Shader.load(device, "instance.vert", {})
    local fragment = Shader.load(device, "instance.frag", {})
    self.pipeline = GraphicsPipeline.create(device, {
        vertexShader = vertex,
        fragmentShader = fragment,
        colorFormats = { albedoFormat, normalFormat },
        name = "ecs.instances",
    })
    vertex:destroy()
    fragment:destroy()

    return self
end

--- Uploads a decoded image into the array and returns a Sprite for it.
---
--- A Sprite is returned rather than a bare layer index because an image
--- smaller than a cell does not reach the cell's edge, so the UV range is not
--- 0..1 and a caller guessing it would sample the undefined remainder. The
--- second return is the region, for building sub-rects of an atlas.
---
--- The handle's pixels are released here: the array holds them now.
function Renderer:registerImage(handle: assets.Handle): components.Sprite, TextureArray.Region
    if handle.status ~= "ready" then
        error(("tecs: image '%s' is %s"):format(handle.path, handle.status), 2)
    end
    local region = self.images:add(handle.pixels, handle.width, handle.height,
        handle.pitch)
    handle:release()
    return components.Sprite(region.layer, 0.0, 0.0, region.u1, region.v1), region
end


--- Registers the sync system and queries on `world`.
---
--- Syncing runs inside the world's update, in RenderFirst. Rendering happens
--- afterwards against a frame, so the two stay separable: the sync needs no
--- command buffer and the render needs no world.
function Renderer:install(world: ecs.World)
    self._renderables = world:query({
        include = {
            components.Transform2D, components.Tint, components.Renderable,
        },
    })
    self._lightSources = world:query({
        include = { components.Transform2D, components.PointLight },
    })

    world:addSystem({
        name = "tecs.SyncRenderState",
        phase = ecs.phases.RenderFirst,
        run = function()
            local started = timing.begin()
            self.count, self.dropped, self.rewritten = syncInstances(self)
            self.deferred:setLights(syncLights(self))
            self._extractSeconds = timing.finish(EXTRACT, started)
        end,
    })
end

--- Seconds the last extraction took, or zero when nothing is being measured.
---
--- Read by the frame loop, which subtracts it from the update to leave
--- simulation on its own. Extraction runs inside `world:update`, so the two
--- are one number until something takes them apart.
function Renderer:extractSeconds(): number
    return self._extractSeconds or 0.0
end

--- Uploads what the sync produced, culls, and runs the pipeline.
---
--- The cull runs on the frame's command buffer, after the upload and before
--- the passes that consume it, so SDL orders all three without anything here
--- having to wait.
function Renderer:render(frame: Frame)
    self.instances:flush(frame.commandBuffer)
    self._bounds:flush(frame.commandBuffer)

    if self.count > 0 then
        if not self._centred then
            self._centred = true
            self.camera.x = frame.width * 0.5
            self.camera.y = frame.height * 0.5
        end

        local groups = math.ceil(self.count / CULL_GROUP)
        local view = self.camera:viewBounds(frame.width, frame.height)
        self._cullUniform[0] = view[1]
        self._cullUniform[1] = view[2]
        self._cullUniform[2] = view[3]
        self._cullUniform[3] = view[4]
        self._cullUniform[4] = self.count
        self._cullUniform[5] = groups

        -- Mark, scan, compact. Each pass reads what the one before it wrote,
        -- and SDL orders them because each declares what it writes.
        local mark = ComputePass.begin(frame.commandBuffer,
            { self._slots.handle, self._blocks.handle })
        mark:bindPipeline(self._mark.handle)
        mark:bindStorageBuffers(0, { self._bounds.handle })
        C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0,
            self._cullUniform, 32)
        mark:dispatch(groups)
        mark:finish()

        local scan = ComputePass.begin(frame.commandBuffer,
            { self._blocks.handle, self._drawArgs.handle })
        scan:bindPipeline(self._scan.handle)
        C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0,
            self._cullUniform, 32)
        scan:dispatch(1)
        scan:finish()

        local compact = ComputePass.begin(frame.commandBuffer,
            { self._visible.handle })
        compact:bindPipeline(self._compact.handle)
        compact:bindStorageBuffers(0,
            { self._slots.handle, self._blocks.handle })
        C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0,
            self._cullUniform, 32)
        compact:dispatch(groups)
        compact:finish()
    end

    self.deferred:render(frame)
end

--- The composited image the last frame produced.
---
--- The lit target rather than the swapchain, because a swapchain texture
--- belongs to the presenter once the frame is submitted while this one
--- persists and can be read at any point between frames. What it does not
--- include is anything drawn after compose, which today is nothing.
function Renderer:captureTexture(): Texture
    return self.deferred.graph:texture("lit")
end

--- Releases everything the renderer owns. Safe to call more than once.
function Renderer:destroy()
    if self._destroyed then return end
    self._destroyed = true
    self.pipeline:destroy()
    self.deferred:destroy()
    self.instances:destroy()
    self.sampler:destroy()
    self.images:destroy()
    self._bounds:destroy()
    self._slots:destroy()
    self._blocks:destroy()
    self._visible:destroy()
    self._drawArgs:destroy()
    self._indices:destroy()
    self._mark:destroy()
    self._scan:destroy()
    self._compact:destroy()
end

return Renderer
