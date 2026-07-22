require("busted")

local luassert <const> = require("luassert")

_G.love = require("spec.love2d.love2d_mock")

local tecs <const> = require("tecs")
local suspension <const> = require("tecs2d.internal.suspension")

describe("tecs2d.internal.suspension", function()
    local function makeWorld(): tecs.World, function(): integer
        local world = tecs.newWorld()
        local frames = 0
        world:addSystem({
            name = "test.FrameCounter",
            phase = tecs.phases.Update,
            run = function() frames = frames + 1 end,
        })
        return world, function(): integer return frames end
    end

    it("suspends on the first holder and resumes after the last", function()
        local world, frames = makeWorld()
        local controller = suspension.ensure(world)
        world:update(0.016)
        luassert.equals(1, frames())

        controller:suspend("mcp")
        world:update(0.016)
        world:update(0.016)
        luassert.equals(1, frames(), "gameplay ran while suspended")

        controller:suspend("debugger")
        controller:resume("mcp")
        world:update(0.016)
        luassert.equals(1, frames(), "second holder did not retain suspension")

        controller:resume("debugger")
        world:update(0.016)
        luassert.equals(2, frames(), "gameplay did not resume after the last holder")
    end)

    it("is idempotent per holder", function()
        local world, frames = makeWorld()
        local controller = suspension.ensure(world)
        luassert.is_true(controller:suspend("mcp"))
        luassert.is_false(controller:suspend("mcp"))
        luassert.is_true(controller:resume("mcp"))
        luassert.is_false(controller:resume("mcp"))
        world:update(0.016)
        luassert.equals(1, frames())
    end)

    it("steps exactly N gameplay frames, then suspends again", function()
        local world, frames = makeWorld()
        local controller = suspension.ensure(world)
        controller:suspend("debugger")
        world:update(0.016)
        luassert.equals(0, frames())

        luassert.is_true((controller:step(3)))
        for _ = 1, 8 do world:update(0.016) end
        luassert.equals(3, frames(), "step did not tick exactly 3 frames")
        controller:resume("debugger")
    end)

    it("rejects stepping while not suspended", function()
        local world = makeWorld()
        local controller = suspension.ensure(world)
        local ok, err = controller:step(2)
        luassert.is_false(ok)
        luassert.matches("not suspended", err)
    end)

    it("returns the same controller per world", function()
        local world = makeWorld()
        luassert.equals(suspension.ensure(world), suspension.ensure(world))
    end)
end)
