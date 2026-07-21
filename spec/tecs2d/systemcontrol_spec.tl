require("busted")

local tecs <const> = require("tecs")
local systemcontrol <const> = require("tecs2d.internal.systemcontrol")

describe("system control world ownership", function()
    it("keeps identically named systems independent", function()
        local a = tecs.newWorld()
        local b = tecs.newWorld()
        local aRuns, bRuns = 0, 0
        a:addSystem({name = "same.Name", phase = tecs.phases.Update,
            run = function() aRuns = aRuns + 1 end})
        b:addSystem({name = "same.Name", phase = tecs.phases.Update,
            run = function() bRuns = bRuns + 1 end})

        assert.is_true(systemcontrol.setEnabled(a, "same.Name", false))
        a:update(0)
        b:update(0)

        assert.equals(0, aRuns)
        assert.equals(1, bRuns)
        assert.is_false(systemcontrol.isEnabled(a, "same.Name"))
        assert.is_true(systemcontrol.isEnabled(b, "same.Name"))
    end)
end)
