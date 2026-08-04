-- Cooperative HTTP over a loopback server. Both ends use ordinary blocking
-- looking calls from tasks; the test loop only stands in for Application's
-- private runtime turn.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local sdl = require("tecs.ffi.sdl3")
local http = require("tecs.io.http")
local httpClients = require("tecs.io.http.clients")
local files = require("tecs.io.files")
local runtime = require("tecs.internal.runtime")
local task = require("tecs.internal.taskruntime")
local URI = require("tecs.io.URI")
local stream = require("tecs.io.stream")

local BODY = "the Rust HTTP runtime streamed this body\n"
local nextPort = 47860

local function listenSomewhere()
    local failures = {}
    for port = nextPort, nextPort + 20 do
        local listener, reason = tecs.io.listen(port)
        if listener ~= nil then
            nextPort = port + 1
            return listener, port
        end
        failures[#failures + 1] = ("%d (%s)"):format(port, reason or "unavailable")
    end
    error("no free port in " .. table.concat(failures, ", "))
end

local function parseRequest(socket)
    local bytes = ""
    while bytes:find("\r\n\r\n", 1, true) == nil do
        local chunk, reason = socket:read(16384)
        assert(chunk, reason)
        assert.is_not.equal("", chunk)
        bytes = bytes .. chunk
    end
    local headEnd = assert(bytes:find("\r\n\r\n", 1, true))
    local head = bytes:sub(1, headEnd - 1)
    local method, path = head:match("^(%u+) (%S+)")
    local length = tonumber(head:lower():match("content%-length:%s*(%d+)")) or 0
    local body = bytes:sub(headEnd + 4)
    while #body < length do
        local chunk, reason = socket:read(length - #body)
        assert(chunk, reason)
        assert.is_not.equal("", chunk)
        body = body .. chunk
    end
    return { method = method, path = path, body = body:sub(1, length) }
end

local function responseHead(status, reason, length, contentType)
    return table.concat({
        ("HTTP/1.1 %d %s\r\n"):format(status, reason),
        ("Content-Type: %s\r\n"):format(contentType or "text/plain"),
        ("Content-Length: %d\r\n"):format(length),
        "Connection: close\r\n\r\n",
    })
end

local function startServer(scheduler, listener, handler)
    return scheduler:spawnImmediate(function()
        local socket, acceptReason = listener:accept()
        assert(socket, acceptReason)
        local request = parseRequest(socket)
        handler(socket, request)
        socket:close()
        return request
    end)
end

local function drive(scheduler, predicate, turns)
    for _ = 1, turns or 3000 do
        runtime.poll()
        scheduler:step()
        if predicate() then
            return true
        end
        sdl.C.SDL_Delay(1)
    end
    return false
end

describe("http.newClient", function()
    local listener, port, client, scheduler

    setup(function()
        assert(sdl.C.SDL_Init(0))
    end)

    teardown(function()
        sdl.C.SDL_Quit()
    end)

    before_each(function()
        listener, port = listenSomewhere()
        client = http.newClient({ userAgent = "tecs-spec/1.0", timeoutMs = 3000 })
        scheduler = task.newScheduler()
    end)

    after_each(function()
        client:close()
        listener:close()
    end)

    local function url(path)
        return assert(URI.new(("http://127.0.0.1:%d%s"):format(port, path)))
    end

    it("has no public pump, Future, or destination-shaped request API", function()
        assert.is_nil(tecs.runtime)
        assert.is_nil(client.pump)
        local request = { url = url("/shape") }
        assert.is_nil(request.into)
        assert.are.equal(1, httpClients.count())
    end)

    it("rejects timeout and size values before the native boundary", function()
        assert.has_error(function()
            http.newClient({ timeoutMs = 0 })
        end)
        assert.has_error(function()
            http.newClient({ maxBytes = -1 })
        end)
        assert.has_error(function()
            client:send({ url = url("/invalid"), maxBytes = -1 })
        end)
    end)

    it("returns at headers and streams the body through a second wait", function()
        local releaseBody = task.newGate()
        local server = startServer(scheduler, listener, function(socket)
            assert(socket:write(responseHead(200, "OK", #BODY)))
            assert(socket:drain(1000))
            releaseBody:wait()
            assert(socket:write(BODY))
            assert(socket:drain(1000))
        end)
        local request = scheduler:spawnImmediate(function()
            return client:send({ url = url("/progressive") })
        end)

        assert.is_true(drive(scheduler, function()
            return request.status ~= "pending"
        end))
        assert.are.equal("ready", request.status, request.error)
        assert.are.equal(200, request.value.status)
        assert.is_true(request.value:ok())
        assert.are.equal("text/plain", request.value.headers["content-type"])
        assert.are.equal(1, client:pending())
        assert.are.equal("pending", server.status)

        local body = scheduler:spawnImmediate(function()
            return assert(request.value.body:readAll(1024))
        end)
        scheduler:step()
        assert.are.equal("pending", body.status)
        releaseBody:complete(true)
        assert.is_true(drive(scheduler, function()
            return body.status ~= "pending"
        end))
        assert.are.equal("ready", body.status, body.error)
        assert.are.equal(BODY, body.value)
        assert.are.equal(0, client:pending())
        assert.are.equal("ready", server.status, server.error)
        request.value.body:close()
    end)

    it("returns non-2xx responses normally", function()
        startServer(scheduler, listener, function(socket)
            assert(socket:write(responseHead(404, "Not Found", #BODY) .. BODY))
            assert(socket:drain(1000))
        end)
        local request = scheduler:spawnImmediate(function()
            local response = client:send({ url = url("/missing") })
            return { response.status, response:ok(), assert(response.body:readAll(1024)) }
        end)

        assert.is_true(drive(scheduler, function()
            return request.status ~= "pending"
        end))
        assert.are.equal("ready", request.status, request.error)
        assert.are.same({ 404, false, BODY }, request.value)
    end)

    it("streams a request body through the same cooperative task", function()
        local server = startServer(scheduler, listener, function(socket, request)
            assert.are.equal("POST", request.method)
            assert.are.equal(BODY, request.body)
            assert(socket:write(responseHead(204, "No Content", 0)))
            assert(socket:drain(1000))
        end)
        local source = tecs.io.newStringStream(BODY, "text/plain")
        local request = scheduler:spawnImmediate(function()
            local response = client:send({ url = url("/upload"), method = "POST", body = source })
            local body = assert(response.body:readAll(1))
            return { response.status, body }
        end)

        assert.is_true(drive(scheduler, function()
            return request.status ~= "pending"
        end))
        assert.are.equal("ready", request.status, request.error)
        assert.are.same({ 204, "" }, request.value)
        assert.are.equal("ready", server.status, server.error)
        source:close()
    end)

    it("streams SDL file bodies on the native HTTP lane", function()
        local path = os.tmpname()
        local handle = assert(io.open(path, "wb"))
        assert(handle:write(BODY))
        handle:close()
        local source = tecs.io.newFileStream(path, "text/plain")
        local server = startServer(scheduler, listener, function(socket, request)
            assert.are.equal("POST", request.method)
            assert.are.equal(BODY, request.body)
            assert(socket:write(responseHead(204, "No Content", 0)))
            assert(socket:drain(1000))
        end)

        local originalOpen = files.open
        files.open = function()
            error("the Lua file reader must not open")
        end
        local ok, reason = pcall(function()
            local request = scheduler:spawnImmediate(function()
                return client:send({ url = url("/file-upload"), method = "POST", body = source }).status
            end)
            assert.is_true(drive(scheduler, function()
                return request.status ~= "pending"
            end))
            assert.are.equal("ready", request.status, request.error)
            assert.are.equal(204, request.value)
            assert.are.equal("ready", server.status, server.error)
        end)
        files.open = originalOpen
        source:close()
        os.remove(path)
        assert(ok, reason)
    end)

    it("parks a composed request reader inside client-owned work", function()
        local release = task.newGate()
        local readInTask = false
        local sent = false
        local reader = {}
        function reader:read()
            readInTask = task.active()
            if sent then
                return ""
            end
            release:wait()
            sent = true
            return BODY
        end
        function reader:close()
            return true
        end
        local source = stream._newReaderStream(reader, "text/plain", #BODY)
        local server = startServer(scheduler, listener, function(socket, request)
            assert.are.equal(BODY, request.body)
            assert(socket:write(responseHead(204, "No Content", 0)))
            assert(socket:drain(1000))
        end)
        local request = scheduler:spawnImmediate(function()
            local response = client:send({ url = url("/composed"), method = "POST", body = source })
            return response.status
        end)

        runtime.poll()
        scheduler:step()
        assert.is_true(readInTask)
        assert.are.equal("pending", request.status)
        assert.are.equal("pending", server.status)

        release:complete(true)
        assert.is_true(drive(scheduler, function()
            return request.status ~= "pending"
        end))
        assert.are.equal("ready", request.status, request.error)
        assert.are.equal(204, request.value)
        assert.are.equal("ready", server.status, server.error)
        source:close()
    end)

    it("keeps every value a repeated response header carries", function()
        local head = table.concat({
            "HTTP/1.1 200 OK\r\n",
            "Content-Type: text/plain\r\n",
            "Set-Cookie: session=abc; Path=/\r\n",
            "Set-Cookie: theme=dark; Path=/\r\n",
            "Vary: Accept\r\n",
            "Vary: Origin\r\n",
            ("Content-Length: %d\r\n"):format(#BODY),
            "Connection: close\r\n\r\n",
        })
        startServer(scheduler, listener, function(socket)
            assert(socket:write(head .. BODY))
            assert(socket:drain(1000))
        end)
        local request = scheduler:spawnImmediate(function()
            local response = client:send({ url = url("/repeated-headers") })
            assert(response.body:readAll(1024))
            return response
        end)

        assert.is_true(drive(scheduler, function()
            return request.status ~= "pending"
        end))
        assert.are.equal("ready", request.status, request.error)
        local response = request.value

        -- Cookies cannot be comma-joined, so the map keeps the first and
        -- `getAll` is the only correct reader.
        assert.are.same({ "session=abc; Path=/", "theme=dark; Path=/" }, response:getAll("Set-Cookie"))
        assert.are.equal("session=abc; Path=/", response.headers["set-cookie"])

        -- Every other repeated field joins per RFC 9110.
        assert.are.equal("Accept, Origin", response.headers["vary"])
        assert.are.same({ "Accept", "Origin" }, response:getAll("vary"))

        assert.are.same({ "text/plain" }, response:getAll("content-type"))
        assert.are.same({}, response:getAll("x-absent"))
        assert.has_error(function()
            response:getAll("")
        end)

        -- The returned array belongs to the caller.
        local taken = response:getAll("vary")
        taken[1] = "mutated"
        assert.are.same({ "Accept", "Origin" }, response:getAll("vary"))
    end)

    it("drains an upload task that suspends while it unwinds", function()
        local parked = task.newGate()
        local entered = false
        local unwound = false
        local reader = {}
        function reader:read()
            entered = true
            local ok, reason = pcall(function()
                return parked:wait()
            end)
            if ok then
                return ""
            end
            -- Cleanup that suspends before the reader rethrows, which is what
            -- a composed body does when its own resources close cooperatively.
            task.yield()
            unwound = true
            task.rethrowCancellation(reason)
            error(reason, 0)
        end
        function reader:close()
            return true
        end
        local source = stream._newReaderStream(reader, "text/plain", #BODY)
        local request = scheduler:spawnImmediate(function()
            return client:send({ url = url("/unwinding-upload"), method = "POST", body = source })
        end)

        assert.is_true(drive(scheduler, function()
            return entered
        end))
        assert.are.equal(1, client:pending())

        client:close()
        assert.is_true(unwound)
        assert.are.equal(0, client:pending())

        scheduler:step()
        assert.are.equal("failed", request.status)
        assert.is_truthy(request.error:find("canceled", 1, true))
        source:close()
    end)

    it("rejects a declared body larger than the request limit", function()
        startServer(scheduler, listener, function(socket)
            assert(socket:write(responseHead(200, "OK", #BODY) .. BODY))
            assert(socket:drain(1000))
        end)
        local request = scheduler:spawnImmediate(function()
            return client:send({ url = url("/too-large"), maxBytes = 8 })
        end)

        assert.is_true(drive(scheduler, function()
            return request.status ~= "pending"
        end))
        assert.are.equal("failed", request.status)
        assert.is_truthy(request.error:find("exceeded 8 bytes", 1, true))
    end)

    it("lets another request finish while one response body is unread", function()
        local chunk = string.rep("x", 64 * 1024)
        local total = 2 * 1024 * 1024
        local server = startServer(scheduler, listener, function(socket)
            assert(socket:write(responseHead(200, "OK", total)))
            for _ = 1, total / #chunk do
                assert(socket:write(chunk))
            end
            assert(socket:drain(3000))
        end)
        local request = scheduler:spawnImmediate(function()
            return client:send({ url = url("/backpressure") })
        end)
        assert.is_true(drive(scheduler, function()
            return request.status ~= "pending"
        end))

        local secondServer = startServer(scheduler, listener, function(socket)
            assert(socket:write(responseHead(200, "OK", #BODY) .. BODY))
            assert(socket:drain(1000))
        end)
        local second = scheduler:spawnImmediate(function()
            local response = client:send({ url = url("/independent") })
            local body = assert(response.body:readAll(1024))
            response.body:close()
            return body
        end)
        assert.is_true(drive(scheduler, function()
            return second.status ~= "pending"
        end, 3000))
        assert.are.equal("ready", second.status, second.error)
        assert.are.equal(BODY, second.value)
        assert.are.equal("ready", secondServer.status, secondServer.error)
        assert.are.equal(1, client:pending())
        request.value.body:close()
        assert.are.equal(0, client:pending())
        drive(scheduler, function()
            return server.status ~= "pending"
        end, 1000)
    end)

    it("drains every chunk after the body queue becomes sparse", function()
        local chunk = ("0123456789abcdef"):rep(4096)
        local total = #chunk * 20
        local server = startServer(scheduler, listener, function(socket)
            assert(socket:write(responseHead(200, "OK", total)))
            for _ = 1, 20 do
                assert(socket:write(chunk))
            end
            assert(socket:drain(3000))
        end)
        local request = scheduler:spawnImmediate(function()
            local response = client:send({ url = url("/sparse-body-queue") })
            return assert(response.body:readAll(total))
        end)

        assert.is_true(drive(scheduler, function()
            return request.status ~= "pending"
        end, 5000))
        assert.are.equal("ready", request.status, request.error)
        assert.are.equal(total, #request.value)
        assert.are.equal(chunk, request.value:sub(1, #chunk))
        assert.are.equal(chunk, request.value:sub(-#chunk))
        assert.are.equal("ready", server.status, server.error)
    end)

    it("cancels a suspended request when its task is canceled", function()
        local request = scheduler:spawnImmediate(function()
            return client:send({ url = url("/never-answered") })
        end)
        assert.are.equal("pending", request.status)
        assert.are.equal(1, client:pending())
        request:cancel("world closed")
        scheduler:step()
        assert.are.equal("canceled", request.status)
        assert.are.equal("world closed", request.error)
        assert.are.equal(0, client:pending())
    end)

    it("rejects forbidden waits before starting native work", function()
        local request = scheduler:spawnImmediate(function()
            task.enterBarrier("deterministic simulation")
            return client:send({ url = url("/forbidden") })
        end)
        assert.are.equal("failed", request.status)
        assert.is_truthy(request.error:find("cannot wait", 1, true))
        assert.are.equal(0, client:pending())
    end)

    it("rejects malformed calls and closed clients at the call site", function()
        assert.has_error(function()
            client:send(nil)
        end)
        assert.has_error(function()
            client:send({})
        end)
        assert.has_error(function()
            client:send({ url = assert(URI.new("file:///not-http")) })
        end)
        client:close()
        assert.has_error(function()
            client:send({ url = url("/closed") })
        end)
    end)
end)

describe("http.plugin", function()
    local listener, port, scheduler, world

    setup(function()
        assert(sdl.C.SDL_Init(0))
    end)

    teardown(function()
        sdl.C.SDL_Quit()
    end)

    before_each(function()
        listener, port = listenSomewhere()
        scheduler = task.newScheduler()
        world = tecs.ecs.newWorld()
        world:addPlugin(http.plugin.install)
    end)

    after_each(function()
        http.plugin.close(world)
        listener:close()
    end)

    it("replaces a request entity with a streaming response", function()
        local endpoint = assert(URI.new(("http://127.0.0.1:%d/plugin"):format(port)))
        startServer(scheduler, listener, function(socket)
            assert(socket:write(responseHead(200, "OK", #BODY) .. BODY))
            assert(socket:drain(1000))
        end)
        local entity = world:spawn(http.plugin.Request({ url = endpoint }))

        local found
        for _ = 1, 3000 do
            runtime.poll()
            scheduler:step()
            world:update(1 / 60)
            found = world:get(entity, http.plugin.Response)
            if found ~= nil then
                break
            end
            sdl.C.SDL_Delay(1)
        end
        assert.is_not_nil(found)
        assert.are.equal(200, found.status)
        assert.is_nil(found.error)
        assert.are.equal(BODY, assert(found.body:readAll(1024)))
        found.body:close()
        assert.is_nil(world:get(entity, http.plugin.Request))
        assert.is_nil(world:get(entity, http.plugin.Pending))
    end)

    it("closes an unread response body when its entity despawns", function()
        local endpoint = assert(URI.new(("http://127.0.0.1:%d/abandoned"):format(port)))
        local total = 2 * 1024 * 1024
        local chunk = string.rep("x", 64 * 1024)
        startServer(scheduler, listener, function(socket)
            assert(socket:write(responseHead(200, "OK", total)))
            for _ = 1, total / #chunk do
                assert(socket:write(chunk))
            end
            socket:drain(3000)
        end)
        local entity = world:spawn(http.plugin.Request({ url = endpoint }))

        local found
        for _ = 1, 3000 do
            runtime.poll()
            scheduler:step()
            world:update(1 / 60)
            found = world:get(entity, http.plugin.Response)
            if found ~= nil then
                break
            end
            sdl.C.SDL_Delay(1)
        end
        assert.is_not_nil(found)
        assert.are.equal(1, http.plugin.clientOf(world):pending())

        world:despawn(entity)
        world:update(1 / 60)
        assert.are.equal(0, http.plugin.clientOf(world):pending())
    end)
end)

describe("the http client registry", function()
    setup(function()
        assert(sdl.C.SDL_Init(0))
    end)

    teardown(function()
        sdl.C.SDL_Quit()
    end)

    it("holds the runtime source once while any client is open", function()
        assert.is_false(runtime.registered("http"), "a previous test left the source registered")

        local first = http.newClient()
        assert.is_true(runtime.registered("http"), "an open client holds the runtime source")

        local second = http.newClient()
        assert.is_true(runtime.registered("http"), "a second client keeps the one registration")
        assert.are.equal(2, httpClients.count())

        first:close()
        assert.is_true(runtime.registered("http"), "the remaining client still holds the source")

        second:close()
        assert.is_false(runtime.registered("http"), "an idle registry releases the source")

        -- The next client registers again from the released state.
        local third = http.newClient()
        assert.is_true(runtime.registered("http"))
        third:close()
        assert.is_false(runtime.registered("http"))
    end)

    it("releases the runtime source when the registry shuts every client down", function()
        assert.is_false(runtime.registered("http"), "a previous test left the source registered")

        local client = http.newClient()
        assert.is_true(runtime.registered("http"))

        httpClients.shutdown()
        assert.are.equal(0, httpClients.count())
        assert.is_false(runtime.registered("http"), "shutdown leaves no source for runtime.shutdown to find")

        -- Closing an already-closed client neither raises nor re-registers.
        client:close()
        assert.is_false(runtime.registered("http"))
    end)
end)
