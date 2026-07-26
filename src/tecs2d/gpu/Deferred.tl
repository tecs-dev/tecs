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

local loader <const> = require("tecs2d.ffi.loader")
local sdl <const> = require("tecs2d.ffi.sdl3")
local PassGraph <const> = require("tecs2d.gpu.PassGraph")
local Shader <const> = require("tecs2d.gpu.Shader")
local Buffer <const> = require("tecs2d.gpu.Buffer")
local GraphicsPipeline <const> = require("tecs2d.gpu.GraphicsPipeline")
local Frame <const> = require("tecs2d.gpu.Frame")

local C <const> = sdl.C

--- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local RGBA8 <const> = 4

--- Most lights the lighting pass will consider in one frame.
local MAX_LIGHTS <const> = 256

--- Bytes per light: vec4 position and radius, vec4 colour and intensity.
local LIGHT_STRIDE <const> = 32

--- Emits a fullscreen triangle and the UV to sample a full-target texture.
---
--- The V coordinate is flipped against the NDC Y: NDC +Y is up while texture
--- V runs down from the top-left, so a pass that samples its input without
--- this correction produces a vertically mirrored image, which reads as a
--- content bug rather than a coordinate one.
local FULLSCREEN_VERTEX <const> = [[
#version 450
layout(location = 0) out vec2 vUV;
void main() {
    vec2 corner = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
    vUV = vec2(corner.x, 1.0 - corner.y);
}
]]

local LIGHTING_FRAGMENT <const> = ([[
#version 450

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;

layout(set = 2, binding = 0) uniform sampler2D gAlbedo;
layout(set = 2, binding = 1) uniform sampler2D gNormal;

struct Light {
    vec4 position;   // xy in target pixels, z height, w radius
    vec4 color;      // rgb colour, a intensity
};

layout(set = 2, binding = 2) readonly buffer Lights {
    Light item[];
} lights;

layout(set = 3, binding = 0) uniform Scene {
    vec4 ambient;      // rgb ambient colour, a unused
    vec4 viewport;     // xy target size, z light count, w unused
} scene;

void main() {
    vec4 albedo = texture(gAlbedo, vUV);

    // Normals are stored biased into unsigned range, as the G-buffer format
    // has no signed representation.
    vec3 normal = normalize(texture(gNormal, vUV).xyz * 2.0 - 1.0);

    vec2 fragment = vUV * scene.viewport.xy;
    vec3 accumulated = scene.ambient.rgb;

    int count = int(scene.viewport.z);
    for (int i = 0; i < count; i++) {
        Light light = lights.item[i];
        vec3 toLight = vec3(light.position.xy - fragment, light.position.z);
        float distance = length(toLight);
        float radius = max(light.position.w, 1.0);

        // Smooth falloff to zero at the radius so a light has bounded reach
        // and the lighting cost stays proportional to what it touches.
        float attenuation = clamp(1.0 - distance / radius, 0.0, 1.0);
        attenuation *= attenuation;

        float lambert = max(dot(normal, normalize(toLight)), 0.0);
        accumulated += light.color.rgb * light.color.a * attenuation * lambert;
    }

    outColor = vec4(albedo.rgb * accumulated, albedo.a);
}
]])

local COMPOSITE_FRAGMENT <const> = [[
#version 450
layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;
layout(set = 2, binding = 0) uniform sampler2D litTexture;
void main() { outColor = texture(litTexture, vUV); }
]]

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
    _lightStaging: loader.CArray
    _lightingPipeline: GraphicsPipeline
    _compositePipeline: GraphicsPipeline
    _sceneUniform: loader.CArray
    _destroyed: boolean
end

local DeferredMT <const>: metatable<Deferred> = { __index = Deferred }

local function buildPipeline(device: loader.CPtr, fragmentSource: string,
                             format: integer, name: string): GraphicsPipeline
    local vertex = Shader.fromGLSL(device, FULLSCREEN_VERTEX, "vertex",
        { name = name .. ".vert" })
    local fragment = Shader.fromGLSL(device, fragmentSource, "fragment",
        { name = name .. ".frag" })
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
    self._lightStaging = loader.newArray("float[?]", MAX_LIGHTS * 8)
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

    self._lightingPipeline = buildPipeline(device, LIGHTING_FRAGMENT,
        RGBA8, "lighting")
    self._compositePipeline = buildPipeline(device, COMPOSITE_FRAGMENT,
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
--- Uploads once rather than per light: the staging array is filled in place
--- and copied in a single transfer.
function Deferred:setLights(lights: {Light})
    local count = math.min(#lights, MAX_LIGHTS)
    self.lightCount = count
    if count == 0 then return end

    local staging = self._lightStaging
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

    self._lightBuffer:upload(staging, count * LIGHT_STRIDE)
end

--- Runs the pipeline for one frame.
function Deferred:render(frame: Frame)
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
