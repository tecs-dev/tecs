--- Socket lifecycle and HTTP framing for the MCP server: bind and
--- background rebind, connection accept, request parsing, response framing,
--- and the close rules that keep a socket open while a deferred response
--- (screenshot or queued world op) is still pending.

local socket <const> = require("socket")
local logging <const> = require("tecs.utils.logging")
local state <const> = require("tecs2d.mcp.internal.state")

local lt <const> = love.timer
local log <const> = logging.getLogger("tecs-mcp")

local record transport
    install: function(ctx: state.Context)
    startServer: function(port: number)
    --- Accept and answer one pending HTTP request per call; POST /mcp
    --- bodies go to `onMessage`. Also drives the background rebinder.
    processCommands: function(onMessage: function(string))
    sendHttpResponse: function(statusCode: integer, statusText: string, body: string)
    sendHttpAccepted: function()
    cleanup: function()
    --- True while the server socket is bound or the rebinder is pending.
    isActive: function(): boolean
    getBoundPort: function(): number
end

local ctx: state.Context = nil
local server: socket.TCP = nil
local client: socket.TCP = nil
local boundPort: number = nil   -- The port we successfully bound to
-- Port the server still needs to bind (set when startServer exhausts
-- its retries after a restart); processCommands retries once per second.
local pendingBindPort: number = nil
local nextBindAttempt: number = 0

function transport.install(c: state.Context)
    ctx = c
end

function transport.isActive(): boolean
    return server ~= nil or pendingBindPort ~= nil
end

function transport.getBoundPort(): number
    return boundPort
end

function transport.sendHttpResponse(statusCode: integer, statusText: string, body: string)
    if not client then return end
    local header = string.format(
        "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n",
        statusCode, statusText, #body
    )
    client:send(header .. body)
end

function transport.sendHttpAccepted()
    if not client then return end
    client:send("HTTP/1.1 202 Accepted\r\n\r\n")
end

-- Read a complete HTTP request from a socket.
-- Returns method, path, headers, body (or nil on error).
local function readHttpRequest(sock: socket.TCP): (string, string, {string:string}, string)
    -- Read request line with short blocking timeout (full request arrives as one packet)
    sock:settimeout(0.05)

    local requestLine = sock:receive("*l")
    if not requestLine then
        return nil, nil, nil, nil
    end

    local httpMethod, path = requestLine:match("^(%S+)%s+(%S+)")
    if not httpMethod then
        return nil, nil, nil, nil
    end

    -- Read headers
    local headers: {string:string} = {}
    while true do
        local headerLine = sock:receive("*l")
        if not headerLine or headerLine == "" or headerLine == "\r" then
            break
        end
        -- Strip trailing \r if present
        headerLine = headerLine:gsub("\r$", "")
        local key, value = headerLine:match("^([^:]+):%s*(.*)")
        if key then
            headers[key:lower()] = value
        end
    end

    -- Read body based on Content-Length
    local body = ""
    local contentLength = tonumber(headers["content-length"])
    if contentLength and contentLength > 0 then
        body = sock:receive(contentLength as integer) or ""
    end

    return httpMethod, path, headers, body
end

-- Close the current client connection (unless a deferred response is pending)
local function closeClient()
    if ctx.pendingScreenshotId then return end  -- keep connection open for async screenshot
    if ctx.pendingWorldOpResponse then return end  -- keep open for deferred world-op response
    if client then
        if ctx.rstOnClose then
            ctx.rstOnClose = false
            pcall(function()
                client:setoption("linger", {on = true, timeout = 0})
            end)
        end
        pcall(function() client:close() end)
        client = nil
    end
end

