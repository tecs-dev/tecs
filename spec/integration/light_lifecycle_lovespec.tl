--- Love2D integration suite: light GPU-slot lifecycle. Boots the lighting
--- fixture (white surface, near-black ambient, deferred lighting) and
--- verifies through pixel probes that lights start affecting the scene
--- when spawned and stop when the Light component is removed or the
--- entity is despawned.
---
--- Run via `make test-love`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/lighting"

local DARK <const> = 0.15
local BRIGHT <const> = 0.5
local SETTLE <const> = fixture.callTimeout

local function centerBrightness(app: fixture.App): number
    local probe = fixture.probePixels(app, {{0.5, 0.5}})[1]
    return math.max(probe[1], probe[2], probe[3])
end

local function waitBright(app: fixture.App): number
    return fixture.eventually(SETTLE, function(): number
        local level = centerBrightness(app)
        if level > BRIGHT then return level end
        return nil
    end)
end

local function waitDark(app: fixture.App): number
    return fixture.eventually(SETTLE, function(): number
        local level = centerBrightness(app)
        if level < DARK then return level end
        return nil
    end)
end

local function spawnCenterLight(app: fixture.App, globalName: string)
    fixture.runLua(app, string.format([[
        local gfx = require("tecs.gfx")
        local Transform = require("tecs").builtins.Transform
        _G[%q] = world:spawn(Transform(160, 120, 0, 1), gfx.Light(300, 2.0, 0.5))
        return true
    ]], globalName))
end

describe("light lifecycle: GPU slot release", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("renders the surface dark under ambient-only lighting", function()
        local level = waitDark(app)
        luassert.is_number(level, "surface never settled dark")
        luassert.is_true(level < DARK, "ambient level too bright: " .. tostring(level))
    end)

    it("spawned light illuminates the surface", function()
        spawnCenterLight(app, "tecsTestLightA")
        local level = waitBright(app)
        luassert.is_number(level, "surface never lit up after spawning a light")
    end)

    it("removing the Light component extinguishes it", function()
        fixture.runLua(app, [[
            local gfx = require("tecs.gfx")
            world:remove(_G.tecsTestLightA, gfx.Light)
            return true
        ]])
        local level = waitDark(app)
        luassert.is_number(level,
            "surface stayed lit after removing the Light component (stale GPU slot)")
    end)

    it("despawning a light frees its slot", function()
        spawnCenterLight(app, "tecsTestLightB")
        luassert.is_number(waitBright(app), "second light never lit the surface")

        fixture.runLua(app, "world:despawn(_G.tecsTestLightB) return true")
        local level = waitDark(app)
        luassert.is_number(level, "surface stayed lit after despawning the light")
    end)
end)
