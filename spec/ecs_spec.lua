-- The ECS-to-GPU bridge, asserted on rendered pixels.
--
-- This is the seam where a mistake is least visible: an entity that never
-- reaches the instance buffer, a transform packed in the wrong order, or a
-- world-to-clip conversion with a flipped axis all render something, just not
-- the right thing. So these tests spawn entities at known positions and check
-- what actually lands on screen.

-- Our build first, so it wins over the ECS repo's own engine tree.
package.path = "build/?.lua;build/?/init.lua;"
    .. "../tecs/build/?.lua;../tecs/build/?/init.lua;" .. package.path

local tecs = require("tecs")
local sdl = require("tecs2d.ffi.sdl3")
local Window = require("tecs2d.platform.Window")
local Device = require("tecs2d.gpu.Device")
local Texture = require("tecs2d.gpu.Texture")
local Renderer = require("tecs2d.ecs.Renderer")
local assets = require("tecs2d.assets")
local components = require("tecs2d.ecs.components")

local C = sdl.C
local FORMAT = 4  -- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local SIZE = 64

local Transform2D = components.Transform2D
local Tint = components.Tint
local PointLight = components.PointLight
local Renderable = components.Renderable
local Sprite = components.Sprite

-- Four by four: the left half red, the right half green.
local FIXTURE = "spec/fixtures/split.png"

