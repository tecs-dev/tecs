-- The HTTP client, driven the way a frame drives it.
--
-- **No network.** A spec that reached a real host would fail on a machine
-- without one and, worse, fail intermittently on a machine with a bad one. So
-- the other end is a listener this process starts over the public Rust-backed
-- `tecs.io` TCP surface, so the request and the response both stay inside this
-- test. `file://` is not a shortcut: it bypasses Reqwest and
-- cannot prove that work moved to Tokio while futures still settle only when
-- the SDL thread pumps their event queue.
--
-- The server stays on this thread and Reqwest uses its own workers. This loop
-- coordinates them by draining futures only from the calling thread.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local sdl = require("tecs.ffi.sdl3")
local http = require("tecs.io.http")
local httpClients = require("tecs.io.http.clients")
local uri = require("tecs.io.URI")
local task = require("tecs.internal.taskruntime")
local tecsIO = tecs.io

local min = math.min

local BODY = "the rust worker drove this without blocking\n"
local CHUNK = 16384

-- A deliberately small HTTP/1.1 fixture. It is test code rather than an engine
-- protocol: the production MCP server uses rmcp, while these Reqwest specs
-- need arbitrary status lines and malformed responses that MCP would reject.
local TestServer = {}
TestServer.__index = TestServer

local function parseRequest(text)
    local headEnd = text:find("\r\n\r\n", 1, true)
    if headEnd == nil then
        return nil
    end
    local head = text:sub(1, headEnd - 1)
    local method, path = head:match("^(%u+) (%S+)")
    if method == nil then
        return nil
    end
    local length = tonumber(head:lower():match("content%-length:%s*(%d+)")) or 0
    local bodyStart = headEnd + 4
    if #text - bodyStart + 1 < length then
        return nil
    end
    return {
        method = method,
        path = path,
        body = text:sub(bodyStart, bodyStart + length - 1),
    }
end

function TestServer:close()
    if self.client ~= nil then
        self.client:close()
        self.client = nil
    end
    self.pending = ""
end

function TestServer:rawRespond(payload)
    if self.client == nil then
        return
    end
    assert(self.client:write(payload))
    assert(self.client:drain(1000))
    self:close()
end

