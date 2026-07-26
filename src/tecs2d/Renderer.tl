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

local tecs <const> = require("tecs")
local loader <const> = require("tecs2d.ffi.loader")
local Buffer <const> = require("tecs2d.gpu.Buffer")
local Shader <const> = require("tecs2d.gpu.Shader")
local Frame <const> = require("tecs2d.gpu.Frame")
local GraphicsPipeline <const> = require("tecs2d.gpu.GraphicsPipeline")
local Deferred <const> = require("tecs2d.gpu.Deferred")
local Sampler <const> = require("tecs2d.gpu.Sampler")
local TextureArray <const> = require("tecs2d.gpu.TextureArray")
local assets <const> = require("tecs2d.assets")
local components <const> = require("tecs2d.components")

--- Floats per instance: four vec4s.
local INSTANCE_FLOATS <const> = 16
local INSTANCE_BYTES <const> = INSTANCE_FLOATS * 4

--- Layers the image array holds, including the white default in layer zero.
local MAX_LAYERS <const> = 64

--- Cell size of the image array. Every image must fit within it.
local DEFAULT_CELL <const> = 512

--- Instances the buffer is sized for. This is a ceiling, not a hint: rows
--- beyond it are dropped rather than growing the buffer mid-frame.
local DEFAULT_CAPACITY <const> = 65536

local INSTANCE_VERTEX <const> = [[
#version 450

struct Instance {
    vec4 xform;   // 2x2 basis of rotation and scale
    vec4 origin;  // xy world position, z array layer, w spare
    vec4 color;
    vec4 uvRect;  // u0 v0 u1 v1
};

layout(set = 0, binding = 0) readonly buffer Instances { Instance item[]; } instances;
// z carries the batch's first instance. Deriving it from gl_BaseInstance
// would need a SPIR-V capability that does not translate uniformly across
// backends, and a uniform costs nothing here.
layout(set = 1, binding = 0) uniform View { vec4 viewport; } view;

layout(location = 0) out vec4 vColor;
layout(location = 1) out vec3 vUV;

const vec2 CORNERS[6] = vec2[6](
    vec2(-0.5, -0.5), vec2( 0.5, -0.5), vec2(-0.5,  0.5),
    vec2( 0.5, -0.5), vec2( 0.5,  0.5), vec2(-0.5,  0.5)
);

void main() {
    Instance self = instances.item[gl_InstanceIndex + int(view.viewport.z)];
    mat2 basis = mat2(self.xform.x, self.xform.y, self.xform.z, self.xform.w);
    vec2 corner = CORNERS[gl_VertexIndex];
    vec2 world = self.origin.xy + basis * corner;

    // World units are pixels with the origin at the top left, which is also
    // what the lighting pass works in, so light positions need no conversion.
    vec2 ndc = vec2(world.x / view.viewport.x * 2.0 - 1.0,
                    1.0 - world.y / view.viewport.y * 2.0);
    gl_Position = vec4(ndc, 0.0, 1.0);
    vColor = self.color;

    // Corners run -0.5..0.5, and V is flipped because texture rows run down
    // from the top while the quad's local Y runs up.
    vUV = vec3(mix(self.uvRect.xy, self.uvRect.zw,
                   vec2(corner.x + 0.5, 0.5 - corner.y)),
               self.origin.z);
}
]]

local INSTANCE_FRAGMENT <const> = [[
#version 450
layout(location = 0) in vec4 vColor;
layout(location = 1) in vec3 vUV;
layout(location = 0) out vec4 albedo;
layout(location = 1) out vec4 normal;

layout(set = 2, binding = 0) uniform sampler2DArray images;

void main() {
    // Untextured geometry samples layer zero, so both paths land here.
    albedo = texture(images, vUV) * vColor;
    normal = vec4(0.5, 0.5, 1.0, 1.0);
}
]]

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
    _device: loader.CPtr
    _view: loader.CArray
    _lights: {Deferred.Light}
    _renderables: tecs.Query
    _lightSources: tecs.Query
    --- UV extent of the white pixel within its cell. An image smaller than a
    --- cell does not reach the cell's edge, so sampling 0..1 would read the
    --- undefined remainder rather than the image.
    _whiteU1: number
    _whiteV1: number
    _runs: {tecs.Archetype: Run}
    _seen: {tecs.Archetype: integer}
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
local function writeRun(self: Renderer, archetype: tecs.Archetype,
                        length: integer, offset: integer)
    local floats = self.instances:mapAs("float *")
    local transforms = archetype:get(components.Transform2D)
    local tints = archetype:get(components.Tint)
    local sprites = archetype:get(components.Sprite)

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

        local angle = transform.rotation
        local cosine = math.cos(angle)
        local sine = math.sin(angle)
        local scaleX = transform.scaleX
        local scaleY = transform.scaleY

        local base = (offset + row - 1) * INSTANCE_FLOATS
        floats[base] = cosine * scaleX
        floats[base + 1] = -sine * scaleY
        floats[base + 2] = sine * scaleX
        floats[base + 3] = cosine * scaleY

        floats[base + 4] = transform.x
        floats[base + 5] = transform.y
        floats[base + 6] = layer
        floats[base + 7] = 0.0

        floats[base + 8] = tint.r
        floats[base + 9] = tint.g
        floats[base + 10] = tint.b
        floats[base + 11] = tint.a

        floats[base + 12] = u0
        floats[base + 13] = v0
        floats[base + 14] = u1
        floats[base + 15] = v1
    end

    self.instances:markDirty(offset * INSTANCE_BYTES, length * INSTANCE_BYTES)
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
    self._view = loader.newArray("float[4]")
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
        usage = { "storage" },
        size = self.capacity * INSTANCE_BYTES,
    })

    self.deferred = Deferred.create(device, swapchainFormat, {
        ambient = options.ambient,
        geometry = function(context: Deferred.PassContext)
            if self.count == 0 then return end
            context.pass:bindPipeline(self.pipeline.handle)
            context.pass:bindVertexStorageBuffers(0, { self.instances.handle })

            self._view[0] = context.width
            self._view[1] = context.height
            self._view[2] = 0
            context.pass:pushVertexUniform(0, self._view, 16)
            context.pass:bindTextures(0, { self.images.handle }, self.sampler.handle)
            -- One draw for the scene: the texture is a per-instance layer.
            context.pass:draw(6, self.count)
        end,
    })

    local albedoFormat, normalFormat = self.deferred:geometryFormats()
    local vertex = Shader.fromGLSL(device, INSTANCE_VERTEX, "vertex",
        { name = "ecs.instance.vert" })
    local fragment = Shader.fromGLSL(device, INSTANCE_FRAGMENT, "fragment",
        { name = "ecs.instance.frag" })
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
        error(("tecs2d: image '%s' is %s"):format(handle.path, handle.status), 2)
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
function Renderer:install(world: tecs.World)
    self._renderables = world:query({
        include = {
            components.Transform2D, components.Tint, components.Renderable,
        },
    })
    self._lightSources = world:query({
        include = { components.Transform2D, components.PointLight },
    })

    world:addSystem({
        name = "tecs2d.SyncRenderState",
        phase = tecs.phases.RenderFirst,
        run = function()
            self.count, self.dropped, self.rewritten = syncInstances(self)
            self.deferred:setLights(syncLights(self))
        end,
    })
end

--- Uploads what the sync produced and runs the pipeline for one frame.
function Renderer:render(frame: Frame)
    self.instances:flush(frame.commandBuffer)
    self.deferred:render(frame)
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
end

return Renderer
