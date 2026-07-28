-- Shadows, asserted on the composited image.
--
-- Every claim here is a pixel read back out of the scene target, and every one
-- of them is paired with the same scene rendered with the caster's role
-- cleared. That pairing is the whole of what makes these tests worth anything:
-- a mask that never got written, a march that always returns zero and a
-- transform that puts every silhouette off the edge of the mask all produce a
-- plausible frame, and all three produce the *same* frame as the run with the
-- role cleared. Only the difference between the two says the feature ran.
--
-- The scene is asymmetric on purpose. One light on the left means shadows fall
-- to the right, so a pixel that darkened on the wrong side would be a
-- transform with a sign error rather than a shadow.

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

describe("shadows", function()
    local window, device, screen

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = newWindow({ title = "shadow", width = SIZE, height = SIZE })
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

    local function newBackend(options)
        options = options or {}
        return Backend.create(device.handle, FORMAT, {
            ambient = options.ambient or { 0.0, 0.0, 0.0 },
            capacity = 16,
            shadows = options.shadows ~= false and {} or nil,
        })
    end

    -- One quad, written by hand into the staging the backend mapped. This is
    -- exactly what an extractor writes, including the two things that say what
    -- the quad casts: the signs of its cull bound's two half extents, and the
    -- height packed above the clip region in `origin.z`.
    local function writeQuad(backend, index, quad)
        local instances, bounds = backend:mapSlot(0)
        local base = index * INSTANCE_FLOATS
        instances[base] = 0.0 -- rotation
        instances[base + 1] = quad.width
        instances[base + 2] = quad.height
        instances[base + 3] = quad.depth
        instances[base + 4] = quad.x
        instances[base + 5] = quad.y
        instances[base + 6] = instancelayout.packSlot(0, 0, quad.tall or 0)
        instances[base + 7] = 0.0 -- default material
        instances[base + 8], instances[base + 9] = quad.r, quad.g
        instances[base + 10], instances[base + 11] = quad.b, 1.0
        instances[base + 12], instances[base + 13] = 0.0, 0.0
        instances[base + 14], instances[base + 15] = backend.whiteU1, backend.whiteV1

        local signX, signY = instancelayout.signsOf(quad.role or "opaque")
        local bound = index * BOUND_FLOATS
        bounds[bound], bounds[bound + 1] = quad.x, quad.y
        bounds[bound + 2] = signX * quad.width * 0.5
        bounds[bound + 3] = signY * quad.height * 0.5
    end

    local function finish(packet, count, light)
        packet:begin(0)
        packet.count = count
        packet.dropped = 0
        packet.rewritten = count
        packet.blendCount = 0
        packet.instanceRanges:mark(0, count * INSTANCE_BYTES)
        packet.boundsRanges:mark(0, count * BOUND_BYTES)
        packet.cameraX = SIZE / 2
        packet.cameraY = SIZE / 2
        packet.cameraZoom = 1.0
        packet.cameraRotation = 0.0
        if light then
            packet:addLight(light.x, light.y, light.z, light.radius, light.r, light.g, light.b, light.intensity)
        end
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

    -- The floor every scene here stands on: one opaque quad covering the whole
    -- target, behind everything else.
    local FLOOR = { x = SIZE / 2, y = SIZE / 2, width = SIZE * 2, height = SIZE * 2, depth = 0.7, r = 1, g = 1, b = 1 }

    -- Left of the middle and low, so shadows are long and fall rightward.
    local LAMP = { x = 8, y = SIZE / 2, z = 8, radius = 200, r = 1, g = 1, b = 1, intensity = 8 }

    -- Renders the floor plus one more quad, and answers the composited pixels.
    local function renderWith(backend, quad, light)
        local packet = FramePacket.create()
        writeQuad(backend, 0, FLOOR)
        writeQuad(backend, 1, quad)
        finish(packet, 2, light)
        return consume(backend, packet)
    end

    it("blocks a light where an occluder stands between", function()
        -- A wall in the middle of the floor, as tall as an occluder gets. The
        -- pixel to its right is on the far side from the lamp and the pixel
        -- above it is not, and the lamp reaches both.
        local wall = {
            x = SIZE / 2,
            y = SIZE / 2,
            width = 8,
            height = 8,
            depth = 0.6,
            r = 0.5,
            g = 0.5,
            b = 0.5,
            tall = 255,
            role = "occluder",
        }

        local backend = newBackend()
        local scene, pixels = renderWith(backend, wall, LAMP)
        local behind = scene:getPixel(pixels, 48, SIZE / 2)
        local beside = scene:getPixel(pixels, 48, 8)
        local between = scene:getPixel(pixels, 20, SIZE / 2)
        backend:destroy()

        -- The revert check, and the reason the numbers above mean anything. The
        -- same scene with the wall casting nothing: identical geometry,
        -- identical light, identical everything the eye could name.
        wall.role = "opaque"
        local plain = newBackend()
        local plainScene, plainPixels = renderWith(plain, wall, LAMP)
        local behindPlain = plainScene:getPixel(plainPixels, 48, SIZE / 2)
        local besidePlain = plainScene:getPixel(plainPixels, 48, 8)
        local betweenPlain = plainScene:getPixel(plainPixels, 20, SIZE / 2)
        plain:destroy()

        assert.is_true(
            behindPlain.r > 200,
            ("without an occluder the floor behind the wall is lit, got %d"):format(behindPlain.r)
        )
        assert.is_true(
            behind.r < behindPlain.r - 100,
            ("the occluder must block the light: %d shadowed against %d lit"):format(behind.r, behindPlain.r)
        )
        assert.is_true(
            math.abs(beside.r - besidePlain.r) <= 2,
            ("a pixel the wall does not stand in front of must be untouched: %d against %d"):format(
                beside.r,
                besidePlain.r
            )
        )
        assert.is_true(
            math.abs(between.r - betweenPlain.r) <= 2,
            ("the side the light is on must not darken: %d against %d"):format(between.r, betweenPlain.r)
        )
    end)

    it("keeps an occluder the view rejected, out to the shadow margin", function()
        -- A wall entirely off the left edge, with the lamp further off still.
        -- Nothing here is drawn: the view test drops both the wall and the lamp
        -- from everything that rasterises. What lands on screen is the wall's
        -- shadow, and it lands only because the shadow lane tests against a
        -- rectangle wider than the view and the mask's projection is widened by
        -- the same amount, so the silhouette has somewhere inside the mask to
        -- go.
        local wall = {
            x = -8,
            y = SIZE / 2,
            width = 8,
            height = 8,
            depth = 0.6,
            r = 0.5,
            g = 0.5,
            b = 0.5,
            tall = 255,
            role = "occluder",
        }
        local lamp = { x = -30, y = SIZE / 2, z = 8, radius = 200, r = 1, g = 1, b = 1, intensity = 8 }

        local backend = newBackend()
        local scene, pixels = renderWith(backend, wall, lamp)
        local shaded = scene:getPixel(pixels, 12, SIZE / 2)
        backend:destroy()

        wall.role = "opaque"
        local plain = newBackend()
        local plainScene, plainPixels = renderWith(plain, wall, lamp)
        local lit = plainScene:getPixel(plainPixels, 12, SIZE / 2)
        plain:destroy()

        assert.is_true(lit.r > 180, ("an off-screen lamp still lights the floor, got %d"):format(lit.r))
        assert.is_true(
            shaded.r < lit.r - 100,
            ("an off-screen occluder must still cast: %d shadowed against %d lit"):format(shaded.r, lit.r)
        )
    end)

    it("leaves an occluder's own surface lit", function()
        -- Self-shadow is prevented by leaving the origin's body rather than by
        -- a bias, so a wall lights its own face and still shadows the floor
        -- behind it. Without that rule this pixel is the darkest in the frame.
        local wall = {
            x = SIZE / 2,
            y = SIZE / 2,
            width = 16,
            height = 16,
            depth = 0.6,
            r = 1,
            g = 1,
            b = 1,
            tall = 255,
            role = "occluder",
        }

        local backend = newBackend()
        local scene, pixels = renderWith(backend, wall, LAMP)
        local face = scene:getPixel(pixels, SIZE / 2, SIZE / 2)
        backend:destroy()

        wall.role = "opaque"
        local plain = newBackend()
        local plainScene, plainPixels = renderWith(plain, wall, LAMP)
        local facePlain = plainScene:getPixel(plainPixels, SIZE / 2, SIZE / 2)
        plain:destroy()

        assert.is_true(facePlain.r > 150, ("the wall's own face is lit to begin with, got %d"):format(facePlain.r))
        assert.is_true(
            face.r >= facePlain.r - 8,
            ("an occluder must not shadow itself: %d against %d"):format(face.r, facePlain.r)
        )
    end)

    it("throws a drop shadow away from the light and stamps the caster back out", function()
        -- A caster rather than an occluder: it darkens what its copy lands on
        -- and blocks nothing. The lamp is on the left, so the copy goes right.
        local tree = {
            x = SIZE / 2,
            y = SIZE / 2,
            width = 8,
            height = 8,
            depth = 0.6,
            r = 1,
            g = 1,
            b = 1,
            tall = 255,
            role = "dropShadow",
        }
        local lamp = { x = 8, y = SIZE / 2, z = 24, radius = 200, r = 1, g = 1, b = 1, intensity = 8 }

        local backend = newBackend()
        local scene, pixels = renderWith(backend, tree, lamp)
        local away = scene:getPixel(pixels, 39, 37)
        local towards = scene:getPixel(pixels, 25, 37)
        local body = scene:getPixel(pixels, SIZE / 2, SIZE / 2)
        backend:destroy()

        tree.role = "opaque"
        local plain = newBackend()
        local plainScene, plainPixels = renderWith(plain, tree, lamp)
        local awayPlain = plainScene:getPixel(plainPixels, 39, 37)
        local towardsPlain = plainScene:getPixel(plainPixels, 25, 37)
        local bodyPlain = plainScene:getPixel(plainPixels, SIZE / 2, SIZE / 2)
        plain:destroy()

        assert.is_true(
            away.r < awayPlain.r - 20,
            ("the ground away from the light must darken: %d against %d"):format(away.r, awayPlain.r)
        )
        assert.is_true(
            math.abs(towards.r - towardsPlain.r) <= 2,
            ("the ground towards the light must not: %d against %d"):format(towards.r, towardsPlain.r)
        )
        assert.is_true(
            math.abs(body.r - bodyPlain.r) <= 2,
            ("the caster must be stamped back out of its own shadow: %d against %d"):format(body.r, bodyPlain.r)
        )
    end)

    it("darkens ambient with a drop shadow, which the occluder mask cannot", function()
        -- The one claim that separates the two features. The lamp is black and
        -- contributes nothing at all to the image, so every lit pixel here is
        -- ambient and nothing else. A shadow that reached only a light's own
        -- contribution would have no output whatsoever in this frame.
        local tree = {
            x = SIZE / 2,
            y = SIZE / 2,
            width = 8,
            height = 8,
            depth = 0.6,
            r = 1,
            g = 1,
            b = 1,
            tall = 255,
            role = "dropShadow",
        }
        local dark = { x = 8, y = SIZE / 2, z = 24, radius = 200, r = 0, g = 0, b = 0, intensity = 1 }

        local backend = newBackend({ ambient = { 1.0, 1.0, 1.0 } })
        local scene, pixels = renderWith(backend, tree, dark)
        local away = scene:getPixel(pixels, 39, 37)
        local towards = scene:getPixel(pixels, 25, 37)
        backend:destroy()

        assert.are.equal(255, towards.r, "a black light leaves ambient as the whole of the image")
        assert.is_true(away.r < 220, ("ambient must be darkened where a drop shadow lands, got %d"):format(away.r))
    end)

    it("renders the same scene as a pipeline with no shadows at all", function()
        -- The gate. A backend built without shadows has no mask, no
        -- drop-shadow target and no pass that writes either, and a caster in
        -- its world draws exactly as an ordinary instance does.
        local wall = {
            x = SIZE / 2,
            y = SIZE / 2,
            width = 8,
            height = 8,
            depth = 0.6,
            r = 0.5,
            g = 0.5,
            b = 0.5,
            tall = 255,
            role = "occluder",
        }

        local off = newBackend({ shadows = false })
        assert.is_nil(off.deferred.graph:texture("occluders"), "an unshadowed pipeline owns no mask")
        local offScene, offPixels = renderWith(off, wall, LAMP)
        local behindOff = offScene:getPixel(offPixels, 48, SIZE / 2)

        local ok = pcall(function()
            off.deferred.graph:depthOf("occluderBlurH")
        end)
        assert.is_false(ok, "an unshadowed pipeline declares no blur pass")
        off:destroy()

        wall.role = "opaque"
        local plain = newBackend({ shadows = false })
        local plainScene, plainPixels = renderWith(plain, wall, LAMP)
        local behindPlain = plainScene:getPixel(plainPixels, 48, SIZE / 2)
        plain:destroy()

        assert.is_true(behindPlain.r > 200, "the floor behind the wall is lit")
        assert.are.equal(behindPlain.r, behindOff.r, "with shadows off a caster casts nothing")
    end)

    it("declares the shadow passes between geometry and lighting", function()
        local backend = newBackend()
        local graph = backend.deferred.graph

        assert.is_not_nil(graph:texture("occluders") == nil or true)
        for _, name in ipairs({ "occluders", "occludersTemp", "dropShadowAO" }) do
            assert.is_truthy(graph:formatOf(name), ("the graph must own a target named %s"):format(name))
        end

        local order = {}
        for index, pass in ipairs(graph._passes) do
            order[pass.name] = index
        end
        assert.is_true(order.geometry < order.occluders, "the mask is built after the geometry it is a silhouette of")
        assert.is_true(order.occluders < order.occluderBlurH)
        assert.is_true(order.occluderBlurH < order.occluderBlurV)
        assert.is_true(order.occluderBlurV < order.lighting, "the resolve reads the mask, so the mask goes first")
        assert.is_true(order.dropShadowAO < order.lighting)
        assert.is_true(order.lighting < order.composite)

        -- One depth attachment at frame size serves every pass that asks for
        -- one, so a pass drawing into a scaled target must not.
        assert.is_nil(graph:depthOf("occluders"))
        assert.is_nil(graph:depthOf("dropShadowAO"))

        backend:destroy()
    end)
end)
