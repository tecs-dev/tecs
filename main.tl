--- Demo entry point.
---
--- GPU-driven, which is the pattern the renderer is built on rather than a
--- showcase: a compute pass animates per-instance data and writes the draw
--- arguments, then one indirect draw consumes both. The CPU issues a single
--- dispatch and a single draw regardless of how many instances there are, and
--- never learns the count.

package.path = "build/?.lua;build/?/init.lua;" .. package.path

local tecs2d <const> = require("tecs2d")
local sdl <const> = require("tecs2d.ffi.sdl3")
local loader <const> = require("tecs2d.ffi.loader")
local Shader <const> = require("tecs2d.gpu.Shader")
local Buffer <const> = require("tecs2d.gpu.Buffer")
local GraphicsPipeline <const> = require("tecs2d.gpu.GraphicsPipeline")
local ComputePipeline <const> = require("tecs2d.gpu.ComputePipeline")
local Deferred <const> = require("tecs2d.gpu.Deferred")

local C <const> = sdl.C

local INSTANCES <const> = math.floor(tonumber(os.getenv("TECS2D_INSTANCES")) or 512)
--- vec4 position/scale plus vec4 colour, per instance.
local INSTANCE_STRIDE <const> = 32

-- Zeroes the visible counter before culling accumulates into it. A separate
-- pass rather than a branch inside the cull, because invocations within one
-- dispatch have no ordering against each other.
local RESET_SOURCE <const> = [[
#version 450
layout(local_size_x = 1) in;
layout(set = 1, binding = 0) writeonly buffer DrawArgs { uint value[]; } args;
void main() {
    args.value[0] = 3u;   // vertices per instance
    args.value[1] = 0u;   // instances, accumulated by the cull
    args.value[2] = 0u;
    args.value[3] = 0u;
}
]]

-- Animates instances, discards those outside the view, and compacts the
-- survivors into an index buffer. The instance count in the draw arguments is
-- an atomic total, so the CPU never learns how many survived.
local ANIMATE_SOURCE <const> = ([[
#version 450
layout(local_size_x = 64) in;

struct Instance {
    vec4 transform;   // xy centre, z scale, w unused
    vec4 color;
};

layout(set = 1, binding = 0) buffer DrawArgs { uint value[]; } args;
layout(set = 1, binding = 1) buffer Instances { Instance item[]; } instances;
layout(set = 1, binding = 2) writeonly buffer Visible { uint index[]; } visible;
layout(set = 2, binding = 0) uniform Frame { float time; float aspect; } frame;

const uint COUNT = %du;

// The field spans several screens, so most instances are off view and the
// cull has something to reject. This is the case that matters: world size and
// drawn size are different numbers.
const float WORLD = %f;

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= COUNT) { return; }

    float t = frame.time;
    float golden = 2.39996;
    float a = float(i) * golden + t * 0.35;
    float radius = sqrt(float(i) / float(COUNT)) * WORLD;

    float scale = 0.020 + 0.028 * (1.0 - radius / WORLD);
    vec2 centre = vec2(cos(a) * radius / frame.aspect, sin(a) * radius);

    instances.item[i].transform = vec4(centre, scale, 0.0);

    float hue = fract(float(i) / float(COUNT) + t * 0.05);
    vec3 c = 0.55 + 0.45 * cos(6.28318 * (hue + vec3(0.0, 0.33, 0.67)));
    instances.item[i].color = vec4(c, 1.0);

    // Reject anything whose bounds fall outside clip space, then compact the
    // survivors so the draw touches only what is visible.
    float extent = scale * 1.2;
    if (abs(centre.x) - extent > 1.0 || abs(centre.y) - extent > 1.0) {
        return;
    }

    uint slot = atomicAdd(args.value[1], 1u);
    visible.index[slot] = i;
}
]]):format(INSTANCES, 3.0)

-- Reads its instance out of the storage buffer; there are no vertex buffers.
local VERTEX_SOURCE <const> = [[
#version 450

struct Instance {
    vec4 transform;
    vec4 color;
};

layout(set = 0, binding = 0) readonly buffer Instances { Instance item[]; } instances;
layout(set = 0, binding = 1) readonly buffer Visible { uint index[]; } visible;

layout(location = 0) out vec4 vColor;

const vec2 CORNERS[3] = vec2[3](
    vec2( 0.0,  1.15),
    vec2(-1.0, -0.65),
    vec2( 1.0, -0.65)
);

void main() {
    // Indexed in two steps: nesting the lookups would spell a doubled
    // closing bracket and end the enclosing Lua long string.
    uint slot = visible.index[gl_InstanceIndex];
    Instance self = instances.item[slot];
    vec2 local = CORNERS[gl_VertexIndex] * self.transform.z;
    gl_Position = vec4(self.transform.xy + local, 0.0, 1.0);
    vColor = self.color;
}
]]

-- Writes the G-buffer rather than a final colour: albedo at location 0 and a
-- normal biased into unsigned range at location 1.
local FRAGMENT_SOURCE <const> = [[
#version 450
layout(location = 0) in vec4 vColor;
layout(location = 0) out vec4 albedo;
layout(location = 1) out vec4 normal;
void main() {
    albedo = vColor;
    normal = vec4(0.5, 0.5, 1.0, 1.0);
}
]]

local reset: ComputePipeline = nil
local animate: ComputePipeline = nil
local deferred: Deferred = nil
local pipeline: GraphicsPipeline = nil
local drawArgs: Buffer = nil
local instances: Buffer = nil
local visible: Buffer = nil
local frameUniform = loader.newArray("float[2]")

