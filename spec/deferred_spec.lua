-- The pass graph and the deferred pipeline built on it.
--
-- Deferred rendering hides its mistakes well: a mis-sampled G-buffer, a
-- flipped UV, or a pass reading a stale target all produce a plausible image.
-- These tests use asymmetric content and read pixels back, so an orientation
-- error cannot pass as a lighting result.

-- Our build first, so it wins over the ECS repo's own engine tree.
-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local sdl = require("tecs.ffi.sdl3")
local newWindow = require("tecs.platform.window").newWindow
local Device = require("tecs.gpu.Device")
local Shader = require("tecs.gpu.Shader")
local Texture = require("tecs.gpu.Texture")
local RenderPass = require("tecs.gpu.RenderPass")
local GraphicsPipeline = require("tecs.gpu.GraphicsPipeline")
local PassGraph = require("tecs.gpu.PassGraph")
local Deferred = require("tecs.gpu.Deferred")

local C = sdl.C
local FORMAT = 4 -- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local SIZE = 64

-- Fills the target with a gradient that differs in every direction, so a
-- flipped or swapped axis changes the sampled value.
local GRADIENT_GEOMETRY = [[
#version 450
layout(location = 0) out vec4 albedo;
layout(location = 1) out vec4 normal;
layout(set = 3, binding = 0) uniform Size { vec4 target; } size;
void main() {
    vec2 uv = gl_FragCoord.xy / size.target.xy;
    albedo = vec4(uv.x, uv.y, 0.25, 1.0);
    normal = vec4(0.5, 0.5, 1.0, 1.0);
}
]]

local FULLSCREEN_VS = [[
#version 450
void main() {
    vec2 p[3] = vec2[3](vec2(-1,-1), vec2(3,-1), vec2(-1,3));
    gl_Position = vec4(p[gl_VertexIndex], 0, 1);
}
]]

-- Covers the target in a color no clear under test uses, so a pixel read back
-- says which of the three wrote it.
local RED_FS = [[
#version 450
layout(location = 0) out vec4 color;
void main() { color = vec4(1.0, 0.0, 0.0, 1.0); }
]]

