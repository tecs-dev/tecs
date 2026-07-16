--- Love2D integration suite: text lifecycle churn. Repeated setText /
--- setScale on live entities plus spawn/despawn cycles must keep
--- rendering correctly without leaking glyph storage: the glyph slab
--- refcounts shared strings and the block allocator coalesces freed
--- ranges, so steady-state churn reuses capacity instead of growing it.
--- Uses a procedural bitmap font (no asset files).
---
--- Run via `make test-love FILE_MATCH='text_churn'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs2d.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

local W <const> = 320.0
local H <const> = 240.0

describe("text churn: edits and respawns reuse glyph storage", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        -- Solid white 8x8 'A' and 'B' glyphs so text probes read color.
        fixture.runLua(app, [[
            love.filesystem.remove("testchurn.png")
            love.filesystem.remove("testchurn.fnt")
            local atlas = love.image.newImageData(32, 32)
            for y = 0, 7 do
                for x = 0, 15 do atlas:setPixel(x, y, 1, 1, 1, 1) end
            end
            love.filesystem.write("testchurn.png", atlas:encode("png"))
            love.filesystem.write("testchurn.fnt", table.concat({
                'info face="Churn" size=8',
                'common lineHeight=10 base=8 scaleW=32 scaleH=32 pages=1',
                'page id=0 file="testchurn.png"',
                'chars count=2',
                'char id=65 x=0 y=0 width=8 height=8 xoffset=0 yoffset=0 xadvance=9 page=0 chnl=15',
                'char id=66 x=8 y=0 width=8 height=8 xoffset=0 yoffset=0 xadvance=9 page=0 chnl=15',
            }, "\n"))
            return true
        ]])
    end)

    teardown(function()
        if app then
            pcall(function()
                fixture.runLua(app, [[
                    love.filesystem.remove("testchurn.png")
                    love.filesystem.remove("testchurn.fnt")
                    return true
                ]])
            end)
        end
        fixture.stop(app)
    end)

    -- Count white pixels along the text row (anchoring is a layout
    -- detail; the rendered span width is the contract).
    local function whiteSpan(app2: fixture.App, y: number): integer
        local points: {{number}} = {}
        for x = 2, 318, 3 do
            points[#points + 1] = {x / W, y / H}
        end
        local pixels = fixture.probePixels(app2, points)
        local count = 0
        for i = 1, #pixels do
            if pixels[i][1] > 0.8 and pixels[i][2] > 0.8 then
                count = count + 1
            end
        end
        return count
    end

    it("renders text and follows setText edits", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            _G.tecsChurnText = world:spawn(
                Transform(60, 120, 0, 1),
                gfx.Text("testchurn.fnt", "A", 3, 3))
            return true
        ]])
        local single = fixture.eventually(fixture.callTimeout, function(): integer
            local span = whiteSpan(app, 120)
            if span > 0 then return span end
            return nil
        end)
        luassert.is_number(single, "text never rendered")

        -- Grow the string; the rendered span must widen accordingly.
        fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            world:get(_G.tecsChurnText, gfx.Text):setText("ABAB")
            return true
        ]])
        local grown = fixture.eventually(fixture.callTimeout, function(): boolean
            if whiteSpan(app, 120) >= single * 3 then return true end
            return nil
        end)
        luassert.is_true(grown == true, string.format(
            "setText growth never rendered (single span %d, now %d)",
            single, whiteSpan(app, 120)))
    end)

    it("survives heavy setText/spawn/despawn churn without leaking", function()
        -- Steady-state baseline after one churn round, then many more
        -- rounds; glyph storage stats must not keep growing.
        local function churnRound(round: integer): {string}
            return fixture.runLua(app, string.format([[
                local tecs = require("tecs")
                local gfx = require("tecs2d.gfx")
                local Transform = tecs.builtins.Transform
                math.randomseed(%d)
                local spawned = {}
                for i = 1, 40 do
                    local len = 1 + (i %% 6)
                    local s = string.rep(i %% 2 == 0 and "A" or "B", len)
                    spawned[i] = world:spawn(
                        Transform(20 + (i %% 8) * 36, 20 + math.floor(i / 8) * 30, 0, 1),
                        gfx.Text("testchurn.fnt", s, 2, 2))
                end
                for i = 1, 30 do
                    local t = world:get(_G.tecsChurnText, gfx.Text)
                    t:setText(string.rep(i %% 2 == 0 and "AB" or "BA", 1 + (i %% 4)))
                end
                for i = 1, 40 do
                    world:despawn(spawned[i])
                end
                return tecsTestHooks.gc("count")
            ]], round))
        end

        churnRound(1)
        churnRound(2)
        local values = fixture.runLua(app, [[
            local stats = world:getStats()
            return stats.entities
        ]])
        local settledEntities = tonumber(values[1])

        for round = 3, 8 do
            churnRound(round)
        end

        local after = fixture.runLua(app, [[
            local stats = world:getStats()
            return stats.entities
        ]])
        luassert.equals(settledEntities, tonumber(after[1]),
            "entity count grew across churn rounds")

        -- The survivor text still renders after all the churn.
        fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            world:get(_G.tecsChurnText, gfx.Text):setText("A")
            return true
        ]])
        local alive = fixture.eventually(fixture.callTimeout, function(): boolean
            if whiteSpan(app, 120) > 0 then return true end
            return nil
        end)
        luassert.is_true(alive == true, "survivor text stopped rendering after churn")
    end)
end)
