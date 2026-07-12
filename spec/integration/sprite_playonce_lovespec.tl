--- Love2D integration suite: sprite pauseAtEnd must clamp the animation on
--- the GPU. The fixture sprite alternates a red frame and a blue frame
--- (150 ms each); after pauseAtEnd the visual must settle on the LAST
--- frame (blue) and never show red again.
---
--- Run via `make test-love FILE_MATCH='sprite_playonce'`.

require("busted")
local luassert <const> = require("luassert")
local socket <const> = require("socket")
local fixture <const> = require("tecs2d.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/sprites"

local CENTER <const> = {{0.5, 0.5}}
local sleep <const> = socket.sleep as function(number)

--- Classify the probed center pixel: "red", "blue", or "other".
local function centerFrame(app: fixture.App): string
    local p = fixture.probePixels(app, CENTER)[1]
    if p[1] > 0.8 and p[3] < 0.2 then return "red" end
    if p[3] > 0.8 and p[1] < 0.2 then return "blue" end
    return "other"
end

describe("sprite play-once: pauseAtEnd clamps on the GPU", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("animates through both frames while playing", function()
        local seen: {string: boolean} = {}
        local deadline = socket.gettime() + 3
        while socket.gettime() < deadline do
            seen[centerFrame(app)] = true
            if seen["red"] and seen["blue"] then break end
            sleep(0.04)
        end
        luassert.is_true(seen["red"], "never saw the red frame while animating")
        luassert.is_true(seen["blue"], "never saw the blue frame while animating")
    end)

    it("pauseAtEnd holds the last frame instead of looping", function()
        fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            world:get(_G.tecsTestSprite, gfx.Sprite):pauseAtEnd()
            return true
        ]])

        -- Let the current cycle finish (2 x 150 ms frames), then the sprite
        -- must hold the last frame (blue) across several animation periods.
        sleep(0.5)
        for sample = 1, 8 do
            local frame = centerFrame(app)
            luassert.are.equal("blue", frame,
                "sample " .. tostring(sample) .. ": expected the held last frame, got " .. frame)
            sleep(0.08)
        end
    end)
end)