describe("pass graph", function()
    local window, device

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = newWindow({ title = "deferred", width = SIZE, height = SIZE })
        device = Device.create(window, { debug = true })
    end)

    teardown(function()
        if device then
            device:destroy()
        end
        if window then
            window:destroy()
        end
        C.SDL_Quit()
    end)

    it("rejects a pass that reads a target nothing has written", function()
        local graph = PassGraph.create(device.handle, FORMAT)
        graph:target({ name = "lit", format = FORMAT })

        local ok, err = pcall(function()
            graph:pass({
                name = "composite",
                inputs = { "lit" },
                outputs = {},
                execute = function() end,
            })
        end)

        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("before any pass writes it"))
        graph:destroy()
    end)

    it("rejects a pass that names an undeclared target", function()
        local graph = PassGraph.create(device.handle, FORMAT)
        local ok, err = pcall(function()
            graph:pass({
                name = "geometry",
                outputs = { "nothingDeclaredThis" },
                execute = function() end,
            })
        end)

        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("undeclared target"))
        graph:destroy()
    end)

    it("rejects depth on a pass that writes a scaled target", function()
        -- One frame-sized depth attachment serves every depth pass, so a pass
        -- drawing into a half-size target cannot share it. SDL would reject the
        -- mismatch when the pass began, which names nothing useful.
        local graph = PassGraph.create(device.handle, FORMAT)
        graph:target({ name = "half", format = FORMAT, scale = 0.5 })

        local ok, err = pcall(function()
            graph:pass({
                name = "bloom",
                outputs = { "half" },
                depth = { test = true, write = true },
                execute = function() end,
            })
        end)

        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("frame sized"))
        graph:destroy()
    end)

    it("skips a pass whose gate returns false", function()
        local graph = PassGraph.create(device.handle, FORMAT)
        graph:target({ name = "scratch", format = FORMAT })

        local ran = 0
        local gate = false
        graph:pass({
            name = "gated",
            outputs = { "scratch" },
            enabled = function()
                return gate
            end,
            execute = function()
                ran = ran + 1
            end,
        })

        -- A frame stands in for the swapchain; only the gate is under test.
        local frame = { width = SIZE, height = SIZE, commandBuffer = nil, swapchainTexture = nil }

        local commandBuffer = C.SDL_AcquireGPUCommandBuffer(device.handle)
        frame.commandBuffer = commandBuffer
        graph:execute(frame)
        assert.are.equal(0, ran, "a disabled pass must not run")

        gate = true
        graph:execute(frame)
        assert.are.equal(1, ran, "an enabled pass must run")

        assert(C.SDL_SubmitGPUCommandBuffer(commandBuffer))
        graph:destroy()
    end)

    it("takes a pass's own clear over the target's, and loads when asked", function()
        -- A clear read from the target is right while one pass writes it and
        -- wrong as soon as two do: the second clears the first one's result
        -- away. Both directions are under test, because a pass adding to a
        -- target needs to refuse a clear the target declares and a pass
        -- sharing a target needs to name one the target does not.
        local graph = PassGraph.create(device.handle, FORMAT)
        graph:target({
            name = "canvas",
            format = FORMAT,
            clear = { r = 0, g = 0, b = 0, a = 1 },
        })

        local fill
        local drawing, loading, overriding = true, false, false

        graph:pass({
            name = "fill",
            outputs = { "canvas" },
            enabled = function()
                return drawing
            end,
            execute = function(context)
                context.pass:bindPipeline(fill.handle)
                context.pass:draw(3)
            end,
        })
        graph:pass({
            name = "loads",
            outputs = { "canvas" },
            clear = PassGraph.LOAD,
            enabled = function()
                return loading
            end,
            execute = function() end,
        })
        graph:pass({
            name = "clears",
            outputs = { "canvas" },
            clear = { r = 0, g = 0, b = 1, a = 1 },
            enabled = function()
                return overriding
            end,
            execute = function() end,
        })

        local vertex = Shader.fromGLSL(device.handle, FULLSCREEN_VS, "vertex", {})
        local fragment = Shader.fromGLSL(device.handle, RED_FS, "fragment", {})
        fill = GraphicsPipeline.create(device.handle, {
            vertexShader = vertex,
            fragmentShader = fragment,
            colorFormat = FORMAT,
        })
        vertex:destroy()
        fragment:destroy()

        -- No swapchain texture: every pass here writes a graph target, and the
        -- target is what is read back between runs.
        local frame = { width = SIZE, height = SIZE, commandBuffer = nil, swapchainTexture = nil }
        local function run()
            frame.commandBuffer = C.SDL_AcquireGPUCommandBuffer(device.handle)
            graph:execute(frame)
            assert(C.SDL_SubmitGPUCommandBuffer(frame.commandBuffer))
            local canvas = graph:texture("canvas")
            return canvas:getPixel(canvas:readback(), SIZE / 2, SIZE / 2)
        end

        assert.are.equal(255, run().r, "the pass that fills the target must leave it red")

        drawing, loading = false, true
        assert.are.equal(255, run().r, "a pass asking to load must keep what the last one left")

        loading, overriding = false, true
        local blue = run()
        assert.are.equal(255, blue.b)
        assert.are.equal(0, blue.r, "a pass naming a clear must have it over the target's")

        fill:destroy()
        graph:destroy()
    end)
end)

