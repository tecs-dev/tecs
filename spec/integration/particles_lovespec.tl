--- Love2D integration suite: particle emitters. A ParticleEmitter
--- wrapping a Love particle system must render particles around the
--- emitter's Transform, follow the entity when it moves, and stop
--- leaving pixels once despawned. First coverage of the particles
--- integration.
---
--- Run via `make test-love FILE_MATCH='particles'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs2d.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

local W <const> = 320.0
local H <const> = 240.0

--- Count bright pixels in a box around (cx, cy).
local function glowCount(app: fixture.App, cx: number, cy: number): integer
    local points: {{number}} = {}
    for dy = -24, 24, 8 do
        for dx = -24, 24, 8 do
            points[#points + 1] = {(cx + dx) / W, (cy + dy) / H}
        end
    end
    local pixels = fixture.probePixels(app, points)
    local count = 0
    for i = 1, #pixels do
        if math.max(pixels[i][1], pixels[i][2], pixels[i][3]) > 0.3 then
            count = count + 1
        end
    end
    return count
end

describe("particles: emitters render, move, and clean up", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform

            local size = 16
            local imgData = love.image.newImageData(size, size)
            for y = 0, size - 1 do
                for x = 0, size - 1 do
                    local dx, dy = x - size / 2, y - size / 2
                    if math.sqrt(dx * dx + dy * dy) <= size / 2 then
                        imgData:setPixel(x, y, 1, 1, 1, 1)
                    end
                end
            end
            local ps = love.graphics.newParticleSystem(love.graphics.newImage(imgData), 500)
            ps:setParticleLifetime(1, 2)
            ps:setEmissionRate(300)
            ps:setEmissionArea("normal", 8, 8)
            ps:setSizes(1)

            _G.tecsEmitter = world:spawn(
                Transform(90, 120, 0, 2),
                gfx.ParticleEmitter(ps),
                gfx.Unlit)
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("renders particles around the emitter", function()
        local emitting = fixture.eventually(fixture.callTimeout, function(): integer
            local count = glowCount(app, 90, 120)
            if count >= 4 then return count end
            return nil
        end)
        luassert.is_number(emitting, "emitter never produced visible particles")
    end)

    it("follows the entity's Transform", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local t = world:getMut(_G.tecsEmitter, tecs.builtins.Transform)
            t.x = 230
            return true
        ]])
        local moved = fixture.eventually(fixture.callTimeout, function(): boolean
            if glowCount(app, 230, 120) >= 4 then return true end
            return nil
        end)
        luassert.is_true(moved == true, "particles never appeared at the new position")
    end)

    it("despawning the emitter clears its particles", function()
        fixture.runLua(app, "world:despawn(_G.tecsEmitter) return true")
        local cleared = fixture.eventually(fixture.callTimeout, function(): boolean
            if glowCount(app, 230, 120) == 0 and glowCount(app, 90, 120) == 0 then
                return true
            end
            return nil
        end)
        luassert.is_true(cleared == true, "particles persisted after despawning the emitter")
    end)
end)
