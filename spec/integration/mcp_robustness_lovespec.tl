--- Love2D integration suite: MCP boundary hardening. Tools that store
--- state consumed on later frames (screenshot, patch_entities, debug_*)
--- must validate input at the handler; nothing reachable from the socket
--- may crash the frame after the client already got a reply. Also covers
--- toggle_system's runIf restoration.
---
--- Run via `make test-love FILE_MATCH='mcp_robustness'`.

require("busted")
local luassert <const> = require("luassert")
local socket <const> = require("socket")
local fixture <const> = require("spec.integration.harness.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/compliance"

local sleep <const> = socket.sleep as function(number)

local function readFrames(app: fixture.App): integer
    local values = fixture.runLua(app, "return tecsTest.frames")
    return tonumber(values[1]) as integer
end

--- Assert the app keeps running frames (i.e. a poisoned command did not
--- kill the render loop).
local function expectAlive(app: fixture.App, context: string)
    local before = readFrames(app)
    local advanced = fixture.eventually(fixture.callTimeout, function(): integer
        local frames = readFrames(app)
        if frames > before then return frames end
        return nil
    end)
    luassert.is_number(advanced, context .. ": app stopped running frames")
end

--- Call a tool expecting a tool-level error envelope.
local function expectToolError(app: fixture.App, tool: string, args: {string: any}, context: string)
    local envelope, err = app.client:tryCall(tool, args)
    luassert.is_nil(err, context .. ": transport error: " .. tostring(err))
    luassert.is_table(envelope, context .. ": no envelope")
    luassert.are.equal(false, envelope.ok as boolean,
        context .. ": expected a tool error, got ok response")
end

describe("mcp robustness: hostile input survives", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("debug_* tools without the debug plugin fail cleanly", function()
        -- This app installs only the MCP plugin; every registry-derived
        -- debugger tool must answer with a debugger_disabled error rather
        -- than crashing or hanging the connection.
        expectToolError(app, "debug_draw_rect",
            {x = 10, y = 10, w = 20, h = 20}, "draw without debug plugin")
        expectToolError(app, "debug_select", {id = 1}, "select without debug plugin")
        expectAlive(app, "after debugger-disabled calls")
    end)

    it("unknown debug_* names still answer cleanly without the plugin", function()
        -- Without the debug plugin the server cannot resolve debug_* names,
        -- so even a bogus one gets the debugger_disabled envelope.
        expectToolError(app, "debug_draw", {type = "rect"}, "retired debug_draw name")
        expectAlive(app, "after unknown debug tool")
    end)

    it("rejects invalid screenshot regions and keeps the connection usable", function()
        expectToolError(app, "screenshot",
            {x = 0, y = 0, width = -5, height = 10}, "negative width")
        expectToolError(app, "screenshot",
            {x = 0, y = 0, width = 10}, "partial region")
        expectAlive(app, "after invalid screenshot regions")

        -- The pending-screenshot slot must not be wedged: a valid
        -- screenshot must still work.
        local base64 = app.client:screenshot({x = 0, y = 0, width = 32, height = 32})
        luassert.is_string(base64, "valid screenshot after rejected region failed")
    end)

    it("rejects patch_entities with non-numeric ids and survives", function()
        expectToolError(app, "patch_entities",
            {ids = {"abc"}, set = {}}, "string id")
        sleep(0.3)  -- the drain runs a frame later; a crash would land there
        expectAlive(app, "after string id patch")
    end)

    it("toggle_system restores runIf across disable/enable cycles", function()
        for _ = 1, 5 do
            app.client:call("toggle_system", {name = "test.FrameCounter", enabled = false})
            app.client:call("toggle_system", {name = "test.FrameCounter", enabled = true})
        end
        local values = fixture.runLua(app, [[
            local pipeline = world.pipeline
            local position = pipeline.systemNameRegistry["test.FrameCounter"]
            for _, config in ipairs(pipeline.systems[position]) do
                if config.name == "test.FrameCounter" then
                    return type(config.runIf)
                end
            end
            return "system-not-found"
        ]])
        luassert.are.equal("nil", values[1],
            "runIf not restored after disable/enable cycles (type: " .. values[1] .. ")")
        expectAlive(app, "after toggle cycles")
    end)
end)
