require("busted")

local luassert <const> = require("luassert")

_G.love = require("spec.love2d.love2d_mock")

local tecs <const> = require("tecs")
local freeze <const> = require("tecs2d.debug.internal.freeze")

describe("tecs2d.debug.internal.freeze", function()
    -- A world with an Update-phase frame counter, so gameplay progress is
    -- observable through the freeze controller's phase gating.
    local function makeWorld(): tecs.World, function(): integer
        local w = tecs.newWorld()
        local frames = 0
        w:addSystem({
            name = "test.FrameCounter",
            phase = tecs.phases.Update,
            run = function() frames = frames + 1 end,
        })
        return w, function(): integer return frames end
    end

    it("freezes on first acquire and thaws on last release", function()
        local w, frames = makeWorld()
        local fz = freeze.ensure(w)
        w:update(0.016)
        luassert.equals(1, frames())

        fz:acquire("mcp")
        w:update(0.016)
        w:update(0.016)
        luassert.equals(1, frames(), "gameplay ran while frozen")

        fz:acquire("debugger")
        fz:release("mcp")
        w:update(0.016)
        luassert.equals(1, frames(), "second holder did not keep the freeze")

        fz:release("debugger")
        w:update(0.016)
        luassert.equals(2, frames(), "gameplay did not resume after last release")
    end)

    it("is idempotent per holder", function()
        local w, frames = makeWorld()
        local fz = freeze.ensure(w)
        luassert.is_true(fz:acquire("mcp"))
        luassert.is_false(fz:acquire("mcp"))
        luassert.is_true(fz:release("mcp"))
        luassert.is_false(fz:release("mcp"))
        w:update(0.016)
        luassert.equals(1, frames())
    end)

    it("steps exactly N gameplay frames, then re-freezes", function()
        local w, frames = makeWorld()
        local fz = freeze.ensure(w)
        fz:acquire("debugger")
        w:update(0.016)
        luassert.equals(0, frames())

        luassert.is_true((fz:step(3)))
        -- One warm-up update enables the phases; the next three tick gameplay.
        for _ = 1, 8 do w:update(0.016) end
        luassert.equals(3, frames(), "step did not tick exactly 3 frames")

        fz:release("debugger")
    end)

    it("rejects stepping while not frozen", function()
        local w = makeWorld()
        local fz = freeze.ensure(w)
        local ok, err = fz:step(2)
        luassert.is_false(ok)
        luassert.matches("not frozen", err)
    end)

    it("returns the same controller per world", function()
        local w = makeWorld()
        luassert.equals(freeze.ensure(w), freeze.ensure(w))
    end)
end)
