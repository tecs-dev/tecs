-- Asynchronous asset loading.
--
-- The interesting part is the hand-off: the worker decodes and returns the
-- address of a surface, and the main thread uploads and destroys it. If that
-- ownership were confused the symptom would be a use-after-free rather than a
-- wrong image, so these tests load the same file repeatedly as well as once.

-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local sdl = require("tecs.ffi.sdl3")
local filesystem = require("tecs.platform.filesystem")
local Window = require("tecs.platform.Window")
local Device = require("tecs.gpu.Device")
local assets = require("tecs.assets")

local C = sdl.C

-- Four by four: the left half red, the right half green.
local FIXTURE = "spec/fixtures/split.png"

describe("assets", function()
    local window, device

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = Window.newWindow({ title = "assets", width = 64, height = 64 })
        device = Device.create(window, { debug = true })
        assets.install()
    end)

    teardown(function()
        assets.shutdown()
        if device then
            device:destroy()
        end
        if window then
            window:destroy()
        end
        C.SDL_Quit()
    end)

    it("returns a handle immediately and resolves it later", function()
        local handle = assets.loadImage(FIXTURE)
        assert.are.equal("loading", handle.status, "loading must not block the caller")

        assets.waitAll()
        assert.are.equal("ready", handle.status)
        assert.is_not_nil(handle.pixels)
        assert.are.equal(4, handle.width)
        assert.are.equal(4, handle.height)
        handle:release()
    end)

    it("decodes the actual pixels, in the right order", function()
        -- The fixture is red on the left, green on the right. Reading the
        -- decoded bytes directly catches a channel swap and a row order flip,
        -- which a size assertion cannot.
        local ffi = require("ffi")
        local handle = assets.loadImage(FIXTURE)
        assets.waitAll()

        local bytes = ffi.cast("uint8_t *", handle.pixels)
        assert.are.equal(255, bytes[0], "left half is red")
        assert.are.equal(0, bytes[1])
        assert.are.equal(0, bytes[12], "right half is green")
        assert.are.equal(255, bytes[13])
        handle:release()
    end)

    it("reports a missing file as failed rather than raising", function()
        local handle = assets.loadImage("spec/fixtures/does-not-exist.png")
        assets.waitAll()

        assert.are.equal("failed", handle.status)
        assert.is_truthy(handle.error:find("cannot decode"))
        assert.is_nil(handle.pixels)
    end)

    it("loads several files concurrently", function()
        -- Distinct paths, so nothing here shares a decode: what is being
        -- checked is that five tasks in the queue at once each come back to
        -- the handle that asked for them, images and sounds together.
        local good = assets.loadImage(FIXTURE)
        local missingA = assets.loadImage("spec/fixtures/missing-a.png")
        local missingB = assets.loadImage("spec/fixtures/missing-b.png")
        local blip = assets.loadSound("spec/fixtures/blip.wav", "resident", 0)
        local absent = assets.loadSound("spec/fixtures/missing.wav", "auto", 0)
        assert.are.equal(5, assets.pending())

        assets.waitAll()
        assert.are.equal(0, assets.pending())
        assert.are.equal("ready", good.status)
        assert.is_not_nil(good.pixels)
        assert.are.equal("failed", missingA.status)
        assert.are.equal("failed", missingB.status)
        assert.are.equal("ready", blip.status)
        assert.are.equal("failed", absent.status)

        good:release()
        blip:release()
    end)

    it("gives each load its own decoded buffer", function()
        -- Surfaces are handed over by address and destroyed by the receiver.
        -- Two loads sharing pixels would mean the ownership transfer went
        -- wrong somewhere, and releasing one would corrupt the other. The
        -- first is resolved before the second is asked for, so this is two
        -- decodes rather than two callers of one.
        local first = assets.loadImage(FIXTURE)
        assets.waitAll()
        local second = assets.loadImage(FIXTURE)
        assets.waitAll()

        assert.is_not_nil(first.pixels)
        assert.is_not_nil(second.pixels)
        assert.are_not.equal(tostring(first.pixels), tostring(second.pixels))

        -- Releasing one leaves the other's pixels readable, which is the
        -- property a confused hand-off would break.
        first:release()
        local ffi = require("ffi")
        local bytes = ffi.cast("uint8_t *", second.pixels)
        assert.are.equal(255, bytes[0])
        second:release()
    end)

    it("shares one decode between loads of a path already in flight", function()
        local first = assets.loadImage(FIXTURE)
        local second = assets.loadImage(FIXTURE)
        local third = assets.loadImage(FIXTURE)
        assert.are.equal(1, assets.pending(), "a path already being decoded must not be queued again")
        assert.are.equal(first, second)
        assert.are.equal(first, third)

        assets.waitAll()
        assert.are.equal("ready", first.status)

        -- Every caller holds it, so it is alive until the last one lets go.
        first:release()
        assert.are.equal("ready", first.status)
        second:release()
        assert.are.equal("ready", first.status)
        third:release()
        assert.are.equal("released", first.status)
        assert.is_nil(first.pixels)
    end)

    it("decodes again once an earlier load has resolved", function()
        local first = assets.loadImage(FIXTURE)
        assets.waitAll()
        first:release()

        -- Nothing here is a cache, so a released handle is never handed back.
        local second = assets.loadImage(FIXTURE)
        assert.are_not.equal(first, second)
        assets.waitAll()
        assert.are.equal("ready", second.status)
        second:release()
    end)

    it("reports a released handle as released", function()
        local handle = assets.loadImage(FIXTURE)
        assets.waitAll()
        handle:release()

        assert.are.equal("released", handle.status, "a released handle must say so rather than look like a nil decode")
        assert.is_nil(handle.pixels)

        -- Terminal, and releasing twice does not free twice.
        handle:release()
        assert.are.equal("released", handle.status)
    end)

    it("destroys what arrives for a load released while in flight", function()
        local handle = assets.loadImage(FIXTURE)
        handle:release()
        assert.are.equal("released", handle.status)

        assets.waitAll()
        assert.are.equal(0, assets.pending())
        assert.are.equal("released", handle.status)
        assert.is_nil(handle.pixels)
    end)

    it("reads a file's bytes, whatever they are", function()
        -- A PNG rather than a text file on purpose: the result has to carry
        -- its own length, or every binary sidecar read through here would be
        -- cut at the first NUL and only the parser would find out.
        local bytes = filesystem.read(FIXTURE)
        assert.is_string(bytes)
        assert.are.equal("PNG", bytes:sub(2, 4))
        assert.is_truthy(bytes:find("\0", 1, true), "the fixture has NULs in it")

        local file = assert(io.open(FIXTURE, "rb"))
        local whole = file:read("*a")
        file:close()
        assert.are.equal(#whole, #bytes)
        assert.are.equal(whole, bytes)
    end)

    it("answers nil for a path with no file", function()
        assert.is_nil(filesystem.read("spec/fixtures/does-not-exist.json"))
    end)

    it("reports nothing to do when idle", function()
        assert.are.equal(0, assets.pending())
        assert.are.equal(0, assets.update())
    end)

    -- Installing twice used to spawn a second worker over the first, which
    -- left a thread and both its channels with nothing reading them. The load
    -- already queued is what makes that visible: its answer comes back on the
    -- channel that was dropped, so it never resolves however long it is waited
    -- for.
    it("installs once however many times it is asked", function()
        local handle = assets.loadImage(FIXTURE)
        assets.install()

        assets.waitAll(2000)
        assert.are.equal("ready", handle.status, "the decode answered a worker nobody was reading")
        handle:release()
    end)

    -- The wait spends a budget of time, not a count of pumps. A pump returns
    -- as soon as one message has arrived, so subtracting its nominal 16 ms
    -- whatever it actually cost turns the budget into a message count: these
    -- sixty answers arrive in a few milliseconds together, and a "400 ms" wait
    -- spent by subtraction gives up after twenty-five of them.
    it("waits for a budget of time rather than a count of pumps", function()
        local handles = {}
        for index = 1, 60 do
            handles[index] = assets.loadImage(("spec/fixtures/missing-%d.png"):format(index))
        end
        assert.are.equal(60, assets.pending())

        local before = tonumber(C.SDL_GetTicks())
        assets.waitAll(400)
        local elapsed = tonumber(C.SDL_GetTicks()) - before

        assert.are.equal(
            0,
            assets.pending(),
            ("the wait gave up after %d ms with loads still in flight"):format(elapsed)
        )
        for index = 1, 60 do
            assert.are.equal("failed", handles[index].status)
        end
    end)

    it("records what it read, and under what kind", function()
        assets.loadImage(FIXTURE):release()
        filesystem.read(FIXTURE)

        -- The kind is the one it was first asked for under, so reading an
        -- image's bytes afterwards does not turn it into a document.
        local loaded = filesystem.loaded()
        assert.are.equal("image", loaded[FIXTURE])
        assert.are.equal("document", loaded["spec/fixtures/test_material.glsl"] or "document")
        assert.is_nil(loaded["spec/fixtures/does-not-exist.json"], "a path with no file was not read")
    end)
end)

