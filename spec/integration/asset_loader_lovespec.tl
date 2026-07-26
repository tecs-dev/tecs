--- Love2D integration suite: threaded asset loader robustness. Drives a
--- real worker queue and asset manager via run_lua:
---   - a throwing observe callback must not wedge isLoading() forever
---   - failed loads must not be cached (a retry after the file appears
---     must succeed)
---   - getFont must find fonts loaded via loadImageFont
---   - shutdown must resolve pending handles instead of leaving waiters
---     spinning
---
--- Run via `make test-love FILE_MATCH='asset_loader'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/compliance"

local function run(app: fixture.App, code: string): {string}
    return fixture.runLua(app, code)
end

--- Pump `am` updates until it goes idle or the deadline passes; returns
--- the final isLoading() value as a string.
local function pumpUntilIdle(app: fixture.App, managerExpr: string, queueExpr: string, seconds: number): string
    local final = fixture.eventually(seconds, function(): string
        local values = run(app, string.format(
            "pcall(function() %s:update() end) return tostring(%s:isLoading())",
            queueExpr, managerExpr))
        if values[1] == "false" then return values[1] end
        return nil
    end)
    return final or "true"
end

describe("asset loader: robustness", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        run(app, [[
            -- love.filesystem.write persists in the save directory across
            -- runs; remove leftovers so failure cases actually fail.
            love.filesystem.remove("late.png")
            love.filesystem.remove("imgfont.png")
            _G.wq = require("tecs.workers").new()
            _G.am = require("tecs.assets").new("", _G.wq)
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("a throwing observe callback does not wedge the loader", function()
        run(app, [[
            local h = _G.am:loadImage("does-not-exist.png")
            h:observe(function() error("observer boom") end)
            return true
        ]])
        local idle = pumpUntilIdle(app, "_G.am", "_G.wq", 4)
        luassert.are.equal("false", idle,
            "isLoading() stuck true after an observer threw")
    end)

    it("retries a failed load once the file exists", function()
        run(app, "_G.lateHandle = _G.am:loadImage('late.png') return true")
        pumpUntilIdle(app, "_G.am", "_G.wq", 4)
        local firstErr = run(app, "return tostring(_G.lateHandle.err ~= nil)")
        luassert.are.equal("true", firstErr[1], "missing file load did not fail")

        run(app, [[
            love.filesystem.write("late.png", love.image.newImageData(4, 4):encode("png"))
            _G.retryHandle = _G.am:loadImage("late.png")
            return true
        ]])
        pumpUntilIdle(app, "_G.am", "_G.wq", 4)
        local values = run(app, [[
            return tostring(_G.retryHandle.err), tostring(_G.retryHandle.isComplete)
        ]])
        luassert.are.equal("nil", values[1],
            "retry returned the cached failed handle (err: " .. values[1] .. ")")
        luassert.are.equal("true", values[2], "retry never completed")
    end)

    it("getFont finds image fonts", function()
        run(app, [[
            -- Image font: separator color (top-left pixel) between glyphs.
            local d = love.image.newImageData(11, 8)
            for y = 0, 7 do
                for x = 0, 10 do
                    if x == 0 or x == 5 or x == 10 then
                        d:setPixel(x, y, 1, 0, 1, 1)
                    else
                        d:setPixel(x, y, 1, 1, 1, 1)
                    end
                end
            end
            love.filesystem.write("imgfont.png", d:encode("png"))
            _G.fontHandle = _G.am:loadImageFont("imgfont.png", {glyphs = "AB"})
            return true
        ]])
        pumpUntilIdle(app, "_G.am", "_G.wq", 4)
        local values = run(app, [[
            local loadErr = tostring(_G.fontHandle.err)
            local ok, result = pcall(function()
                return _G.am:getFont("imgfont.png")
            end)
            return loadErr, tostring(ok), tostring(result)
        ]])
        luassert.are.equal("nil", values[1], "image font failed to load: " .. values[1])
        luassert.are.equal("true", values[2],
            "getFont did not find the image font: " .. values[3])
    end)

    it("shutdown resolves pending handles", function()
        local values = run(app, [[
            local wq2 = require("tecs.workers").new()
            local am2 = require("tecs.assets").new("", wq2)
            local handles = {}
            for i = 1, 8 do
                handles[i] = am2:loadImage("pending-" .. i .. ".png")
            end
            -- The manager does not own its queue. Queue shutdown settles jobs;
            -- manager shutdown only releases its asset cache and pins.
            wq2:shutdown()
            am2:shutdown()
            local unresolved = 0
            for i = 1, 8 do
                if not handles[i].err then
                    unresolved = unresolved + 1
                end
            end
            return tostring(am2:isLoading()), unresolved
        ]])
        luassert.are.equal("false", values[1],
            "isLoading() still true after shutdown")
        luassert.are.equal("0", values[2],
            values[2] .. " handles left unresolved after shutdown")
    end)
end)
