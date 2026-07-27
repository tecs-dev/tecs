-- The lifecycle the host drives.
--
-- Everything here goes through the same four methods `host.c` calls, because
-- the interesting failures are the ones where a subsystem is never told a
-- frame happened. Asset loading is the case that motivated this: a handle is
-- resolved by a pump, and a game that loads an image and nothing else has no
-- other reason for anything to call one.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. package.path

local Application = require("tecs.Application")
local assets = require("tecs.assets")

local FIXTURE = "spec/fixtures/split.png"

--- An application with a window small enough to be cheap and no log file.
local function build(config)
    config.window = { title = "application", width = 64, height = 64 }
    config.logFile = ""
    return Application.create(config)
end

describe("Application", function()
    it("resolves asset handles without the game pumping them", function()
        local handle
        local app = build({
            load = function()
                assets.install()
                handle = assets.loadImage(FIXTURE)
            end,
        })
        assert.is_true(app:_init())
        assert.are.equal("loading", handle.status)

        -- Nothing in this application draws text or plays a sound, so the two
        -- subsystems with pumps of their own never run. Only the loop's own
        -- call can move this handle.
        for _ = 1, 200 do
            if handle.status ~= "loading" then break end
            app:_iterate(nil, 0, nil)
        end

        assert.are.equal("ready", handle.status,
            "the loop never drained the loading worker")
        assert.is_not_nil(handle.pixels)
        handle:release()

        app:_shutdown()
    end)

    it("stops the loading worker at shutdown", function()
        local app = build({
            load = function() assets.install() end,
        })
        assert.is_true(app:_init())
        assert.is_true(assets.installed())

        app:_shutdown()
        assert.is_false(assets.installed(),
            "the decoding thread outlived the application")
    end)

    it("shuts down cleanly when nothing ever loaded an asset", function()
        local app = build({})
        assert.is_true(app:_init())
        app:_iterate(nil, 0, nil)
        assert.is_true(app:_shutdown())
        assert.is_false(assets.installed())
    end)
end)