-- Awaiting a set of handles. Sound and text had each grown this list
-- separately; what is asserted here is the shape they now share, which is that
-- a batch answers how many are outstanding, hands each finished load to one
-- callback with the caller's own value beside it, and can be waited on.
describe("an asset batch", function()
    local window, device

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = Window.newWindow({ title = "batch", width = 64, height = 64 })
        device = Device.create(window, { debug = true })
        assets.install()
    end)

    teardown(function()
        assets.shutdown()
        if device then
            device:destroy()
        end
        if window then
            window:destroy()
        end
        C.SDL_Quit()
    end)

    it("counts what is outstanding and resolves it once", function()
        local resolved = {}
        local batch = assets.newBatch(function(key, handle)
            resolved[#resolved + 1] = { key = key, status = handle.status }
            handle:release()
        end)

        batch:add(assets.loadImage(FIXTURE), "first")
        batch:add(assets.loadImage("spec/fixtures/missing.png"), "second")
        assert.are.equal(2, batch:pending())
        assert.are.equal(0, #resolved, "a load must not resolve before it has finished")

        assert.are.equal(2, batch:wait())
        assert.are.equal(0, batch:pending())
        assert.are.same({ key = "first", status = "ready" }, resolved[1])
        assert.are.same({ key = "second", status = "failed" }, resolved[2], "a failure is a result, not a silence")

        -- Dropped once resolved, so a later drain has nothing to hand over
        -- a second time.
        assert.are.equal(0, batch:resolve())
        assert.are.equal(2, #resolved)
    end)

    it("keeps what is still in flight and its key with it", function()
        local resolved = {}
        local batch = assets.newBatch(function(key, handle)
            resolved[#resolved + 1] = key
            handle:release()
        end)

        -- One drain has to have something to resolve and something to keep,
        -- and both halves of that are pinned rather than timed. A real load
        -- left outstanding is a race the batch always loses eventually: a
        -- missing file fails as fast as the worker can look, so whether it is
        -- still in flight by the time the drain runs is the scheduler's to
        -- decide. Shutting the worker down is the documented way to hold one
        -- at "loading" for good, so that is what the kept entry is.
        local waiting = assets.loadImage("spec/fixtures/missing-later.png")
        assets.shutdown()
        assets.install()

        local done = assets.loadImage(FIXTURE)
        assets.waitAll()
        batch:add(done, "done")
        batch:add(waiting, "waiting")
        assert.are.equal("loading", waiting.status, "the dropped load must not have been answered")

        assert.are.equal(1, batch:resolve())
        assert.are.same({ "done" }, resolved)
        assert.are.equal(1, batch:pending())

        -- Releasing is the other way off "loading", and it needs no worker, so
        -- the drain that hands the kept entry over is as fixed as the one that
        -- kept it. What is being read here is the key, which compaction has to
        -- have moved down beside its handle.
        waiting:release()
        assert.are.equal(1, batch:resolve())
        assert.are.same({ "done", "waiting" }, resolved, "the surviving entry kept the wrong key")
        assert.are.equal(0, batch:pending())
    end)

    it("drains the worker itself", function()
        local resolved = 0
        local batch = assets.newBatch(function(_, handle)
            resolved = resolved + 1
            handle:release()
        end)
        batch:add(assets.loadImage(FIXTURE), true)

        -- Nothing else calls assets.update here, which is the point: a
        -- subsystem polling only its own batch still sees its loads finish.
        -- Driven to a condition rather than to a sleep, and bounded so a
        -- worker that never answers fails rather than hangs.
        local deadline = tonumber(C.SDL_GetTicks()) + 5000
        while resolved == 0 and tonumber(C.SDL_GetTicks()) < deadline do
            batch:resolve()
        end
        assert.are.equal(1, resolved)
    end)

    it("needs somewhere to hand a finished load", function()
        assert.has_error(function()
            assets.newBatch(nil)
        end)
    end)
end)
