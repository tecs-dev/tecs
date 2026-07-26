-- The MCP server.
--
-- Two halves worth testing separately. `dispatch` is the protocol and needs no
-- socket, so most cases live there. Then one test drives a real request over a
-- real connection, because framing is the part that cannot be checked any
-- other way: a Content-Length that disagrees with the body, or a response
-- closed before it drained, both look fine from inside.

local root = os.getenv("TECS2D_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. "../tecs/build/?.lua;../tecs/build/?/init.lua;" .. package.path

local cjson = require("cjson")
local sdl = require("tecs2d.ffi.sdl3")
local net = require("tecs2d.ffi.sdl3net")
local loader = require("tecs2d.ffi.loader")
local mcp = require("tecs2d.mcp")

local C = sdl.C
local N = net.C
local PORT = 7411

local function rpc(method, params, id)
    return mcp.dispatch(cjson.encode({
        jsonrpc = "2.0", id = id or 1, method = method, params = params,
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
            handler = function(args) return { echoed = args.value } end,
        })
        mcp.register({
            name = "spec_boom",
            description = "Always fails.",
            handler = function() error("deliberate") end,
        })
    end)
    teardown(function() C.SDL_Quit() end)

    it("answers initialize with a protocol version", function()
        local result = cjson.decode(rpc("initialize")).result
        assert.is_string(result.protocolVersion)
        assert.are.equal("tecs2d", result.serverInfo.name)
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
        local result = cjson.decode(
            rpc("tools/call", { name = "spec_echo", arguments = { value = 42 } })).result
        assert.are.equal(42, result.structuredContent.echoed)
        -- The text block carries the same payload, for a client that only
        -- reads content.
        assert.are.equal(42, cjson.decode(result.content[1].text).echoed)
    end)

    it("reports a failing tool without taking the server down", function()
        local result = cjson.decode(
            rpc("tools/call", { name = "spec_boom" })).result
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
        assert.are.equal(-32600,
            cjson.decode(mcp.dispatch('{"jsonrpc":"2.0","id":1}')).error.code)
    end)

    it("preserves the request id, including a string one", function()
        assert.are.equal("abc", cjson.decode(rpc("initialize", nil, "abc")).id)
    end)
end)

describe("mcp over a socket", function()
    local server

    setup(function()
        assert(C.SDL_Init(0))
        assert(N.NET_Init())
        server = mcp.listen(PORT)
    end)

    teardown(function()
        if server then server:destroy() end
        N.NET_Quit()
        C.SDL_Quit()
    end)

    it("serves a real request over a real connection", function()
        local address = N.NET_ResolveHostname("127.0.0.1")
        assert.is_not_nil(address)
        assert.are.equal(1, tonumber(N.NET_WaitUntilResolved(address, 2000)))

        local socket = N.NET_CreateClient(address, PORT, 0)
        assert.is_not_nil(socket)
        assert.are.equal(1, tonumber(N.NET_WaitUntilConnected(socket, 2000)))

        local body = cjson.encode({
            jsonrpc = "2.0", id = 9, method = "tools/call",
            params = { name = "spec_echo", arguments = { value = "over the wire" } },
        })
        local request = table.concat({
            "POST /mcp HTTP/1.1\r\n",
            "Host: 127.0.0.1\r\n",
            "Content-Type: application/json\r\n",
            ("Content-Length: %d\r\n\r\n"):format(#body),
            body,
        })
        assert.is_true(N.NET_WriteToStreamSocket(socket, request, #request))

        -- The server only answers when polled, which is the whole design: it
        -- runs on the game's thread, inside a frame.
        local answered = false
        for _ = 1, 200 do
            if server:poll() then answered = true break end
            C.SDL_Delay(5)
        end
        assert.is_true(answered, "the server never saw the request")

        local buffer = loader.newArray("uint8_t[?]", 65536)
        local text = ""
        for _ = 1, 200 do
            local read = tonumber(N.NET_ReadFromStreamSocket(socket, buffer, 65536))
            if read > 0 then
                text = text .. loader.toBytes(buffer, read)
                if text:find("\r\n\r\n", 1, true) then break end
            elseif read < 0 then
                break
            end
            C.SDL_Delay(5)
        end
        N.NET_DestroyStreamSocket(socket)

        assert.is_truthy(text:find("^HTTP/1.1 200 OK"))
        local length = tonumber(text:lower():match("content%-length:%s*(%d+)"))
        local payload = text:sub(text:find("\r\n\r\n", 1, true) + 4)
        assert.are.equal(length, #payload,
            "the declared length must match what was sent")

        local decoded = cjson.decode(payload)
        assert.are.equal(9, decoded.id)
        assert.are.equal("over the wire", decoded.result.structuredContent.echoed)
    end)
end)
