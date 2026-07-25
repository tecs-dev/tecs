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

    it("does not dirty unrelated Sprite archetypes while a callback is pending", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            local ProbeTag = tecs.newComponent({
                name = "SpritePlayOnceDirtyProbe",
                container = {},
            })
            world:spawn(
                Transform(32, 32, 0, 1),
                gfx.Sprite.fromSheet(_G.tecsTestSheet, "play"),
                ProbeTag
            )

            local probeQuery = world:query({
                name = "test.SpritePlayOnceDirtyProbe",
                include = {gfx.Sprite, ProbeTag},
            })
            _G.tecsPlayOnceDirty = {
                stage = "settling",
                samples = 0,
                dirtySamples = 0,
                complete = false,
            }
            world:addSystem({
                name = "test.SpritePlayOnceDirtyRecorder",
                phase = tecs.phases.Update,
                after = {"sprite.PlayOnce"},
                run = function()
                    local rec = _G.tecsPlayOnceDirty
                    local probeDirty = false
                    for arch, len in probeQuery:iter() do
                        if len > 0 and arch:isComponentDirty(gfx.Sprite) then
                            probeDirty = true
                        end
                    end

                    if rec.stage == "settling" then
                        if not probeDirty then
                            world:get(_G.tecsTestSprite, gfx.Sprite):playOnce(
                                "play",
                                function()
                                    rec.complete = true
                                end
                            )
                            rec.stage = "pending"
                        end
                    elseif rec.stage == "pending" and not rec.complete then
                        rec.samples = rec.samples + 1
                        if probeDirty then
                            rec.dirtySamples = rec.dirtySamples + 1
                        end
                    end
                end,
            })
            return true
        ]])

        local samples = 0
        local dirtySamples = -1
        local complete = false
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            local result = fixture.runLua(app, [[
                local rec = _G.tecsPlayOnceDirty
                return rec.samples, rec.dirtySamples, rec.complete
            ]])
            samples = tonumber(result[1]) or 0
            dirtySamples = tonumber(result[2]) or -1
            complete = result[3] == "true"
            if complete then return true end
            return nil
        end)

        luassert.is_true(ok == true, "playOnce callback did not complete")
        luassert.is_true(samples > 0, "dirty recorder did not observe a pending frame")
        luassert.are.equal(0, dirtySamples,
            "pending callback dirtied an unrelated Sprite archetype")
    end)
end)
