-- GPU-driven drawing: a compute pass writes the draw arguments, and the draw
-- reads them without the CPU ever learning the count.
--
-- This is the shape the whole renderer is built on, so it is worth testing
-- directly rather than inferring from the pieces. It exercises compute
-- pipeline creation, workgroup size reflection, read-write storage binding,
-- the barrier SDL derives from the pass declaration, and indirect draw.

package.path = "build/?.lua;build/?/init.lua;" .. package.path

local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")
local Window = require("tecs2d.platform.Window")
local Device = require("tecs2d.gpu.Device")
local Shader = require("tecs2d.gpu.Shader")
local Buffer = require("tecs2d.gpu.Buffer")
local GraphicsPipeline = require("tecs2d.gpu.GraphicsPipeline")
local ComputePipeline = require("tecs2d.gpu.ComputePipeline")
local ComputePass = require("tecs2d.gpu.ComputePass")
local RenderPass = require("tecs2d.gpu.RenderPass")
local RenderTarget = require("tecs2d.gpu.RenderTarget")

local C = sdl.C
local FORMAT = 4  -- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local SIZE = 64

-- Writes an SDL_GPUIndirectDrawCommand: {num_vertices, num_instances,
-- first_vertex, first_instance}. Emitting it from compute is the point.
local BUILD_DRAW = [[
#version 450
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 1, binding = 0) writeonly buffer DrawArgs {
    uint value[];
} args;

void main() {
    args.value[0] = 3u;   // num_vertices
    args.value[1] = 1u;   // num_instances
    args.value[2] = 0u;   // first_vertex
    args.value[3] = 0u;   // first_instance
}
]]

local FULLSCREEN_VS = [[
#version 450
void main() {
    vec2 p[3] = vec2[3](vec2(-1,-1), vec2(3,-1), vec2(-1,3));
    gl_Position = vec4(p[gl_VertexIndex], 0, 1);
}
]]

local SOLID_FS = [[
#version 450
layout(location=0) out vec4 o;
void main() { o = vec4(0.2, 0.9, 0.4, 1.0); }
]]

