local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local system = require("tecs.platform.system")

describe("platform.system dialogs", function()
    it("validates filters before opening a native dialog", function()
        assert.has_error(function()
            system.openFile({ filters = { { name = "", pattern = "png" } } })
        end)
        assert.has_error(function()
            system.saveFile({ filters = { { name = "Images", pattern = "" } } })
        end)
    end)

    it("can poll when no dialog is pending", function()
        assert.are.equal(0, system.updateDialogs())
    end)
end)
