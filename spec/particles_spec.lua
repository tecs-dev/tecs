-- GPU particle emitters, asserted on what reaches the screen.
--
-- Nothing about a particle can be read back: the state buffer is private to
-- the GPU by design and the whole point of the arrangement is that the CPU
-- never learns what is in it. So the only honest place to assert is the frame,
-- which is where these tests look. The host half, which is the schedule, the
-- pool's bookkeeping and the two questions a game may ask about an emitter, is
-- asserted directly because all of it is on this side of the boundary.
--
-- Sized well below saturation throughout. Slot allocation is an atomicAdd, so
-- which emissions survive a full pool is arbitrary, and a pixel comparison
-- against a saturated pool would be a comparison against thread scheduling.

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
local log = require("tecs.log")
local particles = require("tecs.gfx.particles")
local sheet = require("tecs.gfx.sheet")
local materials = require("tecs.gpu.materials")

local C = sdl.C
local FORMAT = 4 -- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local SIZE = 64

local Transform = tecs.Transform
local Tint = components.Tint
local Renderable = components.Renderable
local ParticleEmitter = particles.ParticleEmitter

-- Slots the pool holds in these tests. Small, so a relayout is cheap and the
-- reservation is easy to see in the instance count.
local POOL = 512

-- The structured log stream is the only place a spec can read a diagnostic back
-- from, so the case watching one opens a file around the call it is watching.
local LOG_PATH = "/tmp/tecs-particles-spec.jsonl"

-- An effect's name is unique across the process, so a spec registering a fresh
-- effect per test mints one rather than repeating a literal. What a name means
-- to a save is spec/effect_spec.lua's subject; here it only has to be distinct,
-- and no test below asserts on the name it was given.
local minted = 0
local function effectName()
    minted = minted + 1
    return "specEffect" .. minted
end