os.exit(tecs2d.run({
    window = { title = "tecs2d", width = 1280, height = 720 },
    debug = true,
    maxFrames = tonumber(os.getenv("TECS2D_FRAMES")) as integer,
    presentMode = os.getenv("TECS2D_PRESENT"),

    load = function(app: tecs2d.App)
        print(("tecs2d %s"):format(tecs2d.version))
        print(("  SDL:    %s"):format(sdl.path))
        print(("  driver: %s"):format(app.device.driver))
        local w, h = app.window:getPixelSize()
        print(("  window: %dx%d px"):format(w, h))

        local started = tecs2d.clock.now()

        reset = ComputePipeline.fromGLSL(app.device.handle, RESET_SOURCE,
            { name = "reset.comp" })
        animate = ComputePipeline.fromGLSL(app.device.handle, ANIMATE_SOURCE,
            { name = "animate.comp" })

        deferred = Deferred.create(app.device.handle,
            app.device:getSwapchainFormat(), {
                ambient = { 0.06, 0.06, 0.09 },
                geometry = function(context: Deferred.PassContext)
                    context.pass:bindPipeline(pipeline.handle)
                    context.pass:bindVertexStorageBuffers(0,
                        { instances.handle, visible.handle })
                    context.pass:drawIndirect(drawArgs.handle, 0, 1)
                end,
            })

        local albedoFormat, normalFormat = deferred:geometryFormats()
        local vertex = Shader.fromGLSL(app.device.handle, VERTEX_SOURCE,
            "vertex", { name = "instance.vert" })
        local fragment = Shader.fromGLSL(app.device.handle, FRAGMENT_SOURCE,
            "fragment", { name = "instance.frag" })
        pipeline = GraphicsPipeline.create(app.device.handle, {
            vertexShader = vertex,
            fragmentShader = fragment,
            colorFormats = { albedoFormat, normalFormat },
            name = "instances",
        })
        vertex:destroy()
        fragment:destroy()

        drawArgs = Buffer.create(app.device.handle, {
            usage = { "indirect", "computeWrite" },
            size = 16,
        })
        instances = Buffer.create(app.device.handle, {
            usage = { "storage", "computeWrite" },
            size = INSTANCES * INSTANCE_STRIDE,
        })
        visible = Buffer.create(app.device.handle, {
            usage = { "storage", "computeWrite" },
            size = INSTANCES * 4,
        })

        print(("  shaders: compiled in %.0f ms"):format(
            (tecs2d.clock.now() - started) * 1000))
        print(("  workgroup: %dx%dx%d"):format(
            animate.threadCount[1], animate.threadCount[2], animate.threadCount[3]))
        print(("  %d instances, one dispatch and one indirect draw per frame"):format(
            INSTANCES))
        print("  deferred: geometry, lighting, composite")
        print("  escape or close the window to quit")
    end,

    event = function(app: tecs2d.App, event: loader.CValue)
        if event.type == C.SDL_EVENT_KEY_DOWN
            and event.key.scancode == C.SDL_SCANCODE_ESCAPE then
            app.quitRequested = true
        end
    end,

    draw = function(app: tecs2d.App, frame: tecs2d.Frame)
        frameUniform[0] = app.elapsed
        frameUniform[1] = frame.width / frame.height

        -- Two passes rather than one: the counter must be zero before any
        -- invocation accumulates into it, and invocations within a dispatch
        -- have no ordering against each other.
        local clear = frame:beginComputePass({ drawArgs.handle })
        clear:bindPipeline(reset.handle)
        clear:dispatch(1)
        clear:finish()

        -- Every written buffer is declared to the pass, which is what lets SDL
        -- order the draw below against this dispatch.
        local compute = frame:beginComputePass({
            drawArgs.handle, instances.handle, visible.handle })
        compute:bindPipeline(animate.handle)
        C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0, frameUniform, 8)
        compute:dispatch(math.ceil(INSTANCES / animate.threadCount[1]))
        compute:finish()

        -- Lights orbit against the instance field so the deferred resolve is
        -- visibly doing work rather than passing albedo through.
        local lights: {Deferred.Light} = {}
        for index = 1, 3 do
            local angle = app.elapsed * 0.5 + index * 2.094
            lights[index] = {
                x = frame.width * (0.5 + 0.32 * math.cos(angle)),
                y = frame.height * (0.5 + 0.32 * math.sin(angle)),
                z = 90.0,
                radius = frame.height * 0.75,
                r = index == 1 and 1.0 or 0.35,
                g = index == 2 and 1.0 or 0.4,
                b = index == 3 and 1.0 or 0.5,
                intensity = 2.6,
            }
        end
        deferred:setLights(lights)

        deferred:render(frame)
    end,

    quit = function(app: tecs2d.App)
        if deferred ~= nil then deferred:destroy() end
        if pipeline ~= nil then pipeline:destroy() end
        if animate ~= nil then animate:destroy() end
        if reset ~= nil then reset:destroy() end
        if visible ~= nil then visible:destroy() end
        if drawArgs ~= nil then drawArgs:destroy() end
        if instances ~= nil then instances:destroy() end
        print(("ran %d frames over %.2fs (%.2f ms/frame, %d instances)"):format(
            app.frame, app.elapsed, app.elapsed / math.max(app.frame, 1) * 1000,
            INSTANCES))
    end,
}))