--- One bind attempt. Returns true and installs `server` on success;
--- returns false and the bind error otherwise.
local function tryBind(port: number): boolean, string
    server = socket.tcp()
    server:setoption("reuseaddr", true)
    pcall(function() server:setoption("reuseport", true) end)
    -- luasocket-tl-type currently omits bind's return values. Keep the cast
    -- at this dynamic boundary until its declaration exposes them.
    local bind = server.bind as function(socket.TCP, string, integer): integer, string
    local ok, bindErr = bind(server, "127.0.0.1", port as integer)
    if not ok then
        server:close()
        server = nil
        return false, tostring(bindErr)
    end

    server:listen(5)
    server:settimeout(0)
    boundPort = port
    pendingBindPort = nil
    log:info("MCP HTTP server listening on port %d", port as integer)

    -- Update window title to show MCP port
    local currentTitle = love.window.getTitle()
    currentTitle = currentTitle:gsub("%s*%(MCP:.-%)%s*$", "")
    love.window.setTitle(currentTitle .. " (MCP:" .. port .. ")")
    return true, nil
end

function transport.processCommands(onMessage: function(string))
    -- Background rebinder: the previous instance's kernel connection
    -- state can hold the port for up to ~30 seconds after a restart.
    if not server then
        if pendingBindPort and lt.getTime() >= nextBindAttempt then
            nextBindAttempt = lt.getTime() + 1.0
            tryBind(pendingBindPort)
        end
        return
    end

    -- If a pending screenshot was completed, the callback already sent the response
    -- and cleared pendingScreenshotId. Close that connection now.
    if client and not ctx.pendingScreenshotId and not ctx.pendingWorldOpResponse then
        pcall(function() client:close() end)
        client = nil
    end

    -- Don't accept new connections while a screenshot is pending
    if client then return end

    -- Accept a new connection for this request
    local newClient = server:accept()
    if not newClient then return end

    client = newClient

    local httpMethod, path, _, body = readHttpRequest(newClient)
    if not httpMethod then
        pcall(function() newClient:close() end)
        client = nil
        return
    end

    -- Only accept requests to /mcp
    if path ~= "/mcp" then
        transport.sendHttpResponse(404, "Not Found", '{"error":"Not found"}')
        pcall(function() newClient:close() end)
        client = nil
        return
    end

    if httpMethod == "GET" then
        -- SSE not supported; return method not allowed
        transport.sendHttpResponse(405, "Method Not Allowed", '{"error":"GET not supported, use POST"}')
    elseif httpMethod == "POST" then
        if body and body ~= "" then
            onMessage(body)
        else
            transport.sendHttpResponse(400, "Bad Request", '{"error":"Empty body"}')
        end
    else
        transport.sendHttpResponse(405, "Method Not Allowed", '{"error":"Method not allowed"}')
    end

    closeClient()
end

function transport.startServer(port: number)
    -- Rebinding the same port right after an engine restart can race
    -- kernel connection state from the previous instance (TIME_WAIT
    -- entries live up to 30 seconds on macOS and SO_REUSEADDR does not
    -- always bypass them). Retry briefly here, then hand off to the
    -- per-frame rebinder in processCommands so MCP always comes back
    -- once the kernel releases the port.
    local RETRIES <const> = 20
    local RETRY_DELAY <const> = 0.1

    local lastErr: string = nil
    for attempt = 1, RETRIES do
        local ok, bindErr = tryBind(port)
        if ok then return end
        lastErr = bindErr

        if attempt < RETRIES then
            lt.sleep(RETRY_DELAY)
        end
    end

    pendingBindPort = port
    nextBindAttempt = lt.getTime() + 1.0
    log:warn("MCP HTTP server could not bind port %d yet (%s); retrying in the background",
        port as integer, tostring(lastErr))
end

function transport.cleanup()
    if client then
        -- Linger 0 closes with RST instead of FIN, so the accepted
        -- socket leaves no FIN_WAIT/TIME_WAIT state behind. Without it,
        -- an engine restart can fail to rebind the port for seconds
        -- (SO_REUSEADDR does not bypass every lingering state on macOS)
        -- when the restart request's own connection is still draining.
        pcall(function()
            client:setoption("linger", {on = true, timeout = 0})
        end)
        pcall(function() client:close() end)
        client = nil
    end
    if server then
        pcall(function() server:close() end)
        server = nil
    end
    log:info("MCP server stopped")
end

return transport
