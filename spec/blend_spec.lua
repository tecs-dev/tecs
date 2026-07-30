-- Forward blending, asserted on the composited image.
--
-- Blending is the one part of the renderer whose result cannot be inferred from
-- the parts: a pass that ran and drew nothing, a pipeline whose blend state was
-- dropped, and a sort that ordered the list backwards all produce a plausible
-- frame. So every claim here is a pixel read back out of the scene target, and
-- every one of them is paired with the same scene drawn opaque, which is the
-- only way to tell a blend from a color that happened to look like one.

-- Our build first, so it wins over the ECS repo's own engine tree.
-- The build directory is the build system's to choose, so it is passed in.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local sdl = require("tecs.ffi.sdl3")
local newWindow = require("tecs.platform.window").newWindow
local Device = require("tecs.gpu.Device")
local Texture = require("tecs.gpu.Texture")
local Backend = require("tecs.Backend")
local FramePacket = require("tecs.FramePacket")
local instancelayout = require("tecs.gpu.instancelayout")

local C = sdl.C
local FORMAT = 4 -- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local SIZE = 64
local INSTANCE_FLOATS = instancelayout.FLOATS
local INSTANCE_BYTES = instancelayout.BYTES
local BOUND_FLOATS = instancelayout.BOUND_FLOATS
local BOUND_BYTES = instancelayout.BOUND_BYTES

