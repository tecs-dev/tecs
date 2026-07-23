--- Love2D integration suite: MCP boundary hardening. Tools that store
--- state consumed on later frames (screenshot, the cmd_* command tools)
--- must validate input at the handler; nothing reachable from the socket
--- may crash the frame after the client already got a reply. Also covers
--- runIf restoration across cmd_systems stop/start cycles.
---
--- Run via `make test-love FILE_MATCH='mcp_robustness'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs2d.testing.fixture")
local json <const> = require("tecs.utils.json")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/compliance"

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

    it("cmd_* tools work without the debug plugin", function()
        -- This app installs only the MCP plugin, which ensures the headless
        -- debugger core: registry-derived debugger tools answer normally, and
        -- a hostile call still gets a tool-level error rather than crashing
        -- or hanging the connection.
        local spawned = app.client:call("cmd_spawn", {spec = "Transform {x = 10, y = 10}"})
        luassert.is_number(spawned.id as number, "spawn without debug plugin: no entity id")
        local context = app.client:call("cmd_context")
        luassert.is_number(context.entityCount,
            "context without debug plugin: no world information")
        expectToolError(app, "cmd_select", {id = 999999}, "select of a dead id")
        expectAlive(app, "after headless debugger calls")
    end)

    it("unknown cmd_* names still answer cleanly", function()
        local envelope, err = app.client:tryCall("cmd_not_real", {})
        luassert.is_nil(envelope, "unknown cmd_* tool: expected no envelope")
        luassert.matches("unknown debugger tool", tostring(err))
        expectAlive(app, "after unknown debug tool")
    end)

    it("preserves string JSON-RPC ids", function()
        local body, requestErr = app.client:request(json.serialize({
            jsonrpc = "2.0",
            id = "request-7",
            method = "tools/list",
        }))
        luassert.is_nil(requestErr)
        local response = json.parse(body) as {string: any}
        luassert.are.equal("request-7", response.id)
        luassert.is_table((response.result as {string: any}).tools)
    end)

    it("rejects malformed JSON-RPC envelopes and tool arguments", function()
        local bareBody, bareErr = app.client:request("7")
        luassert.is_nil(bareErr)
        local bareResponse = json.parse(bareBody) as {string: any}
        local bareRpcError = bareResponse.error as {string: any}
        luassert.are.equal(-32600, bareRpcError.code)
        luassert.are.equal(json.NULL, bareResponse.id)

        local nullIdBody, nullIdErr = app.client:request(json.serialize({
            jsonrpc = "2.0",
            id = json.NULL,
            method = "tools/list",
        }))
        luassert.is_nil(nullIdErr)
        local nullIdResponse = json.parse(nullIdBody) as {string: any}
        luassert.are.equal(-32600,
            (nullIdResponse.error as {string: any}).code)

        local argsBody, argsErr = app.client:request(json.serialize({
            jsonrpc = "2.0",
            id = "bad-args",
            method = "tools/call",
            params = {name = "ping", arguments = "not-an-object"},
        }))
        luassert.is_nil(argsErr)
        local argsResponse = json.parse(argsBody) as {string: any}
        luassert.are.equal("bad-args", argsResponse.id)
        luassert.are.equal(-32602,
            (argsResponse.error as {string: any}).code)
        expectAlive(app, "after malformed protocol input")
    end)

    it("negotiates unsupported protocol versions to the server version", function()
        local response, rpcErr = app.client:rpc("initialize", {
            protocolVersion = "2099-01-01",
            capabilities = {},
            clientInfo = {name = "spec", version = "1"},
        })
        luassert.is_nil(rpcErr)
        luassert.are.equal("2025-11-25",
            (response.result as {string: any}).protocolVersion)
    end)

    it("rejects incomplete initialize requests", function()
        local response, rpcErr = app.client:rpc("initialize", {
            protocolVersion = "2025-11-25",
        })
        luassert.is_nil(rpcErr)
        luassert.are.equal(-32602,
            (response.error as {string: any}).code)
        expectAlive(app, "after incomplete initialize")
    end)

    it("acknowledges notifications without a JSON-RPC body", function()
        local body, requestErr = app.client:request(json.serialize({
            jsonrpc = "2.0",
            method = "notifications/initialized",
        }))
        luassert.is_nil(requestErr)
        luassert.are.equal("", body)
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

    it("validates every kernel tool against its advertised schema", function()
        expectToolError(app, "ping", {extra = true},
            "unknown ping argument")
        expectToolError(app, "run_lua", {code = 42},
            "non-string Lua source")
        expectToolError(app, "send_love_event", {event = 7},
            "non-string event name")
        expectToolError(app, "sample_pixels", {
            points = {{x = 1, y = 1}},
            normalized = "yes",
        }, "non-boolean normalized flag")
        expectAlive(app, "after invalid kernel tool arguments")
    end)

    it("rejects cmd_set with non-numeric ids and survives", function()
        expectToolError(app, "cmd_set",
            {ids = {"abc"}, comp = "Transform", value = {x = 0}}, "string id")
        expectAlive(app, "after string id set")
    end)

    it("cmd_systems stop/start restores runIf across cycles", function()
        for _ = 1, 5 do
            app.client:call("cmd_systems_stop", {name = "test.FrameCounter"})
            app.client:call("cmd_systems_start", {name = "test.FrameCounter"})
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
