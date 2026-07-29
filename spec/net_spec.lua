-- Public networking over loopback only.
--
-- These specs never depend on a real host or DNS server. Numeric loopback
-- still exercises Rust's asynchronous resolver, and TCP/UDP packets never
-- leave the machine. A free port is selected from a private range rather than
-- assuming one fixed port is available on a developer workstation.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local sdl = require("tecs.ffi.sdl3")

local C = sdl.C
local net = tecs.net

local nextPort = 27140

local function listen()
    for _ = 1, 100 do
        local port = nextPort
        nextPort = nextPort + 1
        local server = net.listen(port)
        if server then
            return server, port
        end
    end
    error("no loopback TCP port available")
end

local function bind()
    for _ = 1, 100 do
        local port = nextPort
        nextPort = nextPort + 1
        local socket = net.bind(port)
        if socket then
            return socket, port
        end
    end
    error("no loopback UDP port available")
end

local function resolved()
    local future = net.resolve("127.0.0.1")
    future:wait(2000)
    assert.are.equal("ready", future.status, future.error)
    return future.value
end

local function connected(address, server, port)
    local future = net.connect(address, port)
    future:wait(2000)
    assert.are.equal("ready", future.status, future.error)
    assert.is_true(server:wait(2000))
    local accepted, reason = server:accept()
    assert.is_not_nil(accepted, reason)
    return future.value, accepted
end

