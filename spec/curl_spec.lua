-- The libcurl binding, driven through the multi interface.
--
-- What is worth proving is not that the library loads. It is that a transfer
-- can be driven to completion without the calling thread ever waiting, since
-- that is the whole reason the multi interface is bound rather than the easy
-- one alone: `curl_easy_perform` does not return until the transfer is over,
-- and a frame that does not end until the network answers is not a frame.
--
-- **No network.** A spec that reached a real host would fail on a machine
-- without one and, worse, would fail intermittently on a machine with a bad
-- one. So the other end is a listener this process starts: `tecs.mcp.transport`
-- is already a non-blocking HTTP server over SDL3_net, so the request and the
-- response both stay inside this process and inside this test. curl's
-- `file://` support would have been the other option and was not taken: it is
-- disabled in the pinned build, so a spec resting on it would pass against a
-- system libcurl and fail against a packaged one, and it would prove nothing
-- about sockets, which is where blocking actually happens.
--
-- The proof of non-blocking is the first `curl_multi_perform` returning while
-- the transfer is still running, before the listener has so much as accepted
-- the connection. A blocking implementation cannot produce that state.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local ffi = require("ffi")
local sdl = require("tecs.ffi.sdl3")
local curl = require("tecs.ffi.curl")
local transport = require("tecs.mcp.transport")

local C = curl.C

-- A body long enough to be interesting and short enough to arrive in one read.
local BODY = "the multi interface drove this without blocking\n"

