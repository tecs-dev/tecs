-- What a throw part way through a frame leaves behind.
--
-- Everything a frame holds is held across a call that can fail: a render or
-- compute pass is open between its begin and its end, a command buffer holds a
-- slot in a finite pool and, once a swapchain texture has been acquired on it,
-- the texture the display is waiting for, and a query loop holds the world in
-- deferred mutation for as long as it is iterating. Lua has no finally, so
-- none of that is released by the code that took it when the code between the
-- two lines throws.
--
-- So these tests inject the throw rather than wait for one, and assert the
-- invariant each case used to break: the pass was ended, the frame was
-- resolved the one way SDL allows, the world is applying mutations again, and
-- a frame after the failure still draws. "It did not crash" is not one of the
-- assertions here; a leak does not crash, which is the whole problem.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local sdl = require("tecs.ffi.sdl3")
local loader = require("tecs.ffi.loader")
local Window = require("tecs.platform.Window")
local Device = require("tecs.gpu.Device")
local Texture = require("tecs.gpu.Texture")
local Frame = require("tecs.gpu.Frame")
local PassGraph = require("tecs.gpu.PassGraph")
local ComputePass = require("tecs.gpu.ComputePass")
local passscope = require("tecs.gpu.passscope")
local Renderer = require("tecs.Renderer")
local components = require("tecs.components")
local builtins = require("tecs.ecs").builtins

local C = sdl.C
local FORMAT = 4 -- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local SIZE = 64

local Transform = builtins.Transform
local Tint = components.Tint
local Renderable = components.Renderable

