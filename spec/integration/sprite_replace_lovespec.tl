--- Love2D integration suite: replacing a Sprite component in place via
--- world:set must switch the entity to the new sheet. This is a value
--- overwrite with no archetype transition, so it bypasses the lifecycle
--- observer; without explicit handling the entity keeps the old sheet's
--- texture-array assignment and keeps rendering the old image.
---
--- Run via `make test-love FILE_MATCH='sprite_replace'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/sprites"

-- Probe point for the test sprite at world (80, 60).
local PROBE <const> = {{80 / 320, 60 / 240}}

local function dominantChannel(app: fixture.App): string
    local p = fixture.probePixels(app, PROBE)[1]
    if p[1] > 0.7 and p[3] < 0.3 then return "red" end
    if p[3] > 0.7 and p[1] < 0.3 then return "blue" end
    return "none"
end

describe("sprite replacement: world:set swaps the rendered sheet", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs.gfx")
            local Transform = tecs.builtins.Transform

            local function solidSheet(name, r, g, b)
                local imageData = love.image.newImageData(16, 16)
                for y = 0, 15 do
                    for x = 0, 15 do
                        imageData:setPixel(x, y, r, g, b, 1)
                    end
                end
                return gfx.SpriteSheet.builder(love.graphics.newImage(imageData), name)
                    :frame(0, 0, 16, 16, 100000)
                    :build()
            end

            _G.redSheet = solidSheet("replace-red", 1, 0, 0)
            _G.blueSheet = solidSheet("replace-blue", 0, 0, 1)
            _G.testEntity = world:spawn(Transform(80, 60, 0, 1),
                gfx.Sprite.fromSheet(_G.redSheet))
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("renders the original sheet", function()
        local channel = fixture.eventually(fixture.callTimeout, function(): string
            local c = dominantChannel(app)
            if c == "red" then return c end
            return nil
        end)
        luassert.are.equal("red", channel)
    end)

    it("renders the new sheet after world:set replacement", function()
        fixture.runLua(app, [[
            local gfx = require("tecs.gfx")
            world:set(_G.testEntity, gfx.Sprite.fromSheet(_G.blueSheet))
            return true
        ]])
        local channel = fixture.eventually(fixture.callTimeout, function(): string
            local c = dominantChannel(app)
            if c == "blue" then return c end
            return nil
        end)
        luassert.are.equal("blue", channel,
            "entity still renders the old sheet after Sprite replacement")
    end)

    it("keeps rendering the new sheet (stable bucket assignment)", function()
        -- A stale texture-array assignment can flicker back once dirty
        -- state settles; hold the assertion across several frames.
        for _ = 1, 5 do
            luassert.are.equal("blue", dominantChannel(app))
        end
    end)
end)
