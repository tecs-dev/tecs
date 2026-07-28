--- HTTP framing over SDL3_net, polled rather than blocking.
---
--- MCP speaks JSON-RPC over HTTP POST. The whole server therefore has to fit
--- inside one call per frame that never waits, because the thing being
--- debugged is a game loop: a transport that blocked on accept would stall the
--- frame it exists to observe.
---
--- SDL3_net suits that: `NET_AcceptClient` returns immediately with a null
--- client when nobody is waiting, and `NET_ReadFromStreamSocket` returns what
--- has arrived rather than what was asked for. So a request may span several
--- calls, and this keeps a buffer per connection until the body is complete.
---
--- One connection is served at a time. A debugger is one client, and a queue
--- of pending sockets would be state to reason about for no benefit.

local sdl <const> = require("tecs.ffi.sdl3")
local net <const> = require("tecs.ffi.sdl3net")
local loader <const> = require("tecs.ffi.loader")
local log <const> = require("tecs.log")

local C <const> = net.C
local LOGGER <const> = log.get("tecs.mcp")

--- Read chunk, in bytes. Requests are small; bodies that exceed this arrive
--- over several reads and are joined.
local CHUNK <const> = 16384

--- Given up on after this long without the body arriving, so a half-open
--- connection cannot hold the single client slot forever. In the units of the
--- clock `poll` is handed, which the engine keeps in seconds.
local REQUEST_TIMEOUT <const> = 10.0

--- One HTTP request at a time, framed out of a non-blocking socket.
---
--- Nothing here waits, so a `Server` is driven by calling `poll` once a frame
--- from the phase that owns it. The per-connection state is unsynchronized, so
--- one thread has to own a given server; none of this is reached from a worker.
local record transport
    --- A complete request. Nothing is exposed until the whole body has
    --- arrived, so no field is a partial value.
    record Request
        --- Uppercase, as it came off the wire. The line is matched against
        --- `%u+`, so a lowercase method never produces a `Request` at all;
        --- it is reported as malformed instead.
        method: string
        --- The request target exactly as sent, such as `"/"` or `"/mcp"`. Not
        --- URL-decoded, and any query string is still attached.
        path: string
        --- Exactly the byte count `Content-Length` declared. Empty when that
        --- header was absent or zero, and never nil.
        body: string
    end

    --- A listening socket plus the one connection it is currently serving.
    record Server
        --- The TCP port bound. The port that was asked for, since binding
        --- never falls back to a different one.
        port: integer
        --- Private. The listening socket, nil once `destroy` has run.
        _handle: loader.CPtr
        --- Private. The accepted connection, or nil when none is being
        --- served, which is what lets the next `poll` accept a new one.
        _client: loader.CPtr
        --- Private. Bytes received for the current request so far, headers
        --- included, accumulated across polls until a whole request is in it.
        _pending: string
        --- Private. The `now` that `poll` was given when the current
        --- connection was accepted, so the timeout is measured in the
        --- caller's clock rather than a wall clock read here.
        _since: number
        --- Private. Reusable read buffer of `CHUNK` bytes, overwritten by
        --- every read and never handed out.
        _buffer: loader.CArray
        --- Private. Set by `destroy`. Once true, `poll` does nothing and
        --- answers false, and the server cannot be brought back.
        _destroyed: boolean
    end
end

local ServerMT <const>: metatable<transport.Server> = {__index = transport.Server}

local started = false

--- Brings SDL3_net up once. Safe to call repeatedly.
local function ensure()
    if started then
        return
    end
    if not C.NET_Init() then
        error(("tecs: NET_Init failed: %s"):format(sdl.error()), 3)
    end
    started = true
end

--- Binds a server to `port`, or raises.
---
--- No retry loop and no port scanning: a debugger that silently moved would be
--- worse than one that did not start, since the thing connecting to it has
--- only the port it was told.
---
--- @param port TCP port. A port already in use raises here rather than being
---     worked around, and the message carries SDL's reason.
--- @return A server already listening; there is no separate start step. It
---     accepts nothing until `poll` is called, so a client connecting before
---     the first poll waits in the kernel's backlog rather than being refused.
function transport.listen(port: integer): transport.Server
    ensure()

    local handle = C.NET_CreateServer(nil, port, 0)
    if handle == nil then
        error(("tecs: cannot listen on port %d: %s"):format(port, sdl.error()), 2)
    end

    local self = setmetatable({} as transport.Server, ServerMT)
    self.port = port
    self._handle = handle
    self._client = nil
    self._pending = ""
    self._since = 0.0
    self._buffer = loader.newArray("uint8_t[?]", CHUNK)
    self._destroyed = false
    LOGGER:info("listening on port %d", port)
    return self
end

