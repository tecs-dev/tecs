-- Asynchronous asset loading.
--
-- The interesting part is the hand-off: the worker decodes and returns the
-- address of a surface, and the main thread uploads and destroys it. If that
-- ownership were confused the symptom would be a use-after-free rather than a
-- wrong image, so these tests load the same file repeatedly as well as once.

-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. package.path

local sdl = require("tecs.ffi.sdl3")
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
        window = Window.create({ title = "assets", width = 64, height = 64 })
        device = Device.create(window, { debug = true })
        assets.install()
    end)

    teardown(function()
        assets.shutdown()
        if device then device:destroy() end
        if window then window:destroy() end
        C.SDL_Quit()
    end)

    it("returns a handle immediately and resolves it later", function()
        local handle = assets.loadImage(FIXTURE)
        assert.are.equal("loading", handle.status,
            "loading must not block the caller")

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
        assert.are.equal(1, assets.pending(),
            "a path already being decoded must not be queued again")
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

        assert.are.equal("released", handle.status,
            "a released handle must say so rather than look like a nil decode")
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
        local bytes = assets.read(FIXTURE)
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
        assert.is_nil(assets.read("spec/fixtures/does-not-exist.json"))
    end)

    it("reports nothing to do when idle", function()
        assert.are.equal(0, assets.pending())
        assert.are.equal(0, assets.update())
    end)
end)
