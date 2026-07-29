-- The MCP server.
--
-- Two halves worth testing separately. `dispatch` is the protocol and needs no
-- socket, so most cases live there. Then one test drives a real request over a
-- real connection, because framing is the part that cannot be checked any
-- other way: a Content-Length that disagrees with the body, or a response
-- closed before it drained, both look fine from inside.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local cjson = require("cjson")
local sdl = require("tecs.ffi.sdl3")
local net = require("tecs.net")
local mcp = require("tecs.mcp")
local sandbox = require("tecs.mcp.sandbox")

local C = sdl.C
local PORT = 7411

local function rpc(method, params, id)
    return mcp.dispatch(cjson.encode({
        jsonrpc = "2.0",
        id = id or 1,
        method = method,
        params = params,
    }))
end

describe("mcp protocol", function()
    setup(function()
        assert(C.SDL_Init(0))
        mcp.register({
            name = "spec_echo",
            description = "Returns what it was given.",
            readOnly = true,
            inputSchema = { type = "object" },
            handler = function(args)
                return { echoed = args.value }
            end,
        })
        mcp.register({
            name = "spec_boom",
            description = "Always fails.",
            handler = function()
                error("deliberate")
            end,
        })
    end)
    teardown(function()
        C.SDL_Quit()
    end)

    it("answers initialize with a protocol version", function()
        local result = cjson.decode(rpc("initialize")).result
        assert.is_string(result.protocolVersion)
        assert.are.equal("tecs", result.serverInfo.name)
    end)

    it("lists tools from the same table that dispatches them", function()
        -- One registry, so a tool cannot be callable but unlisted, which is
        -- the failure mode of keeping a hand-written list beside it.
        local listed = {}
        for _, tool in ipairs(cjson.decode(rpc("tools/list")).result.tools) do
            listed[tool.name] = tool
        end
        assert.is_not_nil(listed.spec_echo)
        assert.are.equal("Returns what it was given.", listed.spec_echo.description)
        assert.is_true(listed.spec_echo.annotations.readOnlyHint)
        assert.is_false(listed.spec_boom.annotations.readOnlyHint)

        for _, tool in ipairs(mcp.tools()) do
            assert.is_not_nil(listed[tool.name], tool.name .. " must be listed")
        end
    end)

    it("calls a tool and returns structured content", function()
        local result = cjson.decode(rpc("tools/call", { name = "spec_echo", arguments = { value = 42 } })).result
        assert.are.equal(42, result.structuredContent.echoed)
        -- The text block carries the same payload, for a client that only
        -- reads content.
        assert.are.equal(42, cjson.decode(result.content[1].text).echoed)
    end)

    it("reports a failing tool without taking the server down", function()
        local result = cjson.decode(rpc("tools/call", { name = "spec_boom" })).result
        assert.is_true(result.isError)
        assert.is_truthy(result.content[1].text:find("deliberate", 1, true))

        -- Still serving afterwards.
        assert.is_not_nil(cjson.decode(rpc("initialize")).result)
    end)

    it("rejects an unknown tool and an unknown method", function()
        local missing = cjson.decode(rpc("tools/call", { name = "nope" }))
        assert.are.equal(-32601, missing.error.code)
        assert.are.equal(-32601, cjson.decode(rpc("no/such")).error.code)
    end)

    it("survives malformed input", function()
        assert.are.equal(-32700, cjson.decode(mcp.dispatch("{not json")).error.code)
        assert.are.equal(-32600, cjson.decode(mcp.dispatch('{"jsonrpc":"2.0","id":1}')).error.code)
    end)

    it("preserves the request id, including a string one", function()
        assert.are.equal("abc", cjson.decode(rpc("initialize", nil, "abc")).id)
    end)
end)