local function readExactly(stream, length, chunk)
    local pieces = {}
    local total = 0
    local deadline = C.SDL_GetTicks() + 2000
    while total < length and C.SDL_GetTicks() < deadline do
        local ready, reason = stream:wait(50)
        assert.is_nil(reason)
        if ready then
            local bytes, readReason = stream:read(chunk)
            assert.is_nil(readReason)
            if bytes then
                pieces[#pieces + 1] = bytes
                total = total + #bytes
            end
        end
    end
    assert.are.equal(length, total)
    return table.concat(pieces), pieces
end

describe("tecs.net", function()
    setup(function()
        assert(C.SDL_Init(0))
        assert.is_true(net.init())
    end)

    teardown(function()
        local ok, reason = net.quit()
        assert.is_true(ok, reason)
        C.SDL_Quit()
    end)

    it("resolves numeric loopback asynchronously", function()
        local future = net.resolve("127.0.0.1")
        assert.are.equal("pending", future.status)
        assert.are.equal(1, net.pending())

        local deadline = C.SDL_GetTicks() + 2000
        while future.status == "pending" and C.SDL_GetTicks() < deadline do
            net.poll()
        end

        assert.are.equal("ready", future.status, future.error)
        assert.are.equal("127.0.0.1", future.value.host)
        assert.is_string(future.value.text)
        assert.are.equal(0, net.pending())
        future.value:close()
        assert.is_true(future.value:isClosed())
        future.value:close()
    end)

    it("cancels resolution without leaving work pending", function()
        local future = net.resolve("127.0.0.1")
        future:cancel()

        assert.are.equal("canceled", future.status)
        assert.are.equal(0, net.pending())
    end)

    it("cancels a pending client connection", function()
        local address = resolved()
        local server, port = listen()
        local future = net.connect(address, port)

        future:cancel()
        assert.are.equal("canceled", future.status)
        assert.are.equal(0, net.pending())

        server:close()
        address:close()
    end)

    it("advances a client connection through the frame poll", function()
        local address = resolved()
        local server, port = listen()
        local future = net.connect(address, port)
        local deadline = C.SDL_GetTicks() + 2000
        while future.status == "pending" and C.SDL_GetTicks() < deadline do
            net.poll()
        end

        assert.are.equal("ready", future.status, future.error)
        assert.is_true(server:wait(2000))
        local accepted = assert(server:accept())

        future.value:close()
        accepted:close()
        server:close()
        address:close()
    end)

    it("connects, accepts and preserves byte-stream semantics", function()
        local address = resolved()
        local server, port = listen()
        local client, peer = connected(address, server, port)

        assert.is_true(client:write("abcdef"))
        assert.is_true(client:drain(2000))
        local bytes, pieces = readExactly(peer, 6, 2)
        assert.are.equal("abcdef", bytes)
        for _, piece in ipairs(pieces) do
            assert.is_true(#piece <= 2)
        end

        -- Two writes have no message boundary. The receiver asks only for the
        -- total byte stream and owns any framing above it.
        assert.is_true(peer:write("one"))
        assert.is_true(peer:write("two"))
        assert.is_true(peer:drain(2000))
        assert.are.equal("onetwo", readExactly(client, 6, 6))

        local remote, reason = client:peer()
        assert.is_not_nil(remote, reason)
        assert.is_string(remote.text)
        remote:close()

        client:close()
        peer:close()
        server:close()
        address:close()
    end)

    it("reports no stream input without blocking", function()
        local address = resolved()
        local server, port = listen()
        local client, peer = connected(address, server, port)

        local bytes, reason = client:read()
        assert.is_nil(bytes)
        assert.is_nil(reason)
        assert.is_false(client:wait(0))
        assert.are.equal(0, client:pendingWrites())

        client:close()
        assert.is_true(client:isClosed())
        assert.are.same({ false, "stream is closed" }, { client:write("late") })
        client:close()
        peer:close()
        server:close()
        address:close()
    end)

    it("distinguishes peer disconnection from no input", function()
        local address = resolved()
        local server, port = listen()
        local client, peer = connected(address, server, port)

        peer:close()
        assert.is_true(client:wait(2000))
        assert.are.same({ nil, "connection closed" }, { client:read() })

        client:close()
        server:close()
        address:close()
    end)

    it("sends and receives whole datagrams in both directions", function()
        local address = resolved()
        local receiver, port = bind()
        local sender, senderPort = net.bind(0)
        assert.is_not_nil(sender, senderPort)

        assert.is_true(sender:send(address, port, "first packet"))
        assert.is_true(receiver:wait(2000))
        local packet, reason = receiver:receive()
        assert.is_not_nil(packet, reason)
        assert.are.equal("first packet", packet.bytes)
        assert.is_true(packet.port > 0)

        assert.is_true(receiver:send(packet.address, packet.port, "reply"))
        packet:close()
        assert.is_true(sender:wait(2000))
        local reply, replyReason = sender:receive()
        assert.is_not_nil(reply, replyReason)
        assert.are.equal("reply", reply.bytes)
        reply:close()

        sender:close()
        receiver:close()
        address:close()
    end)

    it("keeps a packet source address alive after receiving", function()
        local address = resolved()
        local receiver, port = bind()
        local sender = assert(net.bind(0))

        assert.is_true(sender:send(address, port, "address lifetime"))
        assert.is_true(receiver:wait(2000))
        local packet = assert(receiver:receive())
        receiver:close()

        assert.is_false(packet.address:isClosed())
        assert.is_string(packet.address.text)
        packet:close()
        packet:close()
        sender:close()
        address:close()
    end)

    it("refuses shutdown while an owned object is open", function()
        local address = resolved()
        local ok, reason = net.quit()
        assert.is_false(ok)
        assert.is_truthy(reason:find("still open", 1, true))

        address:close()
        assert.is_true(net.quit())
        assert.is_true(net.init())
    end)

    it("validates ports, bounds and timeouts before native calls", function()
        local address = resolved()
        local socket = assert(net.bind(0))

        assert.has_error(function()
            net.connect(address, 0)
        end)
        assert.has_error(function()
            socket:send(address, 99999, "")
        end)
        assert.has_error(function()
            socket:send(address, 1, string.rep("x", 65508))
        end)
        assert.has_error(function()
            socket:wait(-1)
        end)

        socket:close()
        address:close()
    end)
end)
