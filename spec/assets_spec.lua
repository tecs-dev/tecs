-- Asynchronous asset loading.
--
-- The interesting part is the hand-off: the worker decodes and returns the
-- address of a surface, and the main thread uploads and destroys it. If that
-- ownership were confused the symptom would be a use-after-free rather than a
-- wrong image, so these tests load the same file repeatedly as well as once.

-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS2D_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. "../tecs/build/?.lua;../tecs/build/?/init.lua;" .. package.path

local sdl = require("tecs2d.ffi.sdl3")
local Window = require("tecs2d.platform.Window")
local Device = require("tecs2d.gpu.Device")
local assets = require("tecs2d.assets")

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

    it("loads several images concurrently", function()
        local handles = {}
        for index = 1, 6 do
            handles[index] = assets.loadImage(FIXTURE)
        end
        assert.are.equal(6, assets.pending())

        assets.waitAll()
        assert.are.equal(0, assets.pending())
        for index = 1, 6 do
            assert.are.equal("ready", handles[index].status,
                "handle " .. index .. " never resolved")
            assert.is_not_nil(handles[index].pixels)
            handles[index]:release()
        end
    end)

    it("gives each load its own decoded buffer", function()
        -- Surfaces are handed over by address and destroyed by the receiver.
        -- Two loads sharing pixels would mean the ownership transfer went
        -- wrong somewhere, and releasing one would corrupt the other.
        local first = assets.loadImage(FIXTURE)
        local second = assets.loadImage(FIXTURE)
        assets.waitAll()

        assert.is_not_nil(first.pixels)
        assert.is_not_nil(second.pixels)
        assert.are_not.equal(tostring(first.pixels), tostring(second.pixels))
        first:release()
        second:release()
    end)

    it("reports nothing to do when idle", function()
        assert.are.equal(0, assets.pending())
        assert.are.equal(0, assets.update())
    end)
end)
