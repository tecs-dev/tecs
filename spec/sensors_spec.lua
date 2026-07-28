local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local sensors = require("tecs.platform.sensors")

describe("platform.sensors", function()
    it("enumerates standalone devices without requiring one", function()
        local devices, err = sensors.sensors()
        assert.are.equal("table", type(devices))
        if err ~= nil then
            assert.are.equal("string", type(err))
        end
        for _, device in ipairs(devices) do
            assert.are.equal("number", type(device.id))
            assert.are.equal("string", type(device.name))
            assert.are.equal("string", type(device.kind))
            assert.are.equal("number", type(device.platformType))
        end
    end)

    it("reports an invalid sensor id instead of producing a handle", function()
        local sensor, err = sensors.openSensor(0)
        assert.is_nil(sensor)
        assert.are.equal("string", type(err))
    end)
end)
