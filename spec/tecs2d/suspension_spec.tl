require("busted")

local luassert <const> = require("luassert")
rawset(_G, "love", require("spec.love2d.love2d_mock"))

local tecs <const> = require("tecs")
local suspension <const> = require("tecs2d.suspension")

describe("tecs2d.suspension", function()
    it("composes named holders while render phases continue", function()
        local world = tecs.newWorld()
        local updates, renders = 0, 0
        world:addSystem({
            name = "test.Update",
            phase = tecs.phases.Update,
            run = function() updates = updates + 1 end,
        })
        world:addSystem({
            name = "test.Render",
            phase = tecs.phases.Render,
            run = function() renders = renders + 1 end,
        })

        luassert.is_true(suspension.suspend(world, "loading"))
        luassert.is_false(suspension.suspend(world, "loading"))
        luassert.is_true(suspension.suspend(world, "operator"))
        world:update(0.016)
        luassert.equals(0, updates)
        luassert.equals(1, renders)

        suspension.resume(world, "loading")
        world:update(0.016)
        luassert.equals(0, updates)
        luassert.equals(2, renders)

        suspension.resume(world, "operator")
        world:update(0.016)
        luassert.equals(1, updates)
        luassert.equals(3, renders)
    end)

    it("reports state and validates holder names", function()
        local world = tecs.newWorld()
        luassert.is_false(suspension.isSuspended(world))
        suspension.suspend(world, "loading")
        luassert.is_true(suspension.isSuspended(world))
        luassert.is_true(suspension.heldBy(world, "loading"))
        luassert.has_error(function()
            suspension.resume(world, "")
        end, "suspension holder must be a non-empty string")
    end)
end)
