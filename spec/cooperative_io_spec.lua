-- Public socket operations suspend ordinary systems on native readiness.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local sdl = require("tecs.ffi.sdl3")
local netreactor = require("tecs.internal.netreactor")
local runtime = require("tecs.internal.runtime")

local C = sdl.C
local tecsIO = tecs.io
local nextPort = 27440

local function listen()
    for _ = 1, 100 do
        local port = nextPort
        nextPort = nextPort + 1
        local server = tecsIO.listen(port)
        if server then
            return server, port
        end
    end
    error("no loopback TCP port available for cooperative I/O")
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
    error("no loopback UDP port available for cooperative I/O")
end

local function connected()
    local address = tecsIO.resolve("127.0.0.1")
    local server, port = listen()
    local client = tecsIO.connect(address, port)
    assert.is_true(server:wait(2000))
    local peer = assert(server:accept())
    return address, server, client, peer
end

local function closeNetwork(address, server, client, peer)
    client:close()
    peer:close()
    server:close()
    address:close()
end

local function pollUntilDelivery()
    local deadline = C.SDL_GetTicks() + 2000
    repeat
        local delivered = runtime.poll()
        if delivered > 0 then
            return delivered
        end
        C.SDL_Delay(1)
    until C.SDL_GetTicks() >= deadline
    error("cooperative network readiness did not arrive before timeout")
end

