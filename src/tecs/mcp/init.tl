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

local data <const> = require("tecs.data")
local time <const> = require("tecs.platform.time")
local log <const> = require("tecs.log")
local transport <const> = require("tecs.mcp.transport")

local LOGGER <const> = log.get("tecs.mcp")

--- JSON-RPC error codes, as the specification numbers them.
local PARSE_ERROR <const> = -32700
local INVALID_REQUEST <const> = -32600
local METHOD_NOT_FOUND <const> = -32601
local INTERNAL_ERROR <const> = -32603

--- The tool registry, and the JSON-RPC server that dispatches it.
---
--- The registry is module-wide rather than per-server: `register` and `tools`
--- act on one table, so every server started here answers the same list and
--- destroying a server leaves the registrations standing.
---
--- A handler runs on the game thread, inside the `poll` that read the request,
--- which is to say partway through the update that called it. That is what
--- lets a tool read and write the world without locking, and it is also why a
--- tool must not block: the frame does not end until the handler returns.
local record mcp
    --- What a tool receives and returns. Arguments arrive decoded; the result
    --- is encoded as the tool's structured content.
    type Handler = function(arguments: {string: any}): {string: any}

    --- One registered tool: what it is called, how it is described to an
    --- agent, and what runs when the agent calls it.
    record Tool
        --- The name an agent calls, and the registry key. Established MCP
        --- tool names are spelled the way the protocol's ecosystem spells
        --- them, `run_lua` and `send_event` among them, so they are
        --- snake_case where the rest of this tree is camelCase; that is
        --- deliberate and is not to be renamed. Required.
        name: string
        --- One line shown to the agent alongside the name. Optional: nil is
        --- sent as an empty string rather than omitted.
        description: string
        --- JSON Schema for the arguments, sent verbatim in the tool list.
        inputSchema: {string: any}
        --- Runs on the game thread when the tool is called. Required, and its
        --- absence raises at registration rather than at call time.
        handler: Handler
        --- Declared so an agent can tell what a call will do before making it.
        readOnly: boolean
        --- Whether a call changes state that a caller would not want changed
        --- without asking. Optional, false when nil. Advisory, like
        --- `readOnly`: both are reported to the agent and neither is checked
        --- here, so a tool declared read-only is still free to write.
        destructive: boolean
        --- Still callable after the game has crashed. False by default,
        --- because a crashed world cannot answer anything about itself, and a
        --- tool that read it would return nonsense rather than an error.
        whenCrashed: boolean
    end

    --- A listening MCP endpoint. Answers only while something calls `poll`.
    record Server
        --- The TCP port bound, which is 7100 when `listen` was given none.
        port: integer
        --- Private. The HTTP framing underneath, which owns the socket.
        _transport: transport.Server
        --- Private. Set by `destroy`. Once true, `poll` answers false and the
        --- server cannot be restarted.
        _destroyed: boolean
    end
end

local ServerMT <const>: metatable<mcp.Server> = {__index = mcp.Server}

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
---
--- @param traceback Stored as given and handed back verbatim by `crashed`,
---     and sent as the whole body of the error a blocked tool answers with.
---     Passing nil clears the crashed state and lets every tool run again.
function mcp.setCrashed(traceback: string)
    crashed = traceback
end

--- The crash traceback, or nil while the game is healthy.
---
--- @return nil means no crash has been recorded, which is the only sense in
---     which the game is known to be healthy: nothing here polls for one.
function mcp.crashed(): string
    return crashed
end

