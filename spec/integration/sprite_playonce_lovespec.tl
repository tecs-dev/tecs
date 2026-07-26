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

    it("does not dirty unrelated Sprite archetypes while a pause is pending", function()
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
            -- Completion is an event now, so the observer is what records it.
            world:observe(0, gfx.AnimationComplete, function(e)
                if e.entity == _G.tecsTestSprite then
                    _G.tecsPlayOnceDirty.complete = true
                end
            end)
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
                            world:get(_G.tecsTestSprite, gfx.Sprite):playOnce("play")
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

        luassert.is_true(ok == true, "playOnce never completed")
        luassert.is_true(samples > 0, "dirty recorder did not observe a pending frame")
        luassert.are.equal(0, dirtySamples,
            "pending callback dirtied an unrelated Sprite archetype")
    end)
    -- Fails against a build where completion is a Lua callback: nothing in a
    -- snapshot can carry a closure, so a save taken mid-animation comes back
    -- with the correlation gone and the completion never fires.
    --
    -- The fixture's own sheet is built from an in-memory image, and Sprite
    -- deliberately refuses to serialize a sheet with no durable path, so this
    -- one loads a real sheet off disk instead.
    it("still completes an animation that was saved mid-play", function()
        fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            _G.tecsMidSaveSheet = gfx.SpriteSheet.fromFile("assets/running.png")
            _G.tecsMidSave = world:spawn(
                gfx.Sprite.fromSheet(_G.tecsMidSaveSheet, "run"))
            _G.tecsMidSaveDone = false
            world:observe(0, gfx.AnimationComplete, function(e)
                if e.entity == _G.tecsMidSave then _G.tecsMidSaveDone = true end
            end)
            return true
        ]])

        -- The instance is created by the sprite sync, so the tag cannot start
        -- playing until a frame has run.
        local ready = fixture.eventually(fixture.callTimeout, function(): boolean
            local values = fixture.runLua(app, [[
                local gfx = require("tecs2d.gfx")
                local s = world:get(_G.tecsMidSave, gfx.Sprite)
                return s ~= nil and s:getTag() ~= ""
            ]])
            if values[1] == "true" then return true end
            return nil
        end)
        luassert.is_true(ready == true, "the sprite never synced an instance")

        -- Play and save in one call, so the snapshot is certainly taken
        -- before the animation can reach its last frame.
        fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            world:get(_G.tecsMidSave, gfx.Sprite):playOnce("run")
            _G.tecsMidSaveBuffer = world:saveSnapshot().buffer
            return true
        ]])

        -- Restore it. The completion had not fired when that was written, so
        -- what comes back has to carry it.
        fixture.runLua(app, [[
            world:loadSnapshot(_G.tecsMidSaveBuffer)
            _G.tecsMidSaveDone = false
            return true
        ]])

        local fired = fixture.eventually(fixture.callTimeout, function(): boolean
            local values = fixture.runLua(app, "return _G.tecsMidSaveDone")
            if values[1] == "true" then return true end
            return nil
        end)
        luassert.is_true(fired == true, "a mid-animation save lost its completion")
    end)

    -- The sequencer never learns what a sprite is: gfx registers the action
    -- that starts a tag and the provider that answers whether it is still
    -- going, so the dependency points inward.
    it("lets a program play a tag and wait for it", function()
        fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            local sequence = require("tecs2d.sequence")
            _G.tecsAwaitSheet = gfx.SpriteSheet.fromFile("assets/running.png")
            _G.tecsAwaitEntity = world:spawn(
                gfx.Sprite.fromSheet(_G.tecsAwaitSheet, "run"))
            _G.tecsAwaitDone = false
            sequence.registerAction(world, "spec.awaited", function()
                _G.tecsAwaitDone = true
            end)
            _G.tecsAwaitHandle = sequence.play(world,
                sequence.define("spec.playAndWait", {
                    sequence.call("tecs2d.sprite.playTag",
                        sequence.bind("actor"), "run"),
                    sequence.await("tecs2d.sprite", sequence.bind("actor")),
                    sequence.call("spec.awaited"),
                }), {bindings = {actor = _G.tecsAwaitEntity}})
            return true
        ]])

        local done = fixture.eventually(fixture.callTimeout, function(): boolean
            local values = fixture.runLua(app, "return _G.tecsAwaitDone")
            if values[1] == "true" then return true end
            return nil
        end)
        luassert.is_true(done == true,
            "the program never resumed after the animation finished")
    end)
end)
