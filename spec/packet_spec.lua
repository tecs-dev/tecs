-- The seam between extraction and rendering.
--
-- The renderer specs assert that a world reaches the screen. These assert that
-- the two halves of getting it there are actually separable: the extractor is
-- driven with no device anywhere in the test, and the backend is driven from a
-- packet built by hand with no world anywhere in the test. If either could
-- reach the other, one of these two would need what it does not have.

-- Our build first, so it wins over the ECS repo's own engine tree.
-- The build directory is the build system's to choose, so it is passed in.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local sdl = require("tecs.ffi.sdl3")
local loader = require("tecs.ffi.loader")
local Window = require("tecs.platform.Window")
local Device = require("tecs.gpu.Device")
local Texture = require("tecs.gpu.Texture")
local Extractor = require("tecs.Extractor")
local Backend = require("tecs.Backend")
local FramePacket = require("tecs.FramePacket")
local components = require("tecs.components")
local instancelayout = require("tecs.gpu.instancelayout")

local C = sdl.C
local FORMAT = 4 -- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local SIZE = 64

local Transform = components.Transform
local Tint = components.Tint
local Renderable = components.Renderable
local PointLight = components.PointLight

local INSTANCE_FLOATS = instancelayout.FLOATS
local INSTANCE_BYTES = instancelayout.BYTES
local BOUND_BYTES = instancelayout.BOUND_BYTES

describe("render extraction", function()
    local CAPACITY = 64

    -- Staging is a pair of addresses to the extractor and nothing more, so a
    -- plain C array is the whole of what a device supplies it with.
    local function newExtraction()
        local world = tecs.newWorld()
        local extractor = Extractor.create({
            capacity = CAPACITY,
            whiteU0 = 0.0,
            whiteV0 = 0.0,
            whiteU1 = 1 / 512,
            whiteV1 = 1 / 512,
        })
        local packet = FramePacket.create()
        local instances = loader.newArray("float[?]", CAPACITY * INSTANCE_FLOATS)
        local bounds = loader.newArray("float[?]", CAPACITY * 4)
        extractor:setStaging(0, instances, bounds)
        extractor:install(world, packet)
        return world, extractor, packet, instances
    end

    it("reports what it laid out from a known world", function()
        local world, _, packet = newExtraction()
        for _ = 1, 3 do
            world:spawn(Transform(8, 8, 0, 1, 0, 4, 4), Tint(1, 1, 1, 1), Renderable())
        end

        world:update(1 / 60)

        assert.are.equal(3, packet.count)
        assert.are.equal(0, packet.dropped)
        assert.are.equal(3, packet.rewritten, "the first frame lays the whole run out")
        assert.are.equal(0, packet.slot, "into the slot it was pointed at")
    end)

    it("marks the bytes it wrote and nothing else", function()
        local world, _, packet = newExtraction()
        for _ = 1, 3 do
            world:spawn(Transform(8, 8, 0, 1, 0, 4, 4), Tint(1, 1, 1, 1), Renderable())
        end

        world:update(1 / 60)

        assert.are.equal(1, packet.instanceRanges.count, "one archetype is one contiguous run")
        local offset, size = packet.instanceRanges:at(0)
        assert.are.equal(0, offset)
        assert.are.equal(3 * INSTANCE_BYTES, size)

        local boundsOffset, boundsSize = packet.boundsRanges:at(0)
        assert.are.equal(0, boundsOffset)
        assert.are.equal(3 * BOUND_BYTES, boundsSize)
    end)

    it("marks nothing on a frame where nothing changed", function()
        local world, _, packet = newExtraction()
        world:spawn(Transform(8, 8, 0, 1, 0, 4, 4), Tint(1, 1, 1, 1), Renderable())

        world:update(1 / 60)
        world:update(1 / 60)

        assert.are.equal(1, packet.count, "the instance is still resident")
        assert.are.equal(0, packet.rewritten)
        assert.are.equal(0, packet.instanceRanges.count, "a still frame gives the backend nothing to copy")
    end)

    it("reports rows it could not fit", function()
        local world, _, packet = newExtraction()
        for _ = 1, CAPACITY + 6 do
            world:spawn(Transform(0, 0, 0, 1, 0, 1, 1), Tint(1, 1, 1, 1), Renderable())
        end

        world:update(1 / 60)

        assert.are.equal(CAPACITY, packet.count)
        assert.are.equal(6, packet.dropped)
    end)

    it("writes instances into the staging it was handed", function()
        local world, _, packet, instances = newExtraction()
        world:spawn(Transform(12, 34, 0, 1, 0, 4, 4), Tint(0.25, 0.5, 0.75, 1), Renderable())

        world:update(1 / 60)

        assert.are.equal(12, instances[4], "the origin is where the row said")
        assert.are.equal(34, instances[5])
        assert.are.equal(0.25, instances[8])
        assert.are.equal(1, packet.count)
    end)

    it("copies the camera rather than referring to it", function()
        local world, extractor, packet = newExtraction()
        extractor.camera.x = 200
        extractor.camera.y = 100
        extractor.camera.zoom = 2.0

        world:update(1 / 60)
        assert.are.equal(200, packet.cameraX)
        assert.are.equal(100, packet.cameraY)
        assert.are.equal(2.0, packet.cameraZoom)

        -- Moving it afterwards must not move the frame that was already built.
        extractor.camera.x = 999
        assert.are.equal(200, packet.cameraX)
    end)

    it("packs light entities into the packet's own storage", function()
        local world, _, packet = newExtraction()
        world:spawn(Transform(10, 20, 0, 1, 0, 1, 1), PointLight(12.0, 30.0, 1.0, 0.5, 0.25, 4.0))

        world:update(1 / 60)

        assert.are.equal(1, packet.lightCount)
        assert.are.equal(10, packet.lights[0])
        assert.are.equal(20, packet.lights[1])
        assert.are.equal(12, packet.lights[2], "height")
        assert.are.equal(30, packet.lights[3], "radius")
        assert.are.equal(4, packet.lights[7], "intensity")

        -- Cleared rather than accumulated, so a light that went away goes away.
        world:update(1 / 60)
        assert.are.equal(1, packet.lightCount)
    end)

    it("tells whoever owns the packet that it is filled", function()
        local world = tecs.newWorld()
        local extractor = Extractor.create({
            capacity = CAPACITY,
            whiteU0 = 0.0,
            whiteV0 = 0.0,
            whiteU1 = 1.0,
            whiteV1 = 1.0,
        })
        local packet = FramePacket.create()
        extractor:setStaging(
            0,
            loader.newArray("float[?]", CAPACITY * INSTANCE_FLOATS),
            loader.newArray("float[?]", CAPACITY * 4)
        )

        local seen = 0
        extractor:install(world, packet, function()
            seen = seen + 1
        end)
        world:update(1 / 60)
        world:update(1 / 60)
        assert.are.equal(2, seen, "once per frame, after the packet is filled")
    end)
end)

