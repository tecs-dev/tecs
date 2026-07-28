local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local audio = require("tecs.platform.audio")

describe("platform.audio", function()
    it("enumerates playback and recording devices without requiring hardware", function()
        for _, enumerate in ipairs({ audio.playbackDevices, audio.recordingDevices }) do
            local devices, err = enumerate()
            assert.are.equal("table", type(devices))
            if err ~= nil then
                assert.are.equal("string", type(err))
            end
            for _, device in ipairs(devices) do
                assert.are.equal("number", type(device.id))
                assert.are.equal("string", type(device.name))
                assert.are.equal("number", type(device.frequency))
                assert.are.equal("number", type(device.channels))
            end
        end
    end)

    it("validates microphone formats before opening hardware", function()
        local microphone, err = audio.openMicrophone({ frequency = 0 })
        assert.is_nil(microphone)
        assert.matches("frequency", err)

        microphone, err = audio.openMicrophone({ channels = 33 })
        assert.is_nil(microphone)
        assert.matches("channels", err)
    end)
end)