describe("forward blending", function()
    local window, device, screen

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = newWindow({ title = "blend", width = SIZE, height = SIZE })
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

    local function newBackend()
        return Backend.create(device.handle, FORMAT, {
            -- Fully bright ambient takes lighting out of the question: what
            -- reaches the target is what the material produced, so a difference
            -- between two runs is the blend and nothing else.
            ambient = { 1.0, 1.0, 1.0 },
            capacity = 16,
        })
    end

    -- One quad covering the whole target, written by hand into the staging the
    -- backend mapped. This is exactly what an extractor writes, including the
    -- two things that decide how it is drawn: the first half extent of its cull
    -- bound negated, which routes it forward, and the blend mode packed into the
    -- slot float, which says what the forward pass does with it once it is there.
    local function writeQuad(backend, index, depth, r, g, b, a, blended, mode)
        local instances, bounds = backend:mapSlot(0)
        local base = index * INSTANCE_FLOATS
        instances[base] = 0.0 -- rotation
        instances[base + 1] = SIZE * 2 -- scale
        instances[base + 2] = SIZE * 2
        instances[base + 3] = depth
        instances[base + 4] = SIZE / 2
        instances[base + 5] = SIZE / 2
        -- White layer, no clip region, no cast height. Alpha packs as zero, so
        -- naming no mode writes the float a writer that never heard of blend
        -- modes wrote.
        instances[base + 6] = instancelayout.packSlot(0, 0, nil, instancelayout.blendOf(mode or "alpha"))
        instances[base + 7] = 0.0 -- default material
        instances[base + 8], instances[base + 9] = r, g
        instances[base + 10], instances[base + 11] = b, a
        instances[base + 12], instances[base + 13] = 0.0, 0.0
        instances[base + 14], instances[base + 15] = backend.whiteU1, backend.whiteV1

        local bound = index * BOUND_FLOATS
        bounds[bound], bounds[bound + 1] = SIZE / 2, SIZE / 2
        bounds[bound + 2] = blended and -SIZE or SIZE
        bounds[bound + 3] = SIZE
    end

    -- Names every instance written so far and points the packet's camera at
    -- them, which is what an extraction would have left behind.
    local function finish(packet, count, blendCount)
        packet:begin(0)
        packet.count = count
        packet.dropped = 0
        packet.rewritten = count
        packet.blendCount = blendCount
        packet.instanceRanges:mark(0, count * INSTANCE_BYTES)
        packet.boundsRanges:mark(0, count * BOUND_BYTES)
        packet.cameraX = SIZE / 2
        packet.cameraY = SIZE / 2
        packet.cameraZoom = 1.0
        packet.cameraRotation = 0.0
    end

    local function consume(backend, packet)
        local commandBuffer = C.SDL_AcquireGPUCommandBuffer(device.handle)
        backend:consume(packet, {
            width = SIZE,
            height = SIZE,
            commandBuffer = commandBuffer,
            swapchainTexture = screen.handle,
        })
        assert(C.SDL_SubmitGPUCommandBuffer(commandBuffer))
        local scene = backend:captureTexture()
        return scene, scene:readback()
    end

    -- How far a channel may be from the value straight alpha arithmetic gives,
    -- which is one step of an eight bit channel plus the rounding either side
    -- of it.
    local function near(actual, expected, what)
        assert.is_true(
            math.abs(actual - expected) <= 2,
            ("%s: expected about %d, got %d"):format(what, expected, actual)
        )
    end

    it("blends a tint's alpha over what the G-buffer already drew", function()
        local backend = newBackend()
        local packet = FramePacket.create()

        -- Red behind, opaque. Green in front at half alpha, so half of the red
        -- has to survive it.
        writeQuad(backend, 0, 0.6, 1.0, 0.0, 0.0, 1.0, false)
        writeQuad(backend, 1, 0.5, 0.0, 1.0, 0.0, 0.5, true)
        finish(packet, 2, 1)

        local scene, pixels = consume(backend, packet)
        local center = scene:getPixel(pixels, SIZE / 2, SIZE / 2)
        near(center.r, 128, "half the red behind must survive")
        near(center.g, 128, "half the green in front must land")
        near(center.b, 0, "nothing wrote blue")

        backend:destroy()
    end)

    it("draws the same quad opaque when its alpha is one", function()
        -- The revert check, and the reason the test above means anything. The
        -- scene is identical except for the alpha and the lane it selects, so a
        -- renderer that ignored both would produce the same image twice.
        local backend = newBackend()
        local packet = FramePacket.create()

        writeQuad(backend, 0, 0.6, 1.0, 0.0, 0.0, 1.0, false)
        writeQuad(backend, 1, 0.5, 0.0, 1.0, 0.0, 1.0, false)
        finish(packet, 2, 0)

        local scene, pixels = consume(backend, packet)
        local center = scene:getPixel(pixels, SIZE / 2, SIZE / 2)
        assert.are.equal(255, center.g, "an opaque quad in front must cover what is behind it")
        assert.are.equal(0, center.r, "and none of it may survive")

        backend:destroy()
    end)

    it("draws blended geometry back to front, whatever order it was written in", function()
        -- Two blended quads over an opaque one, written nearest first so that
        -- instance order is exactly the wrong order. Straight alpha does not
        -- commute, so the two orders give different pixels: far then near
        -- leaves more of the near quad's color, and the sort is the only thing
        -- that can produce it from this layout.
        local backend = newBackend()
        local packet = FramePacket.create()

        writeQuad(backend, 0, 0.7, 1.0, 1.0, 1.0, 1.0, false)
        writeQuad(backend, 1, 0.5, 0.0, 0.0, 1.0, 0.5, true)
        writeQuad(backend, 2, 0.6, 1.0, 0.0, 0.0, 0.5, true)
        finish(packet, 3, 2)

        local scene, pixels = consume(backend, packet)
        local center = scene:getPixel(pixels, SIZE / 2, SIZE / 2)

        -- Red over white gives (1, 0.5, 0.5); blue over that gives
        -- (0.5, 0.25, 0.75). The other order gives (0.75, 0.25, 0.5), which is
        -- the same three numbers with red and blue exchanged.
        near(center.r, 128, "the farther quad's red must be half covered")
        near(center.g, 64, "green comes only from the white behind both")
        near(center.b, 191, "the nearer quad's blue must be the last thing applied")
        assert.is_true(center.b > center.r, "back to front, not front to back")

        backend:destroy()
    end)

    it("leaves the scene alone when nothing is blended", function()
        -- The forward pass runs every frame, so it has to be a no-op on a frame
        -- with no forward list. A stale list from an earlier frame would show
        -- up here as the blend that frame produced.
        local backend = newBackend()
        local packet = FramePacket.create()

        writeQuad(backend, 0, 0.6, 1.0, 0.0, 0.0, 1.0, false)
        writeQuad(backend, 1, 0.5, 0.0, 1.0, 0.0, 0.5, true)
        finish(packet, 2, 1)
        consume(backend, packet)

        -- The same two quads, now both opaque and neither routed forward.
        writeQuad(backend, 1, 0.5, 0.0, 1.0, 0.0, 1.0, false)
        finish(packet, 2, 0)

        local scene, pixels = consume(backend, packet)
        local center = scene:getPixel(pixels, SIZE / 2, SIZE / 2)
        assert.are.equal(255, center.g)
        assert.are.equal(0, center.r, "the previous frame's forward list must not be drawn again")

        backend:destroy()
    end)

    it("adds an additive instance to what is behind it instead of covering it", function()
        -- The same scene twice, differing only in the blend mode packed into the
        -- slot float. Blue behind, opaque. Red in front at half alpha, so alpha
        -- over keeps half the blue and additive keeps all of it: the blue channel
        -- is what tells the two apart, and neither pass changes the red.
        local backend = newBackend()
        local packet = FramePacket.create()

        writeQuad(backend, 0, 0.6, 0.0, 0.0, 1.0, 1.0, false)
        writeQuad(backend, 1, 0.5, 1.0, 0.0, 0.0, 0.5, true, "additive")
        finish(packet, 2, 1)

        local scene, pixels = consume(backend, packet)
        local center = scene:getPixel(pixels, SIZE / 2, SIZE / 2)
        near(center.r, 128, "half the red must land")
        near(center.g, 0, "nothing wrote green")
        assert.are.equal(255, center.b, "an additive fragment must leave what is behind it whole")

        backend:destroy()
    end)

    it("blends the same instance over what is behind it when the mode is alpha", function()
        -- The revert check for the pair above, and the reason either means
        -- anything: one number in one float is the whole difference.
        local backend = newBackend()
        local packet = FramePacket.create()

        writeQuad(backend, 0, 0.6, 0.0, 0.0, 1.0, 1.0, false)
        writeQuad(backend, 1, 0.5, 1.0, 0.0, 0.0, 0.5, true, "alpha")
        finish(packet, 2, 1)

        local scene, pixels = consume(backend, packet)
        local center = scene:getPixel(pixels, SIZE / 2, SIZE / 2)
        near(center.r, 128, "half the red must land")
        near(center.b, 128, "and half the blue behind it must give way")

        backend:destroy()
    end)

    it("attaches the geometry pass's depth to the forward pass, unwritten", function()
        local backend = newBackend()
        local graph = backend.deferred.graph

        local depth = graph:depthOf("forward")
        assert.is_not_nil(depth, "a forward pass with no depth cannot sort against the G-buffer")
        assert.is_true(depth.test)
        assert.is_false(depth.write, "writing depth would let a blended fragment hide another")
        assert.are.equal(graph.depthFormat, depth.format)

        assert.are.equal(
            graph:formatOf("scene"),
            backend.deferred:forwardFormat(),
            "the forward pass draws onto the composited image"
        )

        backend:destroy()
    end)
end)
