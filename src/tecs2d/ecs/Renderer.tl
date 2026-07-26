--- Feeds the deferred pipeline from a world.
---
--- This is the bridge, and the only module that knows about both archetypes
--- and GPU buffers. Everything below it is renderer; everything above is ECS.
---
--- The sync walks archetype columns and writes instances straight into mapped
--- staging. There is no intermediate array: the column is contiguous C memory
--- and so is the destination, so a row becomes a handful of float stores into
--- driver memory rather than a copy between two buffers.
---
--- Instances pack as three vec4s. Two would hold position, scale, and colour
--- but not rotation, and a precomputed 2x2 basis costs less on the GPU than a
--- per-vertex sincos. The spare lane in the middle vector is where a material
--- or texture index goes once there is one.

local tecs <const> = require("tecs")
local loader <const> = require("tecs2d.ffi.loader")
local Buffer <const> = require("tecs2d.gpu.Buffer")
local Shader <const> = require("tecs2d.gpu.Shader")
local Frame <const> = require("tecs2d.gpu.Frame")
local GraphicsPipeline <const> = require("tecs2d.gpu.GraphicsPipeline")
local Deferred <const> = require("tecs2d.gpu.Deferred")
local components <const> = require("tecs2d.ecs.components")

--- Floats per instance: three vec4s.
local INSTANCE_FLOATS <const> = 12
local INSTANCE_BYTES <const> = INSTANCE_FLOATS * 4

--- Instances the buffer is sized for. This is a ceiling, not a hint: rows
--- beyond it are dropped rather than growing the buffer mid-frame.
local DEFAULT_CAPACITY <const> = 65536

local INSTANCE_VERTEX <const> = [[
#version 450

struct Instance {
    vec4 xform;   // 2x2 basis of rotation and scale
    vec4 origin;  // xy world position, zw spare
    vec4 color;
};

layout(set = 0, binding = 0) readonly buffer Instances { Instance item[]; } instances;
layout(set = 1, binding = 0) uniform View { vec4 viewport; } view;

layout(location = 0) out vec4 vColor;

const vec2 CORNERS[6] = vec2[6](
    vec2(-0.5, -0.5), vec2( 0.5, -0.5), vec2(-0.5,  0.5),
    vec2( 0.5, -0.5), vec2( 0.5,  0.5), vec2(-0.5,  0.5)
);

void main() {
    Instance self = instances.item[gl_InstanceIndex];
    mat2 basis = mat2(self.xform.x, self.xform.y, self.xform.z, self.xform.w);
    vec2 world = self.origin.xy + basis * CORNERS[gl_VertexIndex];

    // World units are pixels with the origin at the top left, which is also
    // what the lighting pass works in, so light positions need no conversion.
    vec2 ndc = vec2(world.x / view.viewport.x * 2.0 - 1.0,
                    1.0 - world.y / view.viewport.y * 2.0);
    gl_Position = vec4(ndc, 0.0, 1.0);
    vColor = self.color;
}
]]

local INSTANCE_FRAGMENT <const> = [[
#version 450
layout(location = 0) in vec4 vColor;
layout(location = 0) out vec4 albedo;
layout(location = 1) out vec4 normal;
void main() {
    albedo = vColor;
    normal = vec4(0.5, 0.5, 1.0, 1.0);
}
]]

local record RendererOptions
    --- Ambient colour applied everywhere.
    ambient: {number}
    --- Instances the buffer is sized for.
    capacity: integer
end

local record Renderer
    deferred: Deferred
    instances: Buffer
    pipeline: GraphicsPipeline
    capacity: integer
    --- Instances written by the last sync.
    count: integer
    --- Instances the last sync could not fit.
    dropped: integer
    _device: loader.CPtr
    _view: loader.CArray
    _lights: {Deferred.Light}
    _renderables: tecs.Query
    _lightSources: tecs.Query
    _destroyed: boolean
end

local RendererMT <const>: metatable<Renderer> = { __index = Renderer }

--- Writes every renderable archetype into mapped staging.
---
--- Columns are read, not mutated, so `get` is correct here. Taking `getMut`
--- would mark these components dirty on every archetype every frame and
--- defeat every dirty-gated consumer downstream.
local function syncInstances(self: Renderer): integer, integer
    local floats = self.instances:mapAs("float *")
    local written = 0
    local dropped = 0
    local capacity = self.capacity

    for archetype, length in self._renderables:iter() do
        local transforms = archetype:get(components.Transform2D)
        local tints = archetype:get(components.Tint)

        for row = 1, length do
            if written >= capacity then
                dropped = dropped + 1
            else
                local transform = transforms[row]
                local tint = tints[row]

                local angle = transform.rotation
                local cosine = math.cos(angle)
                local sine = math.sin(angle)
                local scaleX = transform.scaleX
                local scaleY = transform.scaleY

                local base = written * INSTANCE_FLOATS
                floats[base] = cosine * scaleX
                floats[base + 1] = -sine * scaleY
                floats[base + 2] = sine * scaleX
                floats[base + 3] = cosine * scaleY

                floats[base + 4] = transform.x
                floats[base + 5] = transform.y
                floats[base + 6] = 0.0
                floats[base + 7] = 0.0

                floats[base + 8] = tint.r
                floats[base + 9] = tint.g
                floats[base + 10] = tint.b
                floats[base + 11] = tint.a

                written = written + 1
            end
        end
    end

    if written > 0 then
        self.instances:markDirty(0, written * INSTANCE_BYTES)
    end
    return written, dropped
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
    self._view = loader.newArray("float[4]")
    self._lights = {}
    self._destroyed = false

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
            context.pass:pushVertexUniform(0, self._view, 16)
            -- Six vertices per quad, one instance per renderable.
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
            self.count, self.dropped = syncInstances(self)
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
end

return Renderer