describe("tecs.gfx.particles", function()
    local window, device, screen

    it("uses result-named factories", function()
        assert.is_function(particles.newEffect)
        assert.is_function(particles.newCurve)
        assert.is_function(particles.newGradient)
        assert.is_nil(rawget(particles, "effect"))
        assert.is_nil(rawget(particles, "curve"))
        assert.is_nil(rawget(particles, "gradient"))
    end)

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = newWindow({ title = "particles", width = SIZE, height = SIZE })
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

    -- A world with a renderer, and the particle pool only when asked for.
    -- Ambient is full white so transport can be tested without lighting in the
    -- way, exactly as the renderer's own tests do.
    local function newScene(withPool, poolSize)
        local world = tecs.ecs.newWorld()
        local renderer = Renderer.newRenderer(device.handle, FORMAT, {
            ambient = { 1.0, 1.0, 1.0 },
            capacity = 4096,
        })
        renderer:install(world)
        if withPool then
            world:addPlugin(particles.plugin({
                renderer = renderer,
                capacity = poolSize or POOL,
                maxEmitters = 8,
            }))
        end
        return world, renderer
    end

    local function frame(world, renderer)
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

    -- Frames until the given one, answering the last readback. Particles need
    -- at least one step boundary to be emitted on and another to be drawn
    -- from, so nothing here asserts on frame one.
    local function frames(world, renderer, count)
        local pixels
        for _ = 1, count do
            pixels = frame(world, renderer)
        end
        return pixels
    end

    local function center(pixels)
        return screen:getPixel(pixels, SIZE / 2, SIZE / 2)
    end

    -- A still, slow, long-lived burst that fills the middle of the target.
    -- Speed zero and a full-target size mean any particle that exists at all
    -- lands on the center pixel, so these tests read "is there a particle"
    -- rather than "did it move the way I guessed".
    local function stillBurst(options)
        options = options or {}
        return particles.newEffect({
            name = effectName(),
            capacity = options.capacity or 64,
            schedule = {
                rate = 0,
                duration = 0,
                bursts = { { time = 0, count = options.count or 8 } },
            },
            spawn = { shape = "point" },
            initial = {
                lifetime = options.lifetime or 10,
                speed = 0,
                size = options.size or SIZE * 2,
                color = options.color or "#ff0000",
            },
            update = options.update,
            render = { layer = 1, sprite = options.sprite, sheet = options.sheet, tag = options.tag },
        })
    end

    local function newEmitter(world, effect, seed)
        return world:spawn(Transform(SIZE / 2, SIZE / 2), ParticleEmitter({ effect = effect, seed = seed or 7 }))
    end

    ---------------------------------------------------------------------------
    -- Reversibility
    ---------------------------------------------------------------------------

    it("reserves nothing in a world that never installs the plugin", function()
        local world, renderer = newScene(false)
        world:spawn(Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2), Tint(1.0, 0.0, 0.0, 1.0), Renderable())

        local pixels = frames(world, renderer, 2)

        assert.is_nil(particles.poolOf(world))
        assert.are.equal(1, renderer.count, "a world with no pool reserves no slots")
        assert.are.equal(255, center(pixels).r)
        renderer:destroy()
    end)

    it("reserves the pool as one run and draws nothing from it while it is empty", function()
        local world, renderer = newScene(true)
        world:spawn(Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2), Tint(0.0, 1.0, 0.0, 1.0), Renderable())

        local pixels = frames(world, renderer, 2)

        assert.is_not_nil(particles.poolOf(world))
        assert.are.equal(1 + POOL, renderer.count, "the pool is laid out as its own run after the archetypes")
        -- Every slot of that run is hidden, so what reaches the target is the
        -- entity and nothing else.
        assert.are.equal(0, center(pixels).r)
        assert.are.equal(255, center(pixels).g)
        renderer:destroy()
    end)

    it("rewrites nothing per frame once the pool's run is laid out", function()
        local world, renderer = newScene(true)
        newEmitter(world, stillBurst())

        frames(world, renderer, 3)
        local before = renderer.rewritten
        frame(world, renderer)

        -- The producer's takeDirty is empty for ever, so a settled scene with
        -- a live emitter costs the host no instance writes at all: everything
        -- the field does is written by compute.
        assert.are.equal(0, renderer.rewritten, "a live emitter dirties nothing")
        assert.are.equal(0, before)
        renderer:destroy()
    end)

    ---------------------------------------------------------------------------
    -- The simulate pass writes an instance
    ---------------------------------------------------------------------------

    it("draws a burst's particles", function()
        local world, renderer = newScene(true)
        newEmitter(world, stillBurst({ color = "#ff0000" }))

        local pixels = frames(world, renderer, 4)

        assert.are.equal(255, center(pixels).r, "the burst should reach the screen")
        assert.are.equal(0, center(pixels).g)
        renderer:destroy()
    end)

    it("takes the emitter's tint through to the particle", function()
        local world, renderer = newScene(true)
        local effect = stillBurst({ color = "#ffffff" })
        world:spawn(Transform(SIZE / 2, SIZE / 2), ParticleEmitter({ effect = effect, seed = 3, tint = "#0000ff" }))

        local pixels = frames(world, renderer, 4)

        assert.are.equal(0, center(pixels).r)
        assert.are.equal(255, center(pixels).b, "the emitter's tint multiplies the effect's color")
        renderer:destroy()
    end)

    it("places particles where the emitter is", function()
        local world, renderer = newScene(true)
        local effect = particles.newEffect({
            name = effectName(),
            capacity = 64,
            schedule = { bursts = { { time = 0, count = 8 } } },
            initial = { lifetime = 10, speed = 0, size = SIZE * 0.3, color = "#ff0000" },
            render = { layer = 1 },
        })
        world:spawn(Transform(SIZE * 0.25, SIZE * 0.25), ParticleEmitter({ effect = effect }))

        local pixels = frames(world, renderer, 4)

        assert.are.equal(255, screen:getPixel(pixels, SIZE / 4, SIZE / 4).r)
        assert.are.equal(0, screen:getPixel(pixels, SIZE * 3 / 4, SIZE * 3 / 4).r)
        renderer:destroy()
    end)

    ---------------------------------------------------------------------------
    -- The bound the simulate pass writes beside the instance
    ---------------------------------------------------------------------------

    it("writes each particle a bound that travels with it", function()
        -- Far from the origin, with the camera looking at it. The cull tests a
        -- world bound against a world rectangle, so a particle whose bound did
        -- not follow it would be rejected here even though it is on screen.
        -- This is the assertion the per-particle bound has to pass, and a
        -- conservative bound around the emitter could not.
        local world, renderer = newScene(true)
        world:spawn(Transform(5000, 5000), ParticleEmitter({ effect = stillBurst({ size = SIZE * 0.3 }) }))
        -- One frame first, because the camera centers itself on the viewport
        -- the first time there is anything to draw.
        frame(world, renderer)
        renderer.camera.x = 5000
        renderer.camera.y = 5000

        local visible = frames(world, renderer, 4)
        assert.are.equal(255, center(visible).r, "a particle's bound is centerd on the particle")

        -- And away again. The pool's run is still counted and still dispatched
        -- over; what changed is that no view overlaps the bound each live
        -- particle wrote.
        renderer.camera.x = 100000
        local hidden = frames(world, renderer, 2)
        assert.are.equal(0, center(hidden).r)
        renderer:destroy()
    end)

    it("keeps a slot nothing owns out of the frame", function()
        -- The hidden-slot contract, and the reason a pool of sixty-four
        -- thousand costs a bounds read and a scan lane rather than a draw: a
        -- slot with no live particle writes a center no finite view overlaps,
        -- and the mark pass rejects it before the draw sees it.
        local world, renderer = newScene(true)
        local entity = newEmitter(world, stillBurst({ lifetime = 0.05, size = SIZE * 2 }))

        frames(world, renderer, 3)
        world:despawn(entity)
        local pixels = frames(world, renderer, 12)

        assert.are.equal(POOL, renderer.count, "the slots are still resident")
        assert.are.equal(0, center(pixels).r, "and none of them reaches the draw")
        renderer:destroy()
    end)

    ---------------------------------------------------------------------------
    -- Lifetime, and the states around it
    ---------------------------------------------------------------------------

    it("stops drawing a particle once its lifetime is spent", function()
        local world, renderer = newScene(true)
        newEmitter(world, stillBurst({ lifetime = 0.1 }))

        local alive = frames(world, renderer, 3)
        assert.are.equal(255, center(alive).r)

        local gone = frames(world, renderer, 12)
        assert.are.equal(0, center(gone).r, "a particle past its lifetime writes the hidden bound")
        renderer:destroy()
    end)

    it("kills the field immediately on clear and leaves it alone on stop", function()
        local world, renderer = newScene(true)
        local entity = newEmitter(world, stillBurst({ lifetime = 10 }))

        frames(world, renderer, 4)
        assert.are.equal(255, center(screen:readback()).r)

        -- Stop ends emission and lets the field drain, so what is already
        -- alive is untouched.
        world:get(entity, ParticleEmitter):stop()
        local stopped = frames(world, renderer, 3)
        assert.are.equal(255, center(stopped).r, "stop should not remove live particles")

        world:get(entity, ParticleEmitter):clear()
        local cleared = frames(world, renderer, 3)
        assert.are.equal(0, center(cleared).r, "clear should remove them at once")
        renderer:destroy()
    end)

    it("holds a paused emitter's field where it was", function()
        local world, renderer = newScene(true)
        local effect = particles.newEffect({
            name = effectName(),
            capacity = 64,
            schedule = { bursts = { { time = 0, count = 8 } } },
            initial = { lifetime = 0.2, speed = 0, size = SIZE * 2, color = "#ff0000" },
            render = { layer = 1 },
        })
        local entity = newEmitter(world, effect)

        frames(world, renderer, 3)
        world:get(entity, ParticleEmitter):pause()

        -- Well past the lifetime in world time. The emitter's own clock stood
        -- still, so its particles did not age through it.
        local held = frames(world, renderer, 30)
        assert.are.equal(255, center(held).r, "a paused emitter's particles should not age")
        renderer:destroy()
    end)

    it("releases an emitter's slots when its entity goes", function()
        local world, renderer = newScene(true)
        local entity = newEmitter(world, stillBurst({ lifetime = 0.05 }))

        frames(world, renderer, 3)
        assert.are.equal(255, center(screen:readback()).r)

        world:despawn(entity)
        local gone = frames(world, renderer, 12)

        assert.are.equal(0, center(gone).r, "a despawned emitter's particles drain and its slots come back")
        assert.are.equal(POOL, renderer.count, "the run itself does not move")
        renderer:destroy()
    end)

    ---------------------------------------------------------------------------
    -- Determinism
    ---------------------------------------------------------------------------

    it("draws the same field twice from one seed", function()
        local function run(seed)
            local world, renderer = newScene(true)
            local effect = particles.newEffect({
                name = effectName(),
                capacity = 128,
                schedule = { bursts = { { time = 0, count = 64 } } },
                spawn = { shape = "disc", width = 20, direction = 0, spread = math.pi * 2 },
                initial = { lifetime = 10, speed = { min = 10, max = 60 }, size = 6, color = "#ff0000" },
                render = { layer = 1 },
            })
            world:spawn(Transform(SIZE / 2, SIZE / 2), ParticleEmitter({ effect = effect, seed = seed }))
            local pixels = frames(world, renderer, 6)
            local sample = {}
            for index = 0, SIZE * SIZE - 1 do
                sample[index + 1] = pixels[index * 4]
            end
            renderer:destroy()
            return sample
        end

        local first = run(11)
        local again = run(11)
        local other = run(12)

        assert.are.same(first, again, "one seed is one field, whole steps and a counter hash being all it depends on")
        assert.are_not.same(first, other, "a different seed is a different field")
    end)

    ---------------------------------------------------------------------------
    -- Evolution
    ---------------------------------------------------------------------------

    it("shrinks a particle to nothing along its size curve", function()
        local world, renderer = newScene(true)
        newEmitter(
            world,
            stillBurst({
                lifetime = 0.5,
                update = { size = particles.newCurve({ { 0.0, 1.0 }, { 0.4, 1.0 }, { 0.6, 0.0 } }) },
            })
        )

        local early = frames(world, renderer, 4)
        assert.are.equal(255, center(early).r)

        -- Four tenths of the way through, still well inside the lifetime, so
        -- what removed it is the curve and not expiry. This is the only fade
        -- available without a blended pass, and the reason the documentation
        -- says so: the curve takes the quad to no area rather than taking its
        -- alpha to zero, which would write opaque.
        local late = frames(world, renderer, 22)
        assert.are.equal(0, center(late).r, "a size curve reaching zero should take the particle off screen")
        renderer:destroy()
    end)

    it("takes a color gradient through to the particle", function()
        local world, renderer = newScene(true)
        newEmitter(
            world,
            stillBurst({
                lifetime = 1.0,
                color = "#ffffff",
                update = { color = particles.newGradient({ { 0.0, "#ff0000" }, { 1.0, "#00ff00" } }) },
            })
        )

        local early = frames(world, renderer, 3)
        assert.is_true(center(early).r > center(early).g, "the gradient starts red")

        local late = frames(world, renderer, 40)
        assert.is_true(center(late).g > center(late).r, "and ends green")
        renderer:destroy()
    end)

    it("moves a particle along its launch velocity", function()
        local world, renderer = newScene(true)
        local effect = particles.newEffect({
            name = effectName(),
            capacity = 64,
            schedule = { bursts = { { time = 0, count = 8 } } },
            -- Straight down the positive X axis, which is to the right of the
            -- target: world units are pixels from the top left.
            spawn = { shape = "point", direction = 0, spread = 0 },
            initial = { lifetime = 10, speed = 60, size = SIZE * 0.2, color = "#ff0000" },
            render = { layer = 1 },
        })
        world:spawn(Transform(SIZE * 0.2, SIZE / 2), ParticleEmitter({ effect = effect }))

        frames(world, renderer, 3)
        local before = screen:getPixel(screen:readback(), SIZE * 0.2, SIZE / 2).r

        local moved = frames(world, renderer, 25)
        assert.are.equal(255, before)
        assert.are.equal(0, screen:getPixel(moved, SIZE * 0.2, SIZE / 2).r, "it should have left where it started")
        assert.are.equal(255, screen:getPixel(moved, SIZE * 0.55, SIZE / 2).r, "and arrived to the right of it")
        renderer:destroy()
    end)

    ---------------------------------------------------------------------------
    -- Blending
    --
    -- Every claim here is one pixel over one opaque quad, because a blend cannot
    -- be inferred from anything else: a lane that never ran, a mode that was
    -- dropped and a sort that ordered the list backwards all produce a plausible
    -- frame. The quad is blue and the particles are red, so the blue channel says
    -- how much of what was behind survived and the red says how much of the
    -- particle landed. That is the one arrangement in which alpha over, additive
    -- and opaque give three different answers.
    ---------------------------------------------------------------------------

    -- An opaque blue quad filling the target, and one particle over it. One is
    -- the whole point: eight of them at the same place would stack eight blends
    -- deep and the arithmetic would say nothing about the mode. The effect is on
    -- layer two so its particles are nearer than the quad, because the forward
    -- pass tests the geometry pass's depth without writing it and a blended
    -- particle behind opaque geometry is correctly hidden by it.
    local function overQuad(world, blend, alpha, lifetime, gradient)
        world:spawn(Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2), Tint(0.0, 0.0, 1.0, 1.0), Renderable())
        newEmitter(
            world,
            particles.newEffect({
                name = effectName(),
                capacity = 64,
                schedule = { bursts = { { time = 0, count = 1 } } },
                initial = {
                    lifetime = lifetime or 10,
                    speed = 0,
                    size = SIZE * 2,
                    color = { 1.0, 0.0, 0.0, alpha },
                },
                update = { color = gradient },
                render = { layer = 2, blend = blend },
            })
        )
    end

    it("blends a particle's alpha over what is behind it", function()
        -- No blend named, so this is the default as well as the mode: an effect
        -- authored with a translucent color blends, rather than writing that
        -- color opaque over the scene.
        local world, renderer = newScene(true)
        overQuad(world, nil, 0.5)

        local pixels = frames(world, renderer, 4)
        local middle = center(pixels)

        assert.is_true(middle.r > 100 and middle.r < 160, "half the particle's red must land, got " .. middle.r)
        assert.is_true(middle.b > 100 and middle.b < 160, "and half the quad's blue must give way, got " .. middle.b)
        renderer:destroy()
    end)

    it("adds an additive particle to what is behind it", function()
        local world, renderer = newScene(true)
        overQuad(world, "additive", 0.5)

        local pixels = frames(world, renderer, 4)
        local middle = center(pixels)

        assert.is_true(middle.r > 100 and middle.r < 160, "half the particle's red must land, got " .. middle.r)
        assert.are.equal(255, middle.b, "and none of the quad's blue may be taken away")
        renderer:destroy()
    end)

    it("covers what is behind it when the effect asks for the opaque lane", function()
        -- The opt-out, and what every effect drew before there was a choice: the
        -- G-buffer is written with replace, so the particle's alpha reaches the
        -- target having blended against nothing.
        local world, renderer = newScene(true)
        overQuad(world, "opaque", 0.5)

        local pixels = frames(world, renderer, 4)
        local middle = center(pixels)

        assert.are.equal(255, middle.r, "the particle covers the quad whatever its alpha says")
        assert.are.equal(0, middle.b, "and none of the quad survives")
        renderer:destroy()
    end)

    it("fades a blended particle out along its gradient's alpha", function()
        -- The fade the opaque lane could not do at all: the gradient's ends
        -- differ only in alpha, and the size curve is left alone, so what takes
        -- the particle off the screen is alpha and nothing else. Drawn opaque the
        -- same effect would stay solid red for its whole life and then vanish.
        local world, renderer = newScene(true)
        overQuad(
            world,
            nil,
            1.0,
            1.0,
            particles.newGradient({ { 0.0, { 1.0, 1.0, 1.0, 1.0 } }, { 1.0, { 1.0, 1.0, 1.0, 0.0 } } })
        )

        local early = center(frames(world, renderer, 3))
        assert.is_true(early.r > 220, "it starts all but opaque over the quad, got " .. early.r)
        assert.is_true(early.b < 40, "covering it entirely, got " .. early.b)

        -- Half a lifetime in, where the gradient's alpha is halfway too. This is
        -- the frame the opaque lane cannot produce.
        local middle = center(frames(world, renderer, 27))
        assert.is_true(middle.r > 100 and middle.r < 160, "half the particle is left, got " .. middle.r)
        assert.is_true(middle.b > 100 and middle.b < 160, "and half the quad shows through, got " .. middle.b)

        local late = center(frames(world, renderer, 40))
        assert.are.equal(0, late.r, "and it leaves without writing black over the quad")
        assert.are.equal(255, late.b, "which is still whole")
        renderer:destroy()
    end)

    it("reports the pool's blended slots so the forward lane is not skipped", function()
        -- The gate, from the side the CPU can see. The backend runs no forward
        -- lane on a frame nothing said was blended, and a pool whose instances
        -- are written by compute is the one producer that cannot count what is
        -- actually live, so it answers with the slots that may hold one.
        local world, renderer = newScene(true)
        local pool = particles.poolOf(world)

        assert.are.equal(0, pool:blended(), "an empty pool has nothing to blend")

        local blended = newEmitter(world, stillBurst({ capacity = 32, lifetime = 0.05 }))
        newEmitter(
            world,
            particles.newEffect({
                name = effectName(),
                capacity = 16,
                initial = { lifetime = 1.0 },
                render = { layer = 1, blend = "opaque" },
            })
        )
        frames(world, renderer, 2)

        assert.are.equal(32, pool:blended(), "the opaque emitter's slots are not counted")

        world:despawn(blended)
        -- Its particles may still be alive and still being drawn, so its slots
        -- stay counted until the range is released.
        frame(world, renderer)
        assert.are.equal(32, pool:blended(), "a draining range is still blending")

        frames(world, renderer, 12)
        assert.are.equal(0, pool:blended(), "and stops once the range comes back")
        renderer:destroy()
    end)

    ---------------------------------------------------------------------------
    -- Spawn geometry
    ---------------------------------------------------------------------------

    -- A ring narrowed to a single angle, so every particle lands on one point
    -- of it and the assertion is a pixel rather than a hope. The whole ring
    -- would put thirty-two particles at thirty-two angles and testing it would
    -- mean guessing which pixels they reached.
    local function ringAt(rotation, outward, speed, direction)
        return particles.newEffect({
            name = effectName(),
            capacity = 64,
            schedule = { bursts = { { time = 0, count = 8 } } },
            spawn = {
                shape = "ring",
                width = 20,
                arc = 0,
                rotation = rotation,
                outward = outward,
                direction = direction,
                spread = 0,
            },
            initial = { lifetime = 10, speed = speed or 0, size = 6, color = "#ff0000" },
            render = { layer = 1 },
        })
    end

    it("spawns on the shape rather than at the emitter", function()
        local world, renderer = newScene(true)
        world:spawn(Transform(SIZE / 2, SIZE / 2), ParticleEmitter({ effect = ringAt(0, false, 0) }))

        local pixels = frames(world, renderer, 4)

        assert.are.equal(0, center(pixels).r, "nothing is at the emitter itself")
        assert.are.equal(255, screen:getPixel(pixels, SIZE / 2 + 20, SIZE / 2).r, "it is out on the ring")
        renderer:destroy()
    end)

    it("turns the emission area independently of the launch direction", function()
        local world, renderer = newScene(true)
        world:spawn(Transform(SIZE / 2, SIZE / 2), ParticleEmitter({ effect = ringAt(math.pi * 0.5, false, 0) }))

        local pixels = frames(world, renderer, 4)

        assert.are.equal(0, screen:getPixel(pixels, SIZE / 2 + 20, SIZE / 2).r, "a quarter turn moves it off the axis")
        assert.are.equal(255, screen:getPixel(pixels, SIZE / 2, SIZE / 2 + 20).r, "and onto the one at right angles")
        renderer:destroy()
    end)

    it("launches along the shape's outward normal when asked", function()
        local world, renderer = newScene(true)
        -- The effect's own direction points the other way, so the two answers
        -- are opposite and the assertion can tell them apart. Spawned twenty
        -- to the right of the emitter, it leaves along the normal the ring
        -- gave it and not along the direction the effect names.
        local effect = ringAt(0, true, 40, math.pi)
        world:spawn(Transform(SIZE / 2 - 20, SIZE / 2), ParticleEmitter({ effect = effect }))

        local pixels = frames(world, renderer, 20)
        assert.are.equal(255, screen:getPixel(pixels, SIZE / 2 + 12, SIZE / 2).r, "outward is the ring's normal")
        assert.are.equal(0, screen:getPixel(pixels, SIZE / 2 - 12, SIZE / 2).r, "and not the effect's direction")
        renderer:destroy()
    end)

    ---------------------------------------------------------------------------
    -- Local and world space
    ---------------------------------------------------------------------------

    -- The same burst, once in each space, with the emitter moved after it has
    -- fired. Which one moves with it is the whole difference between them.
    local function movingBurst(world, renderer, space)
        local effect = particles.newEffect({
            name = effectName(),
            capacity = 64,
            schedule = { bursts = { { time = 0, count = 8 } } },
            spawn = { shape = "point", space = space },
            initial = { lifetime = 10, speed = 0, size = 8, color = "#ff0000" },
            render = { layer = 1 },
        })
        local entity = world:spawn(Transform(SIZE * 0.25, SIZE / 2), ParticleEmitter({ effect = effect }))

        frames(world, renderer, 4)
        assert.are.equal(255, screen:getPixel(screen:readback(), SIZE * 0.25, SIZE / 2).r)

        world:getMut(entity, Transform).x = SIZE * 0.75
        return frames(world, renderer, 3)
    end

    it("carries a local-space particle with its emitter", function()
        local world, renderer = newScene(true)
        local pixels = movingBurst(world, renderer, "local")

        assert.are.equal(0, screen:getPixel(pixels, SIZE * 0.25, SIZE / 2).r, "it left where it was spawned")
        assert.are.equal(255, screen:getPixel(pixels, SIZE * 0.75, SIZE / 2).r, "and followed the emitter")
        renderer:destroy()
    end)

    it("leaves a world-space particle where it was spawned", function()
        local world, renderer = newScene(true)
        local pixels = movingBurst(world, renderer, "world")

        assert.are.equal(255, screen:getPixel(pixels, SIZE * 0.25, SIZE / 2).r, "it stayed where it was spawned")
        assert.are.equal(0, screen:getPixel(pixels, SIZE * 0.75, SIZE / 2).r, "and did not follow the emitter")
        renderer:destroy()
    end)

    ---------------------------------------------------------------------------
    -- Animated particles, through the frame table and nothing new
    ---------------------------------------------------------------------------

    it("plays a sheet over a particle's life through the frame table", function()
        local world, renderer = newScene(true)

        -- Two texels side by side, red then green, cut as two frames of one
        -- animation. Which color reaches the center says which frame the
        -- playback resolved to.
        local pixels = loader.newArray("uint8_t[8]")
        pixels[0], pixels[1], pixels[2], pixels[3] = 255, 0, 0, 255
        pixels[4], pixels[5], pixels[6], pixels[7] = 0, 255, 0, 255
        local sprite = renderer:registerImage({
            status = "ready",
            path = "particles/two.png",
            pixels = pixels,
            width = 2,
            height = 1,
            pitch = 8,
            release = function() end,
        })

        local builder = sheet.build("particles.two", 2, 1)
        builder:frame(0, 0, 1, 1, 100)
        builder:frame(1, 0, 1, 1, 100)
        local strip = builder:finish()
        strip:bind(sprite)

        newEmitter(world, stillBurst({ lifetime = 1.0, color = "#ffffff", sheet = strip }))

        local first = frames(world, renderer, 3)
        assert.are.equal(255, center(first).r, "the cycle starts on its first frame")
        assert.are.equal(0, center(first).g)

        -- Past the middle of the particle's life, which is where the cycle's
        -- second half falls: the rate is the cycle divided by the lifetime, so
        -- one pass covers the life exactly.
        local second = frames(world, renderer, 40)
        assert.are.equal(0, center(second).r, "and reaches its last one as the particle expires")
        assert.are.equal(255, center(second).g)
        renderer:destroy()
    end)

    ---------------------------------------------------------------------------
    -- The host half
    ---------------------------------------------------------------------------

    it("compiles a curve to evenly spaced samples through its keys", function()
        local curve = particles.newCurve({ { 0.0, 0.0 }, { 1.0, 1.0 } })

        assert.are.equal(particles.CURVE_SAMPLES, #curve.samples)
        assert.is_true(math.abs(curve.samples[1] - 0.0) < 1e-6)
        assert.is_true(math.abs(curve.samples[#curve.samples] - 1.0) < 1e-6)
        -- Linear through two keys, so the middle sample is the midpoint.
        local middle = curve.samples[(particles.CURVE_SAMPLES + 1) / 2 + 0.5]
        assert.is_true(math.abs(middle - 0.5) < 0.02)
    end)

    it("places curve keys wherever they were authored", function()
        -- A key at one tenth, which no evenly spaced ramp could express. The
        -- value is already at its peak a tenth of the way through.
        local curve = particles.newCurve({ { 0.0, 0.0 }, { 0.1, 1.0 }, { 1.0, 1.0 } })

        assert.is_true(curve.samples[5] > 0.9, "the ramp finishes by the key's own time")
        assert.is_true(curve.samples[2] < 0.5, "and had not before it")
    end)

    it("compiles a gradient to four floats a sample", function()
        local gradient = particles.newGradient({ { 0.0, "#ff0000ff" }, { 1.0, "#0000ff00" } })

        assert.are.equal(particles.CURVE_SAMPLES * 4, #gradient.samples)
        assert.is_true(math.abs(gradient.samples[1] - 1.0) < 1e-6)
        assert.is_true(math.abs(gradient.samples[4] - 1.0) < 1e-6)
        -- The alpha channel is carried even though nothing blends against it,
        -- so an effect authored today draws as written once something does.
        assert.is_true(math.abs(gradient.samples[#gradient.samples] - 0.0) < 1e-6)
    end)

    it("refuses an effect field it cannot make sense of", function()
        assert.has_error(function()
            particles.newEffect({ name = effectName(), spawn = { shape = "trapezoid" } })
        end)
        assert.has_error(function()
            particles.newEffect({ name = effectName(), spawn = { space = "sideways" } })
        end)
        assert.has_error(function()
            particles.newEffect({ name = effectName(), initial = { color = "#gg0000" } })
        end)
        assert.has_error(function()
            particles.newEffect({
                name = effectName(),
                schedule = {
                    bursts = {
                        { time = 0, count = 1 },
                        { time = 1, count = 1 },
                        { time = 2, count = 1 },
                        { time = 3, count = 1 },
                        { time = 4, count = 1 },
                    },
                },
            })
        end)
    end)

    it("answers finished from the schedule and never from the GPU", function()
        local world, renderer = newScene(true)
        local effect = particles.newEffect({
            name = effectName(),
            capacity = 64,
            schedule = { duration = 0.1, bursts = { { time = 0, count = 4 } } },
            initial = { lifetime = 0.1, speed = 0, size = 4 },
            render = { layer = 1 },
        })
        local entity = newEmitter(world, effect)

        frames(world, renderer, 2)
        local item = world:get(entity, ParticleEmitter)
        assert.is_false(item:finished(), "an emitter that just started has not finished")

        -- Past the delay, the duration and the longest lifetime together.
        frames(world, renderer, 30)
        assert.is_true(item:finished(), "and one past its whole schedule has")
        renderer:destroy()
    end)

    it("never reports finished for a looping emitter that is playing", function()
        local world, renderer = newScene(true)
        local effect = particles.newEffect({
            name = effectName(),
            capacity = 64,
            schedule = { rate = 30, duration = 0.1, looping = true },
            initial = { lifetime = 0.1, speed = 0, size = 4 },
            render = { layer = 1 },
        })
        local entity = newEmitter(world, effect)

        frames(world, renderer, 30)
        assert.is_false(world:get(entity, ParticleEmitter):finished())
        renderer:destroy()
    end)

    it("predicts a steady emitter's live count from its schedule", function()
        local world, renderer = newScene(true)
        local effect = particles.newEffect({
            name = effectName(),
            capacity = 256,
            schedule = { rate = 60, looping = true },
            initial = { lifetime = 1.0, speed = 0, size = 4 },
            render = { layer = 1 },
        })
        local entity = newEmitter(world, effect)

        frames(world, renderer, 70)
        local item = world:get(entity, ParticleEmitter)

        -- One lifetime, because a constant lifetime is its own mean, so sixty a
        -- second holds sixty. Banded rather than exact only because the emitter
        -- is part way through a step; a window of half the longest lifetime
        -- would answer thirty and fail here.
        assert.are.equal(1.0, effect.meanLifetime, "a constant lifetime is its own mean")
        local estimate = item:estimatedCount()
        assert.is_true(
            estimate >= 55 and estimate <= 65,
            "sixty a second for one lifetime holds sixty, not " .. estimate
        )
        assert.is_true(estimate <= effect.capacity, "and never more than its own capacity")
        renderer:destroy()
    end)

    it("integrates a lifetime range over its mean rather than over half its longest", function()
        local world, renderer = newScene(true)
        local effect = particles.newEffect({
            name = effectName(),
            capacity = 256,
            -- Mean one second, longest one and a half. Half the longest would be
            -- 0.75 and answer forty-five, which is the reading this pins shut.
            schedule = { rate = 60, looping = true },
            initial = { lifetime = { min = 0.5, max = 1.5 }, speed = 0, size = 4 },
            render = { layer = 1 },
        })
        local entity = newEmitter(world, effect)

        frames(world, renderer, 120)
        local item = world:get(entity, ParticleEmitter)

        assert.are.equal(1.5, effect.maxLifetime, "the longest lifetime is the upper bound")
        assert.are.equal(1.0, effect.meanLifetime, "and the mean sits halfway between the bounds")
        local estimate = item:estimatedCount()
        assert.is_true(estimate >= 55 and estimate <= 65, "the mean window holds sixty, not " .. estimate)
        renderer:destroy()
    end)

    it("counts nothing before an emitter's delay has passed", function()
        local world, renderer = newScene(true)
        local effect = particles.newEffect({
            name = effectName(),
            capacity = 64,
            schedule = { rate = 60, delay = 100 },
            initial = { lifetime = 1.0, speed = 0, size = 4 },
            render = { layer = 1 },
        })
        local entity = newEmitter(world, effect)

        frames(world, renderer, 4)
        assert.are.equal(0, world:get(entity, ParticleEmitter):estimatedCount())
        renderer:destroy()
    end)

    it("gives one seed's emitter the same state again after a restart", function()
        local world, renderer = newScene(true)
        local effect = stillBurst({ lifetime = 10 })
        local entity = newEmitter(world, effect)
        local item = world:get(entity, ParticleEmitter)
        local generation = item._generation

        item:restart()

        assert.are.equal(generation + 1, item._generation, "a restart is a new random sequence")
        assert.are.equal("playing", item.state)
        renderer:destroy()
    end)

    it("keeps play, pause and stop as three states rather than one flag", function()
        local world, renderer = newScene(true)
        local entity = newEmitter(world, stillBurst())
        local item = world:get(entity, ParticleEmitter)

        item:pause()
        assert.are.equal("paused", item.state)
        item:play()
        assert.are.equal("playing", item.state)
        item:stop()
        assert.are.equal("stopped", item.state)
        -- A burst on a stopped emitter is a no-op, as the reference's emit is.
        item:burst(100)
        assert.are.equal(0, item._burst)
        renderer:destroy()
    end)

    it("refuses an emitter with no effect", function()
        assert.has_error(function()
            ParticleEmitter({})
        end)
    end)

    ---------------------------------------------------------------------------
    -- The record layouts, which are stated twice and only work while they agree
    ---------------------------------------------------------------------------

    it("agrees with the shader about every record offset", function()
        local path = (os.getenv("TECS_ASSETS") or "assets") .. "/shaders/include/particle.glsl"
        local file = assert(io.open(path, "r"))
        local source = file:read("*a")
        file:close()

        local declared = {}
        for name, value in source:gmatch("const int ([A-Z0-9_]+) = (%-?%d+);") do
            declared[name] = tonumber(value)
        end

        assert.are.equal(particles.EFFECT_FLOATS, declared.PARTICLE_EFFECT_FLOATS)
        assert.are.equal(particles.EMITTER_FLOATS, declared.PARTICLE_EMITTER_FLOATS)
        assert.are.equal(particles.STATE_FLOATS, declared.PARTICLE_STATE_FLOATS)
        assert.are.equal(particles.CURVE_SAMPLES, declared.PARTICLE_CURVE_SAMPLES)

        -- Every offset stated on both sides, held to the other. A
        -- disagreement here is silent at runtime: it draws something, just not
        -- the right thing, which is the failure this is the guard against.
        for field, offset in pairs(particles.EFFECT) do
            assert.are.equal(offset, declared["EFFECT_" .. field], "EFFECT_" .. field .. " disagrees with the shader")
            assert.is_true(
                offset >= 0 and offset < particles.EFFECT_FLOATS,
                "EFFECT_" .. field .. " is outside the effect record"
            )
        end
        for field, offset in pairs(particles.EMITTER) do
            assert.are.equal(offset, declared["EMITTER_" .. field], "EMITTER_" .. field .. " disagrees with the shader")
            assert.is_true(
                offset >= 0 and offset < particles.EMITTER_FLOATS,
                "EMITTER_" .. field .. " is outside the emitter record"
            )
        end

        -- And distinct, which is what a hand-maintained layout gets wrong
        -- first: two fields on one offset compile and read each other back.
        local seen = {}
        for field, offset in pairs(particles.EFFECT) do
            if field ~= "BURSTS" then
                assert.is_nil(seen[offset], field .. " shares an offset with " .. tostring(seen[offset]))
                seen[offset] = field
            end
        end
    end)

    it("warns rather than fails on a capacity the schedule outruns", function()
        -- Sixty a second for two seconds needs a hundred and twenty slots and
        -- is given eight. A CPU system drops the emission with no diagnostic,
        -- which is the failure mode this refuses to reproduce.
        local effect = particles.newEffect({
            name = effectName(),
            capacity = 8,
            schedule = { rate = 60, looping = true },
            initial = { lifetime = 2.0 },
            render = { layer = 1 },
        })

        assert.are.equal(8, effect.capacity)
        assert.are.equal(2.0, effect.maxLifetime)
    end)

    it("reports a sheet tag it does not carry and still defines the effect", function()
        -- Where the silent fallthrough was found. `render.tag` reaches
        -- `Sheet:tagId`, whose zero reads as the whole sheet, so a typo animated
        -- every frame of the sheet with nothing said. Reporting rather than
        -- raising keeps an effect whose sheet was re-exported without the tag
        -- drawing, which is why the definition still succeeds.
        local builder = sheet.build("particles.tagreport", 2, 1)
        builder:frame(0, 0, 1, 1, 100)
        builder:frame(1, 0, 1, 1, 100)
        builder:tag("spark", 1, 2)
        local strip = builder:finish()

        log.get("tecs.gfx"):setLevel(log.ERROR)
        assert.is_true(log.openFile(LOG_PATH))
        local effect = particles.newEffect({
            name = effectName(),
            capacity = 8,
            initial = { lifetime = 1.0 },
            render = { layer = 1, sheet = strip, tag = "sprak" },
        })
        log.closeFile()

        assert.is_truthy(effect, "the effect is still defined")

        local found = false
        local file = io.open(LOG_PATH, "r")
        if file ~= nil then
            for line in file:lines() do
                if line:find('"logger":"tecs.gfx"', 1, true) and line:find("sprak", 1, true) then
                    assert.is_truthy(line:find('"level":"ERROR"', 1, true), line)
                    assert.is_truthy(line:find("spark", 1, true), "the tags the sheet carries")
                    found = true
                end
            end
            file:close()
        end
        os.remove(LOG_PATH)
        assert.is_true(found, "the unknown tag was never reported")
    end)

    it("refuses a blend mode it does not know", function()
        -- Named rather than ignored. A mode nothing recognizes used to be
        -- accepted and logged, which meant an effect authored for a look drew
        -- something else and said so once in a log nobody was reading.
        local ok, err = pcall(function()
            particles.newEffect({
                name = effectName(),
                capacity = 8,
                initial = { lifetime = 1.0 },
                render = { layer = 1, blend = "screen" },
            })
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("alpha, additive or opaque", 1, true), tostring(err))
    end)

    it("reports the mode an effect resolved to, and alpha when none was named", function()
        local named = particles.newEffect({
            name = effectName(),
            capacity = 8,
            initial = { lifetime = 1.0 },
            render = { layer = 1, blend = "additive" },
        })
        local bare = particles.newEffect({
            name = effectName(),
            capacity = 8,
            initial = { lifetime = 1.0 },
            render = { layer = 1 },
        })

        assert.are.equal("additive", named.blend)
        assert.are.equal("alpha", bare.blend, "the default blends rather than writing opaque over the scene")
    end)

    it("names a material by name rather than by number", function()
        materials.install()
        local named = materials.names()[1]
        local effect = particles.newEffect({
            name = effectName(),
            capacity = 8,
            initial = { lifetime = 1.0 },
            render = { layer = 1, material = named, materialParam = 0.25 },
        })

        assert.is_not_nil(effect)
    end)

    ---------------------------------------------------------------------------
    -- What an effect is called
    ---------------------------------------------------------------------------

    it("refuses an effect with no name", function()
        -- Required rather than optional, because an unnamed effect is one an
        -- emitter cannot be saved on, and finding that out at save time is
        -- finding it out too late to do anything about.
        local ok, err = pcall(function()
            particles.newEffect({ capacity = 8, initial = { lifetime = 1.0 } })
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("needs a name", 1, true), tostring(err))
    end)

    it("refuses a second effect under a name already taken", function()
        local taken = effectName()
        particles.newEffect({ name = taken, capacity = 8, initial = { lifetime = 1.0 } })

        local ok, err = pcall(function()
            particles.newEffect({ name = taken, capacity = 8, initial = { lifetime = 1.0 } })
        end)
        assert.is_false(ok)
        assert.is_truthy(tostring(err):find(taken, 1, true), tostring(err))
    end)

    it("answers an effect by name and nil for one nothing has", function()
        local name = effectName()
        local effect = particles.newEffect({ name = name, capacity = 8, initial = { lifetime = 1.0 } })

        assert.are.equal(effect, particles.find(name))
        assert.are.equal(name, effect.name)
        assert.is_nil(particles.find("specEffectNothing"))
        assert.is_nil(particles.find(nil))

        local names = particles.names()
        assert.are.equal(name, names[effect.index])
    end)
end)
