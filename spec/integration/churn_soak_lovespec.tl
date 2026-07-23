--- Love2D integration suite: spawn/despawn churn soak. Repeatedly batch
--- spawns thousands of shapes past the renderer's initial buffer
--- capacity and despawns them again while a sentinel keeps rendering.
--- This forces GPU buffer growth mid-flight (the two-frame retire path),
--- archetype churn, and slot reuse; the failure modes it guards are
--- crashes on buffer reallocation, ghost instances from stale GPU rows,
--- and entity leaks.
---
--- Run via `make test-love FILE_MATCH='churn_soak'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs2d.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

local ITERATIONS <const> = 4
-- Past the default 4096-per-shape size hints, so both the canonical
-- shadow columns and the cull output buffers must grow.
local CHURN_COUNT <const> = 6000

local W <const> = 320.0
local H <const> = 240.0
local SENTINEL_PROBE <const> = {{160 / W, 120 / H}}
-- A spot the churn field covers densely while alive.
local FIELD_PROBE <const> = {{80 / W, 60 / H}}

local function entityCount(app: fixture.App): integer
    return tonumber(fixture.runLua(app, "return world:getStats().entities")[1]) as integer
end

local function sentinelVisible(app: fixture.App): boolean
    local p = fixture.probePixels(app, SENTINEL_PROBE)[1]
    return p[1] > 0.8 and p[2] > 0.8 and p[3] > 0.8
end

describe("churn soak: buffer growth and slot reuse survive", function()
    local app: fixture.App
    local baseline: integer

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            world:spawn(Transform(160, 120, 0.5, 2), gfx.Rectangle(40, 40), gfx.Color(1, 1, 1, 1))
            return true
        ]])
        local visible = fixture.eventually(fixture.callTimeout, function(): boolean
            if sentinelVisible(app) then return true end
            return nil
        end)
        luassert.is_true(visible == true, "sentinel rect never rendered")
        baseline = entityCount(app)
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("survives repeated over-capacity spawn/despawn cycles", function()
        for iteration = 1, ITERATIONS do
            -- Spawn a mixed field of rects and circles. batchSpawn skips
            -- FFI defaults, so every field is written explicitly. Half
            -- the field lands in view, half beyond it, so both the
            -- visible and culled paths see the rows.
            local values = fixture.runLua(app, string.format([[
                local tecs = require("tecs")
                local gfx = require("tecs2d.gfx")
                local Transform = tecs.builtins.Transform
                local Rectangle = gfx.Rectangle
                local Circle = gfx.Circle
                local Color = gfx.Color
                math.randomseed(%d)
                local ids = {}
                local function fill(arch, startRow, lastRow)
                    local transforms = arch:getMut(Transform)
                    local colors = arch:getMut(Color)
                    local entities = arch.entities
                    for i = startRow, lastRow do
                        local t = transforms[i]
                        t.x = math.random() * 640
                        t.y = math.random() * 480
                        t.z = 0
                        t.layer = 1
                        t.rotation = 0
                        t.scaleX = 1
                        t.scaleY = 1
                        local c = colors[i]
                        c.r, c.g, c.b, c.a = 1, 0, 0, 1
                        ids[#ids + 1] = entities[i]
                    end
                end
                world:batchSpawn(%d, {Transform, Rectangle, Color},
                    function(arch, startRow, lastRow)
                        local rects = arch:getMut(Rectangle)
                        for i = startRow, lastRow do
                            local r = rects[i]
                            r.width, r.height, r.lineWidth = 8, 8, 0
                        end
                        fill(arch, startRow, lastRow)
                    end)
                world:batchSpawn(%d, {Transform, Circle, Color},
                    function(arch, startRow, lastRow)
                        local circles = arch:getMut(Circle)
                        for i = startRow, lastRow do
                            local c = circles[i]
                            c.radius, c.lineWidth = 5, 0
                        end
                        fill(arch, startRow, lastRow)
                    end)
                _G.tecsChurn = ids
                return #ids
            ]], iteration, CHURN_COUNT, CHURN_COUNT))
            luassert.equals(tostring(CHURN_COUNT * 2), values[1],
                "iteration " .. iteration .. ": spawn count mismatch")

            -- The field must actually render before it is torn down.
            local fieldVisible = fixture.eventually(fixture.callTimeout, function(): boolean
                local p = fixture.probePixels(app, FIELD_PROBE)[1]
                if p[1] > 0.5 then return true end
                return nil
            end)
            luassert.is_true(fieldVisible == true,
                "iteration " .. iteration .. ": churn field never rendered")

            fixture.runLua(app, [[
                for i = 1, #_G.tecsChurn do
                    world:despawn(_G.tecsChurn[i])
                end
                _G.tecsChurn = nil
                return true
            ]])
        end
    end)

    it("returns to the baseline entity count", function()
        local settled = fixture.eventually(fixture.callTimeout, function(): boolean
            if entityCount(app) == baseline then return true end
            return nil
        end)
        luassert.is_true(settled == true, string.format(
            "entity count leaked: baseline %d, now %d", baseline, entityCount(app)))
    end)

    it("leaves no ghost instances and keeps rendering", function()
        -- Ghosts from stale GPU rows would keep the field probe lit.
        local clear = fixture.eventually(fixture.callTimeout, function(): boolean
            local p = fixture.probePixels(app, FIELD_PROBE)[1]
            if p[1] < 0.1 and p[2] < 0.1 then return true end
            return nil
        end)
        luassert.is_true(clear == true, "churn field still renders after full despawn (ghost instances)")
        luassert.is_true(sentinelVisible(app), "sentinel rect vanished after churn")
    end)
end)
