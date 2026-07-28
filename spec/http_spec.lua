-- The HTTP client, driven the way a frame drives it.
--
-- **No network.** A spec that reached a real host would fail on a machine
-- without one and, worse, fail intermittently on a machine with a bad one. So
-- the other end is a listener this process starts: `tecs.mcp.transport` is a
-- non-blocking HTTP server over SDL3_net, so the request and the response both
-- stay inside this test. `spec/curl_spec.lua` established the pattern and this
-- follows it, including why `file://` is not the shortcut it looks like: the
-- pinned build disables it, so a spec resting on it would pass against a
-- system libcurl and fail against a packaged one, and it completes inside
-- `curl_multi_perform`, which would prove nothing about non-blocking.
--
-- Both halves are non-blocking, so a transfer and the server that answers it
-- are one loop on one thread rather than two threads.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local sdl = require("tecs.ffi.sdl3")
local transport = require("tecs.mcp.transport")
local http = require("tecs.http")

local BODY = "the multi interface drove this without blocking\n"

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

describe("http.client", function()
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
    -- connection, into a socket whose curl handle is gone, while its own waits
    -- behind it. That reads as a client that stopped working and is really a
    -- fixture that is one request behind. Building the listener per test is
    -- what makes the suite deterministic rather than usually right.
    before_each(function()
        client = http.client({ userAgent = "tecs-spec/1.0" })
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

    it("settles a completed body, its status and its headers", function()
        local pending = client:send({ url = url("/body") })
        drive(pending, function()
            server:respond(200, "OK", BODY, "text/plain")
        end)

        assert.are.equal("ready", pending.status)
        local response = pending.value
        assert.are.equal(200, response.status)
        assert.is_true(response:ok())
        assert.are.equal(BODY, response.body)
        assert.are.equal(#BODY, response.bytes)
        assert.are.equal("text/plain", response.headers["content-type"])
        assert.are.equal(url("/body"), response.url)
        assert.is_nil(response.path)
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
            return #response.body
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
        -- The large case has a spelling of its own, and it does not also hand
        -- back the string it was asked not to build.
        assert.is_nil(pending.value.body)
        assert.are.equal(path, pending.value.path)

        local file = assert(io.open(path, "rb"))
        local written = file:read("*a")
        file:close()
        os.remove(path)
        assert.are.equal(BODY, written)
    end)

    it("reports a refused connection as a failure", function()
        -- Port 1 on loopback with nothing on it, so this fails without ever
        -- leaving the machine. libcurl reports a transport error on the multi
        -- handle's message queue, which is the only place it reports one.
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

    it("stops a transfer when it is cancelled", function()
        local pending = client:send({ url = url("/cancelled") })
        client:pump()
        assert.are.equal("pending", pending.status)
        assert.are.equal(1, client:pending())

        pending:cancel()
        assert.are.equal("cancelled", pending.status)
        assert.are.equal(0, client:pending())

        -- Gone rather than merely ignored. The listener is driven and allowed
        -- to answer, because on loopback curl may already have written the
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
        assert.are.equal("cancelled", pending.status)
        assert.is_nil(pending.value)
    end)

    it("settles every transfer it still holds when it is closed", function()
        local one = client:send({ url = url("/closing-one") })
        local two = client:send({ url = url("/closing-two") })
        client:pump()

        client:close()
        assert.are.equal("cancelled", one.status)
        assert.are.equal("cancelled", two.status)
        assert.are.equal(0, client:pending())
        -- A closed client is useless rather than silently useless.
        assert.are.equal(0, client:pump())
        assert.has_error(function()
            client:send({ url = url("/after-close") })
        end)
    end)

    it("refuses to be pumped from inside its own pump", function()
        -- `wait` advances this client's source and settling runs listeners, so
        -- a listener that waits or pumps would re-enter the multi handle.
        -- libcurl does not define that, so it is refused rather than left to
        -- chance. The pcall is the listener's own: `Future` logs a listener
        -- that raises rather than propagating it.
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
        -- Two halves, and this exercises the cheaper one: the listener
        -- declares a `Content-Length`, so `CURLOPT_MAXFILESIZE_LARGE` refuses
        -- the transfer before a byte of the body arrives. The write callback
        -- is the other half, for a server that declares nothing, and it fails
        -- the same way with the ceiling named in the message.
        local pending = client:send({ url = url("/too-big"), maxBytes = 8 })
        drive(pending, function()
            server:respond(200, "OK", BODY, "text/plain")
        end)

        assert.are.equal("failed", pending.status)
        assert.is_string(pending.error)
        assert.is_truthy(pending.error:find(url("/too-big"), 1, true))
        assert.is_nil(pending.value)
    end)

    it("takes a per-host list to skip TLS on, and nothing broader", function()
        -- There is no `insecure = true`. A wildcard, a port, a scheme and a
        -- URL are all refused, so what a reviewer reads is a list of hosts.
        for _, bad in ipairs({ "*", "", "localhost:8080", "https://example.com", "*.example.com" }) do
            assert.has_error(function()
                http.client({ insecureHosts = { bad } })
            end)
        end

        local allowed = http.client({ insecureHosts = { "dev.example.com" } })
        assert.is_not_nil(allowed)
        allowed:close()
    end)

    it("still settles transfers after the pump loop has been compiled", function()
        -- The one property no single-request test can have. LuaJIT traces a
        -- loop after fifty-six turns, and two things go wrong in compiled code
        -- here: a C callback cannot be entered from a trace at all, and a
        -- variadic call passes its arguments by the wrong ABI on this
        -- platform, so `curl_easy_setopt` quietly stores something other than
        -- what it was given. Both are refused in the module, and this is what
        -- says so: a hundred and twenty transfers, which is twice the
        -- threshold, every one of them settling with its body intact.
        --
        -- Before the refusal this failed from about the sixtieth transfer on,
        -- with the transfer completing inside libcurl and its future never
        -- settling, because the tag identifying it came back with a bit set
        -- that was never in it.
        local completed = 0
        for request = 1, 120 do
            local pending = client:send({ url = url("/compiled") })
            drive(pending, function()
                server:respond(200, "OK", BODY, "text/plain")
            end, 400)
            if pending.status == "ready" and pending.value.body == BODY then
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
        assert.has_error(function()
            client:send({ url = url("/no-length"), bodyBytes = "bytes" })
        end)
    end)
end)
