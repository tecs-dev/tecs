--- Minimal MCP JSON-RPC client over raw TCP for Love2D integration tests.
--- Each call opens one connection, POSTs one JSON-RPC message to /mcp, and
--- reads one HTTP response. The game's MCP server handles a single request
--- per connection and closes it after responding, so no keep-alive handling
--- is needed. Deferred tool responses (run_lua, screenshot) arrive on the
--- same connection one or more frames later; the read timeout covers that.

local socket <const> = require("socket")
local json <const> = require("tecs.utils.json")

local record mcp_client
    record Options
        --- Server host. Defaults to `127.0.0.1`.
        host: string
        --- Server TCP port.
        port: integer
        --- Default per-call timeout in seconds. Individual calls can override.
        timeout: number
    end

    record Client
        host: string
        port: integer
        timeout: number
        nextId: integer

        --- Send one HTTP POST and return its response body or a transport error.
        request: function(self: Client, payload: string, timeout?: number): string | nil, string | nil
        --- Send one JSON-RPC request and return its decoded response.
        rpc: function(self: Client, method: string, params: any, timeout?: number): {string: any} | nil, string | nil
        --- Call a tool and return its decoded envelope or a protocol error.
        tryCall: function(self: Client, tool: string, args?: {string: any}, timeout?: number): {string: any} | nil, string | nil
        --- Call a tool, raising on failure, and return the envelope result.
        call: function(self: Client, tool: string, args?: {string: any}, timeout?: number): {string: any}
        --- Capture and return base64-encoded PNG bytes.
        screenshot: function(self: Client, args?: {string: any}, timeout?: number): string
        --- Poll `ping` until the server answers or the deadline passes.
        waitReady: function(self: Client, seconds: number): boolean, string | nil
    end

    --- Create an MCP client. `port` is required.
    new: function(opts: Options): Client
end

local ClientImpl = {}
local clientMt <const> = {__index = ClientImpl}

function mcp_client.new(opts: mcp_client.Options): mcp_client.Client
    if not opts or not opts.port then
        error("mcp_client.new requires a port")
    end
    local client: mcp_client.Client = setmetatable({
        host = opts.host or "127.0.0.1",
        port = opts.port,
        timeout = opts.timeout or 5,
        nextId = 0,
    } as mcp_client.Client, clientMt as metatable<mcp_client.Client>)
    return client
end

