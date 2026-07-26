-- The ECS-to-GPU bridge, asserted on rendered pixels.
--
-- This is the seam where a mistake is least visible: an entity that never
-- reaches the instance buffer, a transform packed in the wrong order, or a
-- world-to-clip conversion with a flipped axis all render something, just not
-- the right thing. So these tests spawn entities at known positions and check
-- what actually lands on screen.

-- Our build first, so it wins over the ECS repo's own engine tree.
-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. package.path

local tecs = require("tecs")
local sdl = require("tecs.ffi.sdl3")
local loader = require("tecs.ffi.loader")
local Window = require("tecs.platform.Window")
local Device = require("tecs.gpu.Device")
local Texture = require("tecs.gpu.Texture")
local Renderer = require("tecs.Renderer")
local assets = require("tecs.assets")
local components = require("tecs.components")
local materials = require("tecs.gpu.materials")
local Camera = require("tecs.gfx.Camera")

local C = sdl.C
local FORMAT = 4  -- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local SIZE = 64

local Transform = components.Transform
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
        assets.install()
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
    local function newScene(ambient, capacity)
        local world = tecs.newWorld()
        local renderer = Renderer.create(device.handle, FORMAT, {
            ambient = ambient or { 1.0, 1.0, 1.0 },
            capacity = capacity or 256,
        })
        renderer:install(world)
        return world, renderer
    end

    -- A decoded image of one solid colour, in the shape registerImage
    -- consumes. Telling a name apart from a layer takes two images whose
    -- difference reaches the screen, and building them here keeps that
    -- difference in the test rather than in a fixture file.
    local function solid(name, r, g, b)
        local pixels = loader.newArray("uint8_t[4]")
        pixels[0], pixels[1], pixels[2], pixels[3] = r, g, b, 255
        return {
            status = "ready",
            path = name,
            pixels = pixels,
            width = 1,
            height = 1,
            pitch = 4,
            release = function() end,
        }
    end

    local function readyFixture()
        local handle = assets.loadImage(FIXTURE)
        assets.waitAll()
        return handle
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
            Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2),
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
            Transform(SIZE * 0.25, SIZE * 0.25, 0, 1, 0, SIZE * 0.3, SIZE * 0.3),
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
            Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2),
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
            Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2),
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
            Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2),
            Tint(1.0, 1.0, 1.0, 1.0),
            Renderable()
        )

        local dark = frameOnce(world, renderer)
        assert.are.equal(0, screen:getPixel(dark, SIZE / 2, SIZE / 2).r,
            "no ambient and no lights must be black")

        world:spawn(
            Transform(SIZE / 2, SIZE / 2, 0, 1, 0, 1, 1),
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
            Transform(SIZE * 0.25, SIZE / 2, 0, 1, 0, SIZE * 0.3, SIZE * 0.3),
            Tint(1.0, 1.0, 0.0, 1.0),
            Renderable()
        )

        local moving = world:query({ include = { Transform, Renderable } })
        world:addSystem({
            name = "spec.Move",
            phase = tecs.phases.Update,
            run = function()
                for archetype, length in moving:iter() do
                    local transforms = archetype:getMut(Transform)
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

        -- registerImage returns a ready Sprite: an image smaller than a cell
        -- does not reach the cell's edge, so the UV range is not 0..1.
        local sprite = renderer:registerImage(handle)
        world:spawn(
            Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2),
            Tint(1.0, 1.0, 1.0, 1.0),
            sprite,
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
        renderer:registerImage(readyFixture())
        -- Sample only the right half of the image.
        world:spawn(
            Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2),
            Tint(1.0, 1.0, 1.0, 1.0),
            renderer:sprite(FIXTURE, 0.55, 0.0, 1.0, 1.0),
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
        renderer:registerImage(readyFixture())
        world:spawn(
            Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2),
            -- Half brightness, so the red half reads as half red.
            Tint(0.5, 0.5, 0.5, 1.0),
            renderer:sprite(FIXTURE, 0.0, 0.0, 0.45, 1.0),
            Renderable()
        )

        local centre = screen:getPixel(frameOnce(world, renderer), SIZE / 2, SIZE / 2)
        assert.is_true(math.abs(centre.r - 128) <= 2,
            ("expected the tint to halve red, got %d"):format(centre.r))
        renderer:destroy()
    end)

    it("mixes textured and untextured geometry in one draw", function()
        -- Both quads go through one draw because the texture is a layer
        -- index, so a wrong layer would put the wrong image on a quad.
        local world, renderer = newScene()
        renderer:registerImage(readyFixture())

        -- Left quad untextured (layer 0, white default) tinted blue.
        world:spawn(
            Transform(SIZE * 0.25, SIZE / 2, 0, 1, 0, SIZE * 0.4, SIZE * 0.4),
            Tint(0.0, 0.0, 1.0, 1.0),
            Renderable()
        )
        -- Right quad sampling the green half of the fixture.
        world:spawn(
            Transform(SIZE * 0.75, SIZE / 2, 0, 1, 0, SIZE * 0.4, SIZE * 0.4),
            Tint(1.0, 1.0, 1.0, 1.0),
            renderer:sprite(FIXTURE, 0.55, 0.0, 1.0, 1.0),
            Renderable()
        )

        local pixels = frameOnce(world, renderer)
        assert.are.equal(2, renderer.count)

        local left = screen:getPixel(pixels, SIZE * 0.25, SIZE / 2)
        local right = screen:getPixel(pixels, SIZE * 0.75, SIZE / 2)

        assert.are.equal(255, left.b, "the untextured quad stays blue")
        assert.are.equal(0, left.g)
        assert.are.equal(255, right.g, "the sprite quad samples green")
        assert.are.equal(0, right.b)
        renderer:destroy()
    end)


    -- A Sprite names its image and the renderer decides which layer that name
    -- occupies. These pin the two halves of that: a name is one layer however
    -- often it is asked for, and a name outlives the layer numbering of the run
    -- that saved it.
    it("hands a name one layer however often it is registered", function()
        local world, renderer = newScene()
        local first = renderer:registerImage(readyFixture())
        local layers = renderer.images.used
        local second = renderer:registerImage(readyFixture())

        assert.are.equal(first.image, second.image, "one name, one image")
        assert.are.equal(first.slot, second.slot)
        assert.are.equal(layers, renderer.images.used,
            "registering a name again must not consume another layer")

        -- And it still draws: the second registration answers with the layer
        -- the first one uploaded into, not with an empty one.
        world:spawn(
            Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2),
            Tint(1.0, 1.0, 1.0, 1.0),
            second,
            Renderable()
        )
        local pixels = frameOnce(world, renderer)
        assert.are.equal(255, screen:getPixel(pixels, SIZE / 4, SIZE / 2).r)
        assert.are.equal(255, screen:getPixel(pixels, SIZE * 3 / 4, SIZE / 2).g)
        renderer:destroy()
    end)

    it("resolves a restored sprite by its image's name", function()
        -- The two renderers register the same two images in opposite orders,
        -- so red and green swap layers between them. A snapshot that carried a
        -- layer would come back as the other image; one that carries the name
        -- comes back as itself.
        local world, first = newScene()
        first:registerImage(solid("spec://red", 255, 0, 0))
        first:registerImage(solid("spec://green", 0, 255, 0))
        local green = first:sprite("spec://green")
        world:spawn(
            Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2),
            Tint(1.0, 1.0, 1.0, 1.0),
            green,
            Renderable()
        )
        assert.are.equal(255,
            screen:getPixel(frameOnce(world, first), SIZE / 2, SIZE / 2).g,
            "green before the round trip")
        local savedSlot = green.slot
        local saved = world:saveSnapshot({}).buffer
        first:destroy()

        local restored, second = newScene()
        second:registerImage(solid("spec://green", 0, 255, 0))
        second:registerImage(solid("spec://red", 255, 0, 0))
        assert.are_not.equal(savedSlot, second:sprite("spec://green").slot,
            "the point of the test is that the layer moved")

        restored:loadSnapshot(saved)
        local centre = screen:getPixel(frameOnce(restored, second),
            SIZE / 2, SIZE / 2)
        assert.are.equal(255, centre.g, "and green after it")
        assert.are.equal(0, centre.r)
        second:destroy()
    end)

    it("fails on a sprite whose image is not registered", function()
        local world, renderer = newScene()

        local ok, reason = pcall(function() renderer:sprite("spec://missing") end)
        assert.is_false(ok, "asking for an unregistered name must not answer")
        assert.is_truthy(tostring(reason):find("spec://missing", 1, true),
            "the error should name the image that is missing")

        -- And the same is true of a Sprite that reaches extraction unresolved,
        -- which is how one restored from a snapshot arrives. Drawing it against
        -- whatever layer happens to hold that number is the failure a name
        -- exists to prevent.
        world:spawn(
            Transform(SIZE / 2, SIZE / 2, 0, 1, 0, 4, 4),
            Tint(1.0, 1.0, 1.0, 1.0),
            Sprite(components.imageId("spec://missing"), 0.0, 0.0, 1.0, 1.0),
            Renderable()
        )
        local drawn, failure = pcall(frameOnce, world, renderer)
        assert.is_false(drawn)
        assert.is_truthy(tostring(failure):find("spec://missing", 1, true))
        renderer:destroy()
    end)

    it("rewrites nothing on a frame where nothing changed", function()
        -- This is the whole point of the layout being archetype-contiguous.
        -- Walking every entity every frame is the cost that decides whether a
        -- large world is affordable, and most frames change very little.
        local world, renderer = newScene()
        for _ = 1, 8 do
            world:spawn(
                Transform(SIZE / 2, SIZE / 2, 0, 1, 0, 4, 4),
                Tint(1, 1, 1, 1),
                Renderable()
            )
        end

        frameOnce(world, renderer)
        assert.are.equal(8, renderer.count)
        assert.are.equal(8, renderer.rewritten, "the first frame writes everything")

        frameOnce(world, renderer)
        assert.are.equal(8, renderer.count, "the instances are still resident")
        assert.are.equal(0, renderer.rewritten,
            "a still frame must not touch the buffer")
        renderer:destroy()
    end)

    it("rewrites only when a component is actually written", function()
        local world, renderer = newScene()
        world:spawn(Transform(SIZE / 2, SIZE / 2, 0, 1, 0, 4, 4), Tint(1, 1, 1, 1),
            Renderable())

        frameOnce(world, renderer)
        frameOnce(world, renderer)
        assert.are.equal(0, renderer.rewritten)

        -- getMut is what marks the column dirty, so a system that writes is
        -- what wakes the sync back up.
        local moving = world:query({ include = { Transform, Renderable } })
        world:addSystem({
            name = "spec.Nudge",
            phase = tecs.phases.Update,
            run = function()
                for archetype, length in moving:iter() do
                    local transforms = archetype:getMut(Transform)
                    for row = 1, length do
                        transforms[row].x = transforms[row].x + 1
                    end
                end
            end,
        })

        frameOnce(world, renderer)
        assert.are.equal(1, renderer.rewritten,
            "writing a transform must re-sync its archetype")
        renderer:destroy()
    end)

    it("re-lays out when an entity is spawned", function()
        local world, renderer = newScene()
        world:spawn(Transform(0, 0, 0, 1, 0, 4, 4), Tint(1, 1, 1, 1), Renderable())
        frameOnce(world, renderer)
        frameOnce(world, renderer)
        assert.are.equal(0, renderer.rewritten)

        world:spawn(Transform(8, 8, 0, 1, 0, 4, 4), Tint(1, 1, 1, 1), Renderable())
        frameOnce(world, renderer)
        assert.are.equal(2, renderer.count)
        assert.are.equal(2, renderer.rewritten,
            "a changed length moves runs, so the layout is rebuilt")
        renderer:destroy()
    end)

    it("culls geometry outside the view", function()
        -- Nothing here tells the CPU what survived: the compute pass writes
        -- the instance count into the draw arguments. So the check is what
        -- reaches the screen, not a number this side could have got wrong.
        local world, renderer = newScene()

        -- Well off the right edge, and large enough that a failed cull would
        -- be unmistakable if it were drawn at the origin instead.
        world:spawn(
            Transform(SIZE * 8, SIZE / 2, 0, 1, 0, SIZE, SIZE),
            Tint(1.0, 0.0, 0.0, 1.0),
            Renderable()
        )

        local pixels = frameOnce(world, renderer)
        assert.are.equal(1, renderer.count, "it is still a resident instance")
        assert.are.equal(0, screen:getPixel(pixels, SIZE / 2, SIZE / 2).r,
            "but nothing offscreen should reach the target")
        renderer:destroy()
    end)

    it("keeps geometry that straddles the edge", function()
        -- A quad half outside must still draw. Culling on centre alone would
        -- pop things out at the border, which reads as flicker rather than as
        -- a culling bug.
        local world, renderer = newScene()
        world:spawn(
            Transform(0, SIZE / 2, 0, 1, 0, SIZE * 0.8, SIZE * 0.8),
            Tint(0.0, 1.0, 0.0, 1.0),
            Renderable()
        )

        local pixels = frameOnce(world, renderer)
        assert.are.equal(255, screen:getPixel(pixels, 2, SIZE / 2).g,
            "the visible part of a straddling quad must survive the cull")
        renderer:destroy()
    end)

    it("draws only the survivors when the view is crowded", function()
        local world, renderer = newScene()
        -- One on screen, three far outside in different directions.
        world:spawn(Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE, SIZE),
            Tint(0.0, 0.0, 1.0, 1.0), Renderable())
        world:spawn(Transform(-SIZE * 8, SIZE / 2, 0, 1, 0, 4, 4),
            Tint(1, 1, 1, 1), Renderable())
        world:spawn(Transform(SIZE / 2, -SIZE * 8, 0, 1, 0, 4, 4),
            Tint(1, 1, 1, 1), Renderable())
        world:spawn(Transform(SIZE / 2, SIZE * 8, 0, 1, 0, 4, 4),
            Tint(1, 1, 1, 1), Renderable())

        local pixels = frameOnce(world, renderer)
        assert.are.equal(4, renderer.count, "all four are resident")
        assert.are.equal(255, screen:getPixel(pixels, SIZE / 2, SIZE / 2).b,
            "the one in view draws")
        renderer:destroy()
    end)

    it("drops rows past capacity rather than overrunning the buffer", function()
        local world = tecs.newWorld()
        local renderer = Renderer.create(device.handle, FORMAT,
            { ambient = { 1, 1, 1 }, capacity = 4 })
        renderer:install(world)

        for _ = 1, 10 do
            world:spawn(Transform(0, 0, 0, 1, 0, 1, 1), Tint(1, 1, 1, 1), Renderable())
        end

        frameOnce(world, renderer)
        assert.are.equal(4, renderer.count)
        assert.are.equal(6, renderer.dropped)
        renderer:destroy()
    end)

    -- Shapes are a fragment-side material on the same quad, same instance
    -- format, same batch. What must be true is that the silhouette is the
    -- shape and not the quad, which only a corner sample can tell you.
    it("renders a circle as a circle, not as its quad", function()
        local world, renderer = newScene()
        world:spawn(
            Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE, SIZE),
            Tint(1.0, 0.0, 0.0, 1.0),
            components.Material(materials.id("circle"), 0),
            Renderable()
        )

        local pixels = frameOnce(world, renderer)
        local centre = screen:getPixel(pixels, SIZE / 2, SIZE / 2)
        local corner = screen:getPixel(pixels, 2, 2)

        assert.are.equal(255, centre.r, "the middle of the circle is filled")
        assert.are.equal(0, corner.r,
            "the quad's corner falls outside the circle and must be rejected")
        renderer:destroy()
    end)

    it("keeps a quad square when no Material is present", function()
        -- The default path must be untouched: absence of Material means the
        -- default material, which covers the whole quad, corners included.
        local world, renderer = newScene()
        world:spawn(
            Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE, SIZE),
            Tint(0.0, 1.0, 0.0, 1.0),
            Renderable()
        )

        local pixels = frameOnce(world, renderer)
        local corner = screen:getPixel(pixels, 2, 2)
        assert.are.equal(255, corner.g, "a quad covers its own corners")
        renderer:destroy()
    end)

    it("rounds a rectangle's corners by its radius", function()
        local world, renderer = newScene()
        world:spawn(
            Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE, SIZE),
            Tint(0.0, 0.0, 1.0, 1.0),
            -- Radius is a ratio of the quad, so half of it is a circle.
            components.Material(materials.id("rounded"), 0.5),
            Renderable()
        )

        local pixels = frameOnce(world, renderer)
        assert.are.equal(255, screen:getPixel(pixels, SIZE / 2, SIZE / 2).b)
        assert.are.equal(0, screen:getPixel(pixels, 2, 2).b,
            "a fully rounded rectangle rejects its corners like a circle")
        renderer:destroy()
    end)


    -- The compaction has to be ordered, not merely correct. An atomic append
    -- produces a different list every frame, so overlapping geometry swaps
    -- which one wins and a dense scene shimmers. These pin the guarantee that
    -- replaced it: survivors keep their index order, so the highest index
    -- draws last and is what you see.
    it("draws overlapping entities in index order", function()
        local COUNT = 700   -- more than two 256-wide cull workgroups
        local world, renderer = newScene(nil, COUNT + 16)
        for index = 1, COUNT do
            -- Every entity covers the target. The last one spawned is blue and
            -- must win; every earlier one is red.
            local last = index == COUNT
            world:spawn(
                Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2),
                Tint(last and 0.0 or 1.0, 0.0, last and 1.0 or 0.0, 1.0),
                Renderable()
            )
        end

        local centre = screen:getPixel(frameOnce(world, renderer),
            SIZE / 2, SIZE / 2)
        assert.are.equal(255, centre.b,
            "the highest-index entity must be the one on top")
        assert.are.equal(0, centre.r)
        renderer:destroy()
    end)

    -- Depth rides in the fourth float of an instance's transform vector, which
    -- nothing on the host writes yet. So these two quads are spawned
    -- identically and then have their depth and their colour written straight
    -- into the instance buffer, which is exactly the memory the vertex shader
    -- reads. Instance one draws after instance zero, so without a depth
    -- attachment it wins every time and neither assertion below can hold.
    local INSTANCE_FLOATS = 16

    local function drawAtDepths(firstDepth, secondDepth)
        local world, renderer = newScene()
        for _ = 1, 2 do
            world:spawn(
                Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2),
                Tint(1.0, 1.0, 1.0, 1.0),
                Renderable()
            )
        end

        world:update(1 / 60)
        assert.are.equal(2, renderer.count)

        -- Instance zero is red and instance one is blue, so which one survived
        -- the depth test is legible in the pixel rather than inferred.
        local floats = renderer.instances:mapAs("float *")
        floats[3] = firstDepth
        floats[8], floats[9], floats[10] = 1.0, 0.0, 0.0
        floats[INSTANCE_FLOATS + 3] = secondDepth
        floats[INSTANCE_FLOATS + 8] = 0.0
        floats[INSTANCE_FLOATS + 9] = 0.0
        floats[INSTANCE_FLOATS + 10] = 1.0
        renderer.instances:markDirty(0, 2 * INSTANCE_FLOATS * 4)

        local commandBuffer = C.SDL_AcquireGPUCommandBuffer(device.handle)
        renderer:render({
            width = SIZE,
            height = SIZE,
            commandBuffer = commandBuffer,
            swapchainTexture = screen.handle,
        })
        assert(C.SDL_SubmitGPUCommandBuffer(commandBuffer))

        local centre = screen:getPixel(screen:readback(), SIZE / 2, SIZE / 2)
        renderer:destroy()
        return centre
    end

    it("lets the nearer instance win regardless of draw order", function()
        local firstNearer = drawAtDepths(0.25, 0.75)
        assert.are.equal(255, firstNearer.r,
            "the nearer instance must win even though the other drew after it")
        assert.are.equal(0, firstNearer.b)

        local secondNearer = drawAtDepths(0.75, 0.25)
        assert.are.equal(255, secondNearer.b,
            "and must still win when it is the one that drew last")
        assert.are.equal(0, secondNearer.r)
    end)

    it("keeps draw order deciding between instances at the same depth", function()
        -- Every instance is at depth zero today, so the depth attachment has to
        -- land without changing what is seen. Equal depths let the later
        -- fragment through, which is what makes that true.
        local tie = drawAtDepths(0.5, 0.5)
        assert.are.equal(255, tie.b, "the later instance wins a tie")
        assert.are.equal(0, tie.r)
    end)

    it("draws the same scene the same way every frame", function()
        local COUNT = 700
        local world, renderer = newScene(nil, COUNT + 16)
        for index = 1, COUNT do
            world:spawn(
                Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2),
                Tint(index / COUNT, 1.0 - index / COUNT, 0.5, 1.0),
                Renderable()
            )
        end

        -- Nothing changes between frames, so nothing about the output may
        -- either. An unordered compaction fails this intermittently.
        local first = screen:getPixel(frameOnce(world, renderer), 8, 8)
        for _ = 1, 4 do
            local again = screen:getPixel(frameOnce(world, renderer), 8, 8)
            assert.are.equal(first.r, again.r)
            assert.are.equal(first.g, again.g)
            assert.are.equal(first.b, again.b)
        end
        renderer:destroy()
    end)


    -- Rotation is applied in the vertex shader, so nothing on the host side
    -- would notice if it were dropped or had its sign flipped. A long thin
    -- quad makes the difference unmistakable: unrotated it is a horizontal
    -- band, and a quarter turn makes it a vertical one.
    local function bandScene(rotation)
        local world, renderer = newScene()
        world:spawn(
            Transform(SIZE / 2, SIZE / 2, 0, 1, rotation, SIZE * 2, SIZE / 4),
            Tint(1.0, 0.0, 0.0, 1.0),
            Renderable()
        )
        return screen:readback(), world, renderer
    end

    it("leaves an unrotated quad on its own axes", function()
        local world, renderer = newScene()
        world:spawn(
            Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE / 4),
            Tint(1.0, 0.0, 0.0, 1.0),
            Renderable()
        )
        local pixels = frameOnce(world, renderer)
        assert.are.equal(255, screen:getPixel(pixels, 4, SIZE / 2).r,
            "a wide band reaches the left edge")
        assert.are.equal(0, screen:getPixel(pixels, SIZE / 2, 4).r,
            "and does not reach the top")
        renderer:destroy()
    end)

    it("turns a quad a quarter turn", function()
        local world, renderer = newScene()
        world:spawn(
            Transform(SIZE / 2, SIZE / 2, 0, 1, math.pi / 2, SIZE * 2, SIZE / 4),
            Tint(1.0, 0.0, 0.0, 1.0),
            Renderable()
        )
        local pixels = frameOnce(world, renderer)
        -- Exactly the reverse of the unrotated case. Either sign of a quarter
        -- turn produces this, so the test does not depend on the convention.
        assert.are.equal(0, screen:getPixel(pixels, 4, SIZE / 2).r,
            "a turned band no longer reaches the left edge")
        assert.are.equal(255, screen:getPixel(pixels, SIZE / 2, 4).r,
            "and now reaches the top")
        renderer:destroy()
    end)

    it("culls a rotated quad by an extent that covers its turn", function()
        -- The bound is computed without trigonometry, so it has to be
        -- conservative enough that a quad turned to reach into view is kept.
        -- Placed off the left edge, unrotated it misses; turned, its long axis
        -- swings into view and it must survive the cull.
        local world, renderer = newScene()
        world:spawn(
            Transform(-SIZE / 3, SIZE / 2, 0, 1, math.pi / 2, SIZE / 4, SIZE * 2),
            Tint(0.0, 1.0, 0.0, 1.0),
            Renderable()
        )
        local pixels = frameOnce(world, renderer)
        assert.are.equal(255, screen:getPixel(pixels, 4, SIZE / 2).g,
            "the turned quad reaches into view and must not be culled")
        renderer:destroy()
    end)


    it("dispatches to a material supplied in memory", function()
        -- A material is a file, but it does not have to be: this is the same
        -- path a game's own material takes, minus the file. What it proves is
        -- that a material nobody built into the engine reaches the shader.
        materials.reset()
        materials.define("spec.halfplane", [[
            MaterialOutput material(MaterialInput frag) {
                MaterialOutput result;
                result.albedo = vec4(0.0, 0.0, 1.0, 1.0);
                // Keeps the left half of the quad only.
                result.coverage = -frag.local.x;
                return result;
            }
        ]])

        local world, renderer = newScene()
        world:spawn(
            Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2),
            Tint(1.0, 1.0, 1.0, 1.0),
            components.Material(materials.id("spec.halfplane"), 0),
            Renderable()
        )

        local pixels = frameOnce(world, renderer)
        assert.are.equal(255, screen:getPixel(pixels, 8, SIZE / 2).b,
            "the kept half must draw in the material's colour")
        assert.are.equal(0, screen:getPixel(pixels, SIZE - 8, SIZE / 2).b,
            "and the discarded half must not")
        renderer:destroy()
        materials.reset()
    end)

    it("gives the default material id zero", function()
        -- An entity with no Material component writes a zero, so zero has to
        -- mean something specific rather than whatever sorted first. It sorts
        -- last of the three, which is how this was found.
        materials.reset()
        assert.are.equal(0, materials.id(materials.defaultName))
        assert.are.equal(materials.defaultName, materials.names()[1])
    end)

    it("numbers the rest by sorted name", function()
        materials.reset()
        local names = materials.names()
        for index, name in ipairs(names) do
            assert.are.equal(index - 1, materials.id(name))
        end

        -- Everything after the default is in sorted order, so the same files
        -- always produce the same numbering.
        local rest = {}
        for index = 2, #names do rest[#rest + 1] = names[index] end
        local sorted = {}
        for index, name in ipairs(rest) do sorted[index] = name end
        table.sort(sorted)
        assert.are.same(sorted, rest)
    end)

    it("names what it found when a material is missing", function()
        local ok, reason = pcall(materials.id, "no.such.material")
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("circle", 1, true),
            "the error should list what is available")
    end)


    it("lets a material opt out of lighting", function()
        -- Ambient is dim, so a lit fragment comes back darkened and an unlit
        -- one does not. With full ambient the two are indistinguishable, which
        -- is why the scene is built dark here rather than reusing the default.
        materials.reset()
        materials.define("spec.lit", [[
            MaterialOutput material(MaterialInput frag) {
                MaterialOutput result;
                result.albedo = vec4(1.0, 1.0, 1.0, 1.0);
                result.coverage = 1.0;
                result.lit = 1.0;
                return result;
            }
        ]])
        materials.define("spec.unlit", [[
            MaterialOutput material(MaterialInput frag) {
                MaterialOutput result;
                result.albedo = vec4(1.0, 1.0, 1.0, 1.0);
                result.coverage = 1.0;
                result.lit = 0.0;
                return result;
            }
        ]])

        local function draw(material)
            local world, renderer = newScene({ 0.25, 0.25, 0.25 })
            world:spawn(
                Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2),
                Tint(1.0, 1.0, 1.0, 1.0),
                components.Material(materials.id(material), 0),
                Renderable()
            )
            local pixel = screen:getPixel(frameOnce(world, renderer),
                SIZE / 2, SIZE / 2)
            renderer:destroy()
            return pixel
        end

        assert.are.equal(255, draw("spec.unlit").r,
            "an unlit material keeps its own colour")
        assert.is_true(draw("spec.lit").r < 128,
            "a lit one is darkened by the dim ambient")
        materials.reset()
    end)


    -- The camera is the one place the world-to-clip transform lives, including
    -- the Y flip. These pin that it moves what is drawn and what survives the
    -- cull together, since a camera that panned the image but not the culling
    -- would blank the edges of the screen.
    it("defaults to leaving world coordinates as screen coordinates", function()
        local world, renderer = newScene()
        world:spawn(
            Transform(SIZE * 0.25, SIZE * 0.25, 0, 1, 0, SIZE * 0.3, SIZE * 0.3),
            Tint(1.0, 0.0, 0.0, 1.0),
            Renderable()
        )
        local pixels = frameOnce(world, renderer)
        assert.are.equal(255, screen:getPixel(pixels, SIZE * 0.25, SIZE * 0.25).r)
        renderer:destroy()
    end)

    it("pans what is drawn", function()
        local world, renderer = newScene()
        world:spawn(
            Transform(SIZE * 0.25, SIZE / 2, 0, 1, 0, SIZE * 0.3, SIZE * 0.3),
            Tint(1.0, 0.0, 0.0, 1.0),
            Renderable()
        )
        frameOnce(world, renderer)

        -- Moving the camera left moves the subject right by the same amount.
        renderer.camera.x = renderer.camera.x - SIZE * 0.5
        local pixels = frameOnce(world, renderer)
        assert.are.equal(255, screen:getPixel(pixels, SIZE * 0.75, SIZE / 2).r,
            "the subject should have moved with the camera")
        assert.are.equal(0, screen:getPixel(pixels, SIZE * 0.25, SIZE / 2).r,
            "and left where it was")
        renderer:destroy()
    end)

    it("culls against what the camera can see, not the window", function()
        -- A subject far outside the default view, brought into frame by moving
        -- the camera. If the cull still worked in screen space this would be
        -- rejected before it could draw.
        local world, renderer = newScene()
        world:spawn(
            Transform(SIZE * 10, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2),
            Tint(0.0, 1.0, 0.0, 1.0),
            Renderable()
        )
        assert.are.equal(0, screen:getPixel(frameOnce(world, renderer),
            SIZE / 2, SIZE / 2).g, "not visible before the camera moves")

        renderer.camera.x = SIZE * 10
        assert.are.equal(255, screen:getPixel(frameOnce(world, renderer),
            SIZE / 2, SIZE / 2).g, "visible once the camera looks at it")
        renderer:destroy()
    end)

    it("zooms about the centre of the view", function()
        local world, renderer = newScene()
        -- A quarter-size square at the centre, which zooming doubles.
        world:spawn(
            Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 0.25, SIZE * 0.25),
            Tint(1.0, 0.0, 0.0, 1.0),
            Renderable()
        )
        local before = screen:getPixel(frameOnce(world, renderer),
            SIZE / 2 + SIZE * 0.2, SIZE / 2)
        assert.are.equal(0, before.r, "outside the square at rest")

        renderer.camera.zoom = 2.0
        local after = screen:getPixel(frameOnce(world, renderer),
            SIZE / 2 + SIZE * 0.2, SIZE / 2)
        assert.are.equal(255, after.r, "inside it once magnified")
        renderer:destroy()
    end)

    it("agrees with itself converting between world and screen", function()
        -- toWorld and toScreen are written out rather than inverted, so the
        -- only thing keeping them consistent is that they round-trip.
        local camera = Camera.create({ x = 120, y = 80, zoom = 1.5,
            rotation = 0.7 })
        local screenX, screenY = camera:toScreen(200, 140, SIZE, SIZE)
        local worldX, worldY = camera:toWorld(screenX, screenY, SIZE, SIZE)
        assert.is_true(math.abs(worldX - 200) < 0.01)
        assert.is_true(math.abs(worldY - 140) < 0.01)
    end)

end)
