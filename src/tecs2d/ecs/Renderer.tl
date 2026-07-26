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
--- Instances pack as four vec4s: a 2x2 basis, an origin, a colour, and a UV
--- rect. A precomputed basis costs less on the GPU than a per-vertex sincos.
---
--- SDL_GPU binds samplers per pipeline rather than bindlessly, so instances
--- are grouped by texture and drawn one batch per texture. The grouping is a
--- counting sort over the registry, which is why the registry is small and
--- indexed rather than open. Entities with no Sprite land in slot zero, a
--- one-pixel white texture, so untextured and textured geometry go through
--- one shader instead of two.

local tecs <const> = require("tecs")
local loader <const> = require("tecs2d.ffi.loader")
local Buffer <const> = require("tecs2d.gpu.Buffer")
local Shader <const> = require("tecs2d.gpu.Shader")
local Frame <const> = require("tecs2d.gpu.Frame")
local GraphicsPipeline <const> = require("tecs2d.gpu.GraphicsPipeline")
local Deferred <const> = require("tecs2d.gpu.Deferred")
local Texture <const> = require("tecs2d.gpu.Texture")
local Sampler <const> = require("tecs2d.gpu.Sampler")
local components <const> = require("tecs2d.ecs.components")

--- Floats per instance: four vec4s.
local INSTANCE_FLOATS <const> = 16
local INSTANCE_BYTES <const> = INSTANCE_FLOATS * 4

--- Textures the registry holds, including the white default in slot zero.
local MAX_TEXTURES <const> = 64

--- Instances the buffer is sized for. This is a ceiling, not a hint: rows
--- beyond it are dropped rather than growing the buffer mid-frame.
local DEFAULT_CAPACITY <const> = 65536

local INSTANCE_VERTEX <const> = [[
#version 450

struct Instance {
    vec4 xform;   // 2x2 basis of rotation and scale
    vec4 origin;  // xy world position, zw spare
    vec4 color;
    vec4 uvRect;  // u0 v0 u1 v1
};

layout(set = 0, binding = 0) readonly buffer Instances { Instance item[]; } instances;
// z carries the batch's first instance. Deriving it from gl_BaseInstance
// would need a SPIR-V capability that does not translate uniformly across
// backends, and a uniform costs nothing here.
layout(set = 1, binding = 0) uniform View { vec4 viewport; } view;

layout(location = 0) out vec4 vColor;
layout(location = 1) out vec2 vUV;

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
    vUV = mix(self.uvRect.xy, self.uvRect.zw,
              vec2(corner.x + 0.5, 0.5 - corner.y));
}
]]