describe("cooperative socket systems", function()
    setup(function()
        assert(C.SDL_Init(0))
        assert.is_true(tecsIO.init())
    end)

    teardown(function()
        local ok, reason = tecsIO.shutdown()
        assert.is_true(ok, reason)
        C.SDL_Quit()
    end)

    it("parks a world on would-block and resumes at the read call", function()
        local address, server, client, peer = connected()
        local world = tecs.ecs.newWorld()
        local destination = tecsIO.newBuffer()
        local entered = 0
        local count
        local order = {}
        local closed = 0

        world:addSystem({
            name = "CooperativeSocketRead",
            phase = tecs.ecs.phases.Update,
            run = function()
                entered = entered + 1
                order[#order + 1] = "read"
                tecs.scoped(function(scope)
                    scope:own({
                        close = function()
                            closed = closed + 1
                            return true
                        end,
                    })
                    count = assert(peer:readInto(destination, 0, 11))
                    order[#order + 1] = "resumed"
                end)
            end,
        })
        world:addSystem({
            name = "AfterCooperativeSocketRead",
            phase = tecs.ecs.phases.Last,
            run = function()
                order[#order + 1] = "after"
            end,
        })

        local stable = world:saveSnapshot({ format = "table" })

        assert.is_false(world:update(1 / 60))
        assert.is_true(world._updateStalled)
        assert.are.equal(1, entered)
        assert.are.same({ "read" }, order)
        assert.are.equal(0, closed)
        assert.are.equal(1, netreactor.pending())
        assert.has_error(function()
            world:saveSnapshot({ format = "table" })
        end, "tecs: cannot save a snapshot while a world update is suspended")
        assert.has_error(function()
            world:loadSnapshot(stable)
        end, "tecs: cannot load a snapshot while a world update is suspended")

        assert.is_true(client:write("hello world"))
        assert.is_true(client:drain(2000))
        assert.are.equal(1, pollUntilDelivery())
        assert.is_true(world:update(99))

        assert.is_false(world._updateStalled)
        assert.are.equal(1, entered)
        assert.are.equal(11, count)
        assert.are.equal("hello world", destination:getString())
        assert.are.same({ "read", "resumed", "after" }, order)
        assert.are.equal(1, closed)
        assert.are.equal(0, netreactor.pending())

        world:shutdown()
        destination:close()
        closeNetwork(address, server, client, peer)
    end)

    it("keeps an already-readable socket on the inline path", function()
        local address, server, client, peer = connected()
        local world = tecs.ecs.newWorld()
        local received

        assert.is_true(client:write("ready"))
        assert.is_true(client:drain(2000))
        world:addSystem({
            name = "InlineSocketRead",
            phase = tecs.ecs.phases.Update,
            run = function()
                received = assert(peer:read(5))
            end,
        })

        assert.is_true(world:update(1 / 60))
        assert.is_false(world._updateStalled)
        assert.are.equal("ready", received)
        assert.are.equal(0, netreactor.pending())

        world:shutdown()
        closeNetwork(address, server, client, peer)
    end)

    it("resumes a timed readiness wait without blocking the SDL thread", function()
        local address, server, client, peer = connected()
        local world = tecs.ecs.newWorld()
        local ready
        local reason

        world:addSystem({
            name = "TimedSocketWait",
            phase = tecs.ecs.phases.Update,
            run = function()
                ready, reason = peer:wait(5)
            end,
        })

        assert.is_false(world:update(1 / 60))
        assert.are.equal(1, netreactor.pending())
        C.SDL_Delay(10)
        assert.are.equal(1, pollUntilDelivery())
        assert.is_true(world:update(1 / 60))
        assert.is_false(ready)
        assert.is_nil(reason)

        world:shutdown()
        closeNetwork(address, server, client, peer)
    end)

    it("unwinds a resource scope when shutdown cancels its parked system", function()
        local address, server, client, peer = connected()
        local world = tecs.ecs.newWorld()
        local closed = 0

        world:addSystem({
            name = "ScopedCanceledSocketRead",
            phase = tecs.ecs.phases.Update,
            run = function()
                tecs.scoped(function(scope)
                    scope:own({
                        close = function()
                            closed = closed + 1
                            return true
                        end,
                    })
                    peer:read()
                end)
            end,
        })

        assert.is_false(world:update(1 / 60))
        assert.are.equal(0, closed)
        assert.are.equal(1, netreactor.pending())

        world:shutdown()
        assert.are.equal(1, closed)
        assert.are.equal(0, netreactor.pending())

        closeNetwork(address, server, client, peer)
    end)

    it("cancels a parked read when its socket closes", function()
        local address, server, client, peer = connected()
        local world = tecs.ecs.newWorld()
        local bytes
        local reason

        world:addSystem({
            name = "CanceledSocketRead",
            phase = tecs.ecs.phases.Update,
            run = function()
                bytes, reason = peer:read()
            end,
        })

        assert.is_false(world:update(1 / 60))
        assert.are.equal(1, netreactor.pending())
        peer:close()
        assert.are.equal(0, netreactor.pending())
        assert.is_true(world:update(1 / 60))
        assert.is_nil(bytes)
        assert.are.equal("connection closed", reason)

        world:shutdown()
        client:close()
        server:close()
        address:close()
    end)

    it("parks accept until a connection reaches a listener", function()
        local address = tecsIO.resolve("127.0.0.1")
        local server, port = listen()
        local world = tecs.ecs.newWorld()
        local accepted

        world:addSystem({
            name = "CooperativeSocketAccept",
            phase = tecs.ecs.phases.Update,
            run = function()
                accepted = assert(server:accept())
            end,
        })

        assert.is_false(world:update(1 / 60))
        assert.are.equal(1, netreactor.pending())
        local client = tecsIO.connect(address, port)
        assert.are.equal(1, pollUntilDelivery())
        assert.is_true(world:update(1 / 60))
        assert.is_not_nil(accepted)
        assert.are.equal(0, netreactor.pending())

        world:shutdown()
        accepted:close()
        client:close()
        server:close()
        address:close()
    end)

    it("parks receive until a datagram reaches its socket", function()
        local address = tecsIO.resolve("127.0.0.1")
        local receiver, port = bind()
        local sender = assert(tecsIO.bind(0))
        local world = tecs.ecs.newWorld()
        local packet

        world:addSystem({
            name = "CooperativeDatagramReceive",
            phase = tecs.ecs.phases.Update,
            run = function()
                packet = assert(receiver:receive())
            end,
        })

        assert.is_false(world:update(1 / 60))
        assert.are.equal(1, netreactor.pending())
        assert.is_true(sender:send(address, port, "one packet"))
        assert.are.equal(1, pollUntilDelivery())
        assert.is_true(world:update(1 / 60))
        assert.are.equal("one packet", packet.bytes:getString())
        assert.are.equal(0, netreactor.pending())

        world:shutdown()
        packet:close()
        sender:close()
        receiver:close()
        address:close()
    end)
end)