--- Registers a tool. Re-registering a name replaces it.
---
--- Replacing keeps the name's original position in the list, so the order a
--- client sees is first-registration order rather than last.
---
--- @param tool Stored by reference and never copied, so mutating the table
---     afterwards changes what the server dispatches and reports. `name` and
---     `handler` are required and their absence raises; the rest may be nil.
function mcp.register(tool: mcp.Tool)
    if tool.name == nil or tool.handler == nil then
        error("tecs: a tool needs a name and a handler", 2)
    end
    if tools[tool.name] == nil then
        order[#order + 1] = tool.name
    end
    tools[tool.name] = tool
end

--- Every registered tool, in registration order.
---
--- @return A fresh list each call, so the caller may keep it. The `Tool`
---     values in it are the registered tables themselves rather than copies,
---     so writing to one writes to the registry.
function mcp.tools(): {mcp.Tool}
    local list: {mcp.Tool} = {}
    for index = 1, #order do
        list[index] = tools[order[index]]
    end
    return list
end

--- The tool list as MCP describes it.
local function describe(): {any}
    local list: {any} = {}
    for _, tool in ipairs(mcp.tools()) do
        list[#list + 1] = {
            name = tool.name,
            description = tool.description or "",
            inputSchema = tool.inputSchema or {type = "object", properties = data.empty_array},
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
    if #list == 0 then
        return data.empty_array as {any}
    end
    return list
end

local function reply(id: any, result: {string: any}): string
    return data.encodeJSON({jsonrpc = "2.0", id = id, result = result})
end

local function fail(id: any, code: integer, message: string): string
    return data.encodeJSON({
        jsonrpc = "2.0",
        id = id,
        error = {code = code, message = message},
    })
end

--- Runs one JSON-RPC request and returns the response text.
---
--- Exposed so the protocol can be tested without a socket, which is most of
--- what there is to get wrong here.
---
--- The three methods answered, `initialize`, `tools/list` and `tools/call`,
--- are spelled as the MCP specification spells them and are not this tree's to
--- rename. Anything else is a method-not-found error.
---
--- A handler that raises is caught: the agent is told through `isError` and
--- the server carries on. A handler that returns nil is not an error, and
--- comes back as an empty `structuredContent`.
---
--- @param text One JSON-RPC request object. A batch, that is a JSON array, is
---     not supported; it decodes, has no `method`, and comes back as an
---     invalid-request error rather than being fanned out.
--- @return Always a response as JSON text, never nil, and never a raise, since
---     bad input is reported in-band. A request that carried no `id` is still
---     answered, with the `id` field absent from the response.
function mcp.dispatch(text: string): string
    local ok, decoded = pcall(data.decodeJSON, text)
    if not ok then
        return fail(data.null, PARSE_ERROR, "invalid JSON")
    end

    local request = decoded as {string: any}
    local id = request.id
    local method = request.method as string
    if method == nil then
        return fail(id, INVALID_REQUEST, "no method")
    end

    if method == "initialize" then
        return reply(
            id,
            {
                protocolVersion = "2025-06-18",
                capabilities = {tools = {}},
                serverInfo = {name = "tecs", version = "0.1.0"},
            }
        )
    elseif method == "tools/list" then
        return reply(id, {tools = describe()})
    elseif method == "tools/call" then
        local params = (request.params or {}) as {string: any}
        local name = params.name as string
        local tool = name ~= nil and tools[name] or nil
        if tool == nil then
            return fail(id, METHOD_NOT_FOUND, ("no tool named '%s'"):format(tostring(name)))
        end

        if crashed ~= nil and not tool.whenCrashed then
            return reply(
                id,
                {
                    isError = true,
                    crashed = true,
                    content = {{type = "text", text = crashed}},
                }
            )
        end

        local arguments = (params.arguments or {}) as {string: any}
        -- A tool that raises must not take the server with it: the agent is
        -- told, the frame carries on.
        local called, payload = pcall(tool.handler, arguments)
        if not called then
            LOGGER:warn("tool %s failed: %s", name, tostring(payload))
            return reply(
                id,
                {
                    isError = true,
                    content = {{type = "text", text = tostring(payload)}},
                }
            )
        end

        local structured = (payload or {}) as {string: any}
        return reply(
            id,
            {
                structuredContent = structured,
                content = {{type = "text", text = data.encodeJSON(structured)}},
            }
        )
    end

    return fail(id, METHOD_NOT_FOUND, ("no method '%s'"):format(method))
end

--- Starts the server on `port`.
---
--- @param port Defaults to 7100. A port already in use raises rather than
---     being worked around, since a debugger that moved could not be found.
--- @return Listening, but answering nothing until something calls `poll`.
function mcp.listen(port?: integer): mcp.Server
    local self = setmetatable({} as mcp.Server, ServerMT)
    self.port = port or 7100
    self._transport = transport.listen(self.port)
    self._destroyed = false
    return self
end

--- Answers at most one request. Call once per frame.
---
--- Reads the clock itself, so no time is passed in. Only POST is accepted;
--- anything else is answered 405 without reaching `dispatch`.
---
--- @return True when a request was answered, which includes one answered with
---     a 405 or a JSON-RPC error. False when nothing was waiting, when a
---     request is still arriving, or when the server has been destroyed.
function mcp.Server:poll(): boolean
    if self._destroyed then
        return false
    end
    return self._transport:poll(
        time.now(),
        function(request: transport.Request)
            if request.method ~= "POST" then
                self._transport:respond(405, "Method Not Allowed", '{"error":"POST only"}')
                return
            end
            local ok, response = pcall(mcp.dispatch, request.body)
            if not ok then
                LOGGER:error("dispatch failed: %s", tostring(response))
                self._transport:respond(
                    500, "Internal Server Error", fail(data.null, INTERNAL_ERROR, tostring(response))
                )
                return
            end
            self._transport:respond(200, "OK", response as string)
        end
    )
end

--- Releases the server. Safe to call more than once.
---
--- One way: the port is given up and the server cannot be made to listen
--- again. The tool registry is module-wide and is left untouched, so a later
--- `listen` answers the same tools.
function mcp.Server:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    self._transport:destroy()
end

return mcp
