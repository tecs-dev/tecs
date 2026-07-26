





























local tecs = require("tecs")
local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")
local Buffer = require("tecs2d.gpu.Buffer")
local Shader = require("tecs2d.gpu.Shader")
local Frame = require("tecs2d.gpu.Frame")
local GraphicsPipeline = require("tecs2d.gpu.GraphicsPipeline")
local Deferred = require("tecs2d.gpu.Deferred")
local Sampler = require("tecs2d.gpu.Sampler")
local ComputePipeline = require("tecs2d.gpu.ComputePipeline")
local ComputePass = require("tecs2d.gpu.ComputePass")
local TextureArray = require("tecs2d.gpu.TextureArray")
local assets = require("tecs2d.assets")
local components = require("tecs2d.components")

local C = sdl.C


local INSTANCE_FLOATS = 16
local INSTANCE_BYTES = INSTANCE_FLOATS * 4


local MAX_LAYERS = 64


local DEFAULT_CELL = 512



local DEFAULT_CAPACITY = 65536




local RESET_COMPUTE = [[
#version 450
layout(local_size_x = 1) in;
layout(set = 1, binding = 0) writeonly buffer DrawArgs { uint value[]; } args;
void main() {
    args.value[0] = 6u;   // vertices per quad
    args.value[1] = 0u;   // instances, accumulated by the cull
    args.value[2] = 0u;
    args.value[3] = 0u;
}
]]


local CULL_COMPUTE = [[
#version 450
layout(local_size_x = 64) in;

struct Instance {
    vec4 xform;
    vec4 origin;
    vec4 color;
    vec4 uvRect;
};

layout(set = 0, binding = 0) readonly buffer Instances { Instance item[]; } instances;
layout(set = 1, binding = 0) buffer DrawArgs { uint value[]; } args;
layout(set = 1, binding = 1) writeonly buffer Visible { uint index[]; } visible;
layout(set = 2, binding = 0) uniform Cull { vec4 params; } cull;

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= uint(cull.params.z)) { return; }

    Instance self = instances.item[i];

    // The quad's half extent along each axis, from the columns of its basis.
    // A rotated quad reaches further than its scale alone, so both columns
    // contribute to both axes.
    float ex = 0.5 * (abs(self.xform.x) + abs(self.xform.z));
    float ey = 0.5 * (abs(self.xform.y) + abs(self.xform.w));

    vec2 origin = self.origin.xy;
    if (origin.x + ex < 0.0 || origin.x - ex > cull.params.x ||
        origin.y + ey < 0.0 || origin.y - ey > cull.params.y) {
        return;
    }

    visible.index[atomicAdd(args.value[1], 1u)] = i;
}
]]

local INSTANCE_VERTEX = [[
#version 450

struct Instance {
    vec4 xform;   // 2x2 basis of rotation and scale
    vec4 origin;  // xy world position, z array layer, w spare
    vec4 color;
    vec4 uvRect;  // u0 v0 u1 v1
};

layout(set = 0, binding = 0) readonly buffer Instances { Instance item[]; } instances;
layout(set = 0, binding = 1) readonly buffer Visible { uint index[]; } visible;
layout(set = 1, binding = 0) uniform View { vec4 viewport; } view;

layout(location = 0) out vec4 vColor;
layout(location = 1) out vec3 vUV;

const vec2 CORNERS[6] = vec2[6](
    vec2(-0.5, -0.5), vec2( 0.5, -0.5), vec2(-0.5,  0.5),
    vec2( 0.5, -0.5), vec2( 0.5,  0.5), vec2(-0.5,  0.5)
);

void main() {
    // The cull compacted the survivors, so this walks the visible list rather
    // than the instance array.
    uint slot = visible.index[gl_InstanceIndex];
    Instance self = instances.item[slot];
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

local INSTANCE_FRAGMENT = [[
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












local Renderer = {}

































local RendererMT = { __index = Renderer }

















local function writeRun(self, archetype,
   length, offset)
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







local function syncInstances(self)
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
      local dirty = relayout or
      archetype:isComponentDirty(components.Transform2D) or
      archetype:isComponentDirty(components.Tint) or
      archetype:isComponentDirty(components.Sprite)

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


local function syncLights(self)
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


function Renderer.create(device, swapchainFormat,
   options)
   options = options or {}

   local self = setmetatable({}, RendererMT)
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




   local pixel = loader.newArray("uint8_t[4]")
   pixel[0], pixel[1], pixel[2], pixel[3] = 255, 255, 255, 255
   local white = self.images:add(pixel, 1, 1, 4)
   self._whiteU1 = white.u1
   self._whiteV1 = white.v1

   self.instances = Buffer.create(device, {
      usage = { "storage", "computeRead" },
      size = self.capacity * INSTANCE_BYTES,
   })
   self._visible = Buffer.create(device, {
      usage = { "storage", "computeWrite" },
      size = self.capacity * 4,
   })
   self._drawArgs = Buffer.create(device, {
      usage = { "indirect", "computeWrite" },
      size = 16,
   })
   self._cullUniform = loader.newArray("float[4]")

   self._reset = ComputePipeline.fromGLSL(device, RESET_COMPUTE,
   { name = "renderer.reset" })
   self._cull = ComputePipeline.fromGLSL(device, CULL_COMPUTE,
   { name = "renderer.cull" })

   self.deferred = Deferred.create(device, swapchainFormat, {
      ambient = options.ambient,
      geometry = function(context)
         if self.count == 0 then return end
         context.pass:bindPipeline(self.pipeline.handle)

         self._view[0] = context.width
         self._view[1] = context.height
         context.pass:pushVertexUniform(0, self._view, 16)
         context.pass:bindVertexStorageBuffers(0,
         { self.instances.handle, self._visible.handle })
         context.pass:bindTextures(0, { self.images.handle }, self.sampler.handle)


         context.pass:drawIndirect(self._drawArgs.handle, 0, 1)
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









function Renderer:registerImage(handle)
   if handle.status ~= "ready" then
      error(("tecs2d: image '%s' is %s"):format(handle.path, handle.status), 2)
   end
   local region = self.images:add(handle.pixels, handle.width, handle.height,
   handle.pitch)
   handle:release()
   return components.Sprite(region.layer, 0.0, 0.0, region.u1, region.v1), region
end







function Renderer:install(world)
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






function Renderer:render(frame)
   self.instances:flush(frame.commandBuffer)

   if self.count > 0 then



      local clear = ComputePass.begin(frame.commandBuffer,
      { self._drawArgs.handle })
      clear:bindPipeline(self._reset.handle)
      clear:dispatch(1)
      clear:finish()

      self._cullUniform[0] = frame.width
      self._cullUniform[1] = frame.height
      self._cullUniform[2] = self.count

      local cull = ComputePass.begin(frame.commandBuffer,
      { self._drawArgs.handle, self._visible.handle })
      cull:bindPipeline(self._cull.handle)
      cull:bindStorageBuffers(0, { self.instances.handle })
      C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0,
      self._cullUniform, 16)
      cull:dispatch(math.ceil(self.count / self._cull.threadCount[1]))
      cull:finish()
   end

   self.deferred:render(frame)
end


function Renderer:destroy()
   if self._destroyed then return end
   self._destroyed = true
   self.pipeline:destroy()
   self.deferred:destroy()
   self.instances:destroy()
   self.sampler:destroy()
   self.images:destroy()
   self._visible:destroy()
   self._drawArgs:destroy()
   self._reset:destroy()
   self._cull:destroy()
end

return Renderer
