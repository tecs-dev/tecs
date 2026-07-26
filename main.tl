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

local C <const> = sdl.C

local INSTANCES <const> = 512
--- vec4 position/scale plus vec4 colour, per instance.
local INSTANCE_STRIDE <const> = 32

-- Animates instances and emits the draw arguments for them.
local ANIMATE_SOURCE <const> = ([[
#version 450
layout(local_size_x = 64) in;

struct Instance {
    vec4 transform;   // xy centre, z scale, w unused
    vec4 color;
};

layout(set = 1, binding = 0) writeonly buffer DrawArgs { uint value[]; } args;
layout(set = 1, binding = 1) buffer Instances { Instance item[]; } instances;
layout(set = 2, binding = 0) uniform Frame { float time; float aspect; } frame;

const uint COUNT = %du;

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= COUNT) { return; }

    // One invocation emits the draw for the whole batch.
    if (i == 0u) {
        args.value[0] = 3u;      // vertices per instance
        args.value[1] = COUNT;   // instances, decided on the GPU
        args.value[2] = 0u;
        args.value[3] = 0u;
    }

    float t = frame.time;
    float golden = 2.39996;
    float a = float(i) * golden + t * 0.35;
    float radius = sqrt(float(i) / float(COUNT)) * 0.86;

    instances.item[i].transform = vec4(
        cos(a) * radius / frame.aspect,
        sin(a) * radius,
        0.020 + 0.028 * (1.0 - radius),
        0.0
    );

    float hue = fract(float(i) / float(COUNT) + t * 0.05);
    vec3 c = 0.55 + 0.45 * cos(6.28318 * (hue + vec3(0.0, 0.33, 0.67)));
    instances.item[i].color = vec4(c, 1.0);
}
]]):format(INSTANCES)

-- Reads its instance out of the storage buffer; there are no vertex buffers.
local VERTEX_SOURCE <const> = [[
#version 450

struct Instance {
    vec4 transform;
    vec4 color;
};

layout(set = 0, binding = 0) readonly buffer Instances { Instance item[]; } instances;

layout(location = 0) out vec4 vColor;

const vec2 CORNERS[3] = vec2[3](
    vec2( 0.0,  1.15),
    vec2(-1.0, -0.65),
    vec2( 1.0, -0.65)
);

void main() {
    Instance self = instances.item[gl_InstanceIndex];
    vec2 local = CORNERS[gl_VertexIndex] * self.transform.z;
    gl_Position = vec4(self.transform.xy + local, 0.0, 1.0);
    vColor = self.color;
}
]]

local FRAGMENT_SOURCE <const> = [[
#version 450
layout(location = 0) in vec4 vColor;
layout(location = 0) out vec4 outColor;
void main() { outColor = vColor; }
]]

local animate: ComputePipeline = nil
local pipeline: GraphicsPipeline = nil
local drawArgs: Buffer = nil
local instances: Buffer = nil
local frameUniform = loader.newArray("float[2]")

os.exit(tecs2d.run({
    window = { title = "tecs2d", width = 1280, height = 720 },
    debug = true,
    maxFrames = tonumber(os.getenv("TECS2D_FRAMES")) as integer,

    load = function(app: tecs2d.App)
        print(("tecs2d %s"):format(tecs2d.version))
        print(("  SDL:    %s"):format(sdl.path))
        print(("  driver: %s"):format(app.device.driver))
        local w, h = app.window:getPixelSize()
        print(("  window: %dx%d px"):format(w, h))

        local started = tecs2d.clock.now()

        animate = ComputePipeline.fromGLSL(app.device.handle, ANIMATE_SOURCE,
            { name = "animate.comp" })

        local vertex = Shader.fromGLSL(app.device.handle, VERTEX_SOURCE,
            "vertex", { name = "instance.vert" })
        local fragment = Shader.fromGLSL(app.device.handle, FRAGMENT_SOURCE,
            "fragment", { name = "instance.frag" })
        pipeline = GraphicsPipeline.create(app.device.handle, {
            vertexShader = vertex,
            fragmentShader = fragment,
            colorFormat = app.device:getSwapchainFormat(),
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

        print(("  shaders: compiled in %.0f ms"):format(
            (tecs2d.clock.now() - started) * 1000))
        print(("  workgroup: %dx%dx%d"):format(
            animate.threadCount[1], animate.threadCount[2], animate.threadCount[3]))
        print(("  %d instances, one dispatch and one indirect draw per frame"):format(
            INSTANCES))
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

        -- Both written buffers are declared to the pass, which is what lets
        -- SDL order the draw below against this dispatch.
        local compute = frame:beginComputePass({ drawArgs.handle, instances.handle })
        compute:bindPipeline(animate.handle)
        C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0, frameUniform, 8)
        compute:dispatch(math.ceil(INSTANCES / animate.threadCount[1]))
        compute:finish()

        local pass = frame:beginRenderPass({
            clear = { r = 0.05, g = 0.06, b = 0.08, a = 1.0 },
        })
        pass:bindPipeline(pipeline.handle)

        local buffers = loader.newArray("SDL_GPUBuffer*[1]")
        buffers[0] = instances.handle
        C.SDL_BindGPUVertexStorageBuffers(pass.handle, 0, buffers, 1)

        pass:drawIndirect(drawArgs.handle, 0, 1)
        pass:finish()
    end,

    quit = function(app: tecs2d.App)
        if pipeline ~= nil then pipeline:destroy() end
        if animate ~= nil then animate:destroy() end
        if drawArgs ~= nil then drawArgs:destroy() end
        if instances ~= nil then instances:destroy() end
        print(("ran %d frames over %.1fs"):format(app.frame, app.elapsed))
    end,
}))
