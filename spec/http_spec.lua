-- The HTTP client, driven the way a frame drives it.
--
-- **No network.** A spec that reached a real host would fail on a machine
-- without one and, worse, fail intermittently on a machine with a bad one. So
-- the other end is a listener this process starts: `tecs.mcp.transport` is a
-- non-blocking HTTP server over SDL3_net, so the request and the response both
-- stay inside this test. `file://` is not a shortcut: it bypasses Reqwest and
-- cannot prove that work moved to Tokio while futures still settle only when
-- the SDL thread pumps their event queue.
--
-- The server stays on this thread and Reqwest uses its own workers. This loop
-- coordinates them by draining futures only from the calling thread.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local sdl = require("tecs.ffi.sdl3")
local net = require("tecs.ffi.sdl3net")
local transport = require("tecs.mcp.transport")
local http = require("tecs.net.http")

local BODY = "the rust worker drove this without blocking\n"

-- Ports are a shared resource on the machine running the suite, so this takes
-- the first free one rather than insisting on a number, and never hands the
-- same one out twice: a listener is built and destroyed per test, and reusing
-- a port would mean a connection an earlier test abandoned arriving at a
-- later test's listener.
local nextPort = 47860

local function listenSomewhere()
    local failures = {}
    for port = nextPort, nextPort + 20 do
        local ok, server = pcall(transport.listen, port)
        if ok then
            nextPort = port + 1
            return server, port
        end
        failures[#failures + 1] = tostring(port)
    end
    error("no free port in " .. table.concat(failures, ", "))
end

describe("http.newClient", function()
    local server, port, client
    local silent, silentPort

    setup(function()
        assert(sdl.C.SDL_Init(0))
    end)

    teardown(function()
        sdl.C.SDL_Quit()
    end)

    -- A listener per test, on a port no other test uses. The transport serves
    -- one connection at a time and several tests here deliberately leave one
    -- unanswered, so a shared listener carries an accept queue from each test
    -- into the next: the next test's listener answers the previous test's
    -- connection, into a request the old client no longer owns, while its own waits
    -- behind it. That reads as a client that stopped working and is really a
    -- fixture that is one request behind. Building the listener per test is
    -- what makes the suite deterministic rather than usually right.
    before_each(function()
        client = http.newClient({ userAgent = "tecs-spec/1.0" })
        server, port = listenSomewhere()
        -- A second listener that is never polled. A connection to it completes,
        -- because the kernel accepts into the backlog, and then nothing ever
        -- answers it. That is what a test needing a transfer to stay pending
        -- wants, and it has to be a listener of its own for the same reason.
        silent, silentPort = listenSomewhere()
    end)

    after_each(function()
        client:close()
        server:destroy()
        silent:destroy()
    end)

    local function url(path)
        return ("http://127.0.0.1:%d%s"):format(port, path)
    end

    --- A URL that connects and is never answered.
    local function silentUrl(path)
        return ("http://127.0.0.1:%d%s"):format(silentPort, path)
    end

    --- Writes an exact HTTP response for protocol cases `respond` hides.
    local function rawRespond(payload)
        net.C.NET_WriteToStreamSocket(server._client, payload, #payload)
        net.C.NET_WaitUntilStreamSocketDrained(server._client, 1000)
        server:close()
    end

    --- Pumps the client and the listener together until `future` settles.
    ---
    --- `respond` is called with each request the listener parses; nil leaves
    --- the listener alone, which is what the refused-connection and
    --- cancellation cases want.
    ---
    --- Two details that are the difference between this passing and passing
    --- most of the time. It sleeps a millisecond a turn, because both halves
    --- are non-blocking and a loop over them otherwise runs its whole budget
    --- in less wall time than the kernel takes to refuse a connection. And the
    --- clock it hands the listener runs fast, so a connection some earlier test
    --- left half-open is dropped by the transport's own timeout rather than
    --- holding its single slot for the rest of the run.
    local function drive(future, respond, turns)
        local seen = nil
        for turn = 1, turns or 2000 do
            client:pump()
            if respond ~= nil then
                server:poll(turn * 0.05, function(request)
                    seen = request
                    respond(request)
                end)
            end
            if future.status ~= "pending" then
                break
            end
            sdl.C.SDL_Delay(1)
        end
        return seen
    end

    it("leaves a transfer running after the first pump", function()
        -- The proof of non-blocking, and the only state a blocking
        -- implementation cannot produce: `send` returned, a pump happened, and
        -- the listener has not so much as accepted the connection yet.
        local pending = client:send({ url = url("/still-running") })
        assert.are.equal("pending", pending.status)

        client:pump()
        assert.are.equal("pending", pending.status)
        assert.are.equal(1, client:pending())

        local seen = drive(pending, function()
            server:respond(200, "OK", BODY, "text/plain")
        end)
        assert.are.equal("ready", pending.status)
        assert.are.equal("/still-running", seen.path)
        assert.are.equal(0, client:pending())
    end)

    it("settles only when the SDL thread drains the Rust queue", function()
        local pending = client:send({ url = url("/queued") })
        local seen
        for turn = 1, 2000 do
            server:poll(turn * 0.05, function(request)
                seen = request
                server:respond(200, "OK", BODY, "text/plain")
            end)
            if seen ~= nil then
                break
            end
            sdl.C.SDL_Delay(1)
        end
        assert.is_not_nil(seen, "Reqwest never reached the local server")

        -- Tokio may finish the transfer, but it can only enqueue ordinary
        -- data. A worker never calls Lua or settles this future itself.
        sdl.C.SDL_Delay(50)
        assert.are.equal("pending", pending.status)

        drive(pending, nil)
        assert.are.equal("ready", pending.status)
        assert.are.equal(BODY, pending.value.body:text())
    end)

    it("settles a completed body, its status and its headers", function()
        local pending = client:send({ url = url("/body") })
        drive(pending, function()
            server:respond(200, "OK", BODY, "text/plain")
        end)

        assert.are.equal("ready", pending.status)
        local response = pending.value
        assert.are.equal(200, response.status)
        assert.is_true(response:ok())
        -- One field holding the body whatever it is, rather than a `body` and
        -- a `path` where exactly one is meaningful.
        assert.are.equal("string", response.body.kind)
        assert.are.equal(BODY, response.body:text())
        assert.are.equal(#BODY, response.body.length)
        assert.are.equal("text/plain", response.body.contentType)
        assert.are.equal("text/plain", response.headers["content-type"])
        assert.are.equal(url("/body"), response.url)
        assert.is_nil(response.body.path)
    end)

    it("keeps only the final response headers", function()
        local pending = client:send({ url = url("/interim") })
        drive(pending, function()
            rawRespond(table.concat({
                "HTTP/1.1 100 Continue\r\n",
                "X-Interim: hidden\r\n\r\n",
                "HTTP/1.1 200 OK\r\n",
                "X-Final: visible\r\n",
                "Content-Length: 2\r\n",
                "Connection: close\r\n\r\n",
                "ok",
            }))
        end)

        assert.are.equal("ready", pending.status)
        assert.are.equal("visible", pending.value.headers["x-final"])
        assert.is_nil(pending.value.headers["x-interim"])
    end)

    it("sends a method and a body, and settles a non-2xx as ready", function()
        local pending = client:send({
            url = url("/submit"),
            method = "POST",
            headers = { ["content-type"] = "application/json" },
            body = '{"score":11}',
        })
        local seen = drive(pending, function()
            server:respond(404, "Not Found", "gone", "text/plain")
        end)

        assert.are.equal("POST", seen.method)
        assert.are.equal('{"score":11}', seen.body)

        -- A status code is the answer to the request, not a broken transfer.
        -- Reading it the other way would propagate a 404 through `map` as a
        -- failure, which is wrong for everything that branches on the code.
        assert.are.equal("ready", pending.status)
        assert.are.equal(404, pending.value.status)
        assert.is_false(pending.value:ok())
        assert.is_nil(pending.error)
    end)

    it("composes, because a request is a future like any other", function()
        local length = client:send({ url = url("/compose") }):map(function(response)
            return response.body.length
        end)

        drive(length, function()
            server:respond(200, "OK", BODY, "text/plain")
        end)
        assert.are.equal("ready", length.status)
        assert.are.equal(#BODY, length.value)
    end)

    it("writes the body to a file when `into` names one", function()
        local path = os.tmpname()
        local pending = client:send({ url = url("/download"), into = path })
        drive(pending, function()
            server:respond(200, "OK", BODY, "application/octet-stream")
        end)

        assert.are.equal("ready", pending.status)
        -- The body is where it was asked to go, and the response says so in
        -- the same field a string body would have come back in.
        local body = pending.value.body
        assert.are.equal("file", body.kind)
        assert.are.equal(path, body.path)
        assert.are.equal(#BODY, body.length)
        assert.are.equal(BODY, body:text())

        local file = assert(io.open(path, "rb"))
        local written = file:read("*a")
        file:close()
        os.remove(path)
        assert.are.equal(BODY, written)
    end)

    it("writes into a handle as the bytes arrive, never assembling them", function()
        -- `into` streams. Rust's bounded queue holds what has arrived, the pump
        -- hands each chunk to the handle, and the worker cannot outrun that
        -- bound. The whole body is never assembled in Lua or native memory.
        local path = os.tmpname()
        local file = assert(io.open(path, "wb"))
        local pending = client:send({
            url = url("/streamed"),
            into = http.DataStream.ofHandle(file),
        })
        drive(pending, function()
            server:respond(200, "OK", BODY, "application/octet-stream")
        end)
        file:close()

        assert.are.equal("ready", pending.status)
        assert.are.equal("handle", pending.value.body.kind)
        assert.are.equal(#BODY, pending.value.body.length)

        local written = assert(io.open(path, "rb"))
        local bytes = written:read("*a")
        written:close()
        os.remove(path)
        assert.are.equal(BODY, bytes)
    end)

    it("counts a streamed body against maxBytes, though it holds none of it", function()
        -- A destination is not a way around the ceiling. Rust counts chunks
        -- before queueing them, so the limit means the same thing whether the
        -- body is going to a string or to a file.
        local path = os.tmpname()
        local file = assert(io.open(path, "wb"))
        local pending = client:send({
            url = url("/too-big-streamed"),
            into = http.DataStream.ofHandle(file),
            maxBytes = 8,
        })
        drive(pending, function()
            server:respond(200, "OK", BODY, "text/plain")
        end)
        file:close()
        os.remove(path)

        assert.are.equal("failed", pending.status)
        assert.is_truthy(pending.error:find("exceeded", 1, true))
    end)

    it("sends a body read from a file", function()
        -- The asymmetry, stated: a destination is written when Lua drains a
        -- Rust event, while a request body has to cross into the background
        -- task before it starts. The source is therefore read at `send`.
        local path = os.tmpname()
        local upload = assert(io.open(path, "wb"))
        upload:write(BODY)
        upload:close()

        local pending = client:send({
            url = url("/upload"),
            method = "PUT",
            body = http.DataStream.ofFile(path, "application/octet-stream"),
        })
        local seen = drive(pending, function()
            server:respond(204, "No Content", "", "text/plain")
        end)
        os.remove(path)

        assert.are.equal("ready", pending.status)
        assert.are.equal("PUT", seen.method)
        assert.are.equal(BODY, seen.body)
    end)

    it("reports a refused connection as a failure", function()
        -- Port 1 on loopback with nothing on it, so this fails without ever
        -- leaving the machine. Reqwest reports the transport error through the
        -- same queue as completions.
        local pending = client:send({ url = "http://127.0.0.1:1/" })
        drive(pending, nil)

        assert.are.equal("failed", pending.status)
        assert.is_string(pending.error)
        assert.is_truthy(pending.error:find("127.0.0.1:1", 1, true))
        assert.is_nil(pending.value)
    end)

    it("refuses a url that is not http or https", function()
        -- Data rather than a mistake in the program: a URL out of a manifest
        -- settles the future instead of raising at the call site.
        local pending = client:send({ url = "file:///etc/passwd" })
        assert.are.equal("failed", pending.status)
        assert.is_truthy(pending.error:find("not an http", 1, true))
    end)

    it("returns from wait inside its budget when nothing answers", function()
        -- Nothing ever answers this listener, so the wait ends because its
        -- budget ran out rather than because the transfer finished.
        local pending = client:send({ url = silentUrl("/never-answered") })

        local before = sdl.C.SDL_GetTicks()
        pending:wait(120)
        local elapsed = tonumber(sdl.C.SDL_GetTicks() - before)

        assert.are.equal("pending", pending.status)
        assert.is_true(elapsed >= 100)
        -- One slice past the budget at the very worst, so this proves the wait
        -- is bounded rather than merely finite.
        assert.is_true(elapsed < 2000)
    end)

    it("returns from wait as soon as the transfer settles", function()
        -- The other direction: the work finishes well inside the budget, so
        -- `wait` returns because of the settlement rather than the clock.
        local pending = client:send({ url = "http://127.0.0.1:1/" })

        local before = sdl.C.SDL_GetTicks()
        pending:wait(5000)
        local elapsed = tonumber(sdl.C.SDL_GetTicks() - before)

        assert.are.equal("failed", pending.status)
        assert.is_true(elapsed < 4000)
    end)

    it("stops a transfer when it is canceled", function()
        local pending = client:send({ url = url("/canceled") })
        client:pump()
        assert.are.equal("pending", pending.status)
        assert.are.equal(1, client:pending())

        pending:cancel()
        assert.are.equal("canceled", pending.status)
        assert.are.equal(0, client:pending())

        -- Gone rather than merely ignored. The listener is driven and allowed
        -- to answer, because on loopback Reqwest may already have written the
        -- request before the cancel landed; what has to be true is that the
        -- answer settles nothing and reaches nobody.
        local settled = 0
        for turn = 1, 200 do
            settled = settled + client:pump()
            server:poll(turn * 0.05, function()
                server:respond(200, "OK", BODY, "text/plain")
            end)
            sdl.C.SDL_Delay(1)
        end
        assert.are.equal(0, settled)
        assert.are.equal("canceled", pending.status)
        assert.is_nil(pending.value)
    end)

    it("settles every transfer it still holds when it is closed", function()
        local one = client:send({ url = url("/closing-one") })
        local two = client:send({ url = url("/closing-two") })
        client:pump()

        client:close()
        assert.are.equal("canceled", one.status)
        assert.are.equal("canceled", two.status)
        assert.are.equal(0, client:pending())
        -- A closed client is useless rather than silently useless.
        assert.are.equal(0, client:pump())
        assert.has_error(function()
            client:send({ url = url("/after-close") })
        end)
    end)

    it("refuses to be pumped from inside its own pump", function()
        -- `wait` advances this client's source and settling runs listeners, so
        -- a listener that waits or pumps would recursively drain the same
        -- queue. It is refused rather than given order-dependent behavior. The
        -- pcall is the listener's own: `Future` logs a listener that raises.
        local pumped, waited
        local pending = client:send({ url = url("/reentrant") })
        -- A second transfer, because `wait` on a future that has just settled
        -- returns without advancing anything and so would prove nothing.
        local other = client:send({ url = silentUrl("/never-answered") })
        pending:onSettle(function()
            pumped = { pcall(function()
                client:pump()
            end) }
            waited = { pcall(function()
                other:wait(10)
            end) }
        end)

        drive(pending, function()
            server:respond(200, "OK", BODY, "text/plain")
        end)

        assert.are.equal("ready", pending.status)
        assert.is_false(pumped[1])
        assert.is_truthy(tostring(pumped[2]):find("already pumping", 1, true))
        assert.is_false(waited[1])
        assert.is_truthy(tostring(waited[2]):find("already pumping", 1, true))
    end)

    it("fails a body larger than maxBytes", function()
        -- The listener declares Content-Length, so the worker can refuse the
        -- transfer before queueing a body chunk. A chunked response is counted
        -- as it arrives and fails with the same ceiling.
        local pending = client:send({ url = url("/too-big"), maxBytes = 8 })
        drive(pending, function()
            server:respond(200, "OK", BODY, "text/plain")
        end)

        assert.are.equal("failed", pending.status)
        assert.is_string(pending.error)
        assert.is_truthy(pending.error:find(url("/too-big"), 1, true))
        assert.is_nil(pending.value)
    end)

    it("lets a request override maxBytes with unbounded zero", function()
        client:close()
        client = http.newClient({ maxBytes = 8 })
        local pending = client:send({ url = url("/unbounded"), maxBytes = 0 })
        drive(pending, function()
            server:respond(200, "OK", BODY, "text/plain")
        end)

        assert.are.equal("ready", pending.status)
        assert.are.equal(BODY, pending.value.body:text())
    end)

    it("takes a per-host list to skip TLS on, and nothing broader", function()
        -- There is no `insecure = true`. A wildcard, a port, a scheme and a
        -- URL are all refused, so what a reviewer reads is a list of hosts.
        for _, bad in ipairs({ "*", "", "localhost:8080", "https://example.com", "*.example.com" }) do
            assert.has_error(function()
                http.newClient({ insecureHosts = { bad } })
            end)
        end

        local allowed = http.newClient({ insecureHosts = { "dev.example.com" } })
        assert.is_not_nil(allowed)
        allowed:close()
    end)

    it("still settles transfers after the pump loop has been compiled", function()
        -- The one property no single-request test can have. LuaJIT traces this
        -- loop after fifty-six turns. Rust never calls into Lua; the traced
        -- pump only pulls ordinary data from the C ABI queue. This crosses the
        -- threshold twice and checks that every transfer still settles.
        local completed = 0
        for request = 1, 120 do
            local pending = client:send({ url = url("/compiled") })
            drive(pending, function()
                server:respond(200, "OK", BODY, "text/plain")
            end, 400)
            if pending.status == "ready" and pending.value.body:text() == BODY then
                completed = completed + 1
            end
        end
        assert.are.equal(120, completed)
        assert.are.equal(0, client:pending())
    end)

    it("raises on a call that is malformed rather than merely unlucky", function()
        assert.has_error(function()
            client:send(nil)
        end)
        assert.has_error(function()
            client:send({})
        end)
        -- A string in memory is a body, not somewhere a body can go.
        assert.has_error(function()
            client:send({
                url = url("/nowhere-to-put-it"),
                into = http.DataStream.ofString("not a destination"),
            })
        end)
    end)

    -- The loop's half. A game builds a client and sends a request; nothing in
    -- a frame belongs to it and nothing in a frame is written by hand. What
    -- `tecs.Application` calls each iteration is `clients.pump`, so that is
    -- what these drive, and `client:pump` is never touched.
    describe("the list a frame turns", function()
        it("pumps a client the game only built, without the game asking", function()
            local pending = client:send({ url = url("/unattended") })
            assert.are.equal("pending", pending.status)

            for turn = 1, 2000 do
                -- The one call an application makes. Note what is absent.
                http.pumpClients()
                server:poll(turn * 0.05, function()
                    server:respond(200, "OK", BODY, "text/plain")
                end)
                if pending.status ~= "pending" then
                    break
                end
                sdl.C.SDL_Delay(1)
            end

            assert.are.equal("ready", pending.status)
            assert.are.equal(BODY, pending.value.body:text())
        end)

        it("stops turning a client once it is closed", function()
            -- Closing is what ends a client's place in a frame; dropping the
            -- last reference to one deliberately does not, or a request nobody
            -- kept would stop moving whenever a collection happened to run.
            local before = http.openClients()
            local extra = http.newClient({ userAgent = "tecs-spec/1.0" })
            assert.are.equal(before + 1, http.openClients())

            local pending = extra:send({ url = silentUrl("/never-answered") })
            extra:close()
            assert.are.equal(before, http.openClients())
            assert.are.equal("canceled", pending.status)

            -- And the list turns without it rather than reaching a closed
            -- client, which is what a stale entry would look like.
            assert.are.equal(0, http.pumpClients())
        end)
    end)

    -- A request as an entity. The world's client is on the same list the
    -- frame turns, so this drives `clients.pump` and `world:update` and calls
    -- nothing on a client at all.
    describe("the plugin", function()
        local world

        after_each(function()
            if world ~= nil then
                http.plugin.close(world)
                world = nil
            end
        end)

        local function turn(entity, component, turns)
            for count = 1, turns or 2000 do
                http.pumpClients()
                world:update(1 / 60)
                server:poll(count * 0.05, function()
                    server:respond(200, "OK", BODY, "text/plain")
                end)
                local found = world:get(entity, component)
                if found ~= nil then
                    return found
                end
                sdl.C.SDL_Delay(1)
            end
            return nil
        end

        it("replaces a spawned Request with a Response", function()
            world = tecs.ecs.newWorld()
            world:addPlugin(http.plugin.install)

            local entity = world:spawn(http.plugin.Request({ url = url("/scores") }))
            local response = turn(entity, http.plugin.Response)

            assert.is_not_nil(response)
            assert.are.equal(200, response.status)
            assert.are.equal(BODY, response.body:text())
            assert.is_nil(response.error)
            -- The request is gone, so a system that reacts to one does not see
            -- the same one twice.
            assert.is_nil(world:get(entity, http.plugin.Request))
        end)

        it("answers a transfer that failed with a Response carrying why", function()
            world = tecs.ecs.newWorld()
            world:addPlugin(http.plugin.install)

            -- Nothing on port 1, so the transfer fails rather than answering.
            local entity = world:spawn(http.plugin.Request({ url = "http://127.0.0.1:1/" }))
            local response = turn(entity, http.plugin.Response)

            assert.is_not_nil(response)
            assert.are.equal(0, response.status)
            assert.is_string(response.error)
        end)
    end)
end)