describe("deferred pipeline", function()
    local window, device, screen

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = newWindow({ title = "deferred", width = SIZE, height = SIZE })
        device = Device.create(window, { debug = true })
        screen = Texture.create(device.handle, { width = SIZE, height = SIZE, format = FORMAT })
    end)

    teardown(function()
        if screen then
            screen:destroy()
        end
        if device then
            device:destroy()
        end
        if window then
            window:destroy()
        end
        C.SDL_Quit()
    end)

    -- Runs the pipeline against an offscreen texture standing in for the
    -- swapchain, and returns the composited pixels.
    local function render(pipeline)
        local commandBuffer = C.SDL_AcquireGPUCommandBuffer(device.handle)
        local frame = {
            width = SIZE,
            height = SIZE,
            commandBuffer = commandBuffer,
            swapchainTexture = screen.handle,
        }
        pipeline:render(frame)
        assert(C.SDL_SubmitGPUCommandBuffer(commandBuffer))
        return screen:readback()
    end

    it("carries G-buffer content through lighting to the screen", function()
        local sizeUniform = require("tecs.ffi.loader").newArray("float[4]")
        sizeUniform[0] = SIZE
        sizeUniform[1] = SIZE

        local geometryPipeline
        local pipeline = Deferred.create(device.handle, FORMAT, {
            -- Fully bright ambient isolates transport from lighting: whatever
            -- geometry wrote should arrive unchanged.
            ambient = { 1.0, 1.0, 1.0 },
            geometry = function(context)
                context.pass:bindPipeline(geometryPipeline.handle)
                C.SDL_PushGPUFragmentUniformData(context.commandBuffer, 0, sizeUniform, 16)
                context.pass:draw(3)
            end,
        })

        local albedoFormat, normalFormat = pipeline:geometryFormats()
        local vertex = Shader.fromGLSL(device.handle, FULLSCREEN_VS, "vertex", { name = "gbuffer.vert" })
        local fragment = Shader.fromGLSL(device.handle, GRADIENT_GEOMETRY, "fragment", { name = "gbuffer.frag" })
        geometryPipeline = GraphicsPipeline.create(device.handle, {
            vertexShader = vertex,
            fragmentShader = fragment,
            colorFormats = { albedoFormat, normalFormat },
            depth = pipeline:geometryDepth(),
        })
        vertex:destroy()
        fragment:destroy()

        local pixels = render(pipeline)

        -- gl_FragCoord has its origin at the top-left, matching readback rows,
        -- so red tracks the column and green tracks the row. Sampling a corner
        -- pins both axes: a flipped V would swap the green readings.
        local topLeft = screen:getPixel(pixels, 4, 4)
        local topRight = screen:getPixel(pixels, SIZE - 4, 4)
        local bottomLeft = screen:getPixel(pixels, 4, SIZE - 4)

        assert.is_true(
            topRight.r > topLeft.r + 200,
            ("red must grow rightward: %d then %d"):format(topLeft.r, topRight.r)
        )
        assert.is_true(
            bottomLeft.g > topLeft.g + 200,
            ("green must grow downward: %d then %d"):format(topLeft.g, bottomLeft.g)
        )
        assert.is_true(math.abs(topLeft.b - 64) <= 2, ("blue must survive transport, got %d"):format(topLeft.b))

        geometryPipeline:destroy()
        pipeline:destroy()
    end)

    it("darkens the scene when no light reaches it", function()
        local geometryPipeline
        local pipeline = Deferred.create(device.handle, FORMAT, {
            ambient = { 0.0, 0.0, 0.0 },
            geometry = function(context)
                context.pass:bindPipeline(geometryPipeline.handle)
                context.pass:draw(3)
            end,
        })

        local albedoFormat, normalFormat = pipeline:geometryFormats()
        local vertex = Shader.fromGLSL(device.handle, FULLSCREEN_VS, "vertex", {})
        local fragment = Shader.fromGLSL(
            device.handle,
            [[
#version 450
layout(location = 0) out vec4 albedo;
layout(location = 1) out vec4 normal;
void main() {
    albedo = vec4(1.0, 1.0, 1.0, 1.0);
    normal = vec4(0.5, 0.5, 1.0, 1.0);
}
]],
            "fragment",
            {}
        )
        geometryPipeline = GraphicsPipeline.create(device.handle, {
            vertexShader = vertex,
            fragmentShader = fragment,
            colorFormats = { albedoFormat, normalFormat },
            depth = pipeline:geometryDepth(),
        })
        vertex:destroy()
        fragment:destroy()

        local dark = screen:getPixel(render(pipeline), SIZE / 2, SIZE / 2)
        assert.are.equal(0, dark.r, "white albedo with no light must be black")

        -- One light over the center must brighten it and leave a far corner
        -- comparatively dark, which is what proves attenuation is applied.
        pipeline:setLights({
            { x = SIZE / 2, y = SIZE / 2, z = 12, radius = 28, r = 1, g = 1, b = 1, intensity = 4 },
        })

        local pixels = render(pipeline)
        local center = screen:getPixel(pixels, SIZE / 2, SIZE / 2)
        local corner = screen:getPixel(pixels, 2, 2)

        assert.is_true(center.r > 180, ("lit center should be bright, got %d"):format(center.r))
        assert.is_true(corner.r < 40, ("beyond the radius should stay dark, got %d"):format(corner.r))

        geometryPipeline:destroy()
        pipeline:destroy()
    end)

    it("attaches depth to geometry and to nothing else", function()
        -- A pipeline's target info has to match the pass it draws in, so "no
        -- depth" has to be an answer the graph gives rather than something the
        -- caller assumes. The fullscreen passes cover every pixel once and
        -- would only have an attachment to keep in step.
        local pipeline = Deferred.create(device.handle, FORMAT, {})

        local depth = pipeline:geometryDepth()
        assert.is_not_nil(depth, "geometry must have a depth attachment")
        assert.is_true(depth.test)
        assert.is_true(depth.write)
        assert.are.equal(pipeline.graph.depthFormat, depth.format)

        assert.is_nil(pipeline.graph:depthOf("lighting"), "a fullscreen resolve has nothing to be occluded by")
        assert.is_nil(pipeline.graph:depthOf("composite"))
        assert.is_nil(pipeline.graph:depthOf("present"))
        pipeline:destroy()
    end)

    it("composites into a scene target and copies that to the screen", function()
        -- The seam. Composite writes a target the graph owns and present puts
        -- it on the swapchain, so anything wanting to run after compositing
        -- has a target to read and a pass to sit before. What must not change
        -- is the image, so the two are compared to each other rather than each
        -- asserted against a color: a flipped or offset copy fails here even
        -- though both halves would look plausible alone.
        local sizeUniform = require("tecs.ffi.loader").newArray("float[4]")
        sizeUniform[0] = SIZE
        sizeUniform[1] = SIZE

        local geometryPipeline
        local pipeline = Deferred.create(device.handle, FORMAT, {
            ambient = { 1.0, 1.0, 1.0 },
            geometry = function(context)
                context.pass:bindPipeline(geometryPipeline.handle)
                C.SDL_PushGPUFragmentUniformData(context.commandBuffer, 0, sizeUniform, 16)
                context.pass:draw(3)
            end,
        })

        local albedoFormat, normalFormat = pipeline:geometryFormats()
        local vertex = Shader.fromGLSL(device.handle, FULLSCREEN_VS, "vertex", {})
        local fragment = Shader.fromGLSL(device.handle, GRADIENT_GEOMETRY, "fragment", {})
        geometryPipeline = GraphicsPipeline.create(device.handle, {
            vertexShader = vertex,
            fragmentShader = fragment,
            colorFormats = { albedoFormat, normalFormat },
            depth = pipeline:geometryDepth(),
        })
        vertex:destroy()
        fragment:destroy()

        local screenPixels = render(pipeline)

        local scene = pipeline.graph:texture("scene")
        assert.is_not_nil(scene, "the graph must own a target named scene")
        local scenePixels = scene:readback()

        for _, point in ipairs({
            { 4, 4 },
            { SIZE - 4, 4 },
            { 4, SIZE - 4 },
            { SIZE - 4, SIZE - 4 },
            { SIZE / 2, SIZE / 2 },
        }) do
            local x, y = point[1], point[2]
            local shown = screen:getPixel(screenPixels, x, y)
            local held = scene:getPixel(scenePixels, x, y)
            assert.are.equal(shown.r, held.r, ("red differs at %d,%d"):format(x, y))
            assert.are.equal(shown.g, held.g, ("green differs at %d,%d"):format(x, y))
            assert.are.equal(shown.b, held.b, ("blue differs at %d,%d"):format(x, y))
        end

        -- And the scene really carries the image rather than a uniform fill,
        -- which is what makes the comparison above worth making.
        assert.is_true(
            scene:getPixel(scenePixels, SIZE - 4, 4).r > scene:getPixel(scenePixels, 4, 4).r + 200,
            "the scene target must hold the gradient composite produced"
        )

        geometryPipeline:destroy()
        pipeline:destroy()
    end)

    it("refuses to answer for a pass it does not have", function()
        local pipeline = Deferred.create(device.handle, FORMAT, {})
        local ok, err = pcall(function()
            pipeline.graph:depthOf("noSuchPass")
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("no pass named"))
        pipeline:destroy()
    end)
end)