describe("render backend", function()
    local window, device, screen

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = Window.create({ title = "packet", width = SIZE, height = SIZE })
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
            ambient = { 1.0, 1.0, 1.0 },
            capacity = 16,
        })
    end

    -- One instance covering the whole target, written by hand into the staging
    -- the backend mapped. This is exactly what an extractor writes and is
    -- deliberately written without one.
    local function writeQuad(backend, packet, x, y, r, g, b)
        local instances, bounds = backend:mapSlot(0)
        instances[0] = 0.0 -- rotation
        instances[1] = SIZE * 2 -- scale
        instances[2] = SIZE * 2
        instances[3] = 0.5 -- depth
        instances[4] = x
        instances[5] = y
        instances[6] = 0.0 -- white layer, no clip region
        instances[7] = 0.0 -- default material
        instances[8], instances[9] = r, g
        instances[10], instances[11] = b, 1.0
        instances[12], instances[13] = 0.0, 0.0
        instances[14], instances[15] = backend.whiteU1, backend.whiteV1

        bounds[0], bounds[1] = x, y
        bounds[2], bounds[3] = SIZE, SIZE

        packet:begin(0)
        packet.count = 1
        packet.dropped = 0
        packet.rewritten = 1
        packet.instanceRanges:mark(0, INSTANCE_BYTES)
        packet.boundsRanges:mark(0, BOUND_BYTES)
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
        return screen:readback()
    end

    it("draws a packet built by hand, with no world anywhere", function()
        local backend = newBackend()
        local packet = FramePacket.create()
        writeQuad(backend, packet, SIZE / 2, SIZE / 2, 1.0, 0.0, 0.0)
        packet.cameraX = SIZE / 2
        packet.cameraY = SIZE / 2
        packet.cameraZoom = 1.0

        local centre = screen:getPixel(consume(backend, packet), SIZE / 2, SIZE / 2)
        assert.are.equal(255, centre.r, "the packet's instance reached the screen")
        assert.are.equal(0, centre.g)
        backend:destroy()
    end)

    it("draws from where the packet says the camera was", function()
        local backend = newBackend()
        local packet = FramePacket.create()
        writeQuad(backend, packet, SIZE / 2, SIZE / 2, 0.0, 1.0, 0.0)
        packet.cameraX = SIZE / 2
        packet.cameraY = SIZE / 2
        packet.cameraZoom = 1.0
        assert.are.equal(255, screen:getPixel(consume(backend, packet), SIZE / 2, SIZE / 2).g)

        -- Far enough away that the quad leaves the view entirely, which also
        -- pins that the cull reads the packet's camera and not a stale one.
        writeQuad(backend, packet, SIZE / 2, SIZE / 2, 0.0, 1.0, 0.0)
        packet.cameraX = SIZE * 20
        assert.are.equal(
            0,
            screen:getPixel(consume(backend, packet), SIZE / 2, SIZE / 2).g,
            "the camera the packet carried is the one that was drawn from"
        )
        backend:destroy()
    end)

    it("copies only the ranges the packet named", function()
        local backend = newBackend()
        local packet = FramePacket.create()
        writeQuad(backend, packet, SIZE / 2, SIZE / 2, 0.0, 0.0, 1.0)
        packet.cameraX = SIZE / 2
        packet.cameraY = SIZE / 2
        packet.cameraZoom = 1.0
        consume(backend, packet)

        -- A second frame that names no range at all. The device buffer is
        -- persistent, so the instance is still there and still draws; a backend
        -- that uploaded whatever it found in staging would draw the same thing,
        -- so the claim is checked from the other end below.
        packet:begin(0)
        assert.are.equal(0, packet.instanceRanges.count)
        assert.are.equal(
            255,
            screen:getPixel(consume(backend, packet), SIZE / 2, SIZE / 2).b,
            "what an earlier packet uploaded stays resident"
        )

        -- Now the staging is changed without the packet saying so. Nothing may
        -- reach the device until a range names those bytes.
        local instances = backend:mapSlot(0)
        instances[8], instances[9], instances[10] = 1.0, 0.0, 0.0
        packet:begin(0)
        assert.are.equal(
            255,
            screen:getPixel(consume(backend, packet), SIZE / 2, SIZE / 2).b,
            "an unnamed write must not be copied"
        )

        packet:begin(0)
        packet.instanceRanges:mark(0, INSTANCE_BYTES)
        assert.are.equal(
            255,
            screen:getPixel(consume(backend, packet), SIZE / 2, SIZE / 2).r,
            "and must be copied once a range names it"
        )
        backend:destroy()
    end)

    it("lights a packet from the light array it carries", function()
        local backend = Backend.create(device.handle, FORMAT, {
            ambient = { 0.0, 0.0, 0.0 },
            capacity = 16,
        })
        local packet = FramePacket.create()
        writeQuad(backend, packet, SIZE / 2, SIZE / 2, 1.0, 1.0, 1.0)
        packet.cameraX = SIZE / 2
        packet.cameraY = SIZE / 2
        packet.cameraZoom = 1.0

        assert.are.equal(
            0,
            screen:getPixel(consume(backend, packet), SIZE / 2, SIZE / 2).r,
            "no ambient and no lights is black"
        )

        writeQuad(backend, packet, SIZE / 2, SIZE / 2, 1.0, 1.0, 1.0)
        packet.cameraX = SIZE / 2
        packet.cameraY = SIZE / 2
        packet.cameraZoom = 1.0
        packet:addLight(SIZE / 2, SIZE / 2, 12.0, 30.0, 1.0, 1.0, 1.0, 4.0)

        local pixels = consume(backend, packet)
        assert.is_true(screen:getPixel(pixels, SIZE / 2, SIZE / 2).r > 180, "the packet's light lit its own frame")
        assert.is_true(screen:getPixel(pixels, 2, 2).r < 60, "and only as far as its radius")
        backend:destroy()
    end)

    -- The line is only where it is claimed to be if the backend cannot reach
    -- across it, and a pixel test cannot tell you that: a module can require
    -- the ECS and still draw the right thing. This reads the module the build
    -- produced, so a require added later fails here rather than being found
    -- when the two halves are moved onto different threads.
    it("names nothing from the ECS", function()
        local forbidden = {
            "tecs%.ecs",
            "tecs%.components",
            "tecs%.internal",
            "tecs%.Extractor",
        }
        for _, module in ipairs({ "Backend", "FramePacket" }) do
            local file = assert(io.open(root .. "/tecs/" .. module .. ".lua"))
            local source = file:read("*a")
            file:close()
            for _, name in ipairs(forbidden) do
                assert.is_nil(
                    source:match('require%("' .. name .. '[%."]'),
                    ("tecs.%s must not require %s"):format(module, name:gsub("%%", ""))
                )
            end
        end
    end)

    it("draws nothing for a packet that counted nothing", function()
        local backend = newBackend()
        local packet = FramePacket.create()
        packet:begin(0)
        packet.count = 0
        packet.cameraX = SIZE / 2
        packet.cameraY = SIZE / 2
        packet.cameraZoom = 1.0

        assert.are.equal(0, screen:getPixel(consume(backend, packet), SIZE / 2, SIZE / 2).r)
        backend:destroy()
    end)
end)