describe("gpu-driven drawing", function()
    local window, device, target

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = Window.create({ title = "indirect", width = SIZE, height = SIZE })
        device = Device.create(window, { debug = true })
        target = RenderTarget.create(device.handle, SIZE, SIZE, FORMAT)
    end)

    teardown(function()
        if target then target:destroy() end
        if device then device:destroy() end
        if window then window:destroy() end
        C.SDL_Quit()
    end)

    it("reflects the declared workgroup size", function()
        local pipeline = ComputePipeline.fromGLSL(device.handle, [[
#version 450
layout(local_size_x = 8, local_size_y = 4, local_size_z = 2) in;
layout(set = 1, binding = 0) writeonly buffer Out { uint v[]; } o;
void main() { o.v[0] = 1u; }
]], { name = "workgroup.comp" })

        assert.are.same({ 8, 4, 2 }, pipeline.threadCount)
        assert.are.equal(1, pipeline.counts.readWriteStorageBuffers)
        assert.are.equal(0, pipeline.counts.readOnlyStorageBuffers)
        pipeline:destroy()
    end)

    it("draws from arguments a compute pass wrote", function()
        -- INDIRECT so the draw can source its arguments from it, and
        -- computeWrite so the compute pass may produce them.
        local args = Buffer.create(device.handle, {
            usage = { "indirect", "computeWrite" },
            size = 16,
        })

        local build = ComputePipeline.fromGLSL(device.handle, BUILD_DRAW,
            { name = "builddraw.comp" })
        local vertex = Shader.fromGLSL(device.handle, FULLSCREEN_VS, "vertex",
            { name = "indirect.vert" })
        local fragment = Shader.fromGLSL(device.handle, SOLID_FS, "fragment",
            { name = "indirect.frag" })
        local pipeline = GraphicsPipeline.create(device.handle, {
            vertexShader = vertex,
            fragmentShader = fragment,
            colorFormat = FORMAT,
        })
        vertex:destroy()
        fragment:destroy()

        local commandBuffer = C.SDL_AcquireGPUCommandBuffer(device.handle)

        -- Compute and draw share one command buffer so SDL can order them.
        local compute = ComputePass.begin(commandBuffer, { args.handle })
        compute:bindPipeline(build.handle)
        compute:dispatch(1)
        compute:finish()

        local pass = RenderPass.wrap(
            target:beginRenderPass(commandBuffer, { r = 0, g = 0, b = 0, a = 1 }))
        pass:bindPipeline(pipeline.handle)
        pass:drawIndirect(args.handle, 0, 1)
        pass:finish()

        assert(C.SDL_SubmitGPUCommandBuffer(commandBuffer))

        local pixels = target:readback()
        local center = target:getPixel(pixels, SIZE / 2, SIZE / 2)

        assert.is_true(math.abs(center.r - 51) <= 2,
            ("expected ~51 red, got %d"):format(center.r))
        assert.is_true(math.abs(center.g - 230) <= 2,
            ("expected ~230 green, got %d"):format(center.g))
        assert.is_true(math.abs(center.b - 102) <= 2,
            ("expected ~102 blue, got %d"):format(center.b))

        pipeline:destroy()
        build:destroy()
        args:destroy()
    end)

    it("instances from a vertex-stage storage buffer", function()
        -- The vertex stage reads storage buffers from set 0 while the fragment
        -- stage uses set 2. Covering both matters: a shader that binds the
        -- wrong set still compiles and still draws, just from the wrong data.
        local data = loader.newArray("float[16]")   -- 2 instances x 8 floats
        -- Instance 0: shifted left, red.
        data[0], data[1], data[2], data[3] = -0.5, 0.0, 0.4, 0.0
        data[4], data[5], data[6], data[7] = 1.0, 0.0, 0.0, 1.0
        -- Instance 1: shifted right, blue.
        data[8], data[9], data[10], data[11] = 0.5, 0.0, 0.4, 0.0
        data[12], data[13], data[14], data[15] = 0.0, 0.0, 1.0, 1.0

        local instances = Buffer.create(device.handle, {
            usage = { "storage" },
            size = 16 * 4,
        })
        instances:upload(data, 16 * 4)

        local args = Buffer.create(device.handle, {
            usage = { "indirect", "computeWrite" },
            size = 16,
        })
        local build = ComputePipeline.fromGLSL(device.handle, [[
#version 450
layout(local_size_x = 1) in;
layout(set = 1, binding = 0) writeonly buffer DrawArgs { uint value[]; } args;
void main() {
    args.value[0] = 3u;
    args.value[1] = 2u;   // instance count decided on the GPU
    args.value[2] = 0u;
    args.value[3] = 0u;
}
]], { name = "instanced.comp" })

        local vertex = Shader.fromGLSL(device.handle, [[
#version 450
struct Instance { vec4 transform; vec4 color; };
layout(set = 0, binding = 0) readonly buffer Instances { Instance item[]; } instances;
layout(location = 0) out vec4 vColor;
const vec2 CORNERS[3] = vec2[3](vec2(-1,-1), vec2(1,-1), vec2(0,1));
void main() {
    Instance self = instances.item[gl_InstanceIndex];
    gl_Position = vec4(CORNERS[gl_VertexIndex] * self.transform.z
        + self.transform.xy, 0.0, 1.0);
    vColor = self.color;
}
]], "vertex", { name = "instanced.vert" })

        local fragment = Shader.fromGLSL(device.handle, [[
#version 450
layout(location = 0) in vec4 vColor;
layout(location = 0) out vec4 o;
void main() { o = vColor; }
]], "fragment", { name = "instanced.frag" })

        assert.are.equal(1, vertex.counts.readOnlyStorageBuffers,
            "vertex stage must reflect its set 0 storage buffer")

        local pipeline = GraphicsPipeline.create(device.handle, {
            vertexShader = vertex,
            fragmentShader = fragment,
            colorFormat = FORMAT,
        })
        vertex:destroy()
        fragment:destroy()

        local commandBuffer = C.SDL_AcquireGPUCommandBuffer(device.handle)
        local compute = ComputePass.begin(commandBuffer, { args.handle })
        compute:bindPipeline(build.handle)
        compute:dispatch(1)
        compute:finish()

        local pass = RenderPass.wrap(
            target:beginRenderPass(commandBuffer, { r = 0, g = 0, b = 0, a = 1 }))
        pass:bindPipeline(pipeline.handle)
        local handles = loader.newArray("SDL_GPUBuffer*[1]")
        handles[0] = instances.handle
        C.SDL_BindGPUVertexStorageBuffers(pass.handle, 0, handles, 1)
        pass:drawIndirect(args.handle, 0, 1)
        pass:finish()
        assert(C.SDL_SubmitGPUCommandBuffer(commandBuffer))

        local pixels = target:readback()
        -- NDC (-0.5, -0.25) and (0.5, -0.25), inside each instance's triangle.
        local left = target:getPixel(pixels, 16, 40)
        local right = target:getPixel(pixels, 48, 40)

        assert.are.equal(255, left.r, "instance 0 must be red")
        assert.are.equal(0, left.b)
        assert.are.equal(255, right.b, "instance 1 must be blue")
        assert.are.equal(0, right.r)

        pipeline:destroy()
        build:destroy()
        args:destroy()
        instances:destroy()
    end)

    it("draws nothing when compute writes a zero vertex count", function()
        -- The negative case matters: if the indirect buffer were ignored and
        -- the draw fell back to fixed arguments, the previous test would pass
        -- for the wrong reason.
        local args = Buffer.create(device.handle, {
            usage = { "indirect", "computeWrite" },
            size = 16,
        })

        local build = ComputePipeline.fromGLSL(device.handle, [[
#version 450
layout(local_size_x = 1) in;
layout(set = 1, binding = 0) writeonly buffer DrawArgs { uint value[]; } args;
void main() {
    args.value[0] = 0u;   // no vertices
    args.value[1] = 0u;
    args.value[2] = 0u;
    args.value[3] = 0u;
}
]], { name = "nodraw.comp" })

        local vertex = Shader.fromGLSL(device.handle, FULLSCREEN_VS, "vertex", {})
        local fragment = Shader.fromGLSL(device.handle, SOLID_FS, "fragment", {})
        local pipeline = GraphicsPipeline.create(device.handle, {
            vertexShader = vertex,
            fragmentShader = fragment,
            colorFormat = FORMAT,
        })
        vertex:destroy()
        fragment:destroy()

        local commandBuffer = C.SDL_AcquireGPUCommandBuffer(device.handle)
        local compute = ComputePass.begin(commandBuffer, { args.handle })
        compute:bindPipeline(build.handle)
        compute:dispatch(1)
        compute:finish()

        local pass = RenderPass.wrap(
            target:beginRenderPass(commandBuffer, { r = 0, g = 0, b = 0, a = 1 }))
        pass:bindPipeline(pipeline.handle)
        pass:drawIndirect(args.handle, 0, 1)
        pass:finish()
        assert(C.SDL_SubmitGPUCommandBuffer(commandBuffer))

        local pixels = target:readback()
        local center = target:getPixel(pixels, SIZE / 2, SIZE / 2)
        assert.are.equal(0, center.g, "a zero vertex count must draw nothing")

        pipeline:destroy()
        build:destroy()
        args:destroy()
    end)
end)
