-- Real loopback TCP coverage for the internal Task reactor prototype.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local sdl = require("tecs.ffi.sdl3")
local task = require("tecs.internal.taskruntime")
local tasknet = require("tecs.internal.tasknet")

local C = sdl.C
local tecsIO = tecs.io
local nextPort = 27340

local function listen()
    for _ = 1, 100 do
        local port = nextPort
        nextPort = nextPort + 1
        local server = tecsIO.listen(port)
        if server then
            return server, port
        end
    end
    error("no loopback TCP port available for task reactor")
end

local function connected()
    local address = tecsIO.resolve("127.0.0.1")
    local server, port = listen()
    local client = tecsIO.connect(address, port)
    assert.is_true(server:wait(2000))
    local peer = assert(server:accept())
    return address, server, client, peer
end

describe("internal TCP task reactor prototype", function()
    setup(function()
        assert(C.SDL_Init(0))
        assert.is_true(tecsIO.init())
    end)

    teardown(function()
        local ok, reason = tecsIO.shutdown()
        assert.is_true(ok, reason)
        C.SDL_Quit()
    end)

    it("suspends on would-block and resumes from native readiness", function()
        local address, server, client, peer = connected()
        local reactor = assert(tasknet.newReactor())
        local writer = reactor:wrap(client)
        local reader = reactor:wrap(peer)
        local source = tecsIO.newBuffer("native readiness")
        local destination = tecsIO.newBuffer()

        local count = tasknet.run(reactor, function(scope)
            scope:spawn(function()
                task.yield()
                assert.are.equal(source:length(), assert(writer:writeFrom(source)))
            end)
            return assert(reader:readInto(destination, 0, source:length()))
        end)

        assert.are.equal(source:length(), count)
        assert.are.equal("native readiness", destination:getString())
        assert.is_true(reader:lastReadyNs() > 0)

        reactor:close()
        source:close()
        destination:close()
        client:close()
        peer:close()
        server:close()
        address:close()
    end)

    it("moves a long stream through two persistent coroutines", function()
        local address, server, client, peer = connected()
        local reactor = assert(tasknet.newReactor())
        local writer = reactor:wrap(client)
        local reader = reactor:wrap(peer)
        local source = tecsIO.newBuffer(("0123456789abcdef"):rep(256))
        local destination = tecsIO.newBuffer()
        local chunks = 2000

        local total = tasknet.run(reactor, function(scope)
            local writing = scope:spawn(function()
                for _ = 1, chunks do
                    assert.are.equal(source:length(), assert(writer:writeFrom(source)))
                end
            end)
            local read = 0
            while read < source:length() * chunks do
                destination:clear()
                read = read + assert(reader:readInto(destination, 0, source:length()))
            end
            writing:join()
            return read
        end)

        assert.are.equal(source:length() * chunks, total)

        reactor:close()
        source:close()
        destination:close()
        client:close()
        peer:close()
        server:close()
        address:close()
    end)

    it("unregisters native readiness when a blocked Task is canceled", function()
        local address, server, client, peer = connected()
        local reactor = assert(tasknet.newReactor())
        local reader = reactor:wrap(peer)
        local destination = tecsIO.newBuffer()
        local scheduler = task.newScheduler()
        local reading = scheduler:spawn(function()
            return reader:readInto(destination, 0, 1)
        end)

        assert.are.equal(1, scheduler:step())
        assert.are.equal("pending", reading.status)
        assert.is_true(reader._armed)
        reading:cancel("entity despawned")
        assert.is_false(reader._armed)
        assert.are.equal(1, scheduler:step())
        assert.are.equal("canceled", reading.status)
        assert.are.equal(0, assert(reactor:poll(0)))

        reactor:close()
        destination:close()
        client:close()
        peer:close()
        server:close()
        address:close()
    end)
end)
