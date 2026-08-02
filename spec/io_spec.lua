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
local tecsIO = tecs.io

local nextPort = 27140

local function listen()
    for _ = 1, 100 do
        local port = nextPort
        nextPort = nextPort + 1
        local server = tecsIO.listen(port)
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
        local socket = tecsIO.bind(port)
        if socket then
            return socket, port
        end
    end
    error("no loopback UDP port available")
end

local function resolved()
    return tecsIO.resolve("127.0.0.1")
end

local function connected(address, server, port)
    local client = tecsIO.connect(address, port)
    assert.is_true(server:wait(2000))
    local accepted, reason = server:accept()
    assert.is_not_nil(accepted, reason)
    return client, accepted
end

local function readExactly(connection, length, chunk)
    local pieces = {}
    local total = 0
    local deadline = C.SDL_GetTicks() + 2000
    while total < length and C.SDL_GetTicks() < deadline do
        local ready, reason = connection:wait(50)
        assert.is_nil(reason)
        if ready then
            local bytes, readReason = connection:read(chunk)
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

describe("tecs.io", function()
    setup(function()
        assert(C.SDL_Init(0))
        assert.is_true(tecsIO.init())
    end)

    teardown(function()
        local ok, reason = tecsIO.shutdown()
        assert.is_true(ok, reason)
        C.SDL_Quit()
    end)

    it("exposes connected TCP resources", function()
        assert.is_table(tecsIO.TCPSocket)
        assert.is_table(tecsIO.TCPListener)
        assert.is_table(tecsIO.UDPSocket)
        assert.is_table(tecsIO.UDPPacket)
        assert.is_nil(tecsIO.Connection)
        assert.is_nil(tecsIO.Server)
        assert.is_nil(tecsIO.DatagramSocket)
        assert.is_nil(tecsIO.Packet)
        assert.is_function(tecsIO.shutdown)
        assert.is_nil(tecsIO.quit)
    end)

    it("resolves numeric loopback directly", function()
        local address = tecsIO.resolve("127.0.0.1")
        assert.are.equal("127.0.0.1", address.host)
        assert.is_string(address.text)
        assert.are.equal(0, tecsIO.pending())
        address:close()
        assert.is_true(address:isClosed())
        address:close()
    end)

    it("connects directly while the native reactor advances in the background", function()
        local address = resolved()
        local server, port = listen()
        local client = tecsIO.connect(address, port)
        assert.is_true(server:wait(2000))
        local accepted = assert(server:accept())

        client:close()
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

    it("reads into and writes from reusable buffers", function()
        local address = resolved()
        local server, port = listen()
        local client, peer = connected(address, server, port)
        local source = tecsIO.newBuffer("0123456789")
        local destination = tecsIO.newBuffer("pre")

        assert.are.equal(5, client:writeFrom(source, 2, 5))
        source:close()
        assert.is_true(client:drain(2000))
        assert.is_true(peer:wait(2000))
        assert.are.equal(3, peer:readInto(destination, 3, 3))
        assert.are.equal("pre234", destination:getString())
        assert.is_true(peer:wait(2000))
        assert.are.equal(2, peer:readInto(destination, 6))
        assert.are.equal("pre23456", destination:getString())

        destination:close()
        client:close()
        peer:close()
        server:close()
        address:close()
    end)

    it("leaves a destination buffer unchanged for a zero-byte TCP read", function()
        local address = resolved()
        local server, port = listen()
        local client, peer = connected(address, server, port)
        local destination = tecsIO.newBuffer("kept")

        assert.are.equal(0, client:readInto(destination, 8, 0))
        assert.are.equal("kept", destination:getString())
        assert.has_error(function()
            client:readInto(destination, 0, -1)
        end)
        assert.has_error(function()
            client:readInto(destination, -1, 1)
        end)
        assert.has_error(function()
            client:writeFrom(destination, 5)
        end)
        assert.has_error(function()
            client:writeFrom(destination, 1, 4)
        end)

        destination:close()
        client:close()
        peer:close()
        server:close()
        address:close()
    end)

    it("reports readiness without changing direct read semantics", function()
        local address = resolved()
        local server, port = listen()
        local client, peer = connected(address, server, port)

        assert.is_false(client:wait(0))
        assert.are.equal(0, client:pendingWrites())

        client:close()
        assert.is_true(client:isClosed())
        assert.are.same({ false, "connection is closed" }, { client:write("late") })
        local buffer = tecsIO.newBuffer("late")
        assert.are.same({ nil, "connection is closed" }, { client:readInto(buffer) })
        assert.are.same({ nil, "connection is closed" }, { client:writeFrom(buffer) })
        buffer:close()
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
        local sender, senderPort = tecsIO.bind(0)
        assert.is_not_nil(sender, senderPort)

        assert.is_true(sender:send(address, port, "first packet"))
        assert.is_true(receiver:wait(2000))
        local packet, reason = receiver:receive()
        assert.is_not_nil(packet, reason)
        assert.are.equal("first packet", packet.bytes:getString())
        assert.is_true(packet.port > 0)

        assert.is_true(receiver:send(packet.address, packet.port, "reply"))
        packet:close()
        assert.is_true(sender:wait(2000))
        local reply, replyReason = sender:receive()
        assert.is_not_nil(reply, replyReason)
        assert.are.equal("reply", reply.bytes:getString())
        reply:close()

        sender:close()
        receiver:close()
        address:close()
    end)

    it("keeps a packet source address alive after receiving", function()
        local address = resolved()
        local receiver, port = bind()
        local sender = assert(tecsIO.bind(0))

        assert.is_true(sender:send(address, port, "address lifetime"))
        assert.is_true(receiver:wait(2000))
        local packet = assert(receiver:receive())
        receiver:close()

        assert.is_false(packet.address:isClosed())
        assert.is_string(packet.address.text)
        assert.is_false(packet.bytes:isReleased())
        packet:close()
        assert.is_true(packet.bytes:isReleased())
        packet:close()
        sender:close()
        address:close()
    end)

    it("refuses shutdown while an owned object is open", function()
        local address = resolved()
        local ok, reason = tecsIO.shutdown()
        assert.is_false(ok)
        assert.is_truthy(reason:find("still open", 1, true))

        address:close()
        assert.is_true(tecsIO.shutdown())
        assert.is_true(tecsIO.init())
    end)

    it("reclaims abandoned owned network handles", function()
        local address = resolved()
        local listener, port = listen()
        local client = tecsIO.connect(address, port)
        assert.is_true(listener:wait(2000))
        local accepted = assert(listener:accept())
        local datagram = assert(tecsIO.bind(0))

        address = nil
        listener = nil
        client = nil
        accepted = nil
        datagram = nil
        collectgarbage("collect")

        assert.is_true(tecsIO.shutdown())
        assert.is_true(tecsIO.init())
    end)

    it("validates ports, bounds and timeouts before native calls", function()
        local address = resolved()
        local socket = assert(tecsIO.bind(0))

        assert.has_error(function()
            tecsIO.connect(address, 0)
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
