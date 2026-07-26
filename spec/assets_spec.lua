-- Asynchronous asset loading.
--
-- The interesting part is the hand-off: the worker decodes and returns the
-- address of a surface, and the main thread uploads and destroys it. If that
-- ownership were confused the symptom would be a use-after-free rather than a
-- wrong image, so these tests load the same file repeatedly as well as once.

package.path = "build/?.lua;build/?/init.lua;"
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
        assets.install(device.handle)
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
        assert.is_not_nil(handle.texture)
        assert.are.equal(4, handle.texture.width)
        assert.are.equal(4, handle.texture.height)
    end)

    it("decodes the actual pixels, in the right order", function()
        -- The fixture is red on the left, green on the right. Checking both
        -- halves catches a channel swap and a row order flip, which a size
        -- assertion cannot.
        local handle = assets.loadImage(FIXTURE)
        assets.waitAll()

        local texture = handle.texture
        local pixels = texture:readback()
        local left = texture:getPixel(pixels, 0, 0)
        local right = texture:getPixel(pixels, 3, 0)

        assert.are.equal(255, left.r, "left half is red")
        assert.are.equal(0, left.g)
        assert.are.equal(0, right.r, "right half is green")
        assert.are.equal(255, right.g)
    end)

    it("reports a missing file as failed rather than raising", function()
        local handle = assets.loadImage("spec/fixtures/does-not-exist.png")
        assets.waitAll()

        assert.are.equal("failed", handle.status)
        assert.is_truthy(handle.error:find("cannot decode"))
        assert.is_nil(handle.texture)
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
            assert.is_not_nil(handles[index].texture)
        end
    end)

    it("gives each load its own texture", function()
        -- Surfaces are handed over by address and destroyed by the receiver.
        -- Two loads sharing a texture would mean the ownership transfer went
        -- wrong somewhere.
        local first = assets.loadImage(FIXTURE)
        local second = assets.loadImage(FIXTURE)
        assets.waitAll()

        assert.is_not_nil(first.texture)
        assert.is_not_nil(second.texture)
        assert.are_not.equal(first.texture, second.texture)
    end)

    it("reports nothing to do when idle", function()
        assert.are.equal(0, assets.pending())
        assert.are.equal(0, assets.update())
    end)
end)
