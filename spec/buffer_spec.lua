-- Staged, dirty-ranged buffer writes.
--
-- The failure mode worth guarding against is silent: a partial upload that
-- also erases the bytes it did not write looks exactly like a producer bug in
-- whatever reads the buffer later. So these tests write disjoint regions in
-- separate flushes and check that earlier regions survive.

-- Our build first, so it wins over the ECS repo's own engine tree.
-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS2D_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. "../tecs/build/?.lua;../tecs/build/?/init.lua;" .. package.path

local ffi = require("ffi")
local sdl = require("tecs.ffi.sdl3")
local loader = require("tecs.ffi.loader")
local Window = require("tecs.platform.Window")
local Device = require("tecs.gpu.Device")
local Buffer = require("tecs.gpu.Buffer")
local Shader = require("tecs.gpu.Shader")
local Texture = require("tecs.gpu.Texture")
local RenderPass = require("tecs.gpu.RenderPass")
local GraphicsPipeline = require("tecs.gpu.GraphicsPipeline")

local C = sdl.C
local FORMAT = 4  -- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local SIZE = 8

describe("gpu.Buffer", function()
    local window, device, target, pipeline

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = Window.create({ title = "buffer", width = SIZE, height = SIZE })
        device = Device.create(window, { debug = true })
        target = Texture.create(device.handle,
            { width = SIZE, height = SIZE, format = FORMAT })

        -- Reads one vec4 out of a storage buffer and paints it, so buffer
        -- contents can be asserted on through actual rendering.
        local vertex = Shader.fromGLSL(device.handle, [[
#version 450
void main() {
    vec2 p[3] = vec2[3](vec2(-1,-1), vec2(3,-1), vec2(-1,3));
    gl_Position = vec4(p[gl_VertexIndex], 0, 1);
}
]], "vertex", {})
        local fragment = Shader.fromGLSL(device.handle, [[
#version 450
layout(set = 2, binding = 0) readonly buffer Data { vec4 item[]; } data;
layout(set = 3, binding = 0) uniform Pick { int index; } pick;
layout(location = 0) out vec4 o;
void main() { o = data.item[pick.index]; }
]], "fragment", {})
        pipeline = GraphicsPipeline.create(device.handle, {
            vertexShader = vertex,
            fragmentShader = fragment,
            colorFormat = FORMAT,
        })
        vertex:destroy()
        fragment:destroy()
    end)

    teardown(function()
        if pipeline then pipeline:destroy() end
        if target then target:destroy() end
        if device then device:destroy() end
        if window then window:destroy() end
        C.SDL_Quit()
    end)

    -- Renders element `index` of `buffer` and returns its colour.
    local function readElement(buffer, index)
        local pick = loader.newArray("int32_t[4]")
        pick[0] = index
        local commandBuffer = C.SDL_AcquireGPUCommandBuffer(device.handle)
        local pass = RenderPass.begin(commandBuffer,
            { { texture = target.handle, clear = { r = 0, g = 0, b = 0, a = 1 } } })
        pass:bindPipeline(pipeline.handle)
        pass:bindFragmentStorageBuffers(0, { buffer.handle })
        C.SDL_PushGPUFragmentUniformData(commandBuffer, 0, pick, 16)
        pass:draw(3)
        pass:finish()
        assert(C.SDL_SubmitGPUCommandBuffer(commandBuffer))
        return target:getPixel(target:readback(), SIZE / 2, SIZE / 2)
    end

    -- Writes a vec4 straight into mapped staging, with no staging array.
    local function writeElement(buffer, index, r, g, b)
        local floats = buffer:mapAs("float *")
        local base = index * 4
        floats[base] = r
        floats[base + 1] = g
        floats[base + 2] = b
        floats[base + 3] = 1.0
        buffer:markDirty(index * 16, 16)
    end

    local function flush(buffer)
        local commandBuffer = C.SDL_AcquireGPUCommandBuffer(device.handle)
        local wrote = buffer:flush(commandBuffer)
        assert(C.SDL_SubmitGPUCommandBuffer(commandBuffer))
        return wrote
    end

    it("uploads a range written directly into mapped memory", function()
        local buffer = Buffer.create(device.handle,
            { usage = { "storage" }, size = 16 * 8 })
        writeElement(buffer, 0, 1.0, 0.0, 0.0)
        assert.is_true(flush(buffer))

        local pixel = readElement(buffer, 0)
        assert.are.equal(255, pixel.r)
        assert.are.equal(0, pixel.g)
        buffer:destroy()
    end)

    it("preserves ranges a later flush did not rewrite", function()
        -- The destination must never be cycled: cycling discards the whole
        -- buffer, so element 0 would come back black after the second flush.
        local buffer = Buffer.create(device.handle,
            { usage = { "storage" }, size = 16 * 8 })

        writeElement(buffer, 0, 1.0, 0.0, 0.0)
        flush(buffer)

        writeElement(buffer, 3, 0.0, 0.0, 1.0)
        flush(buffer)

        local first = readElement(buffer, 0)
        local second = readElement(buffer, 3)

        assert.are.equal(255, first.r, "the untouched range must survive")
        assert.are.equal(0, first.b)
        assert.are.equal(255, second.b)
        buffer:destroy()
    end)

    it("merges adjacent writes into one range", function()
        local buffer = Buffer.create(device.handle,
            { usage = { "storage" }, size = 16 * 8 })
        buffer:map()
        buffer:markDirty(0, 16)
        buffer:markDirty(16, 16)
        buffer:markDirty(32, 16)
        assert.are.equal(1, buffer._rangeCount,
            "sequential rows should collapse into a single copy")
        assert.are.equal(48, buffer.dirtyBytes)
        buffer:destroy()
    end)

    it("keeps disjoint writes as separate ranges", function()
        local buffer = Buffer.create(device.handle,
            { usage = { "storage" }, size = 16 * 64 })
        buffer:map()
        buffer:markDirty(0, 16)
        buffer:markDirty(512, 16)
        assert.are.equal(2, buffer._rangeCount)
        buffer:destroy()
    end)

    it("collapses to one span rather than losing track", function()
        local buffer = Buffer.create(device.handle,
            { usage = { "storage" }, size = 16 * 1024 })
        buffer:map()
        -- Every write disjoint, well past the tracked-range limit.
        for index = 0, 200 do
            buffer:markDirty(index * 64, 16)
        end
        assert.are.equal(1, buffer._rangeCount,
            "overflow must collapse, never drop a range")
        local ranges = buffer._ranges
        assert.are.equal(0, tonumber(ranges[0]))
        assert.is_true(tonumber(ranges[1]) >= 200 * 64,
            "the collapsed span must cover every marked write")
        buffer:destroy()
    end)

    it("reports nothing to do when no range was marked", function()
        local buffer = Buffer.create(device.handle,
            { usage = { "storage" }, size = 64 })
        assert.is_false(flush(buffer), "an unmarked buffer must not copy")
        buffer:destroy()
    end)

    it("sizes staging to the buffer by default", function()
        local buffer = Buffer.create(device.handle,
            { usage = { "storage" }, size = 4096 })
        assert.are.equal(4096, buffer._transferSize)

        local bounded = Buffer.create(device.handle,
            { usage = { "storage" }, size = 4096, stagingSize = 256 })
        assert.are.equal(256, bounded._transferSize)

        buffer:destroy()
        bounded:destroy()
    end)
end)
