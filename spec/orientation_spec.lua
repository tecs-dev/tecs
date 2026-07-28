-- Which way up a sampled image lands, asserted on rendered pixels.
--
-- Vertical orientation is the one thing a fixture split left and right cannot
-- test, and it is the axis that goes wrong: world Y runs down the screen, the
-- camera negates it on the way to clip space, and a second flip anywhere
-- between the instance's UV rect and the sampler composes with that one
-- instead of canceling it. The result still draws the image, in the right
-- place, at the right size, mirrored. So the image here is split top and
-- bottom as well as left and right, and every quadrant is checked.

-- Our build first, so it wins over the ECS repo's own engine tree.
-- The build directory is the build system's to choose, so it is passed in.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local sdl = require("tecs.ffi.sdl3")
local loader = require("tecs.ffi.loader")
local newWindow = require("tecs.platform.window").newWindow
local Device = require("tecs.gpu.Device")
local Texture = require("tecs.gpu.Texture")
local Renderer = require("tecs.Renderer")
local assets = require("tecs.assets")
local components = require("tecs.components")
local ecs = require("tecs.ecs")

local C = sdl.C
local FORMAT = 4 -- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local SIZE = 64

local Transform = tecs.Transform
local Tint = components.Tint
local Renderable = components.Renderable

describe("a sampled image", function()
    local window, device, screen

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = newWindow({ title = "orientation", width = SIZE, height = SIZE })
        device = Device.create(window, { debug = true })
        screen = Texture.create(device.handle, { width = SIZE, height = SIZE, format = FORMAT })
        assets.install()
    end)

    teardown(function()
        assets.shutdown()
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

    local function newScene()
        local world = tecs.ecs.newWorld()
        local renderer = Renderer.newRenderer(device.handle, FORMAT, {
            ambient = { 1.0, 1.0, 1.0 },
            capacity = 64,
        })
        renderer:install(world)
        return world, renderer
    end

    -- Two texels by two, one color each, in the shape registerImage consumes.
    -- Rows arrive top first, which is what every decoder this reads from
    -- produces and what the region's v0 therefore names.
    local function quadrants(name)
        local pixels = loader.newArray("uint8_t[16]")
        local colors = {
            { 255, 0, 0 }, -- top left, red
            { 0, 255, 0 }, -- top right, green
            { 0, 0, 255 }, -- bottom left, blue
            { 255, 255, 0 }, -- bottom right, yellow
        }
        for index = 0, 3 do
            local color = colors[index + 1]
            pixels[index * 4] = color[1]
            pixels[index * 4 + 1] = color[2]
            pixels[index * 4 + 2] = color[3]
            pixels[index * 4 + 3] = 255
        end
        return {
            status = "ready",
            path = name,
            pixels = pixels,
            width = 2,
            height = 2,
            pitch = 8,
            release = function() end,
        }
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

    -- A quad the size of the target, so the image maps onto it one to one and
    -- a readback quadrant is an image quadrant.
    local function covering()
        return Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE, SIZE)
    end

    it("puts each of the image's quadrants on the matching quarter of the screen", function()
        local world, renderer = newScene()
        local sprite = renderer:registerImage(quadrants("spec://quadrants"))
        world:spawn(covering(), Tint(1.0, 1.0, 1.0, 1.0), sprite, Renderable())

        local pixels = frameOnce(world, renderer)
        local topLeft = screen:getPixel(pixels, SIZE / 4, SIZE / 4)
        local topRight = screen:getPixel(pixels, SIZE * 3 / 4, SIZE / 4)
        local bottomLeft = screen:getPixel(pixels, SIZE / 4, SIZE * 3 / 4)
        local bottomRight = screen:getPixel(pixels, SIZE * 3 / 4, SIZE * 3 / 4)

        -- Readback row zero is the top of the image, so the image's first row
        -- belongs at low row indices. Naming the color each corner would
        -- carry under a flip is what makes a failure readable.
        assert.are.equal(255, topLeft.r, "the image's first row is red on the left, and belongs at the top")
        assert.are.equal(0, topLeft.b, "blue at the top left is the image drawn upside down")
        assert.are.equal(255, topRight.g, "and green on the right")
        assert.are.equal(0, topRight.r, "yellow at the top right is the image drawn upside down")
        assert.are.equal(255, bottomLeft.b, "the image's last row is blue on the left, and belongs at the bottom")
        assert.are.equal(255, bottomRight.r, "and yellow on the right")
        assert.are.equal(255, bottomRight.g)
        assert.are.equal(0, bottomRight.b)
        renderer:destroy()
    end)

    it("measures a V range from the top of the image", function()
        -- A sub-rect names texels rather than screen edges, so the two ranges
        -- here have to pick different rows. Which end of a range reaches which
        -- end of the quad is the test above; this is the complement, and it is
        -- what a fix applied on the extraction side rather than in the shader
        -- would break.
        local world, renderer = newScene()
        renderer:registerImage(quadrants("spec://vrange"))
        world:spawn(
            covering(),
            Tint(1.0, 1.0, 1.0, 1.0),
            renderer:sprite("spec://vrange", 0.0, 0.0, 1.0, 0.45),
            Renderable()
        )

        local upper = screen:getPixel(frameOnce(world, renderer), SIZE / 4, SIZE / 2)
        assert.are.equal(255, upper.r, "the image's first row is red on the left")
        assert.are.equal(0, upper.b, "and a range ending short of halfway never reaches the blue below it")

        local second, secondRenderer = newScene()
        secondRenderer:registerImage(quadrants("spec://vrange"))
        second:spawn(
            covering(),
            Tint(1.0, 1.0, 1.0, 1.0),
            secondRenderer:sprite("spec://vrange", 0.0, 0.55, 1.0, 1.0),
            Renderable()
        )

        local lower = screen:getPixel(frameOnce(second, secondRenderer), SIZE / 4, SIZE / 2)
        assert.are.equal(255, lower.b, "the image's last row is blue on the left")
        assert.are.equal(0, lower.r, "and a range starting past halfway never reaches the red above it")

        secondRenderer:destroy()
        renderer:destroy()
    end)
end)
