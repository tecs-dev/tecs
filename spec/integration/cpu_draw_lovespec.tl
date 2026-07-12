--- Love2D integration suite: CPU Draw-phase rendering. Custom
--- love.graphics draws attached through pipeline:worldShader() must land
--- in the G-buffer and depth-sort against GPU-rendered content: a CPU
--- rect drawn at higher z covers a GPU rect at the same position, and at
--- lower z is covered by it. Covers the world-shader attach/detach
--- contract and Draw-phase interleaving.
---
--- Run via `make test-love FILE_MATCH='cpu_draw'`.

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

local function isMagenta(p: {number}): boolean return p[1] > 0.8 and p[3] > 0.8 and p[2] < 0.2 end
local function isGreen(p: {number}): boolean return p[2] > 0.8 and p[1] < 0.2 end

describe("cpu draws: world shader participates in the G-buffer", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        -- GPU content: a green rect at (160, 120), layer 2, z 5. The CPU
        -- draw system renders magenta rects at z read from _G, so tests
        -- can move it through the depth order.
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform

            local greenId = world:spawn(Transform(160, 120, 5, 2),
                gfx.Rectangle(40, 40), gfx.Color(0, 1, 0, 1))

            _G.tecsCpuZ = 1
            local pipeline = world.resources[gfx.PIPELINE]
            world:addSystem({
                name = "test.CpuDraw",
                phase = tecs.phases.Draw,
                run = function()
                    pipeline:worldShader():at(2, _G.tecsCpuZ, 0, 0):unlit():attach()
                    love.graphics.setColor(1, 0, 1, 1)
                    love.graphics.rectangle("fill", 140, 100, 40, 40)
                    love.graphics.setColor(1, 1, 1, 1)
                    pipeline:detachWorldShader()
                end,
            })
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("a CPU draw below the GPU content is covered by it", function()
        waitPixel(app, 160, 120, isGreen,
            "GPU rect (z 5) should cover the CPU rect (z 1)")
    end)

    it("raising the CPU draw's z brings it in front", function()
        fixture.runLua(app, "_G.tecsCpuZ = 9 return true")
        waitPixel(app, 160, 120, isMagenta,
            "CPU rect (z 9) should cover the GPU rect (z 5)")
    end)

    it("CPU draws render standalone where no GPU content sits", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local pipeline = world.resources[gfx.PIPELINE]
            world:addSystem({
                name = "test.CpuDrawLone",
                phase = tecs.phases.Draw,
                run = function()
                    pipeline:worldShader():at(2, 1, 0, 0):unlit():attach()
                    love.graphics.setColor(1, 0, 1, 1)
                    love.graphics.circle("fill", 60, 60, 12)
                    love.graphics.setColor(1, 1, 1, 1)
                    pipeline:detachWorldShader()
                end,
            })
            return true
        ]])
        waitPixel(app, 60, 60, isMagenta, "standalone CPU draw should render")
    end)
end)
