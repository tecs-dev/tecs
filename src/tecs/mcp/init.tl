--- MCP server: JSON-RPC over HTTP, answered from a phase.
---
--- The surface is a registry. A tool is a name, a schema and a function, and
--- everything an agent can do is something registered here, so the tool list
--- is generated from the same table that dispatches. There is no second list
--- to keep in step, which is what went wrong often enough elsewhere to be
--- worth designing against.
---
--- Answering happens inside `update`, on the game's own thread, so a tool
--- reads and writes the world without locking and without a frame boundary in
--- the middle of it. The cost is that a tool must not block: it is running
--- during a frame someone is watching.

local cjson <const> = require("cjson")
local clock <const> = require("tecs.platform.clock")
local log <const> = require("tecs.log")
local transport <const> = require("tecs.mcp.transport")

local LOGGER <const> = log.get("tecs.mcp")

--- JSON-RPC error codes, as the specification numbers them.
local PARSE_ERROR <const> = -32700
local INVALID_REQUEST <const> = -32600
local METHOD_NOT_FOUND <const> = -32601
local INTERNAL_ERROR <const> = -32603

local record mcp
    --- What a tool receives and returns. Arguments arrive decoded; the result
    --- is encoded as the tool's structured content.
    type Handler = function(arguments: {string: any}): {string: any}

    record Tool
        name: string
        description: string
        --- JSON Schema for the arguments, sent verbatim in the tool list.
        inputSchema: {string: any}
        handler: Handler
        --- Declared so an agent can tell what a call will do before making it.
        readOnly: boolean
        destructive: boolean
        --- Still callable after the game has crashed. False by default,
        --- because a crashed world cannot answer anything about itself, and a
        --- tool that read it would return nonsense rather than an error.
        whenCrashed: boolean
    end

    record Server
        port: integer
        _transport: transport.Server
        _destroyed: boolean
    end
end

local ServerMT <const>: metatable<mcp.Server> = { __index = mcp.Server }

local tools <const>: {string: mcp.Tool} = {}
local order <const>: {string} = {}

--- Traceback of a gameplay crash, once one has happened.
---
--- The server outliving the game is the point. An agent that was debugging
--- something up to the moment it broke should get the reason, not a refused
--- connection, and the tools that do not touch the world keep working so it
--- can still read the log and ask what the build was.
local crashed: string = nil

--- Records a crash. Every subsequent world-touching call reports it.
function mcp.setCrashed(traceback: string)
    crashed = traceback
end

--- The crash traceback, or nil while the game is healthy.
function mcp.crashed(): string
    return crashed
end

--- Registers a tool. Re-registering a name replaces it.
function mcp.register(tool: mcp.Tool)
    if tool.name == nil or tool.handler == nil then
        error("tecs2d: a tool needs a name and a handler", 2)
    end
    if tools[tool.name] == nil then
        order[#order + 1] = tool.name
    end
    tools[tool.name] = tool
end

--- Every registered tool, in registration order.
function mcp.tools(): {mcp.Tool}
    local list: {mcp.Tool} = {}
    for index = 1, #order do list[index] = tools[order[index]] end
    return list
end

--- The tool list as MCP describes it.
local function describe(): {any}
    local list: {any} = {}
    for _, tool in ipairs(mcp.tools()) do
        list[#list + 1] = {
            name = tool.name,
            description = tool.description or "",
            inputSchema = tool.inputSchema
                or { type = "object", properties = cjson.empty_array },
            annotations = {
                readOnlyHint = tool.readOnly == true,
                destructiveHint = tool.destructive == true,
                --- Not an MCP annotation; ours, so an agent can tell which
                --- tools remain after a crash without calling them.
                whenCrashedHint = tool.whenCrashed == true,
            },
        }
    end
    -- An empty list has to say so, or it encodes as an object and a client
    -- parsing it strictly rejects the response.
    if #list == 0 then return cjson.empty_array as {any} end
    return list
end

local function reply(id: any, result: {string: any}): string
    return cjson.encode({ jsonrpc = "2.0", id = id, result = result })
end

local function fail(id: any, code: integer, message: string): string
    return cjson.encode({
        jsonrpc = "2.0",
        id = id,
        error = { code = code, message = message },
    })
end

--- Runs one JSON-RPC request and returns the response text.
---
--- Exposed so the protocol can be tested without a socket, which is most of
--- what there is to get wrong here.
function mcp.dispatch(text: string): string
    local ok, decoded = pcall(cjson.decode, text)
    if not ok then
        return fail(cjson.null, PARSE_ERROR, "invalid JSON")
    end

    local request = decoded as {string: any}
    local id = request.id
    local method = request.method as string
    if method == nil then
        return fail(id, INVALID_REQUEST, "no method")
    end

    if method == "initialize" then
        return reply(id, {
            protocolVersion = "2025-06-18",
            capabilities = { tools = {} },
            serverInfo = { name = "tecs", version = "0.1.0" },
        })
    elseif method == "tools/list" then
        return reply(id, { tools = describe() })
    elseif method == "tools/call" then
        local params = (request.params or {}) as {string: any}
        local name = params.name as string
        local tool = name ~= nil and tools[name] or nil
        if tool == nil then
            return fail(id, METHOD_NOT_FOUND,
                ("no tool named '%s'"):format(tostring(name)))
        end

        if crashed ~= nil and not tool.whenCrashed then
            return reply(id, {
                isError = true,
                crashed = true,
                content = { { type = "text", text = crashed } },
            })
        end

        local arguments = (params.arguments or {}) as {string: any}
        -- A tool that raises must not take the server with it: the agent is
        -- told, the frame carries on.
        local called, payload = pcall(tool.handler, arguments)
        if not called then
            LOGGER:warn("tool %s failed: %s", name, tostring(payload))
            return reply(id, {
                isError = true,
                content = { { type = "text", text = tostring(payload) } },
            })
        end

        local structured = (payload or {}) as {string: any}
        return reply(id, {
            structuredContent = structured,
            content = { { type = "text", text = cjson.encode(structured) } },
        })
    end

    return fail(id, METHOD_NOT_FOUND, ("no method '%s'"):format(method))
end

--- Starts the server on `port`.
function mcp.listen(port?: integer): mcp.Server
    local self = setmetatable({} as mcp.Server, ServerMT)
    self.port = port or 7100
    self._transport = transport.listen(self.port)
    self._destroyed = false
    return self
end

--- Answers at most one request. Call once per frame.
function mcp.Server:poll(): boolean
    if self._destroyed then return false end
    return self._transport:poll(clock.now(), function(request: transport.Request)
        if request.method ~= "POST" then
            self._transport:respond(405, "Method Not Allowed",
                '{"error":"POST only"}')
            return
        end
        local ok, response = pcall(mcp.dispatch, request.body)
        if not ok then
            LOGGER:error("dispatch failed: %s", tostring(response))
            self._transport:respond(500, "Internal Server Error",
                fail(cjson.null, INTERNAL_ERROR, tostring(response)))
            return
        end
        self._transport:respond(200, "OK", response as string)
    end)
end

--- Releases the server. Safe to call more than once.
function mcp.Server:destroy()
    if self._destroyed then return end
    self._destroyed = true
    self._transport:destroy()
end

return mcp
