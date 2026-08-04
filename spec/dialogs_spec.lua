local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local sdl = require("tecs.ffi.sdl3")
local platformOS = require("tecs.platform.os")
local runtime = require("tecs.internal.runtime")

-- SDL refuses a file dialog outright while this hint names a driver, and
-- refusing calls the completion callback before the show returns. That is the
-- one path a headless spec can drive: every other one opens a modal panel and
-- waits for a person.
local DRIVER_HINT = "SDL_FILE_DIALOG_DRIVER"

--- Counts the registrations the dialog source makes, and fails on the spot
--- when one arrives while the source already holds the registry or leaves
--- while it does not.
local function watchDialogSource()
    local register = runtime.register
    local unregister = runtime.unregister
    local watch = { registers = 0, releases = 0 }
    runtime.register = function(name, ...)
        if name == "dialogs" then
            assert.is_false(runtime.registered("dialogs"), "the dialog source registered twice")
            watch.registers = watch.registers + 1
        end
        return register(name, ...)
    end
    runtime.unregister = function(name, ...)
        if name == "dialogs" then
            assert.is_true(runtime.registered("dialogs"), "the dialog source released what it does not hold")
            watch.releases = watch.releases + 1
        end
        return unregister(name, ...)
    end
    watch.stop = function()
        runtime.register = register
        runtime.unregister = unregister
    end
    return watch
end

describe("platform.os dialogs", function()
    it("validates filters before opening a native dialog", function()
        assert.has_error(function()
            platformOS.openFile({ filters = { { name = "", pattern = "png" } } })
        end)
        assert.has_error(function()
            platformOS.saveFile({ filters = { { name = "Images", pattern = "" } } })
        end)
    end)

    it("keeps dialog progress private to the runtime", function()
        assert.is_nil(platformOS.updateDialogs)
    end)

    it("registers the runtime source once per dialog and releases it when the last one settles", function()
        assert.is_false(runtime.registered("dialogs"), "a previous test left the source registered")
        assert.is_true(sdl.C.SDL_SetHint(DRIVER_HINT, "none"))
        local watch = watchDialogSource()
        finally(function()
            watch.stop()
            sdl.C.SDL_ResetHint(DRIVER_HINT)
        end)

        assert.has_error(function()
            platformOS.openFile()
        end)
        assert.are.equal(1, watch.registers, "one dialog takes one registration")
        assert.are.equal(1, watch.releases, "the settled dialog releases the source")
        assert.is_false(runtime.registered("dialogs"), "no source remains for runtime.shutdown to find")

        -- The next dialog registers again from the released state.
        assert.has_error(function()
            platformOS.saveFile()
        end)
        assert.are.equal(2, watch.registers)
        assert.are.equal(2, watch.releases)
        assert.is_false(runtime.registered("dialogs"))

        assert.has_error(function()
            platformOS.openFolder()
        end)
        assert.are.equal(3, watch.registers)
        assert.are.equal(3, watch.releases)
        assert.is_false(runtime.registered("dialogs"))
    end)
end)
