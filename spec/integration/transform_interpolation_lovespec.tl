--- Love2D integration coverage for GPU-resident fixed-step Transform
--- interpolation. Renderables move 160 pixels in one fixed update;
--- observing them at the midpoint proves each cull path consumed
--- previous/current GPU samples instead of snapping to the CPU value.
---
--- Run via `make test-love FILE_MATCH='transform_interpolation'`.

require("busted")

local socket <const> = require("socket")
local fixture <const> = require("tecs.testing.fixture")

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

describe("shared GPU Transform interpolation", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
    end)

    teardown(function()
        if app then fixture.stop(app) end
    end)

    it("interpolates shapes, text, and meshes", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs.gfx")
            local Transform = tecs.builtins.Transform
            local lg = love.graphics

            world:despawn(_G.tecsTestSprite)
            world.pipeline.fixedTimestep = 1.0
            world.pipeline.fixedAccumulator = 0

            local function quadMesh(half)
                local vertices = {
                    {-half, -half, 0, 0, 1, 1, 1, 1},
                    { half, -half, 1, 0, 1, 1, 1, 1},
                    { half,  half, 1, 1, 1, 1, 1, 1},
                    {-half, -half, 0, 0, 1, 1, 1, 1},
                    { half,  half, 1, 1, 1, 1, 1, 1},
                    {-half,  half, 0, 1, 1, 1, 1, 1},
                }
                local format = {
                    {name = "VertexPosition", format = "floatvec2",
                        location = 0},
                    {name = "VertexTexCoord", format = "floatvec2",
                        location = 1},
                    {name = "VertexColor", format = "floatvec4",
                        location = 2},
                }
                return lg.newMesh(
                    format,
                    vertices,
                    "triangles",
                    "static"
                )
            end
            gfx.MeshDefinition.new(
                "interpolationquad",
                quadMesh(9),
                4
            )

            local movers = {
                world:spawn(
                    Transform(80, 50, 0, 1),
                    gfx.Rectangle(20, 16),
                    gfx.Color(1, 0, 0, 1)
                ),
                world:spawn(
                    Transform(80, 120, 0, 1),
                    gfx.Text(
                        "assets/firacode-nerd-msdf.json",
                        "O",
                        2,
                        2
                    ),
                    gfx.Color(1, 1, 1, 1)
                ),
                world:spawn(
                    Transform(80, 190, 0, 1),
                    gfx.Mesh("interpolationquad"),
                    gfx.Color(0, 1, 0, 1)
                ),
            }

            _G.tecsInterpolationMoved = false
            world:addSystem({
                name = "spec.MoveSharedRenderersAtFixedRate",
                phase = tecs.phases.FixedUpdate,
                run = function()
                    if _G.tecsInterpolationMoved then return end
                    _G.tecsInterpolationMoved = true
                    for i = 1, #movers do
                        world:getMut(movers[i], Transform).x = 240
                    end
                end,
            })
        ]])

        local probes: {{number, number}} = {}
        local groups: {integer} = {}
        for x = 120, 200, 5 do
            probes[#probes + 1] = {x / 320, 50 / 240}
            groups[#groups + 1] = 1
        end
        for y = 106, 134, 7 do
            for x = 120, 200, 5 do
                probes[#probes + 1] = {x / 320, y / 240}
                groups[#groups + 1] = 2
            end
        end
        for x = 120, 200, 5 do
            probes[#probes + 1] = {x / 320, 190 / 240}
            groups[#groups + 1] = 3
        end

        local observed = {false, false, false}
        local deadline = socket.gettime() + 2.5
        while socket.gettime() < deadline
                and not (observed[1] and observed[2] and observed[3]) do
            local pixels = fixture.probePixels(app, probes)
            for i = 1, #pixels do
                local pixel = pixels[i]
                local group = groups[i]
                if group == 1 and pixel[1] > 0.6 then
                    observed[1] = true
                elseif group == 2 and pixel[1] > 0.5
                        and pixel[2] > 0.5 and pixel[3] > 0.5 then
                    observed[2] = true
                elseif group == 3 and pixel[2] > 0.6 then
                    observed[3] = true
                end
            end
            if not (observed[1] and observed[2] and observed[3]) then
                sleep(0.02)
            end
        end

        assert.same(
            {true, true, true},
            observed,
            "rectangle, text, and mesh must render between fixed samples"
        )
    end)
end)