describe("run_lua sandbox", function()
    before_each(function()
        sandbox.reset()
    end)

    it("runs a statement block and a bare expression alike", function()
        -- An agent types `1 + 1` as often as `return 1 + 1`, and having to
        -- know which is being parsed is friction with no upside.
        local block = sandbox.compile("return 1 + 1")
        assert.are.equal(2, block())
        local expression = sandbox.compile("2 + 3")
        assert.are.equal(5, expression())
    end)

    it("passes the world as the first argument", function()
        local chunk = sandbox.compile("return world.marker")
        assert.are.equal("here", chunk({ marker = "here" }))
    end)

    it("keeps globals between calls", function()
        -- What makes an exploratory session possible: stash a handle now, read
        -- it back in the next call.
        sandbox.compile("stashed = 41")()
        assert.are.equal(42, sandbox.compile("return stashed + 1")())
    end)

    it("forgets them on reset", function()
        sandbox.compile("stashed = 1")()
        sandbox.reset()
        assert.is_nil(sandbox.compile("return stashed")())
    end)

    it("withholds what damages the machine rather than the game", function()
        -- A guard rail, not a security boundary. An agent exploring a world
        -- should not delete a file by mistyping a table name.
        assert.is_nil(sandbox.compile("return io")())
        assert.is_nil(sandbox.compile("return os.execute")())
        assert.is_nil(sandbox.compile("return os.remove")())
        assert.is_nil(sandbox.compile("return dofile")())
        -- But the things a session actually needs are there.
        assert.is_not_nil(sandbox.compile("return os.time")())
        assert.is_not_nil(sandbox.compile("return require")())
        assert.is_not_nil(sandbox.compile("return math.floor")())
    end)

    it("reports a syntax error rather than raising", function()
        local chunk, reason = sandbox.compile("this is not lua")
        assert.is_nil(chunk)
        assert.is_string(reason)
    end)

    it("describes values JSON cannot carry", function()
        -- Returning a function by accident should answer, not fail the call.
        assert.are.equal(1, sandbox.describe(1))
        assert.is_truthy(tostring(sandbox.describe(print)):find("function", 1, true))
        assert.are.same({ 1, 2, 3 }, sandbox.describe({ 1, 2, 3 }))
        assert.are.equal("b", sandbox.describe({ a = "b" }).a)

        -- And a cycle terminates instead of hanging.
        local loop = {}
        loop.self = loop
        assert.is_not_nil(sandbox.describe(loop))
    end)
end)

describe("mcp after a crash", function()
    -- The server outliving the game is the point of it. An agent debugging
    -- something up to the moment it broke should get the reason, not a
    -- refused connection.

    setup(function()
        assert(C.SDL_Init(0))
        mcp.register({
            name = "spec_world",
            description = "Touches the world.",
            handler = function()
                return { touched = true }
            end,
        })
        mcp.register({
            name = "spec_survives",
            description = "Does not touch the world.",
            readOnly = true,
            whenCrashed = true,
            handler = function()
                return { alive = true }
            end,
        })
    end)

    teardown(function()
        mcp.setCrashed(nil)
        C.SDL_Quit()
    end)

    it("refuses world tools and keeps the rest, with the traceback", function()
        assert.is_nil(mcp.crashed())
        assert.is_true(cjson.decode(rpc("tools/call", { name = "spec_world" })).result.structuredContent.touched)

        mcp.setCrashed("spec.lua:1: deliberate\nstack traceback:\n\t...")
        assert.is_not_nil(mcp.crashed())

        local refused = cjson.decode(rpc("tools/call", { name = "spec_world" })).result
        assert.is_true(refused.isError)
        assert.is_true(refused.crashed)
        assert.is_truthy(
            refused.content[1].text:find("deliberate", 1, true),
            "the traceback is what the agent came for"
        )

        local survived = cjson.decode(rpc("tools/call", { name = "spec_survives" })).result
        assert.is_true(survived.structuredContent.alive)

        -- And the protocol itself keeps working, so an agent can still find
        -- out which tools remain.
        assert.is_not_nil(cjson.decode(rpc("tools/list")).result.tools)
    end)

    it("advertises which tools outlive a crash", function()
        for _, tool in ipairs(cjson.decode(rpc("tools/list")).result.tools) do
            if tool.name == "spec_survives" then
                assert.is_true(tool.annotations.whenCrashedHint)
            elseif tool.name == "spec_world" then
                assert.is_false(tool.annotations.whenCrashedHint)
            end
        end
    end)

    it("recovers when the crash is cleared", function()
        mcp.setCrashed(nil)
        assert.is_true(cjson.decode(rpc("tools/call", { name = "spec_world" })).result.structuredContent.touched)
    end)
end)