describe("exception safety", function()
    local window, device, screen

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = Window.create({ title = "exceptions", width = SIZE, height = SIZE })
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

    -- A frame over the offscreen target rather than the swapchain. `acquired`
    -- is true either way, which is what these tests want: it is the state that
    -- decides how a broken frame is resolved, and asserting on it needs a
    -- frame that has it rather than a window that happens to be visible.
    local function newFrame()
        local commandBuffer = C.SDL_AcquireGPUCommandBuffer(device.handle)
        return Frame.wrap(commandBuffer, screen.handle, SIZE, SIZE)
    end

    local function newScene()
        local world = tecs.ecs.newWorld()
        local renderer = Renderer.newRenderer(device.handle, FORMAT, {
            ambient = { 1.0, 1.0, 1.0 },
            capacity = 4096,
        })
        renderer:install(world)
        return world, renderer
    end

    -- One frame through a renderer, onto the offscreen target.
    local function drawFrame(world, renderer)
        world:update(1 / 60)
        local frame = newFrame()
        renderer:render(frame)
        frame:submit()
        return frame
    end

    ---------------------------------------------------------------------------
    -- The frame itself
    ---------------------------------------------------------------------------

    it("refuses to cancel a frame that acquired a swapchain texture", function()
        local frame = newFrame()

        -- SDL documents cancelling after an acquisition as an error, so the
        -- old spelling of "put this frame back" was invalid on essentially
        -- every frame that existed. It raises rather than making the call.
        local ok, reason = pcall(frame.cancel, frame)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("cannot be cancelled", 1, true))
        assert.are.equal("recording", frame.state)

        assert.is_nil(frame:abandon())
        assert.are.equal("submitted", frame.state)
    end)

    it("cancels a frame that acquired nothing", function()
        local commandBuffer = C.SDL_AcquireGPUCommandBuffer(device.handle)
        local frame = Frame.wrap(commandBuffer, nil, SIZE, SIZE)

        assert.is_false(frame.acquired)
        assert.is_nil(frame:abandon())
        assert.are.equal("cancelled", frame.state)
        assert.is_nil(frame.commandBuffer)
    end)

    it("resolves a frame once, however many times it is abandoned", function()
        local frame = newFrame()
        frame:submit()
        assert.are.equal("submitted", frame.state)

        -- Recovery cannot know how far a frame got, so abandoning a resolved
        -- one has to be free rather than a second submission of a command
        -- buffer SDL says must not be referenced again.
        assert.is_nil(frame:abandon())
        assert.is_nil(frame:abandon())
        assert.are.equal("submitted", frame.state)
    end)

    ---------------------------------------------------------------------------
    -- A render pass whose body throws
    ---------------------------------------------------------------------------

    it("ends a render pass whose body threw, and draws the next frame", function()
        local graph = PassGraph.create(device.handle, FORMAT)
        local openInside = -1
        local explode = true
        graph:pass({
            name = "spec.throws",
            execute = function()
                -- Read from inside the pass, so the test is asserting that a
                -- pass which was genuinely open got closed rather than that
                -- one was never begun.
                openInside = passscope.openCount()
                if explode then
                    error("spec: the render pass body threw")
                end
            end,
        })

        local before = passscope.openCount()
        local frame = newFrame()
        local ok, reason = pcall(graph.execute, graph, frame)

        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("the render pass body threw", 1, true))
        assert.are.equal(before + 1, openInside, "the pass was open when the body ran")
        assert.are.equal(before + 1, passscope.openCount(), "the throw left it open")

        assert.is_nil(frame:abandon())
        assert.are.equal(before, passscope.openCount(), "recovery did not end the pass")
        assert.are.equal("submitted", frame.state)

        -- The next frame runs the same graph over the same targets. A pass
        -- left open would take this one down with it, and a command buffer
        -- left unresolved would eventually take the pool.
        explode = false
        local next_ = newFrame()
        graph:execute(next_)
        next_:submit()
        assert.are.equal("submitted", next_.state)
        assert.are.equal(before, passscope.openCount())

        graph:destroy()
    end)

    ---------------------------------------------------------------------------
    -- A compute stage whose record throws
    ---------------------------------------------------------------------------

    it("ends a compute pass a stage left open, and draws the next frame", function()
        local world, renderer = newScene()
        world:spawn(Transform(SIZE / 2, SIZE / 2, 0, 1, 0, SIZE * 2, SIZE * 2), Tint(1, 0, 0, 1), Renderable())

        local explode = true
        local openInside = -1
        renderer:addComputeStage({
            active = function()
                return true
            end,
            record = function(_, frame, instances)
                if not explode then
                    return
                end
                -- A real pass on the frame's own command buffer, so what is
                -- asserted below is a pass SDL has actually begun.
                ComputePass.begin(frame.commandBuffer, { instances.handle })
                openInside = passscope.openCount()
                error("spec: the compute stage threw")
            end,
            destroy = function() end,
        })

        local before = passscope.openCount()
        world:update(1 / 60)
        local frame = newFrame()
        local ok = pcall(renderer.render, renderer, frame)

        assert.is_false(ok)
        assert.are.equal(before + 1, openInside)
        assert.are.equal(before + 1, passscope.openCount())

        assert.is_nil(frame:abandon())
        assert.are.equal(before, passscope.openCount())
        assert.are.equal("submitted", frame.state)

        explode = false
        local next_ = drawFrame(world, renderer)
        assert.are.equal("submitted", next_.state)
        assert.are.equal(before, passscope.openCount())

        renderer:destroy()
    end)

    ---------------------------------------------------------------------------
    -- An instance producer whose write throws
    ---------------------------------------------------------------------------

    it("leaves the world applying mutations after a producer threw", function()
        local world, renderer = newScene()
        local explode = true
        renderer:addProducer({
            count = function()
                return 4
            end,
            takeDirty = function()
                return explode and { 1, 4 } or {}
            end,
            write = function()
                error("spec: the instance producer threw")
            end,
        })

        local before = passscope.openCount()
        -- Extraction runs in RenderFirst, so this throws out of the update
        -- rather than out of the render, and no frame has been acquired yet.
        local ok, reason = pcall(world.update, world, 1 / 60)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("the instance producer threw", 1, true))
        assert.are.equal(before, passscope.openCount(), "a producer opens no pass")

        world:unwind()
        assert.are.equal(0, world._scopeDepth)

        explode = false
        local frame = drawFrame(world, renderer)
        assert.are.equal("submitted", frame.state)

        renderer:destroy()
    end)

    ---------------------------------------------------------------------------
    -- A system that throws inside a query loop
    ---------------------------------------------------------------------------

    it("closes the scope a system threw out of, so later spawns apply", function()
        local world = tecs.ecs.newWorld()
        world:spawn(Tint(1, 0, 0, 1))

        local query = world:query({ name = "spec.Tinted", include = { Tint } })
        local explode = true
        world:addSystem({
            name = "spec.ThrowsInIter",
            phase = tecs.ecs.phases.Update,
            run = function()
                for _ in query:iter() do
                    if explode then
                        error("spec: the system threw mid-iteration")
                    end
                end
            end,
        })

        local ok = pcall(world.update, world, 1 / 60)
        assert.is_false(ok)
        assert.is_true(world._scopeDepth > 0, "the loop's scope is what was left open")

        -- The bug this covers is silence, not a crash. A world left deferred
        -- stages every later mutation and reports nothing, so the entity below
        -- would exist as far as the caller is concerned and be in no
        -- archetype until something happened to drain.
        world:unwind()
        assert.are.equal(0, world._scopeDepth)
        local spawned = world:spawn(Tint(0, 1, 0, 1))
        assert.is_true(world:isAlive(spawned), "the spawn was staged rather than applied")

        -- And the next update runs a whole frame's worth of systems against an
        -- applied world, without the caller having unwound anything.
        explode = false
        world:update(1 / 60)
        assert.are.equal(0, world._scopeDepth)
        assert.are.equal(2, query:count())
    end)

    it("unwinds every scope on the next update, not one level of them", function()
        local world = tecs.ecs.newWorld()
        world:spawn(Tint(1, 0, 0, 1))

        local outer = world:query({ name = "spec.Outer", include = { Tint } })
        local inner = world:query({ name = "spec.Inner", include = { Tint } })
        local explode = true
        world:addSystem({
            name = "spec.ThrowsInNestedIter",
            phase = tecs.ecs.phases.Update,
            run = function()
                for _ in outer:iter() do
                    for _ in inner:iter() do
                        if explode then
                            error("spec: the system threw two loops deep")
                        end
                    end
                end
            end,
        })

        assert.is_false(pcall(world.update, world, 1 / 60))
        -- Two scopes, so decrementing one would leave the world deferred for
        -- the whole of the next update and every one after it.
        assert.is_true(world._scopeDepth >= 2)

        explode = false
        world:update(1 / 60)
        assert.are.equal(0, world._scopeDepth)

        local spawned = world:spawn(Tint(0, 1, 0, 1))
        assert.is_true(world:isAlive(spawned))
    end)

    it("survives a cursor closed after its scope was unwound", function()
        local world = tecs.ecs.newWorld()
        world:spawn(Tint(1, 0, 0, 1))
        local query = world:query({ name = "spec.Stale", include = { Tint } })

        local cursor = query:cursor()
        for _ in cursor:iter() do
            break
        end
        assert.is_true(world._scopeDepth > 0)

        -- Recovery closes scopes, not cursors: it has no way to find the ones
        -- a throw left holding one. So a cursor closed afterwards is giving
        -- back a scope this world no longer has.
        world:unwind()
        assert.are.equal(0, world._scopeDepth)
        cursor:close()
        assert.are.equal(0, world._scopeDepth, "the stale close drove the depth negative")

        -- A negative depth reads as "not deferred" one level too far, so the
        -- next `defer` would apply instantly rather than stage.
        world:defer()
        local spawned = world:spawn(Tint(0, 1, 0, 1))
        assert.is_false(world:isAlive(spawned), "the defer did not defer")
        world:commit()
        assert.is_true(world:isAlive(spawned))
    end)

    ---------------------------------------------------------------------------
    -- The staging slot a throw would have left the next extraction writing into
    ---------------------------------------------------------------------------

    -- Recovery submits whatever the frame had already encoded, which for a
    -- throw after the flush includes the copies out of the staging slot the
    -- extraction wrote. The rotation is what points the next extraction at the
    -- other slot, so a rotation the throw skipped leaves the next extraction
    -- writing into memory the GPU is copying out of. Unreachable until a
    -- crashed loop could render again, and reachable now that it can.
    it("rotates the staging slot even when the recording throws", function()
        local world, renderer = newScene()
        world:spawn(Transform(SIZE / 2, SIZE / 2, 0, 1, 0, 16, 16), Tint(1, 0, 0, 1), Renderable())

        local backend = renderer._backend
        local consume = backend.consume
        backend.consume = function()
            error("spec: the recording threw")
        end

        world:update(1 / 60)
        local wrote = renderer._packet.slot
        local frame = newFrame()
        local ok, reason = pcall(renderer.render, renderer, frame)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("the recording threw", 1, true))
        assert.is_nil(frame:abandon())

        assert.are_not.equal(wrote, renderer._slot, "the next extraction writes the slot that frame read")

        -- And the extractor was actually repointed, rather than the renderer
        -- having moved a number nothing consults.
        backend.consume = consume
        world:update(1 / 60)
        assert.are_not.equal(wrote, renderer._packet.slot)

        local next_ = drawFrame(world, renderer)
        assert.are.equal("submitted", next_.state)

        renderer:destroy()
    end)

    ---------------------------------------------------------------------------
    -- A pass left open on one command buffer does not follow the next one
    ---------------------------------------------------------------------------

    it("tracks an open pass per command buffer", function()
        local before = passscope.openCount()
        local first = newFrame()
        local second = newFrame()

        local pass = ComputePass.begin(first.commandBuffer, {})
        assert.are.equal(before + 1, passscope.openCount())

        -- Nothing is open on the second, so resolving it neither ends the
        -- first's pass nor refuses to run.
        assert.is_nil(second:abandon())
        assert.are.equal(before + 1, passscope.openCount())

        pass:finish()
        assert.are.equal(before, passscope.openCount())
        assert.is_nil(first:abandon())
    end)
end)