--- Splits headers from body, returning nil while the request is incomplete.
---
--- Only Content-Length framing is handled. MCP posts a JSON body and always
--- declares its length; chunked encoding would be a client going out of its
--- way to be difficult.
local function parse(text: string): transport.Request, boolean
    local headEnd = text:find("\r\n\r\n", 1, true)
    if headEnd == nil then
        return nil, false
    end

    local head = text:sub(1, headEnd - 1)
    local method, path = head:match("^(%u+) (%S+)")
    if method == nil then
        return nil, true
    end

    local length = math.floor(tonumber(head:lower():match("content%-length:%s*(%d+)")) or 0) as integer
    local bodyStart = headEnd + 4
    local available = #text - bodyStart + 1
    if available < length then
        return nil, false
    end

    return {
        method = method,
        path = path,
        body = text:sub(bodyStart, bodyStart + length - 1),
    }, false
end

--- Drops the current connection.
---
--- A no-op when none is open, and it leaves the listening socket up, so the
--- next `poll` accepts a new client. Anything already buffered for the current
--- request is discarded rather than carried over.
function transport.Server:close()
    if self._client == nil then
        return
    end
    C.NET_DestroyStreamSocket(self._client)
    self._client = nil
    self._pending = ""
end

--- Writes a response and closes, since each request gets its own connection.
---
--- The write is not checked for a partial send: `NET_WriteToStreamSocket`
--- queues the whole buffer and drains it in the background, which is the
--- difference from a raw socket and the reason there is no resume loop here.
---
--- A no-op when no connection is open, so a handler that answers twice sends
--- once. The drain is given 1000 milliseconds, SDL's unit here rather than the
--- seconds `poll` works in, and a peer that has not read by then loses the tail.
---
--- @param status HTTP status code, sent as given; nothing here maps it to a
---     reason or decides that a 4xx should carry a different body.
--- @param reason The reason phrase, verbatim on the status line. Not derived
---     from `status`, so the two can disagree and nothing notices.
--- @param body Sent as-is, and its byte length becomes `Content-Length`, so it
---     has to be encoded already. An empty string sends a zero-length body.
--- @param contentType Defaults to `"application/json"`.
function transport.Server:respond(status: integer, reason: string, body: string, contentType?: string)
    if self._client == nil then
        return
    end
    local payload = table.concat({
        ("HTTP/1.1 %d %s\r\n"):format(status, reason),
        ("Content-Type: %s\r\n"):format(contentType or "application/json"),
        ("Content-Length: %d\r\n"):format(#body),
        "Connection: close\r\n\r\n",
        body,
    })
    C.NET_WriteToStreamSocket(self._client, payload, #payload)
    -- Drain before closing, or the peer sees a reset instead of the answer.
    C.NET_WaitUntilStreamSocketDrained(self._client, 1000)
    self:close()
end

--- Accepts and reads without waiting, calling `handler` with a whole request.
---
--- Returns true when a request was dispatched. `now` is the engine clock, used
--- only to time out a connection that stopped mid-request.
---
--- At most one request per call, and at most `CHUNK` bytes read per call, so a
--- body larger than that needs as many polls as it needs chunks. A malformed
--- request is answered with 400 here rather than reaching `handler`.
---
--- @param now Monotonic, in the same units as `REQUEST_TIMEOUT`, which is
---     seconds. Only ever used as a difference, so the epoch does not matter.
--- @param handler Called on the calling thread, at most once, and only with a
---     complete request. Its return value is ignored, and the connection is
---     closed after it returns whether or not it answered, so a handler that
---     means to reply has to do so before returning.
--- @return True only when `handler` ran. False covers every other outcome
---     alike: no client waiting, a request still arriving, a malformed one,
---     a peer that went away, and a server already destroyed.
function transport.Server:poll(now: number, handler: function(transport.Request)): boolean
    if self._destroyed then
        return false
    end

    if self._client == nil then
        local out = loader.newArray("NET_StreamSocket *[1]")
        if not C.NET_AcceptClient(self._handle, out) then
            LOGGER:warn("accept failed: %s", sdl.error())
            return false
        end
        if out[0] == nil then
            return false
        end
        self._client = out[0] as loader.CPtr
        self._pending = ""
        self._since = now
    end

    local read = tonumber(C.NET_ReadFromStreamSocket(self._client, self._buffer, CHUNK)) as integer
    if read < 0 then
        -- The peer went away mid-request.
        self:close()
        return false
    end
    if read > 0 then
        self._pending = self._pending .. loader.toBytes(self._buffer as loader.CValue, read)
    end

    local request, malformed = parse(self._pending)
    if malformed then
        self:respond(400, "Bad Request", '{"error":"malformed request"}')
        return false
    end
    if request == nil then
        if now - self._since > REQUEST_TIMEOUT then
            LOGGER:warn("dropping a connection that never finished its request")
            self:close()
        end
        return false
    end

    handler(request)
    -- A handler that answered has already closed; one that did not gets a
    -- closed socket rather than a leaked one.
    self:close()
    return true
end

--- Releases the server and any connection. Safe to call more than once.
---
--- One way: the port is given up and the server cannot be made to listen
--- again. Every later `poll` answers false without touching the socket.
function transport.Server:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    self:close()
    C.NET_DestroyServer(self._handle)
    self._handle = nil
end

return transport
