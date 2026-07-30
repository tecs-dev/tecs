local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local platformOS = require("tecs.platform.os")

describe("platform.os", function()
    it("returns preferred locales as owned strings", function()
        local locales = platformOS.preferredLocales()
        assert.are.equal("table", type(locales))
        for _, locale in ipairs(locales) do
            assert.are.equal("string", type(locale.language))
            assert.are.equal("string", type(locale.country))
        end
    end)

    it("reports power with stable unknown sentinels", function()
        local power = platformOS.power()
        local states = {
            error = true,
            unknown = true,
            onBattery = true,
            noBattery = true,
            charging = true,
            charged = true,
        }
        assert.is_true(states[power.state])
        assert.are.equal("number", type(power.seconds))
        assert.are.equal("number", type(power.percent))
    end)

    it("refuses an empty URL without launching anything", function()
        local ok, err = platformOS.openURL("")
        assert.is_false(ok)
        assert.matches("required", err)
    end)

    it("refuses an unknown message-box kind without showing one", function()
        local ok, err = platformOS.messageBox("question", "title", "message")
        assert.is_false(ok)
        assert.matches("unknown", err)
    end)
end)