describe("mcp over a socket", function()
    local server

    setup(function()
        assert(C.SDL_Init(0))
        assert(net.init())
        server = mcp.listen(PORT)
    end)

    teardown(function()
        if server then
            server:destroy()
        end
        assert(net.quit())
        C.SDL_Quit()
    end)

    local function connect()
        local resolved = net.resolve("127.0.0.1"):wait(2000)
        assert.are.equal("ready", resolved.status, resolved.error)
        local address = resolved.value
        local connected = net.connect(address, PORT):wait(2000)
        address:close()
        assert.are.equal("ready", connected.status, connected.error)
        return connected.value
    end

    local function request(body, extraHeaders, pollTool)
        local socket = connect()
        local headers = table.concat({
            "POST /mcp HTTP/1.1\r\n",
            "Host: 127.0.0.1\r\n",
            "Accept: application/json, text/event-stream\r\n",
            "Content-Type: application/json\r\n",
            extraHeaders or "",
            ("Content-Length: %d\r\n"):format(#body),
            "Connection: close\r\n\r\n",
        })
        assert(socket:write(headers .. body))
        assert(socket:drain(2000))

        local text = ""
        for _ = 1, 400 do
            if pollTool then
                server:poll()
            end
            local bytes, reason = socket:read(65536)
            if reason ~= nil then
                assert.are.equal("connection closed", reason)
                break
            elseif bytes ~= nil then
                text = text .. bytes
                local headEnd = text:find("\r\n\r\n", 1, true)
                if headEnd ~= nil then
                    local length = tonumber(text:sub(1, headEnd):lower():match("content%-length:%s*(%d+)"))
                    if length ~= nil and #text - headEnd - 3 >= length then
                        break
                    end
                end
            else
                socket:wait(5)
            end
        end
        socket:close()
        return text
    end

    local function body(text)
        local headEnd = assert(text:find("\r\n\r\n", 1, true))
        return text:sub(headEnd + 4)
    end

    local function dechunk(text)
        local encoded = body(text)
        local chunks = {}
        local at = 1
        while true do
            local lineEnd = assert(encoded:find("\r\n", at, true))
            local length = assert(tonumber(encoded:sub(at, lineEnd - 1), 16))
            at = lineEnd + 2
            if length == 0 then
                break
            end
            chunks[#chunks + 1] = encoded:sub(at, at + length - 1)
            at = at + length
            assert.are.equal("\r\n", encoded:sub(at, at + 1))
            at = at + 2
        end
        return table.concat(chunks)
    end

    it("serves official Streamable HTTP and queues the tool on poll", function()
        local initialized = request(cjson.encode({
            jsonrpc = "2.0",
            id = 1,
            method = "initialize",
            params = {
                protocolVersion = "2025-06-18",
                capabilities = {},
                clientInfo = { name = "tecs-spec", version = "1" },
            },
        }))
        assert.is_truthy(initialized:find("^HTTP/1.1 200 OK"))
        local session = assert(initialized:lower():match("mcp%-session%-id:%s*([^\r\n]+)"))

        local common = table.concat({
            ("Mcp-Session-Id: %s\r\n"):format(session),
            "MCP-Protocol-Version: 2025-06-18\r\n",
        })
        request(
            cjson.encode({
                jsonrpc = "2.0",
                method = "notifications/initialized",
            }),
            common
        )
        local callBody = cjson.encode({
            jsonrpc = "2.0",
            id = 9,
            method = "tools/call",
            params = { name = "spec_echo", arguments = { value = "over the wire" } },
        })
        local text = request(callBody, common, true)
        assert.is_truthy(text:find("^HTTP/1.1 200 OK"))
        assert.is_truthy(text:lower():find("content%-type: text/event%-stream"))
        assert.is_truthy(text:lower():find("transfer%-encoding: chunked"))
        local payload = assert(dechunk(text):match("data: (%b{})"))

        local decoded = cjson.decode(payload)
        assert.are.equal(9, decoded.id)
        assert.are.equal("over the wire", decoded.result.structuredContent.echoed)
    end)
end)