describe("ecs.Renderer", function()
    local window, device, screen

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = Window.create({ title = "ecs", width = SIZE, height = SIZE })
        device = Device.create(window, { debug = true })
        screen = Texture.create(device.handle,
            { width = SIZE, height = SIZE, format = FORMAT })
        assets.install(device.handle)
    end)

    teardown(function()
        assets.shutdown()
        if screen then screen:destroy() end
        if device then device:destroy() end
        if window then window:destroy() end
        C.SDL_Quit()
    end)

    -- Builds a world with a renderer installed. Ambient is full white by
    -- default so transport can be tested without lighting in the way.
    local function newScene(ambient)
        local world = tecs.newWorld()
        local renderer = Renderer.create(device.handle, FORMAT, {
            ambient = ambient or { 1.0, 1.0, 1.0 },
            capacity = 256,
        })
        renderer:install(world)
        return world, renderer
    end

    local function frameOnce(world, renderer)
        world:update(1 / 60)
        local commandBuffer = C.SDL_AcquireGPUCommandBuffer(device.handle)
        renderer:render({
            width = SIZE,
            height = SIZE,
            commandBuffer = commandBuffer,
            swapchainTexture = screen.handle,
        })
        assert(C.SDL_SubmitGPUCommandBuffer(commandBuffer))
        return screen:readback()
    end

    it("draws nothing when the world is empty", function()
        local world, renderer = newScene()
        local pixels = frameOnce(world, renderer)
        local centre = screen:getPixel(pixels, SIZE / 2, SIZE / 2)

        assert.are.equal(0, renderer.count)
        assert.are.equal(0, centre.r)
        renderer:destroy()
    end)

    it("renders a spawned entity at its transform position", function()
        local world, renderer = newScene()
        -- Covers the whole target, so any position error shows as a miss.
        world:spawn(
            Transform2D(SIZE / 2, SIZE / 2, 0, SIZE * 2, SIZE * 2),
            Tint(1.0, 0.0, 0.0, 1.0),
            Renderable()
        )

        local pixels = frameOnce(world, renderer)
        local centre = screen:getPixel(pixels, SIZE / 2, SIZE / 2)

        assert.are.equal(1, renderer.count)
        assert.are.equal(255, centre.r, "the entity's tint should reach the screen")
        assert.are.equal(0, centre.g)
        renderer:destroy()
    end)

    it("places an entity on the side its transform names", function()
        -- World units are pixels with the origin at the top left. A quad in
        -- the left half must land in the left half of the readback, which is
        -- what pins the world-to-clip conversion including its Y flip.
        local world, renderer = newScene()
        world:spawn(
            Transform2D(SIZE * 0.25, SIZE * 0.25, 0, SIZE * 0.3, SIZE * 0.3),
            Tint(0.0, 1.0, 0.0, 1.0),
            Renderable()
        )

        local pixels = frameOnce(world, renderer)
        local topLeft = screen:getPixel(pixels, SIZE / 4, SIZE / 4)
        local bottomRight = screen:getPixel(pixels, SIZE * 3 / 4, SIZE * 3 / 4)

        assert.are.equal(255, topLeft.g, "the quad belongs at its transform")
        assert.are.equal(0, bottomRight.g, "and nowhere else")
        renderer:destroy()
    end)

    it("ignores entities without Renderable", function()
        local world, renderer = newScene()
        world:spawn(
            Transform2D(SIZE / 2, SIZE / 2, 0, SIZE * 2, SIZE * 2),
            Tint(1.0, 0.0, 0.0, 1.0)
        )

        frameOnce(world, renderer)
        assert.are.equal(0, renderer.count,
            "a transform alone is a position, not geometry")
        renderer:destroy()
    end)

    it("tracks entities spawned after the first frame", function()
        local world, renderer = newScene()
        frameOnce(world, renderer)
        assert.are.equal(0, renderer.count)

        world:spawn(
            Transform2D(SIZE / 2, SIZE / 2, 0, SIZE * 2, SIZE * 2),
            Tint(0.0, 0.0, 1.0, 1.0),
            Renderable()
        )

        local pixels = frameOnce(world, renderer)
        assert.are.equal(1, renderer.count)
        assert.are.equal(255,
            screen:getPixel(pixels, SIZE / 2, SIZE / 2).b)
        renderer:destroy()
    end)

    it("lights the scene from light entities", function()
        local world, renderer = newScene({ 0.0, 0.0, 0.0 })
        world:spawn(
            Transform2D(SIZE / 2, SIZE / 2, 0, SIZE * 2, SIZE * 2),
            Tint(1.0, 1.0, 1.0, 1.0),
            Renderable()
        )

        local dark = frameOnce(world, renderer)
        assert.are.equal(0, screen:getPixel(dark, SIZE / 2, SIZE / 2).r,
            "no ambient and no lights must be black")

        world:spawn(
            Transform2D(SIZE / 2, SIZE / 2, 0, 1, 1),
            PointLight(12.0, 30.0, 1.0, 1.0, 1.0, 4.0)
        )

        local pixels = frameOnce(world, renderer)
        local centre = screen:getPixel(pixels, SIZE / 2, SIZE / 2)
        local corner = screen:getPixel(pixels, 2, 2)

        assert.is_true(centre.r > 180,
            ("under the light should be bright, got %d"):format(centre.r))
        assert.is_true(corner.r < 60,
            ("beyond the radius should stay dark, got %d"):format(corner.r))
        renderer:destroy()
    end)

    it("moves geometry when a system writes the transform", function()
        local world, renderer = newScene()
        world:spawn(
            Transform2D(SIZE * 0.25, SIZE / 2, 0, SIZE * 0.3, SIZE * 0.3),
            Tint(1.0, 1.0, 0.0, 1.0),
            Renderable()
        )

        local moving = world:query({ include = { Transform2D, Renderable } })
        world:addSystem({
            name = "spec.Move",
            phase = tecs.phases.Update,
            run = function()
                for archetype, length in moving:iter() do
                    local transforms = archetype:getMut(Transform2D)
                    for row = 1, length do
                        transforms[row].x = SIZE * 0.75
                    end
                end
            end,
        })

        local pixels = frameOnce(world, renderer)
        local left = screen:getPixel(pixels, SIZE / 4, SIZE / 2)
        local right = screen:getPixel(pixels, SIZE * 3 / 4, SIZE / 2)

        assert.are.equal(0, left.r, "the system moved it off the left")
        assert.are.equal(255, right.r, "and onto the right")
        renderer:destroy()
    end)

    it("samples a registered texture through a Sprite", function()
        local world, renderer = newScene()
        local handle = assets.loadImage(FIXTURE)
        assets.waitAll()
        assert.are.equal("ready", handle.status)

        local slot = renderer:registerTexture(handle.texture)
        world:spawn(
            Transform2D(SIZE / 2, SIZE / 2, 0, SIZE * 2, SIZE * 2),
            Tint(1.0, 1.0, 1.0, 1.0),
            Sprite(slot, 0.0, 0.0, 1.0, 1.0),
            Renderable()
        )

        local pixels = frameOnce(world, renderer)
        -- The fixture is red on the left and green on the right, so a quad
        -- covering the target reproduces that split on screen.
        local left = screen:getPixel(pixels, SIZE / 4, SIZE / 2)
        local right = screen:getPixel(pixels, SIZE * 3 / 4, SIZE / 2)

        assert.are.equal(255, left.r, "the sprite's left half is red")
        assert.are.equal(0, left.g)
        assert.are.equal(255, right.g, "and its right half is green")
        assert.are.equal(0, right.r)
        renderer:destroy()
    end)

    it("selects a region with the UV rect", function()
        -- Sampling only the right half must make the whole quad green, which
        -- is what makes an atlas the same thing as a whole image.
        local world, renderer = newScene()
        local handle = assets.loadImage(FIXTURE)
        assets.waitAll()

        local slot = renderer:registerTexture(handle.texture)
        world:spawn(
            Transform2D(SIZE / 2, SIZE / 2, 0, SIZE * 2, SIZE * 2),
            Tint(1.0, 1.0, 1.0, 1.0),
            Sprite(slot, 0.55, 0.0, 1.0, 1.0),
            Renderable()
        )

        local pixels = frameOnce(world, renderer)
        local left = screen:getPixel(pixels, SIZE / 4, SIZE / 2)
        local right = screen:getPixel(pixels, SIZE * 3 / 4, SIZE / 2)

        assert.are.equal(255, left.g, "the whole quad samples the green half")
        assert.are.equal(255, right.g)
        assert.are.equal(0, left.r)
        renderer:destroy()
    end)

    it("tints a sampled texture", function()
        local world, renderer = newScene()
        local handle = assets.loadImage(FIXTURE)
        assets.waitAll()

        local slot = renderer:registerTexture(handle.texture)
        world:spawn(
            Transform2D(SIZE / 2, SIZE / 2, 0, SIZE * 2, SIZE * 2),
            -- Half brightness, so the red half reads as half red.
            Tint(0.5, 0.5, 0.5, 1.0),
            Sprite(slot, 0.0, 0.4, 0.45, 0.6),
            Renderable()
        )

        local centre = screen:getPixel(frameOnce(world, renderer), SIZE / 2, SIZE / 2)
        assert.is_true(math.abs(centre.r - 128) <= 2,
            ("expected the tint to halve red, got %d"):format(centre.r))
        renderer:destroy()
    end)

    it("batches by texture and still places each correctly", function()
        -- Two textures means two draws. The counting sort puts each slot's
        -- rows in one run, so a batch that read the wrong range would put the
        -- wrong image on the wrong quad.
        local world, renderer = newScene()
        local handle = assets.loadImage(FIXTURE)
        assets.waitAll()
        local slot = renderer:registerTexture(handle.texture)

        -- Left quad untextured (slot 0, white default) tinted blue.
        world:spawn(
            Transform2D(SIZE * 0.25, SIZE / 2, 0, SIZE * 0.4, SIZE * 0.4),
            Tint(0.0, 0.0, 1.0, 1.0),
            Renderable()
        )
        -- Right quad sampling the green half of the fixture.
        world:spawn(
            Transform2D(SIZE * 0.75, SIZE / 2, 0, SIZE * 0.4, SIZE * 0.4),
            Tint(1.0, 1.0, 1.0, 1.0),
            Sprite(slot, 0.55, 0.0, 1.0, 1.0),
            Renderable()
        )

        local pixels = frameOnce(world, renderer)
        assert.are.equal(2, renderer.count)
        assert.are.equal(2, renderer.batches, "two textures means two draws")

        local left = screen:getPixel(pixels, SIZE * 0.25, SIZE / 2)
        local right = screen:getPixel(pixels, SIZE * 0.75, SIZE / 2)

        assert.are.equal(255, left.b, "the untextured quad stays blue")
        assert.are.equal(0, left.g)
        assert.are.equal(255, right.g, "the sprite quad samples green")
        assert.are.equal(0, right.b)
        renderer:destroy()
    end)

    it("drops rows past capacity rather than overrunning the buffer", function()
        local world = tecs.newWorld()
        local renderer = Renderer.create(device.handle, FORMAT,
            { ambient = { 1, 1, 1 }, capacity = 4 })
        renderer:install(world)

        for _ = 1, 10 do
            world:spawn(Transform2D(0, 0, 0, 1, 1), Tint(1, 1, 1, 1), Renderable())
        end

        frameOnce(world, renderer)
        assert.are.equal(4, renderer.count)
        assert.are.equal(6, renderer.dropped)
        renderer:destroy()
    end)
end)
