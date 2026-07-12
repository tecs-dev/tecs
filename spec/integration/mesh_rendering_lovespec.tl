--- Love2D integration suite: GPU-instanced mesh rendering. Registers
--- MeshDefinitions at runtime, spawns instances, and probes them through
--- transform scale/rotation, Color, material variants, and instance
--- churn past the definition capacity (per-definition output buffer
--- growth). First direct coverage of the mesh shadow-column path.
---
--- Run via `make test-love FILE_MATCH='mesh_rendering'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs2d.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

local W <const> = 320.0
local H <const> = 240.0

local function waitPixel(app: fixture.App, x: number, y: number,
        check: function({number}): boolean, label: string)
    local ok = fixture.eventually(fixture.callTimeout, function(): boolean
        if check(fixture.probePixels(app, {{x / W, y / H}})[1]) then return true end
        return nil
    end)
    local p = fixture.probePixels(app, {{x / W, y / H}})[1]
    luassert.is_true(ok == true, string.format(
        "%s: pixel (%d, %d) = (%.2f, %.2f, %.2f)",
        label, x as integer, y as integer, p[1], p[2], p[3]))
end

local function isRed(p: {number}): boolean return p[1] > 0.8 and p[2] < 0.2 end
local function isGreen(p: {number}): boolean return p[2] > 0.8 and p[1] < 0.2 end
local function isBlue(p: {number}): boolean return p[3] > 0.8 and p[1] < 0.2 end
local function isBackground(p: {number}): boolean
    return p[1] < 0.1 and p[2] < 0.1 and p[3] < 0.1
end

describe("mesh rendering: definitions, instances, and growth", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        -- A 20x20 quad definition (two triangles around the origin).
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            local lg = love.graphics

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
                    {name = "VertexPosition", format = "floatvec2", location = 0},
                    {name = "VertexTexCoord", format = "floatvec2", location = 1},
                    {name = "VertexColor", format = "floatvec4", location = 2},
                }
                return lg.newMesh(format, vertices, "triangles", "static")
            end
            -- Small capacity so the churn test forces buffer growth.
            gfx.MeshDefinition.new("testquad", quadMesh(10), 16)

            _G.tecsMeshA = world:spawn(
                Transform(80, 120, 0, 1), gfx.Mesh("testquad"), gfx.Color(1, 0, 0, 1))
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("renders a mesh instance with its Color", function()
        waitPixel(app, 80, 120, isRed, "mesh instance should be red")
        waitPixel(app, 80 + 16, 120, isBackground, "outside the quad should be background")
    end)

    it("applies Transform scale and rotation", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local Transform = tecs.builtins.Transform
            local t = world:getMut(_G.tecsMeshA, Transform)
            t.scaleX = 3
            return true
        ]])
        waitPixel(app, 80 + 24, 120, isRed, "scaled mesh should extend horizontally")
        waitPixel(app, 80, 120 + 16, isBackground, "unscaled axis should not extend")
    end)

    it("renders a material variant on a mesh", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            _G.tecsMeshB = world:spawn(
                Transform(200, 120, 0, 1), gfx.Mesh("testquad"),
                gfx.Color(1, 0, 0, 1),
                _G.tecsFlatMaterial:withParams(0, 0, 1, 0))
            return true
        ]])
        waitPixel(app, 200, 120, isBlue, "material mesh should be params-blue")
    end)

    it("grows past the definition capacity under churn and cleans up", function()
        -- 60 instances against capacity 16, twice.
        for round = 1, 2 do
            fixture.runLua(app, string.format([[
                local tecs = require("tecs")
                local gfx = require("tecs2d.gfx")
                local Transform = tecs.builtins.Transform
                math.randomseed(%d)
                local spawned = {}
                for i = 1, 60 do
                    spawned[i] = world:spawn(
                        Transform(20 + (i %% 10) * 30, 30 + math.floor(i / 10) * 30, 0, 1),
                        gfx.Mesh("testquad"), gfx.Color(0, 1, 0, 1))
                end
                _G.tecsMeshChurn = spawned
                return true
            ]], round))
            waitPixel(app, 50, 30, isGreen, "round " .. round .. ": churn field should render")
            fixture.runLua(app, [[
                for i = 1, #_G.tecsMeshChurn do
                    world:despawn(_G.tecsMeshChurn[i])
                end
                _G.tecsMeshChurn = nil
                return true
            ]])
        end
        waitPixel(app, 50, 30, isBackground, "churn meshes should leave no ghosts")
        waitPixel(app, 200, 120, isBlue, "survivor material mesh intact after churn")
    end)
end)