function TestServer:respond(status, reason, body, contentType)
    self:rawRespond(table.concat({
        ("HTTP/1.1 %d %s\r\n"):format(status, reason),
        ("Content-Type: %s\r\n"):format(contentType or "application/json"),
        ("Content-Length: %d\r\n"):format(#body),
        "Connection: close\r\n\r\n",
        body,
    }))
end

function TestServer:poll(_, handler)
    if self.client == nil then
        self.client = self.listener:accept()
        if self.client == nil then
            return false
        end
    end

    local bytes, reason = self.client:read(CHUNK)
    if reason ~= nil then
        self:close()
        return false
    end
    if bytes == nil then
        return false
    end
    self.pending = self.pending .. bytes
    local request = parseRequest(self.pending)
    if request == nil then
        return false
    end
    handler(request)
    self:close()
    return true
end

function TestServer:destroy()
    self:close()
    self.listener:close()
end

-- Ports are a shared resource on the machine running the suite, so this takes
-- the first free one rather than insisting on a number, and never hands the
-- same one out twice: a listener is built and destroyed per test, and reusing
-- a port would mean a connection an earlier test abandoned arriving at a
-- later test's listener.
local nextPort = 47860

local function listenSomewhere()
    local failures = {}
    for port = nextPort, nextPort + 20 do
        local listener, reason = tecsIO.listen(port)
        if listener ~= nil then
            nextPort = port + 1
            return setmetatable({ listener = listener, client = nil, pending = "" }, TestServer), port
        end
        failures[#failures + 1] = ("%d (%s)"):format(port, reason or "unavailable")
    end
    error("no free port in " .. table.concat(failures, ", "))
end

describe("http.newClient", function()
    local server, port, client, rawClient
    local silent, silentPort

    -- Most transport cases need to drive both ends of the loopback connection
    -- from this Lua thread. Production code calls `Client:send` directly from
    -- a system; this test adapter observes the client's private callback seam
    -- so the fixture can keep pumping its server while a request is pending.
    local function observedClient(raw)
        local methods = {}
        local Pending = {}
        local PendingMT = {
            __index = function(self, key)
                if key == "value" then
                    if self.status == "ready" then
                        return self._value
                    end
                    error(self.error or "the HTTP request is still pending")
                end
                return Pending[key]
            end,
        }

        local function settle(pending, status, value, reason)
            if pending.status ~= "pending" then
                return
            end
            pending.status = status
            pending._value = value
            pending.error = reason
            local listeners = pending._listeners
            pending._listeners = nil
            if listeners ~= nil then
                for index = 1, #listeners do
                    pcall(listeners[index], pending)
                end
            end
        end

        function Pending:onSettle(listener)
            if self.status == "pending" then
                self._listeners = self._listeners or {}
                self._listeners[#self._listeners + 1] = listener
            else
                pcall(listener, self)
            end
            return self
        end

        function Pending:map(transform)
            local derived = setmetatable({ status = "pending" }, PendingMT)
            self:onSettle(function(done)
                if done.status == "ready" then
                    local ok, value = pcall(transform, done._value)
                    settle(derived, ok and "ready" or "failed", ok and value or nil, ok and nil or tostring(value))
                else
                    settle(derived, done.status, nil, done.error)
                end
            end)
            return derived
        end

        function Pending:wait(timeoutMs)
            local remaining = timeoutMs or 30000
            while self.status == "pending" and remaining > 0 do
                local slice = math.min(raw.sliceMs, remaining)
                raw:advance(slice)
                remaining = remaining - slice
            end
            return self
        end

        function Pending:cancel()
            if self.status == "pending" then
                self._cancel()
                settle(self, "canceled", nil, "canceled")
            end
        end

        function methods:send(request)
            local pending = setmetatable({ status = "pending" }, PendingMT)
            pending._cancel = raw:_subscribe(request, function(status, response, reason)
                settle(pending, status, response, reason)
            end)
            return pending
        end

        function methods:cancel(pending)
            pending:cancel()
        end

        return setmetatable(methods, {
            __index = function(_, key)
                local value = raw[key]
                if type(value) == "function" then
                    return function(_, ...)
                        return value(raw, ...)
                    end
                end
                return value
            end,
        })
    end

    it("uses the shared io stream surface", function()
        assert.is_function(tecsIO.newStringStream)

        local buffer = tecsIO.newBuffer()

        assert.is_function(buffer.newStream)

        buffer:close()

        assert.is_function(tecsIO.newByteStream)
        assert.is_function(tecsIO.newFileStream)
        assert.is_function(tecsIO.newHandleStream)
    end)

    setup(function()
        assert(sdl.C.SDL_Init(0))
    end)

    teardown(function()
        sdl.C.SDL_Quit()
    end)

    -- A listener per test, on a port no other test uses. The transport serves
    -- one connection at a time and several tests here deliberately leave one
    -- unanswered, so a shared listener carries an accept queue from each test
    -- into the next. Building the listener per test keeps every request paired
    -- with its own client and makes the suite deterministic.
    before_each(function()
        rawClient = http.newClient({ userAgent = "tecs-spec/1.0" })
        client = observedClient(rawClient)
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
        return uri.new(("http://127.0.0.1:%d%s"):format(port, path))
    end

    --- A URL that connects and is never answered.
    local function silentUrl(path)
        return uri.new(("http://127.0.0.1:%d%s"):format(silentPort, path))
    end

    --- Writes an exact HTTP response for protocol cases `respond` hides.
    local function rawRespond(payload)
        server:rawRespond(payload)
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

    local function partialSink(limit)
        local received = tecsIO.newBuffer()
        local closed = false
        local sink = {}
        function sink:contentLength()
            return received:length()
        end
        function sink:contentType()
            return nil
        end
        function sink:isReadable()
            return false
        end
        function sink:isWritable()
            return true
        end
        function sink:isReplayable()
            return false
        end
        function sink:close()
            closed = true
        end
        function sink:newWriter()
            local writer = {}
            function writer:write()
                error("HTTP should use Writer:writeFrom for response chunks")
            end
            function writer:writeFrom(source, offset, count)
                local taking = min(limit, count)
                received:setString(source:getString(offset, taking), received:length())
                return taking
            end
            function writer:flush()
                return true
            end
            function writer:close()
                closed = true
                return true
            end
            return writer
        end
        function sink:writeAll()
            error("unused")
        end
        function sink:writeBuffer()
            error("unused")
        end
        return sink, received
    end

    local function chunkSource(text, limit)
        local source = {}
        function source:contentLength()
            return #text
        end
        function source:contentType()
            return "application/octet-stream"
        end
        function source:isReadable()
            return true
        end
        function source:isWritable()
            return false
        end
        function source:isReplayable()
            return true
        end
        function source:close() end
        function source:newReader()
            local at = 0
            local closed = false
            local reader = {}
            function reader:read(count)
                if closed then
                    return nil, "reader is closed"
                end
                local taking = min(limit, count, #text - at)
                local bytes = text:sub(at + 1, at + taking)
                at = at + taking
                return bytes
            end
            function reader:readInto(buffer, offset, count)
                if closed then
                    return nil, "reader is closed"
                end
                local taking = min(limit, count or 16 * 1024, #text - at)
                if taking > 0 then
                    buffer:setString(text:sub(at + 1, at + taking), offset or 0)
                    at = at + taking
                end
                return taking
            end
            function reader:close()
                closed = true
            end
            return reader
        end
        function source:readAll()
            error("HTTP should consume the Reader endpoint")
        end
        function source:transferToBuffer()
            error("HTTP should consume the Reader endpoint")
        end
        function source:transferTo()
            error("unused")
        end
        function source:transferToFile()
            error("unused")
        end
        function source:discard()
            error("unused")
        end
        return source
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
        assert.are.equal(BODY, pending.value.body:readAll())
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
        assert.is_true(response.body:isReadable())
        assert.are.equal(BODY, response.body:readAll())
        assert.are.equal(#BODY, response.body:contentLength())
        assert.are.equal("text/plain", response.body:contentType())
        assert.are.equal("text/plain", response.headers["content-type"])
        assert.are.equal(url("/body"):toString(), response.url:toString())
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

    it("sends a shared Buffer without first making a Lua string", function()
        local body = tecsIO.newBuffer(BODY)
        local pending = client:send({
            url = url("/buffer-upload"),
            method = "PUT",
            body = body:newStream("application/octet-stream"),
        })
        local seen = drive(pending, function()
            server:respond(204, "No Content", "", "text/plain")
        end)
        body:close()

        assert.are.equal("ready", pending.status)
        assert.are.equal(BODY, seen.body)
    end)

    it("streams a structural Reader through the bounded upload channel", function()
        local pending = client:send({
            url = url("/reader-upload"),
            method = "PUT",
            headers = { ["Content-Length"] = tostring(#BODY) },
            body = chunkSource(BODY, 5),
        })
        local seen = drive(pending, function()
            server:respond(204, "No Content", "", "text/plain")
        end)

        assert.are.equal("ready", pending.status)
        assert.are.equal(BODY, seen.body)
    end)

    it("does not open a non-replayable reader until native validation succeeds", function()
        local source = chunkSource(BODY, 5)
        local opened = 0
        local original = source.newReader
        function source:isReplayable()
            return false
        end
        function source:newReader()
            opened = opened + 1
            return original(self)
        end

        local pending = client:send({
            url = url("/native-rejection"),
            method = "not a method",
            body = source,
        })

        assert.are.equal("failed", pending.status)
        assert.are.equal(0, opened)
        assert.is_truthy(pending.error:find("cannot start", 1, true))
    end)

    it("cancels a started native upload when its reader cannot open", function()
        local source = chunkSource(BODY, 5)
        local opened = 0
        function source:newReader()
            opened = opened + 1
            return nil, "reader open boom"
        end

        local pending = client:send({
            url = silentUrl("/reader-open-failure"),
            method = "PUT",
            body = source,
        })

        assert.are.equal("failed", pending.status)
        assert.are.equal(1, opened)
        assert.are.equal(0, client:pending())
        assert.is_truthy(pending.error:find("reader open boom", 1, true))
    end)

    it("rejects conflicting Content-Length for every known body backing", function()
        local owned = tecsIO.newBuffer(BODY)
        local bodies = {
            BODY,
            owned:newStream(),
            tecsIO.newByteStream(owned:getFFIPointer(), owned:length()),
            chunkSource(BODY, 5),
        }

        for index, body in ipairs(bodies) do
            local pending = client:send({
                url = url("/length-conflict-" .. index),
                method = "PUT",
                headers = { ["cOnTeNt-LeNgTh"] = tostring(#BODY + 1) },
                body = body,
            })
            assert.are.equal("failed", pending.status)
            assert.is_truthy(pending.error:find("but the request body contains", 1, true))
        end
        owned:close()
    end)

    it("rejects nonzero Content-Length when the request has no body", function()
        local pending = client:send({
            url = url("/missing-body"),
            headers = { ["Content-Length"] = "5" },
        })

        assert.are.equal("failed", pending.status)
        assert.is_truthy(pending.error:find("but the request body contains 0 bytes", 1, true))
        assert.are.equal(0, client:pending())
    end)

    it("rejects malformed Content-Length before opening an upload", function()
        local source = chunkSource(BODY, 5)
        local opened = 0
        local original = source.newReader
        function source:newReader()
            opened = opened + 1
            return original(self)
        end

        for _, value in ipairs({ "-1", "1.5", "+1", "many" }) do
            local pending = client:send({
                url = url("/bad-length"),
                method = "PUT",
                headers = { ["Content-Length"] = value },
                body = source,
            })
            assert.are.equal("failed", pending.status)
            assert.is_truthy(pending.error:find("decimal digits", 1, true))
        end
        assert.are.equal(0, opened)
    end)

    it("rejects invalid or raising lazy body lengths", function()
        local cases = {
            { name = "negative", value = -1 },
            { name = "fractional", value = 1.5 },
            { name = "too-large", value = 9007199254740992 },
            { name = "raising" },
        }
        for _, case in ipairs(cases) do
            local source = chunkSource(BODY, 5)
            local opened = 0
            local original = source.newReader
            function source:newReader()
                opened = opened + 1
                return original(self)
            end
            function source:contentLength()
                if case.name == "raising" then
                    error("metadata boom")
                end
                return case.value
            end

            local pending = client:send({
                url = url("/bad-source-length-" .. case.name),
                method = "PUT",
                body = source,
            })
            assert.are.equal("failed", pending.status)
            assert.are.equal(0, opened)
            assert.is_truthy(pending.error:find("Content-Length", 1, true))
        end
    end)

    it("gives every active upload a bounded scheduler turn", function()
        local bytes = ("x"):rep(CHUNK * 17)
        local readCounts = { 0, 0 }
        local sources = { chunkSource(bytes, CHUNK), chunkSource(bytes, CHUNK) }
        for index, source in ipairs(sources) do
            local original = source.newReader
            function source:newReader()
                local reader = original(self)
                local readInto = reader.readInto
                function reader:readInto(destination, offset, count)
                    readCounts[index] = readCounts[index] + 1
                    return readInto(self, destination, offset, count)
                end
                return reader
            end
        end

        local first = client:send({ url = silentUrl("/fair-one"), method = "PUT", body = sources[1] })
        local second = client:send({ url = silentUrl("/fair-two"), method = "PUT", body = sources[2] })
        client:pump()

        assert.is_true(readCounts[1] > 0)
        assert.is_true(readCounts[2] > 0)
        first:cancel()
        second:cancel()
    end)

    it("rejects Reader counts that cannot safely name initialized bytes", function()
        local cases = {
            { name = "negative", count = -1 },
            { name = "fractional", count = 1.5 },
            { name = "oversized", count = CHUNK + 1 },
            { name = "not-a-number", count = "1" },
            { name = "uninitialized", count = 1 },
        }
        local pending = {}
        for _, case in ipairs(cases) do
            local source = chunkSource(BODY, 5)
            function source:newReader()
                local reader = {}
                function reader:read()
                    error("HTTP should use Reader:readInto")
                end
                function reader:readInto(destination)
                    if case.name ~= "uninitialized" and type(case.count) == "number" and case.count > 0 then
                        destination:setString("x")
                    end
                    return case.count
                end
                function reader:close() end
                return reader
            end
            pending[#pending + 1] = client:send({
                url = silentUrl("/bad-reader-" .. case.name),
                method = "PUT",
                body = source,
            })
        end

        client:pump()
        for index, future in ipairs(pending) do
            assert.are.equal("failed", future.status, cases[index].name)
            assert.is_truthy(future.error:find("request reader returned", 1, true))
        end
    end)

    it("rejects Writer counts outside the offered initialized range", function()
        for _, value in ipairs({ 0, -1, 1.5, #BODY + 1, "1" }) do
            local sink, received = partialSink(3)
            function sink:newWriter()
                local writer = {}
                function writer:write()
                    error("HTTP should use Writer:writeFrom")
                end
                function writer:writeFrom()
                    return value
                end
                function writer:flush()
                    return true
                end
                function writer:close()
                    return true
                end
                return writer
            end
            local pending = client:send({ url = url("/bad-writer"), into = sink })
            drive(pending, function()
                server:respond(200, "OK", BODY, "application/octet-stream")
            end)

            assert.are.equal("failed", pending.status)
            assert.is_truthy(pending.error:find("response writer returned", 1, true))
            received:close()
        end
    end)

    it("settles when opening or closing a structural Writer raises", function()
        local opening, openingBuffer = partialSink(3)
        function opening:newWriter()
            error("writer open boom")
        end
        local openFuture = client:send({ url = url("/writer-open-boom"), into = opening })
        drive(openFuture, function()
            server:respond(200, "OK", BODY, "application/octet-stream")
        end)
        assert.are.equal("failed", openFuture.status)
        assert.is_truthy(openFuture.error:find("writer open boom", 1, true))
        openingBuffer:close()

        local closing, closingBuffer = partialSink(3)
        local newWriter = closing.newWriter
        function closing:newWriter()
            local writer = newWriter(self)
            function writer:close()
                error("writer close boom")
            end
            return writer
        end
        local closeFuture = client:send({ url = url("/writer-close-boom"), into = closing })
        drive(closeFuture, function()
            server:respond(200, "OK", BODY, "application/octet-stream")
        end)
        assert.are.equal("failed", closeFuture.status)
        assert.is_truthy(closeFuture.error:find("writer close boom", 1, true))
        closingBuffer:close()
    end)

    it("fails when destination metadata raises only after completion", function()
        local sink, received = partialSink(3)
        local completed = false
        local newWriter = sink.newWriter
        function sink:newWriter()
            local writer = newWriter(self)
            local close = writer.close
            function writer:close()
                local ok, reason = close(self)
                completed = true
                return ok, reason
            end
            return writer
        end
        function sink:contentType()
            if completed then
                error("destination metadata boom")
            end
            return nil
        end

        local pending = client:send({ url = url("/destination-metadata-boom"), into = sink })
        drive(pending, function()
            server:respond(200, "OK", BODY, "application/octet-stream")
        end)

        assert.are.equal("failed", pending.status)
        assert.are.equal(0, client:pending())
        assert.is_truthy(pending.error:find("destination metadata boom", 1, true))
        received:close()
    end)

    it("preserves the primary transfer failure when Writer cleanup raises", function()
        local sink, received = partialSink(3)
        function sink:newWriter()
            local writer = {}
            function writer:write()
                error("HTTP should use Writer:writeFrom")
            end
            function writer:writeFrom()
                return nil, "primary write failure"
            end
            function writer:flush()
                return true
            end
            function writer:close()
                error("secondary close failure")
            end
            return writer
        end

        local pending = client:send({ url = url("/primary-writer-failure"), into = sink })
        drive(pending, function()
            server:respond(200, "OK", BODY, "application/octet-stream")
        end)

        assert.are.equal("failed", pending.status)
        assert.is_truthy(pending.error:find("primary write failure", 1, true))
        assert.is_nil(pending.error:find("secondary close failure", 1, true))
        received:close()
    end)

    it("retries partial Writer:writeFrom results without losing bytes", function()
        local sink, received = partialSink(3)
        local pending = client:send({ url = url("/partial-writer"), into = sink })
        drive(pending, function()
            server:respond(200, "OK", BODY, "application/octet-stream")
        end)

        assert.are.equal("ready", pending.status)
        assert.are.equal(BODY, received:getString())
        received:close()
    end)

    it("composes, because a request is a future like any other", function()
        local length = client:send({ url = url("/compose") }):map(function(response)
            return response.body:contentLength()
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
        assert.is_true(body:isReadable())
        assert.is_true(body:isWritable())
        assert.are.equal(#BODY, body:contentLength())
        assert.are.equal(BODY, body:readAll())

        local file = assert(io.open(path, "rb"))
        local written = file:read("*a")
        file:close()
        os.remove(path)
        assert.are.equal(BODY, written)
    end)

    it("truncates a file destination for an empty successful response", function()
        local path = os.tmpname()
        local existing = assert(io.open(path, "wb"))
        existing:write(BODY)
        existing:close()

        local pending = client:send({ url = url("/empty-download"), into = path })
        drive(pending, function()
            server:respond(204, "No Content", "", "application/octet-stream")
        end)

        assert.are.equal("ready", pending.status)
        local file = assert(io.open(path, "rb"))
        assert.are.equal("", file:read("*a"))
        file:close()
        os.remove(path)
    end)

    it("writes into a handle as the bytes arrive, never assembling them", function()
        -- `into` streams. Rust's bounded queue holds what has arrived, the pump
        -- hands each chunk to the handle, and the worker cannot outrun that
        -- bound. The whole body is never assembled in Lua or native memory.
        local path = os.tmpname()
        local file = assert(io.open(path, "wb"))
        local pending = client:send({
            url = url("/streamed"),
            into = tecsIO.newHandleStream(file),
        })
        drive(pending, function()
            server:respond(200, "OK", BODY, "application/octet-stream")
        end)
        file:close()

        assert.are.equal("ready", pending.status)
        assert.is_false(pending.value.body:isReplayable())
        assert.are.equal(#BODY, pending.value.body:contentLength())

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
            into = tecsIO.newHandleStream(file),
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
        -- The SDL thread reads bounded pieces into one reusable Buffer. Rust
        -- copies only pieces accepted by its bounded upload channel, so the
        -- background request cannot make Lua materialize the whole file.
        local path = os.tmpname()
        local upload = assert(io.open(path, "wb"))
        upload:write(BODY)
        upload:close()

        local pending = client:send({
            url = url("/upload"),
            method = "PUT",
            body = tecsIO.newFileStream(path, "application/octet-stream"),
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
        local pending = client:send({ url = uri.new("http://127.0.0.1:1/") })
        drive(pending, nil)

        assert.are.equal("failed", pending.status)
        assert.is_string(pending.error)
        assert.is_truthy(pending.error:find("127.0.0.1:1", 1, true))
        assert.has_error(function()
            return pending.value
        end)
    end)

    it("refuses a url that is not http or https", function()
        -- Data rather than a mistake in the program: a URL out of a manifest
        -- settles the future instead of raising at the call site.
        local pending = client:send({ url = uri.new("file:///etc/passwd") })
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
        local pending = client:send({ url = uri.new("http://127.0.0.1:1/") })

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
        assert.has_error(function()
            return pending.value
        end)
    end)

    it("settles a Future canceled directly through its client", function()
        local pending = client:send({ url = url("/client-canceled") })
        assert.are.equal("pending", pending.status)

        client:cancel(pending)
        assert.are.equal("canceled", pending.status)
        assert.are.equal(0, client:pending())
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

    it("rejects a transfer started by a listener during close", function()
        local pending = client:send({ url = silentUrl("/close-listener") })
        local sent
        pending:onSettle(function()
            sent = {
                pcall(function()
                    return client:send({ url = silentUrl("/reentrant-close-send") })
                end),
            }
        end)

        client:close()

        assert.are.equal("canceled", pending.status)
        assert.is_false(sent[1])
        assert.is_truthy(tostring(sent[2]):find("client is closed", 1, true))
        assert.are.equal(0, client:pending())
        assert.is_nil(next(client._byId))
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
        assert.is_truthy(pending.error:find(url("/too-big"):toString(), 1, true))
        assert.has_error(function()
            return pending.value
        end)
    end)

    it("lets a request override maxBytes with unbounded zero", function()
        client:close()
        rawClient = http.newClient({ maxBytes = 8 })
        client = observedClient(rawClient)
        local pending = client:send({ url = url("/unbounded"), maxBytes = 0 })
        drive(pending, function()
            server:respond(200, "OK", BODY, "text/plain")
        end)

        assert.are.equal("ready", pending.status)
        assert.are.equal(BODY, pending.value.body:readAll())
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
            if pending.status == "ready" and pending.value.body:readAll() == BODY then
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
                into = tecsIO.newStringStream("not a destination"),
            })
        end)
    end)

    it("streams upload and download backpressure through one persistent Task", function()
        local sink, received = partialSink(3)
        local scheduler = task.newScheduler()
        local rootTask = scheduler:spawnImmediate(function()
            return rawClient:send({
                url = url("/task-stream"),
                method = "POST",
                body = chunkSource(BODY, 5),
                into = sink,
            })
        end)
        assert.are.equal("pending", rootTask.status)

        local seen
        for turn = 1, 2000 do
            client:pump()
            server:poll(turn * 0.05, function(request)
                seen = request
                server:respond(200, "OK", BODY, "text/plain")
            end)
            scheduler:step()
            if rootTask.status ~= "pending" then
                break
            end
            sdl.C.SDL_Delay(1)
        end

        assert.are.equal("ready", rootTask.status, rootTask.error)
        assert.are.equal(BODY, seen.body)
        assert.are.equal(200, rootTask.value.status)
        assert.are.equal(BODY, received:getString())
        assert.are.equal(0, client:pending())
        received:close()
    end)

    it("cancels an HTTP transfer when its blocked Task is canceled", function()
        local scheduler = task.newScheduler()
        local rootTask = scheduler:spawnImmediate(function()
            return rawClient:send({ url = silentUrl("/task-cancel") })
        end)

        assert.are.equal("pending", rootTask.status)
        assert.are.equal(1, client:pending())
        rootTask:cancel("entity despawned")
        assert.are.equal(0, client:pending())
        assert.are.equal(1, scheduler:step())
        assert.are.equal("canceled", rootTask.status)
        assert.are.equal("entity despawned", rootTask.error)
    end)

    it("finishes a synchronous HTTP rejection without scheduler enrollment", function()
        local scheduler = task.newScheduler()
        local rootTask = scheduler:spawnImmediate(function()
            return rawClient:send({ url = uri.new("file:///not-http") })
        end)

        assert.are.equal("failed", rootTask.status)
        assert.is_truthy(rootTask.error:find("not an http or https url", 1, true))
        assert.are.equal(0, scheduler:step())
        assert.are.equal(0, client:pending())
    end)

    it("does not allocate a public completion object for a direct send", function()
        local scheduler = task.newScheduler()
        local rootTask = scheduler:spawnImmediate(function()
            return rawClient:send({ url = uri.new("file:///task-direct") })
        end)
        assert.are.equal("failed", rootTask.status)
        assert.are.equal(0, rawClient:pending())
    end)

    it("transparently suspends a run system for HTTP", function()
        local world = tecs.ecs.newWorld()
        local Loaded = tecs.ecs.newComponent({
            name = "HttpTaskSystemLoaded",
            container = {},
            fields = { "status" },
            defaults = { 0 },
        })
        local entity = world:spawn(Loaded(0))
        world:addSystem({
            name = "LoadManifest",
            phase = tecs.ecs.phases.Update,
            run = function(_, taskWorld)
                local response = rawClient:send({ url = url("/task-system") })
                taskWorld:set(entity, Loaded, Loaded(response.status))
            end,
        })

        world:update(1 / 60)
        assert.is_true(world._updateStalled)
        assert.are.equal(0, world:get(entity, Loaded).status)
        for turn = 1, 2000 do
            client:pump()
            server:poll(turn * 0.05, function()
                server:respond(204, "No Content", "", "text/plain")
            end)
            world:update(1 / 60)
            if not world._updateStalled then
                break
            end
            sdl.C.SDL_Delay(1)
        end

        assert.are.equal(204, world:get(entity, Loaded).status)
        assert.is_false(world._updateStalled)
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
                httpClients.pump()
                server:poll(turn * 0.05, function()
                    server:respond(200, "OK", BODY, "text/plain")
                end)
                if pending.status ~= "pending" then
                    break
                end
                sdl.C.SDL_Delay(1)
            end

            assert.are.equal("ready", pending.status)
            assert.are.equal(BODY, pending.value.body:readAll())
        end)

        it("stops turning a client once it is closed", function()
            -- Closing is what ends a client's place in a frame; dropping the
            -- last reference to one deliberately does not, or a request nobody
            -- kept would stop moving whenever a collection happened to run.
            local before = http.getOpenClientCount()
            local extra = observedClient(http.newClient({ userAgent = "tecs-spec/1.0" }))
            assert.are.equal(before + 1, http.getOpenClientCount())

            local pending = extra:send({ url = silentUrl("/never-answered") })
            extra:close()
            assert.are.equal(before, http.getOpenClientCount())
            assert.are.equal("canceled", pending.status)

            -- And the list turns without it rather than reaching a closed
            -- client, which is what a stale entry would look like.
            assert.are.equal(0, httpClients.pump())
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
                httpClients.pump()
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
            assert.are.equal(BODY, response.body:readAll())
            assert.is_nil(response.error)
            -- The request is gone, so a system that reacts to one does not see
            -- the same one twice.
            assert.is_nil(world:get(entity, http.plugin.Request))
        end)

        it("answers a transfer that failed with a Response carrying why", function()
            world = tecs.ecs.newWorld()
            world:addPlugin(http.plugin.install)

            -- Nothing on port 1, so the transfer fails rather than answering.
            local entity = world:spawn(http.plugin.Request({
                url = uri.new("http://127.0.0.1:1/"),
            }))
            local response = turn(entity, http.plugin.Response)

            assert.is_not_nil(response)
            assert.are.equal(0, response.status)
            assert.is_string(response.error)
            assert.is_true(response.body:isReadable())
            assert.are.equal(0, response.body:contentLength())
            assert.are.equal("", response.body:readAll())
            assert.are.equal("http://127.0.0.1:1/", response.url:toString())
        end)

        -- What a save does with a request that has not answered yet. The future
        -- behind one is listeners and a source, so it is not a component field
        -- and `Pending` is a transient marker: a save carries the `Request` and
        -- not the marker, which is what makes the load coherent.
        describe("and a snapshot", function()
            -- Spawns a request the silent listener accepts and never answers,
            -- so the transfer is still open when the snapshot is taken.
            local function unanswered()
                local entity = world:spawn(http.plugin.Request({ url = silentUrl("/never-answered") }))
                world:update(1 / 60)
                assert.is_not_nil(world:get(entity, http.plugin.Pending))
                assert.are.equal(1, http.plugin.clientOf(world):pending())
                return entity
            end

            it("saves a world with a request in flight", function()
                world = tecs.ecs.newWorld()
                world:addPlugin(http.plugin.install)
                unanswered()

                -- The binary format is what a save file is, and it is where a
                -- future reached through a component field fails: the encoder
                -- walks the listener graph rather than refusing the component.
                local ok, saved = pcall(world.saveSnapshot, world)
                assert.is_true(ok, tostring(saved))

                local named = {}
                for _, entry in
                    ipairs(world:saveSnapshot({
                        format = "table",
                    }).snapshot.componentTable)
                do
                    named[entry.name] = true
                end
                assert.is_true(named["tecs.http.Request"])
                assert.is_nil(named["tecs.http.Pending"])
            end)

            it("sends a saved request again after a load", function()
                world = tecs.ecs.newWorld()
                world:addPlugin(http.plugin.install)

                -- The answering listener, but nothing polls it yet, so the
                -- transfer is open when the snapshot is taken and the world the
                -- snapshot loads into can still be given a response.
                local entity = world:spawn(http.plugin.Request({ url = url("/scores") }))
                world:update(1 / 60)
                assert.is_not_nil(world:get(entity, http.plugin.Pending))
                local saved = world:saveSnapshot()

                http.plugin.close(world)
                world = tecs.ecs.newWorld()
                world:addPlugin(http.plugin.install)
                world:loadSnapshot(saved)

                -- The request came back and the marker did not, so the entity
                -- that asked is in front of the plugin again rather than waiting
                -- on a transfer that ended with the world that started it.
                assert.is_not_nil(world:get(entity, http.plugin.Request))
                assert.is_nil(world:get(entity, http.plugin.Pending))

                local response = turn(entity, http.plugin.Response)
                assert.is_not_nil(response)
                assert.are.equal(200, response.status)
                assert.are.equal(BODY, response.body:readAll())
            end)

            it("stops a transfer the load left nothing to receive", function()
                world = tecs.ecs.newWorld()
                world:addPlugin(http.plugin.install)

                local empty = world:saveSnapshot()
                unanswered()

                -- A load replaces the world in place and despawns nothing, so
                -- the entity that asked is gone without the despawn observer
                -- hearing about it and no marker is left to drive the future to
                -- a `Response`. The transfer stops rather than running for
                -- nobody.
                world:loadSnapshot(empty)
                assert.are.equal(0, http.plugin.clientOf(world):pending())
            end)

            it("stops a transfer whose requester was despawned", function()
                world = tecs.ecs.newWorld()
                world:addPlugin(http.plugin.install)

                local entity = unanswered()
                world:despawn(entity)
                world:enqueueCommit()

                assert.are.equal(0, http.plugin.clientOf(world):pending())
            end)
        end)
    end)
end)

describe("http.plugin snapshots", function()
    local function only(world, component)
        local query = world:newQuery({ include = { component } })
        for archetype, length in query:iter() do
            assert.are.equal(1, length)
            return archetype:get(component)[1]
        end
        return nil
    end

    for _, format in ipairs({ "table", "binary" }) do
        for _, field in ipairs({ "body", "into" }) do
            it("rejects a handle-backed request " .. field .. " in a " .. format .. " snapshot", function()
                local world = tecs.ecs.newWorld()
                local handle = assert(io.tmpfile())
                local stream = tecsIO.newHandleStream(handle)
                local request = {
                    url = uri.new("https://example.com/upload"),
                    [field] = stream,
                }
                world:spawn(http.plugin.Request(request))

                local ok, failure = pcall(world.saveSnapshot, world, { format = format })
                handle:close()

                assert.is_false(ok)
                assert.matches(
                    "tecs: cannot snapshot tecs.http.Request " .. field .. ": io.newHandleStream is runtime%-only",
                    tostring(failure)
                )
            end)
        end

        it("round-trips shared streams in a " .. format .. " snapshot", function()
            local world = tecs.ecs.newWorld()
            local requestHeaders = { ["authorization"] = "before-save" }
            local responseHeaders = { ["content-type"] = "text/plain", ["x-state"] = "before-save" }
            world:spawn(http.plugin.Request({
                url = uri.new("https://example.test/upload"),
                method = "POST",
                headers = requestHeaders,
                body = tecsIO.newStringStream(BODY, "text/plain"),
            }))
            world:spawn(http.plugin.Response({
                status = 0,
                headers = responseHeaders,
                body = tecsIO.newEmptyStream(),
                url = uri.new("https://example.test/upload"),
                error = "saved failure",
            }))
            local saved = world:saveSnapshot({ format = format })
            requestHeaders.authorization = "after-save"
            responseHeaders["x-state"] = "after-save"

            local restored = tecs.ecs.newWorld()
            restored:loadSnapshot(saved)
            local request = only(restored, http.plugin.Request)
            assert.is_not_nil(request)
            assert.are.equal("before-save", request.headers.authorization)
            assert.are.equal(BODY, request.body:readAll())
            assert.are.equal("text/plain", request.body:contentType())
            assert.are.equal(#BODY, request.body:contentLength())

            local response = only(restored, http.plugin.Response)
            assert.are.equal("before-save", response.headers["x-state"])
            assert.are.equal(0, response.body:contentLength())
            assert.are.equal("", response.body:readAll())
            assert.are.equal("saved failure", response.error)

            request.headers.authorization = "after-load"
            response.headers["x-state"] = "after-load"
            if format == "table" then
                local restoredAgain = tecs.ecs.newWorld()
                restoredAgain:loadSnapshot(saved)
                assert.are.equal("before-save", only(restoredAgain, http.plugin.Request).headers.authorization)
                assert.are.equal("before-save", only(restoredAgain, http.plugin.Response).headers["x-state"])
            end
        end)
    end
end)
