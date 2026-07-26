--- Love2D integration coverage for GPU-resident fixed-step Transform
--- interpolation. The fixture's sprite moves 160 pixels in one fixed
--- update; observing it at the midpoint proves the cull shader consumed
--- previous/current GPU samples instead of snapping to the CPU value.
---
--- Run via `make test-love FILE_MATCH='sprite_transform_interpolation'`.

require("busted")

local socket <const> = require("socket")
local fixture <const> = require("tecs2d.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/sprites"
local sleep <const> = socket.sleep as function(number)

local function isSpritePixel(pixel: {number}): boolean
    return pixel[1] > 0.6 or pixel[3] > 0.6
end

describe("sprite Transform interpolation", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
    end)

    teardown(function()
        if app then fixture.stop(app) end
    end)

    it("renders an intermediate position between fixed samples", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local Transform = tecs.builtins.Transform
            local entity = _G.tecsTestSprite

            -- Stretch the interval so the test can observe the GPU result
            -- through ordinary MCP pixel probes.
            world.pipeline.fixedTimestep = 1.0
            world.pipeline.fixedAccumulator = 0
            world:getMut(entity, Transform).x = 80

            _G.tecsInterpolationMoved = false
            world:addSystem({
                name = "spec.MoveSpriteAtFixedRate",
                phase = tecs.phases.FixedUpdate,
                run = function()
                    if _G.tecsInterpolationMoved then return end
                    _G.tecsInterpolationMoved = true
                    world:getMut(entity, Transform).x = 240
                end,
            })
        ]])

        -- The midpoint is never occupied without interpolation: canonical
        -- Transform jumps directly from x=80 to x=240.
        local observedMidpoint = false
        local probes: {{number, number}} = {}
        for y = 112, 128, 4 do
            for x = 100, 220, 4 do
                probes[#probes + 1] = {x / 320, y / 240}
            end
        end
        local deadline = socket.gettime() + 2.5
        while socket.gettime() < deadline and not observedMidpoint do
            local pixels = fixture.probePixels(app, probes)
            for i = 1, #pixels do
                if isSpritePixel(pixels[i]) then
                    observedMidpoint = true
                    break
                end
            end
            if not observedMidpoint then sleep(0.02) end
        end

        if not observedMidpoint then
            local state = fixture.runLua(app, [[
                local tecs = require("tecs")
                local fixedtracking =
                    require("tecs.internal.fixedtracking")
                local Transform = tecs.builtins.Transform
                local entity = _G.tecsTestSprite
                local _, _, alpha = world:getFixedTiming()
                return world:get(entity, Transform).x,
                    tostring(_G.tecsInterpolationMoved),
                    fixedtracking.currentStep(world),
                    alpha
            ]])
            local endpoints = fixture.probePixels(app, {
                {80 / 320, 120 / 240},
                {240 / 320, 120 / 240},
            })
            error("sprite did not render between fixed samples; state=" ..
                table.concat(state, ",") .. " endpoints=" ..
                table.concat(endpoints[1], ",") .. "/" ..
                table.concat(endpoints[2], ","))
        end
    end)
end)
