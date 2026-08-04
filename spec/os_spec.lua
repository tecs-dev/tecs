local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local ffi = require("ffi")
local platformOS = require("tecs.platform.os")
local runtime = require("tecs.internal.runtime")

if ffi.os ~= "Windows" then
    ffi.cdef([[
        int getpid(void);
        int kill(int, int);
    ]])
end

describe("platform.os", function()
    local opened = {}

    local function ownSignals(selected)
        local listener = assert(platformOS.newSignalListener(selected))
        opened[#opened + 1] = listener
        return listener
    end

    after_each(function()
        for _, listener in ipairs(opened) do
            listener:close()
        end
        opened = {}
    end)

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

    it("validates signal selections before installing a handler", function()
        assert.has_error(function()
            platformOS.newSignalListener({})
        end, "tecs: platform.os.newSignalListener needs at least one signal")
        assert.has_error(function()
            platformOS.newSignalListener({ "interrupt", "interrupt" })
        end, 'tecs: duplicate process signal "interrupt"')
        assert.has_error(function()
            platformOS.newSignalListener({ "unknown" })
        end, 'tecs: unknown process signal "unknown"')
    end)

    it("holds the runtime source once while any signal listener is open", function()
        assert.is_false(runtime.registered("signals"), "a previous test left the source registered")

        local first = ownSignals({ "interrupt" })
        assert.is_true(runtime.registered("signals"), "an open listener holds the runtime source")

        local second = ownSignals({ "terminate" })
        assert.is_true(runtime.registered("signals"), "a second listener keeps the one registration")

        first:close()
        assert.is_true(runtime.registered("signals"), "the remaining listener still holds the source")

        second:close()
        assert.is_false(runtime.registered("signals"), "an idle facility releases the source")

        -- Closing twice neither raises nor disturbs the released state.
        second:close()
        assert.is_false(runtime.registered("signals"))

        -- The next listener registers again from the released state.
        local third = ownSignals()
        assert.is_true(runtime.registered("signals"))
        third:close()
        assert.is_false(runtime.registered("signals"))
    end)

    if ffi.os ~= "Windows" then
        it("delivers selected process signals through the runtime pump", function()
            local signals = ownSignals({ "hangup", "terminate" })

            assert.are.equal(0, signals:pending())
            assert.is_nil(signals:next())
            assert.are.equal(0, ffi.C.kill(ffi.C.getpid(), 1))
            assert.are.equal(1, runtime.poll())
            assert.are.equal(1, signals:pending())
            assert.are.equal("hangup", signals:next())
            assert.is_nil(signals:next())

            signals:close()

            assert.is_true(signals:isClosed())
        end)

        it("broadcasts one signal to every interested listener", function()
            local first = ownSignals({ "quit" })
            local second = ownSignals({ "quit" })

            assert.are.equal(0, ffi.C.kill(ffi.C.getpid(), 3))
            assert.are.equal(2, runtime.poll())
            assert.are.equal("quit", first:next())
            assert.are.equal("quit", second:next())

            first:close()
            second:close()
        end)

        it("filters signals independently and closes idempotently", function()
            local signals = ownSignals({ "terminate" })

            assert.are.equal(0, ffi.C.kill(ffi.C.getpid(), 1))
            assert.are.equal(0, runtime.poll())
            assert.is_nil(signals:next())
            assert.are.equal(0, ffi.C.kill(ffi.C.getpid(), 15))
            assert.are.equal(1, runtime.poll())
            assert.are.equal("terminate", signals:next())

            signals:close()
            signals:close()

            assert.has_error(function()
                signals:pending()
            end, "tecs: SignalListener:pending called after close")
        end)
    end
end)
