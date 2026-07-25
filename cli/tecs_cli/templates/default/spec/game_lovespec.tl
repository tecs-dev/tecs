-- Integration spec run by `tecs integ`: boots the built game under real
-- Love on a free MCP port and drives it live. See tecs2d.testing.fixture
-- for runLua, probePixels, and eventually helpers.
local fixture <const> = require("tecs2d.testing.fixture")
local luassert <const> = require("luassert")

describe("the game", function()
    local app: fixture.App

    setup(function()
        app = fixture.start("build")
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("boots and responds over MCP", function()
        local values = fixture.runLua(app, "return 1 + 1")
        luassert.equal("2", values[1])
    end)

    it("runs inside Love 12", function()
        local values = fixture.runLua(app, "return love.getVersion()")
        luassert.equal("12", values[1])
    end)
end)
