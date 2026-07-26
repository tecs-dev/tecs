-- Rendering behaviour, asserted on real pixels.
--
-- A draw that produces nothing still runs at full frame rate, so these tests
-- render offscreen and read the result back. They exist mainly to pin the
-- binding flattening in shadercompiler: on Metal there are no descriptor sets,
-- so set/binding pairs are remapped to [[buffer]] and [[texture]] indices, and
-- getting that wrong is invisible until a shader reads the wrong resource.

-- Our build first, so it wins over the ECS repo's own engine tree.
-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS2D_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. "../tecs/build/?.lua;../tecs/build/?/init.lua;" .. package.path

local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")
local Window = require("tecs2d.platform.Window")
local Device = require("tecs2d.gpu.Device")
local Shader = require("tecs2d.gpu.Shader")
local Buffer = require("tecs2d.gpu.Buffer")
local GraphicsPipeline = require("tecs2d.gpu.GraphicsPipeline")
local RenderPass = require("tecs2d.gpu.RenderPass")
local Texture = require("tecs2d.gpu.Texture")

local C = sdl.C
local FORMAT = 4  -- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local SIZE = 64

-- Covers the whole viewport from three vertices, with no vertex buffer.
local FULLSCREEN_VS = [[
#version 450
void main() {
    vec2 p[3] = vec2[3](vec2(-1,-1), vec2(3,-1), vec2(-1,3));
    gl_Position = vec4(p[gl_VertexIndex], 0, 1);
}
]]

describe("gpu rendering", function()
    local window, device, target

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = Window.create({ title = "spec", width = SIZE, height = SIZE })
        device = Device.create(window, { debug = true })
        target = Texture.create(device.handle, { width = SIZE, height = SIZE, format = FORMAT })
    end)

    teardown(function()
        if target then target:destroy() end
        if device then device:destroy() end
        if window then window:destroy() end
        C.SDL_Quit()
    end)

    -- Renders one triangle with the given shaders and returns the pixel buffer.
    local function render(vertexSource, fragmentSource, bind)
        local vertex = Shader.fromGLSL(device.handle, vertexSource, "vertex",
            { name = "spec.vert" })
        local fragment = Shader.fromGLSL(device.handle, fragmentSource, "fragment",
            { name = "spec.frag" })
        local pipeline = GraphicsPipeline.create(device.handle, {
            vertexShader = vertex,
            fragmentShader = fragment,
            colorFormat = FORMAT,
        })
        vertex:destroy()
        fragment:destroy()

        local commandBuffer = C.SDL_AcquireGPUCommandBuffer(device.handle)
        local pass = RenderPass.begin(commandBuffer,
            { { texture = target.handle, clear = { r = 0, g = 0, b = 0, a = 1 } } })
        pass:bindPipeline(pipeline.handle)
        if bind then bind(commandBuffer, pass) end
        pass:draw(3)
        pass:finish()
        assert(C.SDL_SubmitGPUCommandBuffer(commandBuffer))

        local pixels = target:readback()
        pipeline:destroy()
        return pixels
    end

    it("rasterizes geometry", function()
        local pixels = render(FULLSCREEN_VS, [[
#version 450
layout(location=0) out vec4 o;
void main() { o = vec4(1.0, 0.0, 1.0, 1.0); }
]])
        local center = target:getPixel(pixels, SIZE / 2, SIZE / 2)
        assert.are.equal(255, center.r)
        assert.are.equal(0, center.g)
        assert.are.equal(255, center.b)
    end)

    it("respects triangle coverage, with NDC +Y up", function()
        -- Covers the half of the target below the anti-diagonal in NDC.
        --
        -- This also pins orientation, which is worth asserting rather than
        -- assuming: NDC +Y points up, while readback row 0 is the top of the
        -- image, so an NDC bottom-left triangle lands at high row indices.
        -- Getting this backwards is the usual source of vertically mirrored
        -- output.
        local pixels = render([[
#version 450
void main() {
    vec2 p[3] = vec2[3](vec2(-1,-1), vec2(1,-1), vec2(-1,1));
    gl_Position = vec4(p[gl_VertexIndex], 0, 1);
}
]], [[
#version 450
layout(location=0) out vec4 o;
void main() { o = vec4(0.0, 1.0, 0.0, 1.0); }
]])
        local bottomLeft = target:getPixel(pixels, 4, SIZE - 4)
        local topLeft = target:getPixel(pixels, 4, 4)
        local bottomRight = target:getPixel(pixels, SIZE - 4, SIZE - 4)

        assert.are.equal(255, bottomLeft.g, "NDC (-1,-1) must land bottom-left")
        assert.are.equal(0, topLeft.g, "outside the triangle must stay cleared")
        assert.are.equal(0, bottomRight.g, "outside the triangle must stay cleared")
    end)

    it("binds a uniform buffer through the flattened MSL mapping", function()
        local value = loader.newArray("float[4]")
        value[0] = 0.0
        value[1] = 1.0
        value[2] = 1.0
        value[3] = 1.0

        local pixels = render(FULLSCREEN_VS, [[
#version 450
layout(set = 3, binding = 0) uniform Tint { vec4 color; } tint;
layout(location = 0) out vec4 o;
void main() { o = tint.color; }
]], function(commandBuffer)
            C.SDL_PushGPUFragmentUniformData(commandBuffer, 0, value, 16)
        end)

        local center = target:getPixel(pixels, SIZE / 2, SIZE / 2)
        assert.are.equal(0, center.r)
        assert.are.equal(255, center.g)
        assert.are.equal(255, center.b)
    end)

    it("reads a storage buffer through the flattened MSL mapping", function()
        -- The SSBO path is what the renderer is built on: per-instance data
        -- lives here, indexed by the shader rather than fed through vertex
        -- attributes.
        local data = loader.newArray("float[4]")
        data[0] = 1.0
        data[1] = 0.5
        data[2] = 0.0
        data[3] = 1.0

        local storage = Buffer.create(device.handle, {
            usage = { "storage" },
            size = 16,
        })
        storage:upload(data, 16)

        local pixels = render(FULLSCREEN_VS, [[
#version 450
layout(set = 2, binding = 0) readonly buffer Colors { vec4 color[]; } colors;
layout(location = 0) out vec4 o;
void main() { o = colors.color[0]; }
]], function(commandBuffer, pass)
            pass:bindFragmentStorageBuffers(0, { storage.handle })
        end)

        local center = target:getPixel(pixels, SIZE / 2, SIZE / 2)
        assert.are.equal(255, center.r)
        assert.is_true(math.abs(center.g - 128) <= 2,
            ("expected ~128 in green, got %d"):format(center.g))
        assert.are.equal(0, center.b)

        storage:destroy()
    end)

    it("reflects resource counts out of the SPIR-V", function()
        local shadercompiler = require("tecs2d.gpu.shadercompiler")
        local _, counts = shadercompiler.translate([[
#version 450
layout(set = 2, binding = 0) readonly buffer A { vec4 v[]; } a;
layout(set = 3, binding = 0) uniform B { vec4 v; } b;
layout(location = 0) out vec4 o;
void main() { o = a.v[0] + b.v; }
]], "fragment", { name = "counts.frag" })

        assert.are.equal(1, counts.readOnlyStorageBuffers)
        assert.are.equal(1, counts.uniformBuffers)
        assert.are.equal(0, counts.samplers)
    end)
end)