-- Ports are a shared resource on the machine running the suite, so this takes
-- the first free one rather than insisting on a number.
local function listenSomewhere()
    local failures = {}
    for port = 47820, 47840 do
        local ok, server = pcall(transport.listen, port)
        if ok then
            return server, port
        end
        failures[#failures + 1] = tostring(port)
    end
    error("no free port in " .. table.concat(failures, ", "))
end

-- Drives the transfer and the listener together until curl says it is done.
--
-- Both halves are non-blocking, so this is one loop rather than two threads.
-- `curl_multi_wait` with a one-millisecond cap keeps it off a hot spin without
-- ever waiting long enough to matter.
local function driveTransfer(url, listener, respond)
    local multi = C.curl_multi_init()
    local easy = C.curl_easy_init()

    local chunks = {}
    local writeCallback = ffi.cast("curl_write_callback", function(buffer, size, nitems, _)
        local length = tonumber(size) * tonumber(nitems)
        chunks[#chunks + 1] = ffi.string(buffer, length)
        return length
    end)

    C.curl_easy_setopt(easy, C.CURLOPT_URL, url)
    C.curl_easy_setopt(easy, C.CURLOPT_WRITEFUNCTION, writeCallback)
    -- A `long` option through a variadic call has to be a `long`. A bare Lua
    -- number arrives as a double and is read as eight bytes of nonsense.
    C.curl_easy_setopt(easy, C.CURLOPT_TIMEOUT_MS, ffi.new("long", 5000))
    C.curl_multi_add_handle(multi, easy)

    local running = ffi.new("int[1]")
    local ready = ffi.new("int[1]")
    local firstStillRunning, turns, served = nil, 0, false

    repeat
        local code = C.curl_multi_perform(multi, running)
        assert.are.equal(0, tonumber(code), curl.multiErrorText(code))
        if firstStillRunning == nil then
            firstStillRunning = tonumber(running[0])
        end
        if listener ~= nil and not served then
            served = listener:poll(turns * 0.001, respond)
        end
        C.curl_multi_wait(multi, nil, 0, 1, ready)
        turns = turns + 1
    until running[0] == 0 or turns > 5000

    local remaining = ffi.new("int[1]")
    local message = C.curl_multi_info_read(multi, remaining)
    local status = ffi.new("long[1]")
    C.curl_easy_getinfo(easy, C.CURLINFO_RESPONSE_CODE, status)

    local result = {
        body = table.concat(chunks),
        status = tonumber(status[0]),
        turns = turns,
        firstStillRunning = firstStillRunning,
        served = served,
        done = message ~= nil and tonumber(message.msg) == tonumber(C.CURLMSG_DONE),
        code = message ~= nil and tonumber(message.data.result) or -1,
    }

    C.curl_multi_remove_handle(multi, easy)
    C.curl_easy_cleanup(easy)
    C.curl_multi_cleanup(multi)
    -- The cast owns a callback slot from a small fixed pool, and libcurl would
    -- call it after collection if it were merely dropped.
    writeCallback:free()
    return result
end

describe("ffi.curl", function()
    local server, port

    setup(function()
        assert(sdl.C.SDL_Init(0))
        C.curl_global_init(curl.K.CURL_GLOBAL_DEFAULT)
        server, port = listenSomewhere()
    end)

    teardown(function()
        if server then
            server:destroy()
        end
        C.curl_global_cleanup()
        sdl.C.SDL_Quit()
    end)

    it("resolves libcurl and reports what it linked", function()
        assert.is_string(curl.path)
        assert.is_not_nil(C.curl_easy_init)
        -- The banner names the version, the TLS backend and the zlib beside
        -- it, which is what tells a development preset from a packaged one.
        assert.is_truthy(curl.version():find("libcurl/", 1, true))
    end)

    it("gives CURLoption constants the values the C compiler computes", function()
        -- These are not plain enumerators. curl writes each one as its type's
        -- base plus an index, so the binding is only right if LuaJIT evaluated
        -- `10000 + 2` the way the compiler did. One from each base, since a
        -- broken evaluation would go wrong per base rather than per option.
        assert.are.equal(41, tonumber(C.CURLOPT_VERBOSE)) -- LONG, base 0
        assert.are.equal(10002, tonumber(C.CURLOPT_URL)) -- OBJECTPOINT, 10000
        assert.are.equal(20011, tonumber(C.CURLOPT_WRITEFUNCTION)) -- FUNCTIONPOINT
        assert.are.equal(30117, tonumber(C.CURLOPT_MAXFILESIZE_LARGE)) -- OFF_T
        assert.are.equal(40291, tonumber(C.CURLOPT_SSLCERT_BLOB)) -- BLOB
        assert.are.equal(2097154, tonumber(C.CURLINFO_RESPONSE_CODE)) -- 0x200000 + 2
        assert.are.equal(20001, tonumber(C.CURLMOPT_SOCKETFUNCTION))
        -- And the bases themselves, which are #defines and so come from the
        -- separately recovered constants table rather than through `C`.
        assert.are.equal(10000, curl.K.CURLOPTTYPE_OBJECTPOINT)
        assert.are.equal(20000, curl.K.CURLOPTTYPE_FUNCTIONPOINT)
        assert.are.equal(40000, curl.K.CURLOPTTYPE_BLOB)
    end)

    it("drives a transfer to completion without ever blocking", function()
        local url = ("http://127.0.0.1:%d/spec"):format(port)
        local seen = nil
        local result = driveTransfer(url, server, function(request)
            seen = request
            server:respond(200, "OK", BODY, "text/plain")
        end)

        assert.is_true(result.served)
        assert.are.equal("GET", seen.method)
        assert.are.equal("/spec", seen.path)

        assert.are.equal(200, result.status)
        assert.are.equal(BODY, result.body)
        assert.is_true(result.done)
        assert.are.equal(0, result.code)

        -- The transfer was still running when the first perform returned, and
        -- it took more than one turn of the loop to finish. Together those say
        -- the work was spread across calls rather than done inside one.
        assert.are.equal(1, result.firstStillRunning)
        assert.is_true(result.turns > 1)
    end)

    it("reports a refused connection as a CURLcode rather than raising", function()
        -- Port 1 on loopback with nothing on it, so this fails without ever
        -- leaving the machine. A transport error has to arrive as a result
        -- code on the message queue, since that is the only place the multi
        -- interface reports one.
        local result = driveTransfer("http://127.0.0.1:1/", nil, nil)
        assert.is_true(result.done)
        assert.are_not.equal(0, result.code)
        assert.is_string(curl.errorText(ffi.cast("CURLcode", result.code)))
    end)
end)