function ClientImpl.request(
    self: mcp_client.Client,
    payload: string,
    timeout?: number
): string | nil, string | nil
    local deadline = timeout or self.timeout
    local sock, sockErr = socket.tcp()
    if not sock then
        return nil, "socket.tcp failed: " .. tostring(sockErr)
    end
    sock:settimeout(deadline as integer)

    local okConnect, connectErr = sock:connect(self.host, self.port)
    if not okConnect then
        sock:close()
        return nil, "connect failed: " .. tostring(connectErr)
    end

    local request = table.concat({
        "POST /mcp HTTP/1.1",
        "Host: " .. self.host .. ":" .. tostring(self.port),
        "Content-Type: application/json",
        "Content-Length: " .. tostring(#payload),
        "",
        payload,
    }, "\r\n")

    local sent, sendErr = sock:send(request)
    if not sent then
        sock:close()
        return nil, "send failed: " .. tostring(sendErr)
    end

    local statusLine, statusErr = sock:receive("*l")
    if not statusLine then
        sock:close()
        return nil, "no response: " .. tostring(statusErr)
    end

    local statusCode = tonumber(statusLine:match("^HTTP/%d%.%d (%d+)"))
    if not statusCode then
        sock:close()
        return nil, "bad status line: " .. statusLine
    end

    local contentLength: integer = nil
    while true do
        local headerLine, headerErr = sock:receive("*l")
        if not headerLine then
            sock:close()
            return nil, "reading headers failed: " .. tostring(headerErr)
        end
        if headerLine == "" then
            break
        end
        local key, value = headerLine:match("^([^:]+):%s*(.*)")
        if key and key:lower() == "content-length" then
            contentLength = tonumber(value) as integer
        end
    end

    local body = ""
    if contentLength and contentLength > 0 then
        local received, bodyErr = sock:receive(contentLength)
        if not received then
            sock:close()
            return nil, "reading body failed: " .. tostring(bodyErr)
        end
        body = received
    end
    sock:close()

    if statusCode ~= 200 and statusCode ~= 202 then
        return nil, "HTTP " .. tostring(statusCode) .. ": " .. body
    end
    return body, nil
end

function ClientImpl.rpc(
    self: mcp_client.Client,
    method: string,
    params: any,
    timeout?: number
): {string: any} | nil, string | nil
    self.nextId = self.nextId + 1
    local message: {string: any} = {
        jsonrpc = "2.0",
        id = self.nextId,
        method = method,
    }
    if params ~= nil then
        message.params = params
    end

    local body, requestErr = self:request(json.serialize(message), timeout)
    if not body then
        return nil, method .. " failed: " .. tostring(requestErr)
    end

    local okParse, parsed = pcall(json.parse, body)
    if not okParse or type(parsed) ~= "table" then
        return nil, method .. " returned unparseable body: " .. body
    end
    return parsed as {string: any}, nil
end

function ClientImpl.tryCall(
    self: mcp_client.Client,
    tool: string,
    args?: {string: any},
    timeout?: number
): {string: any} | nil, string | nil
    local arguments: {string: any} = args
    if not arguments or next(arguments) == nil then
        arguments = json.EMPTY_OBJECT as {string: any}
    end
    local response, rpcErr = self:rpc("tools/call", {
        name = tool,
        arguments = arguments,
    }, timeout)
    if not response then
        return nil, rpcErr
    end
    local presentResponse = response as {string: any}

    local rpcError = presentResponse.error as {string: any}
    if rpcError then
        return nil, tool .. " JSON-RPC error: " .. tostring(rpcError.message)
    end

    local result = presentResponse.result as {string: any}
    if not result then
        return nil, tool .. " response had no result: " .. json.serialize(presentResponse)
    end

    local content = result.content as {{string: any}}
    local first = content and content[1]
    if not first then
        return nil, tool .. " response had no content"
    end

    if first.type == "image" then
        return {ok = true, image = first.data, mimeType = first.mimeType}, nil
    end

    local okParse, envelope = pcall(json.parse, first.text as string)
    if not okParse or type(envelope) ~= "table" then
        return nil, tool .. " returned unparseable envelope: " .. tostring(first.text)
    end
    return envelope as {string: any}, nil
end

function ClientImpl.call(self: mcp_client.Client, tool: string, args?: {string: any}, timeout?: number): {string: any}
    local envelope, callErr = self:tryCall(tool, args, timeout)
    if not envelope then
        error(callErr, 2)
    end
    local presentEnvelope = envelope as {string: any}
    if presentEnvelope.ok == false then
        error(tool .. " returned error: " .. json.serialize(presentEnvelope.error), 2)
    end
    return presentEnvelope.result as {string: any}
end

function ClientImpl.screenshot(self: mcp_client.Client, args?: {string: any}, timeout?: number): string
    local envelope, callErr = self:tryCall("screenshot", args, timeout or 10)
    if not envelope then
        error(callErr, 2)
    end
    local presentEnvelope = envelope as {string: any}
    local image = presentEnvelope.image as string
    if not image then
        error("screenshot returned no image content: " .. json.serialize(presentEnvelope), 2)
    end
    return image
end

function ClientImpl.waitReady(self: mcp_client.Client, seconds: number): boolean, string | nil
    local deadline = socket.gettime() + seconds
    local lastErr: string = "never attempted"
    while socket.gettime() < deadline do
        local envelope, pingErr = self:tryCall("ping", nil, 1)
        if envelope and (envelope as {string: any}).ok then
            return true, nil
        end
        lastErr = pingErr or ("ping envelope: " .. json.serialize(envelope))
        local sleep = socket.sleep as function(number)
        sleep(0.1)
    end
    return false, lastErr
end

return mcp_client
