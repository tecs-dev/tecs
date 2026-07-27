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

    local function frameAt(world, renderer, dt)
        world:update(dt)
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

    -- A frame onto a target of the caller's size, for anything whose answer
    -- depends on how large the target is.
    local function frameInto(world, renderer, target, size)
        world:update(1 / 60)
        local commandBuffer = C.SDL_AcquireGPUCommandBuffer(device.handle)
        renderer:render({
            width = size,
            height = size,
            commandBuffer = commandBuffer,
            swapchainTexture = target.handle,
        })
        assert(C.SDL_SubmitGPUCommandBuffer(commandBuffer))
        return target:readback()
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

    -- Stopping at capacity means leaving an archetype loop early, and leaving
    -- one early through `iter` leaves the world deferred: every later spawn is
    -- queued instead of applied, and nothing says so. The count above is the
    -- same either way, so it takes a spawn after the sync to tell.
    it("leaves the world undeferred after dropping rows", function()
        local world = tecs.newWorld()
        local renderer = Renderer.create(device.handle, FORMAT,
            { ambient = { 1, 1, 1 }, capacity = 4 })
        renderer:install(world)

        -- Two archetypes, because the break has to actually execute. With one,
        -- the first pass fills the buffer and the loop then ends by exhausting
        -- the query, which pops the scope and hides the defect entirely.
        local Second = tecs.newTagComponent({ name = "CapacitySecondArchetype" })
        for _ = 1, 6 do
            world:spawn(Transform(0, 0, 0, 1, 0, 1, 1), Tint(1, 1, 1, 1), Renderable())
        end
        for _ = 1, 6 do
            world:spawn(Transform(0, 0, 0, 1, 0, 1, 1), Tint(1, 1, 1, 1),
                Renderable(), Second)
        end
        frameOnce(world, renderer)

        -- Observed from inside the same update, in a phase after the sync,
        -- because the world drains what it deferred when the update ends. A
        -- scope the sync failed to pop is invisible from outside and defers
        -- every system that runs after it.
        local Marker = tecs.newTagComponent({ name = "AfterCapacityDrop" })
        local seen = -1
        world:addSystem({
            name = "spec.SpawnAfterSync",
            phase = tecs.phases.Last,
            run = function()
                world:spawn(Marker)
                seen = 0
                for _, length in world:query({ include = { Marker } }):iter() do
                    seen = seen + length
                end
            end,
        })

        world:update(1 / 60)
        assert.are.equal(1, seen,
            "a spawn in a later phase was deferred, so the sync left a scope open")
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

    -- The rest of the shapes, each checked the same way: a pixel the silhouette
    -- must contain and one it must not. A shape that quietly filled its quad
    -- passes any test that only samples the middle, so every one of these has a
    -- sample outside the shape and inside the quad.
    --
    -- The quad covers the target exactly, so a pixel's position in the readback
    -- is its position in the shape: local coordinates run -0.5 to 0.5 across
    -- these 64 pixels, and -Y is up on screen.
    local function shape(world, name, param)
        world:spawn(
            Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE, SIZE),
            Tint(1.0, 0.0, 0.0, 1.0),
            components.Material(materials.id(name), param),
            Renderable()
        )
    end

    it("fills an ellipse to the quad's width and its parameter's height", function()
        local world, renderer = newScene()
        shape(world, "ellipse", 0.5)

        local pixels = frameOnce(world, renderer)
        assert.are.equal(255, screen:getPixel(pixels, SIZE / 2, SIZE / 2).r,
            "the middle of the ellipse is filled")
        assert.are.equal(0, screen:getPixel(pixels, SIZE / 2, 6).r,
            "half the height leaves the top of the quad outside")
        assert.are.equal(0, screen:getPixel(pixels, 2, 2).r,
            "and the corner is outside whatever the height")
        renderer:destroy()
    end)

    it("takes an ellipse's height from its parameter", function()
        -- The parameter has to reach the silhouette rather than merely reach
        -- the shader, so the same pixel is sampled at two of them.
        local flatWorld, flatRenderer = newScene()
        shape(flatWorld, "ellipse", 0.5)
        local flat = frameOnce(flatWorld, flatRenderer)

        local fullWorld, fullRenderer = newScene()
        shape(fullWorld, "ellipse", 0.99)
        local full = frameOnce(fullWorld, fullRenderer)

        assert.are.equal(0, screen:getPixel(flat, SIZE / 2, 6).r,
            "a half-height ellipse stops short of the quad's top")
        assert.are.equal(255, screen:getPixel(full, SIZE / 2, 6).r,
            "a full-height one reaches it")
        assert.are.equal(0, screen:getPixel(full, 2, 2).r,
            "and is still an ellipse rather than the quad")
        flatRenderer:destroy()
        fullRenderer:destroy()

        -- A height of zero is a division by it, and a coverage that is not a
        -- number compares false against the discard, so the failure this pins
        -- is the quad filling where the shape vanished.
        local noneWorld, noneRenderer = newScene()
        shape(noneWorld, "ellipse", 0.0)
        local none = frameOnce(noneWorld, noneRenderer)
        assert.are.equal(0, screen:getPixel(none, SIZE / 2, 6).r,
            "an ellipse with no height covers nothing but its own line")
        assert.are.equal(0, screen:getPixel(none, 2, 2).r)
        noneRenderer:destroy()
    end)

    it("cuts a ring's hole to its parameter", function()
        local world, renderer = newScene()
        shape(world, "ring", 0.5)
        local pixels = frameOnce(world, renderer)

        assert.are.equal(255, screen:getPixel(pixels, SIZE / 2, 8).r,
            "the band between the two radii is filled")
        assert.are.equal(0, screen:getPixel(pixels, SIZE / 2, SIZE / 2).r,
            "the hole is not")
        assert.are.equal(0, screen:getPixel(pixels, 2, 2).r,
            "and the corner is outside the ring entirely")
        renderer:destroy()

        -- A hole of no radius is a disc, which is the parameter's other end.
        local solidWorld, solidRenderer = newScene()
        shape(solidWorld, "ring", 0.0)
        local solid = frameOnce(solidWorld, solidRenderer)
        assert.are.equal(255, screen:getPixel(solid, SIZE / 2, SIZE / 2).r,
            "a ring with no hole is filled to its middle")
        assert.are.equal(0, screen:getPixel(solid, 2, 2).r,
            "and still rejects the quad's corner")
        solidRenderer:destroy()
    end)

    it("caps a capsule with semicircles at the quad's ends", function()
        local world, renderer = newScene()
        shape(world, "capsule", 0.4)
        local pixels = frameOnce(world, renderer)

        assert.are.equal(255, screen:getPixel(pixels, 4, SIZE / 2).r,
            "the bar runs the full width, so its cap reaches the left edge")
        assert.are.equal(0, screen:getPixel(pixels, SIZE / 2, 6).r,
            "and its thickness leaves the top of the quad outside")
        assert.are.equal(0, screen:getPixel(pixels, 2, 2).r,
            "as does the corner beside the cap")
        renderer:destroy()
    end)

    it("draws a line along the quad's diagonal", function()
        local world, renderer = newScene()
        shape(world, "line", 0.2)
        local pixels = frameOnce(world, renderer)

        assert.are.equal(255, screen:getPixel(pixels, SIZE / 2, SIZE / 2).r,
            "the line passes through the middle")
        assert.are.equal(255, screen:getPixel(pixels, 2, 2).r,
            "and its cap reaches the corner it runs from")
        assert.are.equal(0, screen:getPixel(pixels, SIZE - 3, 2).r,
            "while the other diagonal's corner is nowhere near it")
        renderer:destroy()
    end)

    it("sweeps a pie by its parameter", function()
        local world, renderer = newScene()
        shape(world, "pie", 0.25)
        local quarter = frameOnce(world, renderer)

        assert.are.equal(255, screen:getPixel(quarter, SIZE / 2, 20).r,
            "a quarter turn opens upwards from the middle")
        assert.are.equal(0, screen:getPixel(quarter, SIZE / 2, 44).r,
            "and does not reach the other way")
        assert.are.equal(0, screen:getPixel(quarter, 2, 2).r,
            "nor outside the circle it is a wedge of")
        renderer:destroy()

        local wideWorld, wideRenderer = newScene()
        shape(wideWorld, "pie", 0.75)
        local wide = frameOnce(wideWorld, wideRenderer)
        assert.are.equal(0, screen:getPixel(quarter, 16, 40).r,
            "a quarter turn stops well short of the lower left")
        assert.are.equal(255, screen:getPixel(wide, 16, 40).r,
            "and three quarters of one sweeps past it")
        wideRenderer:destroy()
    end)

    it("points a triangle at the quad's top edge", function()
        local world, renderer = newScene()
        shape(world, "triangle", 0)
        local pixels = frameOnce(world, renderer)

        assert.are.equal(255, screen:getPixel(pixels, SIZE / 2, SIZE / 2).r,
            "the middle of the triangle is filled")
        assert.are.equal(255, screen:getPixel(pixels, 6, SIZE - 4).r,
            "its base is the whole bottom edge, corner included")
        assert.are.equal(0, screen:getPixel(pixels, 6, 4).r,
            "and the apex leaves the top corners out, so it points up")
        renderer:destroy()
    end)

    it("cuts the valleys between a star's points", function()
        local world, renderer = newScene()
        shape(world, "star", 0.4)
        local pixels = frameOnce(world, renderer)

        assert.are.equal(255, screen:getPixel(pixels, SIZE / 2, SIZE / 2).r,
            "the body of the star is filled")
        assert.are.equal(255, screen:getPixel(pixels, 17, 52).r,
            "and so is a point reaching down to the left")
        assert.are.equal(0, screen:getPixel(pixels, SIZE / 2, 52).r,
            "while the valley between the two lower points is not")
        assert.are.equal(0, screen:getPixel(pixels, 2, 2).r,
            "and neither is the quad's corner")
        renderer:destroy()
    end)

    it("frames a rectangle without filling it", function()
        local world, renderer = newScene()
        shape(world, "frame", 0.25)
        local pixels = frameOnce(world, renderer)

        assert.are.equal(255, screen:getPixel(pixels, 2, SIZE / 2).r,
            "the border is drawn")
        assert.are.equal(255, screen:getPixel(pixels, 2, 2).r,
            "including its corner, which a rounded rectangle drops")
        assert.are.equal(0, screen:getPixel(pixels, SIZE / 2, SIZE / 2).r,
            "and the middle is the hole it frames")
        renderer:destroy()
    end)

    it("puts a shape's edge in the same place at four times the size", function()
        -- Shapes are distance fields evaluated from the quad's own coordinates,
        -- so nothing about them may be measured in pixels. Drawing the same
        -- triangle onto a target four times as large has to put its slanted
        -- edge at the same fraction of the quad, which two samples a thirty
        -- second of the quad either side of it pin.
        local LARGE = SIZE * 4
        local large = Texture.create(device.handle,
            { width = LARGE, height = LARGE, format = FORMAT })

        local world, renderer = newScene()
        shape(world, "triangle", 0)
        local small = frameOnce(world, renderer)

        local bigWorld, bigRenderer = newScene()
        bigWorld:spawn(
            Transform(LARGE / 2, LARGE / 2, 0, 1, 0, LARGE, LARGE),
            Tint(1.0, 0.0, 0.0, 1.0),
            components.Material(materials.id("triangle"), 0),
            Renderable()
        )
        local big = frameInto(bigWorld, bigRenderer, large, LARGE)

        assert.are.equal(255, screen:getPixel(small, 18, SIZE / 2).r,
            "inside the slanted edge at the target's own size")
        assert.are.equal(0, screen:getPixel(small, 13, SIZE / 2).r,
            "and outside it a little further out")
        assert.are.equal(255, large:getPixel(big, 72, LARGE / 2).r,
            "the same fraction of the quad is inside at four times the size")
        assert.are.equal(0, large:getPixel(big, 52, LARGE / 2).r,
            "and the same fraction outside, so the edge did not move")

        renderer:destroy()
        bigRenderer:destroy()
        large:destroy()
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


    -- Simulation advances in fixed jumps while frames arrive whenever the display
    -- asks for one. An entity moved by a fixed step therefore belongs, on a frame
    -- that lands part way through the next step, part way between where the step
    -- found it and where it left it.
    --
    -- Driven entirely through `world:update`: the alpha is whatever the fixed
    -- accumulator has left over, so feeding a dt of one and a quarter steps runs
    -- one step and leaves a quarter. There is no test-only entry point into the
    -- renderer, because a path only tests exercise is not the path that ships.
    describe("ecs.Renderer interpolation", function()
        local STEP = 1 / 60

        --- A world whose body teleports one span to the right per fixed step.
        local function movingScene(span)
            local world = tecs.newWorld()
            local renderer = Renderer.create(device.handle, FORMAT,
                { ambient = { 1, 1, 1 }, capacity = 64 })
            renderer:install(world)

            local entity = world:spawn(
                Transform(0, SIZE / 2, 0, 1, 0, 4, SIZE),
                Tint(1, 1, 1, 1), Renderable(),
                components.PreviousTransform(0, SIZE / 2, 0))

            world:addSystem({
                name = "spec.Teleport",
                phase = tecs.phases.FixedUpdate,
                run = function()
                    local transform = world:getMut(entity, Transform)
                    transform.x = transform.x + span
                end,
            })
            return world, renderer, entity
        end

        it("draws a stepped body part way between its two positions", function()
            local world, renderer = movingScene(SIZE)

            -- One step plus a quarter: the body moves to SIZE, and the frame
            -- lands a quarter of the way into the step that has not run yet, so
            -- it is drawn a quarter of the way along.
            local pixels = frameAt(world, renderer, STEP * 1.25)
            assert.is_true(screen:getPixel(pixels, SIZE * 0.25, SIZE / 2).r > 200,
                "a quarter of the way along")
            assert.is_true(screen:getPixel(pixels, SIZE * 0.75, SIZE / 2).r < 50,
                "and not three quarters")
            renderer:destroy()
        end)

        -- The failure this catches is subtle: the dirty bits say an archetype is
        -- unchanged between fixed steps, which is true of its transform and false
        -- of where it should be drawn. Gated on the bits alone, the body would
        -- hold still for every frame that did not run a step.
        it("keeps moving on frames that run no step", function()
            local world, renderer = movingScene(SIZE)

            frameAt(world, renderer, STEP)
            local early = frameAt(world, renderer, STEP * 0.25)
            local late = frameAt(world, renderer, STEP * 0.5)

            local earlyLit = screen:getPixel(early, SIZE * 0.25, SIZE / 2).r
            local lateLit = screen:getPixel(late, SIZE * 0.75, SIZE / 2).r
            assert.is_true(earlyLit > 200, "a quarter in after one step")
            assert.is_true(lateLit > 200, "three quarters in after another frame")
        end)

        it("leaves an entity without the component alone", function()
            local world = tecs.newWorld()
            local renderer = Renderer.create(device.handle, FORMAT,
                { ambient = { 1, 1, 1 }, capacity = 64 })
            renderer:install(world)
            world:spawn(Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE, SIZE),
                Tint(1, 1, 1, 1), Renderable())

            local pixels = frameAt(world, renderer, STEP * 1.5)
            assert.is_true(screen:getPixel(pixels, SIZE / 2, SIZE / 2).r > 200,
                "drawn where it is, with no previous transform to blend from")
            renderer:destroy()
        end)
    end)


    -- Layers are bands of the depth range, and a band never sorts against
    -- another one. That is the guarantee content is authored against: put the
    -- HUD on a higher layer and it covers the world, whatever the world does.
    describe("layers", function()
        local layers = require("tecs.gfx.layers")

        local function quad(world, x, y, layer, z, r, g, b)
            world:spawn(
                Transform(x, y, z, layer, 0, SIZE, SIZE),
                Tint(r, g, b, 1), Renderable())
        end

        it("draws a higher layer in front whatever the lower one does", function()
            local world, renderer = newScene()
            -- The blue one is spawned first, so draw order would put red on
            -- top. Its layer is what must decide instead.
            quad(world, SIZE / 2, SIZE / 2, 8, 0, 0, 0, 1)
            quad(world, SIZE / 2, SIZE / 2, 1, 0, 1, 0, 0)

            local pixels = frameOnce(world, renderer)
            local centre = screen:getPixel(pixels, SIZE / 2, SIZE / 2)
            assert.is_true(centre.b > 200, "the higher layer is what you see")
            assert.is_true(centre.r < 50, "not the one drawn after it")
            renderer:destroy()
        end)

        it("sorts by depth down the screen within one layer", function()
            local world, renderer = newScene()
            -- Same layer, so position decides. The lower one is nearer.
            quad(world, SIZE / 2, SIZE * 0.25, 1, 0, 1, 0, 0)
            quad(world, SIZE / 2, SIZE * 0.75, 1, 0, 0, 0, 1)

            local pixels = frameOnce(world, renderer)
            assert.is_true(
                screen:getPixel(pixels, SIZE / 2, SIZE / 2).b > 200,
                "the entity lower on the screen is in front")
            renderer:destroy()
        end)

        it("lets z decide on a layer that sorts by z", function()
            local world, renderer = newScene()
            layers.configure(2, { sort = "z" })
            -- The one higher up the screen would lose under a top-down sort,
            -- and wins here because its z is greater.
            quad(world, SIZE / 2, SIZE * 0.25, 2, 100, 0, 0, 1)
            quad(world, SIZE / 2, SIZE * 0.75, 2, 0, 1, 0, 0)

            local pixels = frameOnce(world, renderer)
            assert.is_true(
                screen:getPixel(pixels, SIZE / 2, SIZE / 2).b > 200,
                "greater z is in front when the layer sorts by z")
            layers.configure(2, { sort = "topdown" })
            renderer:destroy()
        end)

        it("refuses a layer outside the range it has bands for", function()
            assert.has_error(function()
                layers.configure(layers.MAX + 1, { sort = "z" })
            end)
            assert.has_error(function()
                layers.configure(1, { sort = "sideways" })
            end)
            assert.has_error(function()
                layers.configure(1, {
                    sort = "z", screenSpace = true, virtualCoords = true,
                })
            end)
        end)

        -- A layer also decides where its contents are positioned and whether
        -- they are lit. These are the four transforms and the one lighting
        -- answer, each checked against a layer that did not ask for it, since
        -- a feature that changes nothing about where a quad lands is the
        -- failure that gets shipped.
        local function box(world, x, y, layer, size, r, g, b)
            world:spawn(
                Transform(x, y, 0, layer, 0, size, size),
                Tint(r, g, b, 1), Renderable())
        end

        it("holds a screen-space layer still while the camera moves", function()
            local world, renderer = newScene()
            layers.configure(3, { sort = "z", screenSpace = true })
            -- The red one is placed by the camera and the blue one in screen
            -- pixels, and both start a quarter of the target across.
            box(world, SIZE / 2, SIZE / 4, 1, SIZE / 4, 1, 0, 0)
            box(world, SIZE / 2, SIZE * 0.75, 3, SIZE / 4, 0, 0, 1)

            frameOnce(world, renderer)
            -- The camera centres itself on the first frame it draws, so this
            -- pans a quarter of the target to the right.
            renderer.camera.x = renderer.camera.x + SIZE / 4
            local pixels = frameOnce(world, renderer)
            layers.configure(3, { sort = "topdown" })

            assert.is_true(screen:getPixel(pixels, SIZE / 4, SIZE / 4).r > 200,
                "the camera carried the world layer left with it")
            assert.is_true(screen:getPixel(pixels, SIZE / 2, SIZE / 4).r < 50,
                "and left nothing where it was")
            assert.is_true(
                screen:getPixel(pixels, SIZE / 2, SIZE * 0.75).b > 200,
                "the screen-space layer is where it was put, camera or not")
            renderer:destroy()
        end)

        it("keeps an ignore-zoom layer its size while the view zooms", function()
            local world, renderer = newScene()
            layers.configure(4, { sort = "topdown", ignoreZoom = true })
            -- Eight units each, above and below the camera's centre so zoom
            -- moves them apart rather than over each other.
            box(world, SIZE / 2, SIZE * 0.375, 1, 8, 1, 0, 0)
            box(world, SIZE / 2, SIZE * 0.625, 4, 8, 0, 0, 1)

            local before = frameOnce(world, renderer)
            assert.is_true(screen:getPixel(before, 32, 24).r > 200,
                "the world layer starts eight pixels across")
            assert.is_true(screen:getPixel(before, 26, 24).r < 50,
                "so nothing reaches six pixels out from its centre")

            renderer.camera.zoom = 2.0
            local pixels = frameOnce(world, renderer)
            layers.configure(4, { sort = "topdown" })

            assert.is_true(screen:getPixel(pixels, 26, 16).r > 200,
                "the world layer doubled and now reaches that far out")
            assert.is_true(screen:getPixel(pixels, 32, 41).b > 200,
                "the ignore-zoom layer is still drawn")
            assert.is_true(screen:getPixel(pixels, 26, 41).b < 50,
                "and is still eight pixels across, where the zoom left it")
            renderer:destroy()
        end)

        it("moves a parallax layer at the fraction it asked for", function()
            local world, renderer = newScene()
            layers.configure(5, { sort = "topdown", parallax = 0.5 })
            -- Placed so that both land in the middle of the target while the
            -- camera is centred, one carried half as far as the other.
            box(world, SIZE / 4, 0, 5, 8, 0, 0, 1)
            box(world, SIZE / 2, SIZE * 0.75, 1, 8, 1, 0, 0)

            local before = frameOnce(world, renderer)
            assert.is_true(screen:getPixel(before, 32, 16).b > 200,
                "the parallax layer starts halfway across")
            assert.is_true(screen:getPixel(before, 32, 48).r > 200,
                "and so does the layer that moves with the world")

            renderer.camera.x = renderer.camera.x + SIZE / 4
            local pixels = frameOnce(world, renderer)
            layers.configure(5, { sort = "topdown" })

            assert.is_true(screen:getPixel(pixels, 16, 48).r > 200,
                "the world layer moved the whole quarter the camera did")
            assert.is_true(screen:getPixel(pixels, 24, 16).b > 200,
                "the parallax layer moved half of it")
            assert.is_true(screen:getPixel(pixels, 32, 16).b < 50,
                "which is a move, not a layer that ignored the camera")
            renderer:destroy()
        end)

        it("leaves an unlit layer at its own colour", function()
            -- No ambient and no lights, so everything the lighting pass
            -- resolves comes out black and only what bypasses it has a colour.
            local world, renderer = newScene({ 0.0, 0.0, 0.0 })
            layers.configure(6, { sort = "z", unlit = true })
            box(world, SIZE / 2, SIZE / 4, 1, SIZE / 4, 1, 0, 0)
            box(world, SIZE / 2, SIZE * 0.75, 6, SIZE / 4, 1, 0, 0)

            local pixels = frameOnce(world, renderer)
            layers.configure(6, { sort = "z" })

            assert.is_true(
                screen:getPixel(pixels, SIZE / 2, SIZE * 0.75).r > 200,
                "the unlit layer kept the colour it was tinted")
            assert.is_true(screen:getPixel(pixels, SIZE / 2, SIZE / 4).r < 50,
                "and the lit one went to what the lighting resolved")
            renderer:destroy()
        end)

        it("holds a virtual layer's proportions across target sizes", function()
            local world, renderer = newScene()
            local half = Texture.create(device.handle,
                { width = SIZE / 2, height = SIZE / 2, format = FORMAT })
            local savedWidth = layers.virtualWidth
            local savedHeight = layers.virtualHeight

            layers.configure(7, { sort = "z", virtualCoords = true })
            layers.virtualWidth = 200
            layers.virtualHeight = 200
            -- The middle half of the virtual space, which is the middle half
            -- of whatever target it is scaled onto.
            box(world, 100, 100, 7, 100, 0, 0, 1)

            local wide = frameOnce(world, renderer)
            local narrow = frameInto(world, renderer, half, SIZE / 2)

            layers.configure(7, { sort = "z" })
            layers.virtualWidth = savedWidth
            layers.virtualHeight = savedHeight

            assert.is_true(screen:getPixel(wide, 32, 32).b > 200,
                "the middle of the virtual space is the middle of the target")
            assert.is_true(screen:getPixel(wide, 18, 32).b > 200,
                "reaching a quarter of the way in")
            assert.is_true(screen:getPixel(wide, 13, 32).b < 50,
                "and no further")

            assert.is_true(half:getPixel(narrow, 16, 16).b > 200,
                "and the same on a target half the size")
            assert.is_true(half:getPixel(narrow, 10, 16).b > 200,
                "reaching a quarter of that target's width in")
            assert.is_true(half:getPixel(narrow, 6, 16).b < 50,
                "and no further, so the layout kept its proportions")

            half:destroy()
            renderer:destroy()
        end)
    end)


    -- A producer draws instances it owns rather than entities. Text is why:
    -- an entity per glyph puts every glyph in one archetype, so editing one
    -- string rewrites all of them, and spawning glyphs moves an archetype's
    -- length, which lays the whole scene out again.
    describe("instance producers", function()
        --- Writes `count` quads in a row, each the colour it is told.
        local function stripe(count, r, g, b)
            local self = { written = {}, dirty = {} }
            function self:count() return count end
            function self:takeDirty()
                local out = self.dirty
                self.dirty = {}
                return out
            end
            function self:write(floats, bounds, base, first, last)
                for index = first, last do
                    local at = (base + index - 1) * 16
                    floats[at] = 0.0
                    floats[at + 1] = SIZE / count
                    floats[at + 2] = SIZE
                    floats[at + 3] = 0.5
                    floats[at + 4] = (index - 0.5) * (SIZE / count)
                    floats[at + 5] = SIZE / 2
                    floats[at + 6] = 0.0
                    floats[at + 7] = 0.0
                    floats[at + 8], floats[at + 9] = r, g
                    floats[at + 10], floats[at + 11] = b, 1.0
                    floats[at + 12], floats[at + 13] = 0.0, 0.0
                    floats[at + 14], floats[at + 15] = 1.0, 1.0

                    local bound = (base + index - 1) * 4
                    bounds[bound] = (index - 0.5) * (SIZE / count)
                    bounds[bound + 1] = SIZE / 2
                    bounds[bound + 2] = SIZE
                    bounds[bound + 3] = SIZE
                    self.written[#self.written + 1] = index
                end
            end
            return self
        end

        it("draws instances that belong to no entity", function()
            local world, renderer = newScene()
            local producer = stripe(4, 1.0, 0.0, 0.0)
            renderer:addProducer(producer)

            local pixels = frameOnce(world, renderer)
            assert.is_true(screen:getPixel(pixels, SIZE / 2, SIZE / 2).r > 200,
                "the producer's instances are drawn")
            assert.are.equal(4, renderer.count)
            renderer:destroy()
        end)

        it("writes only the sub-ranges a producer reports", function()
            local world, renderer = newScene()
            local producer = stripe(8, 0.0, 1.0, 0.0)
            renderer:addProducer(producer)
            frameOnce(world, renderer)

            -- The first frame lays the run out, so everything is written. The
            -- point of a producer is what the second frame costs.
            producer.written = {}
            producer.dirty = { 3, 4 }
            frameOnce(world, renderer)

            assert.are.same({ 3, 4 }, producer.written,
                "a changed pair, not the whole run")
            renderer:destroy()
        end)

        it("writes nothing for a producer that reports nothing", function()
            local world, renderer = newScene()
            local producer = stripe(8, 0.0, 0.0, 1.0)
            renderer:addProducer(producer)
            frameOnce(world, renderer)

            producer.written = {}
            frameOnce(world, renderer)
            assert.are.equal(0, #producer.written,
                "an unchanged producer costs nothing")
            renderer:destroy()
        end)

        it("lays a producer out after the entities", function()
            local world, renderer = newScene()
            world:spawn(Transform(SIZE / 2, SIZE / 2, 0, 1, 0, 4, 4),
                Tint(1, 1, 1, 1), Renderable())
            local producer = stripe(3, 1.0, 1.0, 0.0)
            renderer:addProducer(producer)

            frameOnce(world, renderer)
            assert.are.equal(4, renderer.count,
                "one entity plus three produced instances")
            renderer:destroy()
        end)
    end)


    -- A clip region is a rectangle in target pixels and an index the instance
    -- carries, and the fragment throws away what falls outside. That is what a
    -- scrollable panel needs and what a UI library's scissor means, so these
    -- check where the ink lands rather than that something was drawn.
    --
    -- The index shares `origin.z` with the texture-array layer, which is the
    -- part of this design that can break something that already worked. The
    -- last test here is that one.
    describe("clip regions", function()
        local Clip = components.Clip

        -- A quad covering the whole target, so where its colour lands is the
        -- clip's decision and nothing else's.
        local function fill(world, r, g, b, clip)
            if clip == nil then
                return world:spawn(
                    Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2),
                    Tint(r, g, b, 1.0), Renderable())
            end
            return world:spawn(
                Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2),
                Tint(r, g, b, 1.0), Clip(clip), Renderable())
        end

        it("packs a region and a layer into one exact float", function()
            local instancelayout = require("tecs.gpu.instancelayout")
            local stride = instancelayout.LAYER_SLOTS
            local top = instancelayout.CLIPS - 1
            local packed = instancelayout.packSlot(top, stride - 1)

            assert.are.equal(16383, packed, "the largest value the pair packs")
            assert.are.equal(top, math.floor(packed / stride))
            assert.are.equal(stride - 1, packed % stride)
            assert.are.equal(9, instancelayout.packSlot(0, 9),
                "region zero packs to the layer unchanged")
        end)

        it("keeps a clipped instance inside its region", function()
            local world, renderer = newScene()
            -- The top-left quarter, so both axes are pinned and a flipped Y
            -- shows up as ink in the wrong corner rather than as no ink.
            renderer:setClipRegion(1,
                { x = 0, y = 0, width = SIZE / 2, height = SIZE / 2 })
            fill(world, 1.0, 0.0, 0.0, 1)

            local pixels = frameOnce(world, renderer)
            assert.are.equal(255,
                screen:getPixel(pixels, SIZE / 4, SIZE / 4).r,
                "inside the region")
            assert.are.equal(0,
                screen:getPixel(pixels, SIZE * 3 / 4, SIZE / 4).r,
                "and nothing to the right of it")
            assert.are.equal(0,
                screen:getPixel(pixels, SIZE / 4, SIZE * 3 / 4).r,
                "nor below it")
            assert.are.equal(0,
                screen:getPixel(pixels, SIZE * 3 / 4, SIZE * 3 / 4).r)

            -- Still one instance: clipping happens a fragment at a time and
            -- the cull knows nothing about it.
            assert.are.equal(1, renderer.count)
            renderer:destroy()
        end)

        it("clips instances in different regions independently", function()
            local world, renderer = newScene()
            renderer:setClipRegion(1,
                { x = 0, y = 0, width = SIZE / 2, height = SIZE })
            renderer:setClipRegion(2,
                { x = SIZE / 2, y = 0, width = SIZE / 2, height = SIZE })
            fill(world, 1.0, 0.0, 0.0, 1)
            fill(world, 0.0, 1.0, 0.0, 2)

            local pixels = frameOnce(world, renderer)
            local left = screen:getPixel(pixels, SIZE / 4, SIZE / 2)
            local right = screen:getPixel(pixels, SIZE * 3 / 4, SIZE / 2)

            assert.are.equal(255, left.r, "the first region's half is red")
            assert.are.equal(0, left.g)
            assert.are.equal(255, right.g, "the second's is green")
            assert.are.equal(0, right.r)
            renderer:destroy()
        end)

        it("draws region zero unclipped", function()
            local world, renderer = newScene()
            -- A region exists and is small, so an instance that read the table
            -- when it should not have would lose most of itself.
            renderer:setClipRegion(1, { x = 0, y = 0, width = 4, height = 4 })
            fill(world, 0.0, 0.0, 1.0, 0)

            local pixels = frameOnce(world, renderer)
            assert.are.equal(255, screen:getPixel(pixels, 2, 2).b)
            assert.are.equal(255,
                screen:getPixel(pixels, SIZE / 2, SIZE / 2).b,
                "region zero is not a region")
            assert.are.equal(255,
                screen:getPixel(pixels, SIZE - 2, SIZE - 2).b)
            renderer:destroy()
        end)

        it("stops clipping when a region is cleared", function()
            local world, renderer = newScene()
            renderer:setClipRegion(3,
                { x = 0, y = 0, width = SIZE / 2, height = SIZE })
            fill(world, 1.0, 0.0, 0.0, 3)
            assert.are.equal(0,
                screen:getPixel(frameOnce(world, renderer),
                    SIZE * 3 / 4, SIZE / 2).r,
                "clipped while the region holds a rectangle")

            renderer:clearClipRegion(3)
            assert.are.equal(255,
                screen:getPixel(frameOnce(world, renderer),
                    SIZE * 3 / 4, SIZE / 2).r,
                "and whole once it does not, rather than gone")
            renderer:destroy()
        end)

        it("refuses a region index outside the table", function()
            local _, renderer = newScene()
            local rect = { x = 0, y = 0, width = 1, height = 1 }
            assert.is_false(pcall(function()
                renderer:setClipRegion(0, rect)
            end), "region zero means no clipping and cannot be set")
            assert.is_false(pcall(function()
                renderer:setClipRegion(256, rect)
            end), "and the table ends at 255")
            renderer:destroy()
        end)

        it("clips a text drawn through the producer", function()
            local text = require("tecs.gfx.text")
            local font = text.defaultFont()

            -- The atlas decodes on a worker, so the font arrives no earlier
            -- than the frame after the one that asked for it.
            local function settle(world, renderer)
                frameOnce(world, renderer)
                assets.waitAll()
                frameOnce(world, renderer)
                return frameOnce(world, renderer)
            end

            local function ink(pixels, x0, x1)
                local count = 0
                for y = 0, SIZE - 1 do
                    for x = x0, x1 - 1 do
                        if screen:getPixel(pixels, x, y).g > 128 then
                            count = count + 1
                        end
                    end
                end
                return count
            end

            local function scene(clip)
                local world, renderer = newScene()
                world:addPlugin(text.plugin({ renderer = renderer }))
                local parts = {
                    Transform(2, 2, 0, 1),
                    Tint(0.0, 1.0, 0.0, 1.0),
                    text.Text.new({ text = "MM", font = font, size = 52 }),
                }
                if clip ~= nil then parts[#parts + 1] = Clip(clip) end
                world:spawn(table.unpack(parts))
                return world, renderer
            end

            -- Unclipped first, so "no ink on the right" below is a claim about
            -- the clip rather than about where the glyphs happened to land.
            local world, renderer = scene(nil)
            local whole = settle(world, renderer)
            assert.is_true(ink(whole, 0, SIZE / 2) > 0,
                "the text should reach the left half")
            assert.is_true(ink(whole, SIZE / 2, SIZE) > 0,
                "and the right half")
            renderer:destroy()

            local clipped, clippedRenderer = scene(4)
            clippedRenderer:setClipRegion(4,
                { x = 0, y = 0, width = SIZE / 2, height = SIZE })
            local pixels = settle(clipped, clippedRenderer)

            assert.is_true(ink(pixels, 0, SIZE / 2) > 0,
                "a clipped text still draws inside its region")
            assert.are.equal(0, ink(pixels, SIZE / 2, SIZE),
                "and a glyph is clipped the same way an entity is")
            clippedRenderer:destroy()
        end)

        it("keeps the array layer a sprite named when a region rides with it",
            function()
            -- This is the regression the packing risks. `origin.z` carries the
            -- texture-array layer and the clip index in one float, so a shader
            -- reading it as a bare layer would sample layer 7 * 64 + n, which
            -- nothing was ever uploaded into.
            local world, renderer = newScene()
            renderer:registerImage(solid("spec://clipred", 255, 0, 0))
            renderer:registerImage(solid("spec://clipgreen", 0, 255, 0))
            local green = renderer:sprite("spec://clipgreen")
            assert.is_true(green.slot > 0,
                "the image must not be on the white default layer")

            renderer:setClipRegion(7,
                { x = 0, y = 0, width = SIZE / 2, height = SIZE })
            world:spawn(
                Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2),
                Tint(1.0, 1.0, 1.0, 1.0),
                green,
                Clip(7),
                Renderable()
            )

            local pixels = frameOnce(world, renderer)
            local inside = screen:getPixel(pixels, SIZE / 4, SIZE / 2)

            assert.are.equal(255, inside.g,
                "the sprite still samples the layer its name resolved to")
            assert.are.equal(0, inside.r, "and not the other image")
            assert.are.equal(0, inside.b, "nor the white default layer")
            assert.are.equal(0,
                screen:getPixel(pixels, SIZE * 3 / 4, SIZE / 2).g,
                "and the region packed beside it still clips")
            renderer:destroy()
        end)
    end)

end)