local INSTANCE_FRAGMENT <const> = [[
#version 450
layout(location = 0) in vec4 vColor;
layout(location = 1) in vec2 vUV;
layout(location = 0) out vec4 albedo;
layout(location = 1) out vec4 normal;

layout(set = 2, binding = 0) uniform sampler2D image;

void main() {
    // Untextured geometry samples the white default, so both paths land here.
    albedo = texture(image, vUV) * vColor;
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
    sampler: Sampler
    capacity: integer
    --- Instances written by the last sync.
    count: integer
    --- Instances the last sync could not fit.
    dropped: integer
    --- Distinct textures drawn by the last sync.
    batches: integer
    _device: loader.CPtr
    _view: loader.CArray
    _lights: {Deferred.Light}
    _renderables: tecs.Query
    _sprites: tecs.Query
    _lightSources: tecs.Query
    _textures: {Texture}
    --- Instances per slot, then the running offset of each slot's run.
    _slotCount: {integer: integer}
    _slotStart: {integer: integer}
    _destroyed: boolean
end

local RendererMT <const>: metatable<Renderer> = { __index = Renderer }

--- Writes every renderable archetype into mapped staging.
---
--- Columns are read, not mutated, so `get` is correct here. Taking `getMut`
--- would mark these components dirty on every archetype every frame and
--- defeat every dirty-gated consumer downstream.
local function syncInstances(self: Renderer): integer, integer, integer
    local counts = self._slotCount
    local starts = self._slotStart
    local highest = #self._textures - 1
    for slot = 0, highest do counts[slot] = 0 end

    -- First pass counts per texture so each slot's rows can be written into
    -- one contiguous run. Sorting the rows themselves would mean moving
    -- instance data twice.
    local total = 0
    local dropped = 0
    for archetype, length in self._renderables:iter() do
        local sprites = archetype:get(components.Sprite)
        if sprites == nil then
            counts[0] = counts[0] + length
            total = total + length
        else
            for row = 1, length do
                local slot = sprites[row].slot as integer
                if slot < 0 or slot > highest then slot = 0 end
                counts[slot] = counts[slot] + 1
                total = total + 1
            end
        end
    end

    if total > self.capacity then
        dropped = total - self.capacity
    end

    local offset = 0
    local batches = 0
    for slot = 0, highest do
        starts[slot] = offset
        if counts[slot] > 0 then batches = batches + 1 end
        offset = offset + counts[slot]
    end

    local floats = self.instances:mapAs("float *")
    local cursor: {integer: integer} = {}
    for slot = 0, highest do cursor[slot] = starts[slot] end

    local capacity = self.capacity
    local written = 0

    for archetype, length in self._renderables:iter() do
        local transforms = archetype:get(components.Transform2D)
        local tints = archetype:get(components.Tint)
        local sprites = archetype:get(components.Sprite)

        for row = 1, length do
            local slot = 0
            local u0, v0, u1, v1 = 0.0, 0.0, 1.0, 1.0
            if sprites ~= nil then
                local sprite = sprites[row]
                slot = sprite.slot as integer
                if slot < 0 or slot > highest then slot = 0 end
                u0, v0, u1, v1 = sprite.u0, sprite.v0, sprite.u1, sprite.v1
            end

            local index = cursor[slot]
            if index < capacity then
                cursor[slot] = index + 1

                local transform = transforms[row]
                local tint = tints[row]

                local angle = transform.rotation
                local cosine = math.cos(angle)
                local sine = math.sin(angle)
                local scaleX = transform.scaleX
                local scaleY = transform.scaleY

                local base = index * INSTANCE_FLOATS
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

                floats[base + 12] = u0
                floats[base + 13] = v0
                floats[base + 14] = u1
                floats[base + 15] = v1

                written = written + 1
            end
        end
    end

    if written > 0 then
        self.instances:markDirty(0, written * INSTANCE_BYTES)
    end
    return written, dropped, batches
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
    self.batches = 0
    self._view = loader.newArray("float[4]")
    self._lights = {}
    self._slotCount = {}
    self._slotStart = {}
    self._destroyed = false

    self.sampler = Sampler.create(device, { filter = "nearest", address = "clamp" })

    -- Slot zero is a single white pixel. Entities without a Sprite sample it,
    -- so textured and untextured geometry share one shader and one pipeline
    -- rather than needing a branch or a second path.
    local white = Texture.create(device, {
        width = 1, height = 1, format = 4, usage = { "sampled" },
    })
    local pixel = loader.newArray("uint8_t[4]")
    pixel[0], pixel[1], pixel[2], pixel[3] = 255, 255, 255, 255
    white:upload(pixel as loader.CValue, 4)
    self._textures = { white }

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

            -- One draw per texture. The sort put each slot's instances in a
            -- contiguous run, so a batch is a base and a count.
            local highest = #self._textures - 1
            for slot = 0, highest do
                local count = self._slotCount[slot] or 0
                if count > 0 then
                    self._view[2] = self._slotStart[slot]
                    context.pass:pushVertexUniform(0, self._view, 16)
                    context.pass:bindTextures(0,
                        { self._textures[slot + 1].handle }, self.sampler.handle)
                    -- Six vertices per quad, one instance per renderable.
                    context.pass:draw(6, count)
                end
            end
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

--- Registers a texture and returns the slot a Sprite should name.
---
--- Slots are zero-based because slot zero is the white default, so a Sprite
--- left at its default value samples white rather than pointing at nothing.
--- The backing list is one-based, which is the only place that offset lives.
function Renderer:registerTexture(texture: Texture): integer
    if #self._textures >= MAX_TEXTURES then
        error(("tecs2d: texture registry is full at %d"):format(MAX_TEXTURES), 2)
    end
    self._textures[#self._textures + 1] = texture
    return #self._textures - 1
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
            self.count, self.dropped, self.batches = syncInstances(self)
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
    -- Only the white default belongs to the renderer; registered textures are
    -- owned by whoever loaded them.
    self._textures[1]:destroy()
end

return Renderer
