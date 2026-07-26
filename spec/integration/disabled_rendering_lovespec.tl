--- Love2D integration suite: the Disabled builtin must remove entities
--- from rendering. The render-side archetype registries bypass the query
--- engine (which auto-excludes Disabled), so this drives a real app and
--- asserts through pixel probes that disabling hides an entity and
--- re-enabling brings it back.
---
--- Run via `make test-love`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/compliance"

-- World (80, 120) in the 320x240 fixture -> framebuffer fraction (0.25, 0.5),
-- clear of the red center rectangle.
local PROBE <const> = {{0.25, 0.5}}
local TOLERANCE <const> = 0.06

local function greenLevel(app: fixture.App): number
    return fixture.probePixels(app, PROBE)[1][2]
end

describe("disabled rendering: Disabled hides entities", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs.gfx")
            local Transform = tecs.builtins.Transform
            _G.tecsTestRect = world:spawn(
                Transform(80, 120, 0, 1), gfx.Rectangle(60, 60), gfx.Color(0, 1, 0, 1))
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("renders the fixture rectangle before disabling", function()
        local level = fixture.eventually(fixture.callTimeout, function(): number
            local g = greenLevel(app)
            if g > 1 - TOLERANCE then return g end
            return nil
        end)
        luassert.is_number(level, "green rectangle never appeared")
    end)

    it("adding Disabled removes the rectangle from the frame", function()
        fixture.runLua(app, [[
            world:set(_G.tecsTestRect, require("tecs").builtins.Disabled)
            return true
        ]])
        local level = fixture.eventually(fixture.callTimeout, function(): number
            local g = greenLevel(app)
            if g < TOLERANCE then return g end
            return nil
        end)
        luassert.is_number(level,
            "rectangle still visible after Disabled (render registries ignore it)")
    end)

    it("removing Disabled brings the rectangle back", function()
        fixture.runLua(app, [[
            world:remove(_G.tecsTestRect, require("tecs").builtins.Disabled)
            return true
        ]])
        local level = fixture.eventually(fixture.callTimeout, function(): number
            local g = greenLevel(app)
            if g > 1 - TOLERANCE then return g end
            return nil
        end)
        luassert.is_number(level, "rectangle never reappeared after re-enabling")
    end)
end)
