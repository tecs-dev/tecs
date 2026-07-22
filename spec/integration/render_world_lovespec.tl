require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs2d.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"
local W <const> = 320.0
local H <const> = 240.0

describe("immutable composited render worlds", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            local primary = world.resources[gfx.PIPELINE]

            world:spawn(Transform(160, 120, 0, 1),
                gfx.Rectangle(80, 80), gfx.Color(1, 0, 0, 1))

            local overlayWorld = tecs.newWorld({maxEntities = 64})
            local overlayPipeline = gfx.newPipeline({
                world = overlayWorld,
                sharedWith = primary,
                virtualHeight = 240,
                lightingMode = "none",
                lerpingEnabled = false,
                layers = {[1] = {name = "overlay", space = "screen", unlit = true}},
                sizeHints = {rects = 8},
            })
            overlayWorld:spawn(Transform(160, 120, 0, 1),
                gfx.Rectangle(40, 40), gfx.Color(0, 1, 0, 1))

            -- Deliberately create matching entity slots in both worlds. Sprite
            -- and Text methods must resolve through worldId, not a process-wide
            -- "current world".
            local imageA = love.graphics.newImage(love.image.newImageData(1, 1))
            local imageB = love.graphics.newImage(love.image.newImageData(1, 1))
            local primarySpriteId = world:spawn(Transform(-100, -100), gfx.Sprite.fromTexture(imageA))
            local overlaySpriteId = overlayWorld:spawn(Transform(-100, -100), gfx.Sprite.fromTexture(imageB))
            local font = "tecs2d/assets/fonts/tiny-font.fnt"
            local primaryTextId = world:spawn(Transform(-100, -100), gfx.Text(font, "primary"))
            local overlayTextId = overlayWorld:spawn(Transform(-100, -100), gfx.Text(font, "overlay"))
            -- Spawn after the deliberate cross-world ID collisions above.
            overlayWorld:spawn(Transform(40, 40, 0, 1),
                gfx.Rectangle(20, 20), gfx.Color(1, 1, 1, 0.5))
            overlayWorld:startup()

            world:addSystem({
                name = "test.CompositeWorld",
                phase = tecs.phases.RenderLast,
                before = {"love.Present"},
                run = function(dt)
                    overlayWorld:update(dt)
                    overlayPipeline:render()
                end,
            })

            _G.tecsOverlayWorld = overlayWorld
            _G.tecsOverlayPipeline = overlayPipeline
            _G.tecsRenderWorldIds = {primarySpriteId, overlaySpriteId, primaryTextId, overlayTextId}
            return primary:getWorldId(), overlayPipeline:getWorldId()
        ]])
    end)

    teardown(function()
        if app then
            pcall(function()
                fixture.runLua(app, [[
                    if _G.tecsOverlayWorld then
                        _G.tecsOverlayWorld:shutdown()
                        _G.tecsOverlayWorld = nil
                    end
                    return true
                ]])
            end)
            fixture.stop(app)
        end
    end)

    it("composites transparently over the primary world", function()
        local last = ""
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            local pixels = fixture.probePixels(app, {
                {160 / W, 120 / H},
                {190 / W, 120 / H},
                {20 / W, 20 / H},
                {40 / W, 40 / H},
            })
            last = string.format(
                "center=%.2f,%.2f edge=%.2f,%.2f bg=%.2f,%.2f alpha=%.2f",
                pixels[1][1], pixels[1][2], pixels[2][1], pixels[2][2],
                pixels[3][1], pixels[3][2], pixels[4][1])
            local correct = pixels[1][2] > 0.8 and pixels[1][1] < 0.2
                and pixels[2][1] > 0.8 and pixels[2][2] < 0.2
                and pixels[3][1] < 0.1 and pixels[3][2] < 0.1
                and pixels[4][1] > 0.4 and pixels[4][1] < 0.6
            if correct then return true end
            return nil
        end)
        luassert.is_true(ok == true, "composited pixels did not settle: " .. last)
    end)

    it("keeps world identity and clocks independent", function()
        local values = fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            local primary = world.resources[gfx.PIPELINE]
            local secondary = _G.tecsOverlayPipeline
            local primaryBefore = primary:getTime()
            local secondaryBefore = secondary:getTime()
            _G.tecsOverlayWorld:update(0.5)
            return primary:getWorldId() ~= secondary:getWorldId(),
                secondary:getTime() > 0,
                primary:getTime() - primaryBefore,
                secondary:getTime() - secondaryBefore
        ]])
        luassert.equals("true", values[1])
        luassert.equals("true", values[2])
        luassert.near(0, tonumber(values[3]) as number, 0.0001)
        luassert.near(0.5, tonumber(values[4]) as number, 0.0001)
    end)

    it("rejects replacing a world's pipeline", function()
        local values = fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            local ok, err = pcall(gfx.newPipeline, {world = _G.tecsOverlayWorld})
            return ok, tostring(err):find("already owns a render pipeline", 1, true) ~= nil
        ]])
        luassert.equals("false", values[1])
        luassert.equals("true", values[2])
    end)

    it("keeps Sprite and Text ownership independent when entity IDs collide", function()
        local values = fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            local ids = _G.tecsRenderWorldIds
            local primarySprite = world:get(ids[1], gfx.Sprite)
            local overlaySprite = _G.tecsOverlayWorld:get(ids[2], gfx.Sprite)
            local primaryText = world:get(ids[3], gfx.Text)
            local overlayText = _G.tecsOverlayWorld:get(ids[4], gfx.Text)
            primarySprite:pause(1)
            overlaySprite:pause(2)
            primaryText:setText("changed-primary")
            overlayText:setText("changed-overlay")
            return ids[1] == ids[2], ids[3] == ids[4],
                primarySprite._entity ~= overlaySprite._entity,
                primaryText.textId ~= overlayText.textId,
                primaryText:getText(), overlayText:getText()
        ]])
        luassert.equals("true", values[1])
        luassert.equals("true", values[2])
        luassert.equals("true", values[3])
        luassert.equals("true", values[4])
        luassert.equals("changed-primary", values[5])
        luassert.equals("changed-overlay", values[6])
    end)
end)
